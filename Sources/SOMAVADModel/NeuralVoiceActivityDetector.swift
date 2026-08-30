import CoreML
import Foundation

private let somaVADResourceBundle: Bundle = {
    let bundleName = "SOMA_SOMAVADModel.bundle"
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(bundleName),
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true),
        Bundle.main.bundleURL.appendingPathComponent(bundleName, isDirectory: true),
    ]
    for case let candidate? in candidates {
        if let bundle = Bundle(url: candidate) { return bundle }
    }
    return Bundle.module
}()

public enum NeuralVoiceActivityError: LocalizedError {
    case missingModel
    case unsupportedSampleRate(Double)
    case malformedModelOutput(String)

    public var errorDescription: String? {
        switch self {
        case .missingModel:
            return "Bundled Silero VAD Core ML model is unavailable"
        case .unsupportedSampleRate(let rate):
            return "Silero VAD requires an integer multiple of 16 kHz input, got \(rate) Hz"
        case .malformedModelOutput(let name):
            return "Silero VAD returned an invalid \(name) output"
        }
    }
}

public struct NeuralVoiceActivityEvidence: Sendable {
    public let active: Bool
    public let probability: Double
    public let changed: Bool
    public let inferenceMS: Double
    public let windowStartNS: UInt64
    public let windowEndNS: UInt64
    public let discontinuityReset: Bool

    public init(
        active: Bool,
        probability: Double,
        changed: Bool,
        inferenceMS: Double,
        windowStartNS: UInt64,
        windowEndNS: UInt64,
        discontinuityReset: Bool = false
    ) {
        self.active = active
        self.probability = probability
        self.changed = changed
        self.inferenceMS = inferenceMS
        self.windowStartNS = windowStartNS
        self.windowEndNS = windowEndNS
        self.discontinuityReset = discontinuityReset
    }
}

public final class NeuralVoiceActivityDetector: @unchecked Sendable {
    public static let targetSampleRateHz = 16_000.0
    public static let windowSampleCount = 4_160
    public static let defaultActivationThreshold = 0.5

    public let computeUnits = "cpu_and_neural_engine"
    public private(set) var warmupMS = 0.0

    private let model: MLModel
    private let hiddenState: MLMultiArray
    private let cellState: MLMultiArray
    private var pendingSamples: [Float] = []
    private var pendingStartNS: UInt64?
    private var active = false
    private var holdUntilNS: UInt64 = 0
    private let activationThreshold: Double

    public init(activationThreshold: Double = NeuralVoiceActivityDetector.defaultActivationThreshold) throws {
        precondition((0...1).contains(activationThreshold))
        self.activationThreshold = activationThreshold
        guard let modelURL = somaVADResourceBundle.url(
            forResource: "SileroVAD256ms",
            withExtension: "mlmodelc"
        ) else {
            throw NeuralVoiceActivityError.missingModel
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        hiddenState = try MLMultiArray(shape: [1, 128], dataType: .float32)
        cellState = try MLMultiArray(shape: [1, 128], dataType: .float32)

        let startedNS = DispatchTime.now().uptimeNanoseconds
        _ = try predict(Array(repeating: 0, count: Self.windowSampleCount))
        warmupMS = Double(DispatchTime.now().uptimeNanoseconds - startedNS) / 1_000_000
        reset()
    }

    public func ingest(
        samples: [Float],
        sampleRateHz: Double,
        continuous: Bool,
        at monotonicNS: UInt64,
        durationNS: UInt64? = nil
    ) throws -> [NeuralVoiceActivityEvidence] {
        var evidence: [NeuralVoiceActivityEvidence] = []
        let inferredDurationNS = UInt64(
            max(0, (Double(samples.count) / sampleRateHz * 1_000_000_000).rounded())
        )
        let inputDurationNS = durationNS ?? inferredDurationNS
        let inputStartNS = monotonicNS >= inputDurationNS
            ? monotonicNS - inputDurationNS
            : 0
        if !continuous {
            if active {
                active = false
                evidence.append(NeuralVoiceActivityEvidence(
                    active: false,
                    probability: 0,
                    changed: true,
                    inferenceMS: 0,
                    windowStartNS: inputStartNS,
                    windowEndNS: inputStartNS,
                    discontinuityReset: true
                ))
            }
            reset()
        }
        let downsampled = try downsampleTo16K(samples, sampleRateHz: sampleRateHz)
        if pendingSamples.isEmpty { pendingStartNS = inputStartNS }
        pendingSamples.append(contentsOf: downsampled)

        while pendingSamples.count >= Self.windowSampleCount {
            let window = Array(pendingSamples.prefix(Self.windowSampleCount))
            pendingSamples.removeFirst(Self.windowSampleCount)
            let windowStartNS = pendingStartNS ?? inputStartNS
            let windowDurationNS = UInt64(
                (Double(Self.windowSampleCount) / Self.targetSampleRateHz * 1_000_000_000).rounded()
            )
            let (candidateEndNS, overflow) = windowStartNS.addingReportingOverflow(windowDurationNS)
            let windowEndNS = overflow ? UInt64.max : candidateEndNS
            pendingStartNS = windowEndNS
            let startedNS = DispatchTime.now().uptimeNanoseconds
            let probability = try predict(window)
            let inferenceMS = Double(DispatchTime.now().uptimeNanoseconds - startedNS) / 1_000_000
            let previous = active
            if probability >= activationThreshold {
                active = true
                holdUntilNS = monotonicNS + 520_000_000
            } else if active, monotonicNS >= holdUntilNS {
                active = false
            }
            evidence.append(NeuralVoiceActivityEvidence(
                active: active,
                probability: probability,
                changed: active != previous,
                inferenceMS: inferenceMS,
                windowStartNS: windowStartNS,
                windowEndNS: windowEndNS
            ))
        }
        return evidence
    }

    public func reset() {
        pendingSamples.removeAll(keepingCapacity: true)
        pendingStartNS = nil
        active = false
        holdUntilNS = 0
        zero(hiddenState)
        zero(cellState)
    }

    private func downsampleTo16K(_ samples: [Float], sampleRateHz: Double) throws -> [Float] {
        let ratio = Int((sampleRateHz / Self.targetSampleRateHz).rounded())
        guard ratio >= 1,
              abs(sampleRateHz - Double(ratio) * Self.targetSampleRateHz) < 0.1 else {
            throw NeuralVoiceActivityError.unsupportedSampleRate(sampleRateHz)
        }
        guard ratio > 1 else { return samples }
        var result: [Float] = []
        result.reserveCapacity(samples.count / ratio)
        for start in stride(from: 0, to: samples.count - ratio + 1, by: ratio) {
            var sum: Float = 0
            for offset in 0..<ratio { sum += samples[start + offset] }
            result.append(sum / Float(ratio))
        }
        return result
    }

    private func predict(_ samples: [Float]) throws -> Double {
        let audio = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSampleCount)], dataType: .float32)
        let audioPointer = audio.dataPointer.assumingMemoryBound(to: Float.self)
        for index in samples.indices { audioPointer[index] = samples[index] }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": audio,
            "hidden_state": hiddenState,
            "cell_state": cellState,
        ])
        let output = try model.prediction(from: input)
        guard let probabilityArray = output.featureValue(for: "vad_output")?.multiArrayValue,
              probabilityArray.count == 1 else {
            throw NeuralVoiceActivityError.malformedModelOutput("vad_output")
        }
        guard let nextHiddenState = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
              nextHiddenState.count == hiddenState.count else {
            throw NeuralVoiceActivityError.malformedModelOutput("new_hidden_state")
        }
        guard let nextCellState = output.featureValue(for: "new_cell_state")?.multiArrayValue,
              nextCellState.count == cellState.count else {
            throw NeuralVoiceActivityError.malformedModelOutput("new_cell_state")
        }
        copy(nextHiddenState, to: hiddenState)
        copy(nextCellState, to: cellState)
        let probability = probabilityArray.dataPointer.assumingMemoryBound(to: Float.self)[0]
        guard probability.isFinite else {
            throw NeuralVoiceActivityError.malformedModelOutput("vad_output")
        }
        return min(max(Double(probability), 0), 1)
    }

    private func zero(_ array: MLMultiArray) {
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        for index in 0..<array.count { pointer[index] = 0 }
    }

    private func copy(_ source: MLMultiArray, to destination: MLMultiArray) {
        let sourcePointer = source.dataPointer.assumingMemoryBound(to: Float.self)
        let destinationPointer = destination.dataPointer.assumingMemoryBound(to: Float.self)
        for index in 0..<source.count { destinationPointer[index] = sourcePointer[index] }
    }
}
