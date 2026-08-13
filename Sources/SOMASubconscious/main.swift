@preconcurrency import AVFoundation
import AudioToolbox
import CoreML
import CoreMedia
import CoreVideo
import Foundation
import SOMACore
import SOMAVADModel
@preconcurrency import Vision

private enum RuntimeError: LocalizedError {
    case invalidArgument(String)
    case unavailable(String)
    case unauthorized(String)
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message),
                .unavailable(let message),
                .unauthorized(let message),
                .configuration(let message):
            return message
        }
    }
}

private struct Options {
    let duration: TimeInterval
    let videoID: String
    let audioID: String
    let outputURL: URL
    let guidedScenario: Bool
    let tdoaCalibrationURL: URL?
    let tdoaCalibrationOutputURL: URL?

    static func parse(_ arguments: [String]) throws -> Options {
        var duration: TimeInterval = 60
        var videoID: String?
        var audioID: String?
        var outputURL = defaultOutputURL()
        var guidedScenario = false
        var tdoaCalibrationURL: URL?
        var tdoaCalibrationOutputURL: URL?
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--duration":
                index += 1
                guard index < arguments.count,
                      let parsed = TimeInterval(arguments[index]),
                      parsed > 0 else {
                    throw RuntimeError.invalidArgument("--duration must be a positive number of seconds")
                }
                duration = parsed
            case "--video-id":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--video-id requires the OBSBOT video unique ID")
                }
                videoID = arguments[index]
            case "--audio-id":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--audio-id requires the OBSBOT microphone unique ID")
                }
                audioID = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--output requires a trace path")
                }
                outputURL = URL(fileURLWithPath: arguments[index])
            case "--guided-scenario":
                guidedScenario = true
            case "--tdoa-calibration":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--tdoa-calibration requires a calibration JSON path")
                }
                tdoaCalibrationURL = URL(fileURLWithPath: arguments[index])
            case "--tdoa-calibrate":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--tdoa-calibrate requires an output JSON path")
                }
                tdoaCalibrationOutputURL = URL(fileURLWithPath: arguments[index])
            case "--help", "-h":
                printUsage()
                Foundation.exit(EXIT_SUCCESS)
            default:
                throw RuntimeError.invalidArgument("Unknown argument: \(arguments[index])")
            }
            index += 1
        }

        guard let videoID, let audioID else {
            throw RuntimeError.invalidArgument("--video-id and --audio-id are required. Use `swift run soma-probe --list-formats` first.")
        }
        if guidedScenario, duration != GuidedScenarioPhase.duration {
            throw RuntimeError.invalidArgument("--guided-scenario requires --duration 50")
        }
        if tdoaCalibrationOutputURL != nil, duration != TDOACalibrationPhase.duration {
            throw RuntimeError.invalidArgument("--tdoa-calibrate requires --duration 45")
        }
        if guidedScenario, tdoaCalibrationOutputURL != nil {
            throw RuntimeError.invalidArgument("--guided-scenario and --tdoa-calibrate cannot run together")
        }
        if tdoaCalibrationURL != nil, tdoaCalibrationOutputURL != nil {
            throw RuntimeError.invalidArgument("Choose either --tdoa-calibration or --tdoa-calibrate")
        }
        return Options(
            duration: duration,
            videoID: videoID,
            audioID: audioID,
            outputURL: outputURL,
            guidedScenario: guidedScenario,
            tdoaCalibrationURL: tdoaCalibrationURL,
            tdoaCalibrationOutputURL: tdoaCalibrationOutputURL
        )
    }

    private static func defaultOutputURL() -> URL {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/subconscious/subconscious-\(stamp).jsonl")
    }
}

private struct GuidedScenarioPhase {
    static let duration: TimeInterval = 50

    let startsAfterSeconds: TimeInterval
    let state: String
    let instruction: String

    static let phases = [
        GuidedScenarioPhase(startsAfterSeconds: 0, state: "prepare_out_of_frame", instruction: "0-5s: move fully outside the frame and become silent"),
        GuidedScenarioPhase(startsAfterSeconds: 5, state: "quiet_out_of_frame", instruction: "5-15s: remain outside the frame and silent"),
        GuidedScenarioPhase(startsAfterSeconds: 15, state: "enter_and_move", instruction: "15-25s: enter the frame and move normally"),
        GuidedScenarioPhase(startsAfterSeconds: 25, state: "speak_to_camera", instruction: "25-35s: face the camera and speak normally"),
        GuidedScenarioPhase(startsAfterSeconds: 35, state: "exit_and_silence", instruction: "35-45s: leave the frame and remain silent"),
        GuidedScenarioPhase(startsAfterSeconds: 45, state: "settle", instruction: "45-50s: remain out of frame and silent")
    ]
}

private struct TDOACalibrationPhase {
    static let duration: TimeInterval = 45

    let startsAfterSeconds: TimeInterval
    let position: TDOACalibrationPosition
    let instruction: String

    static let phases = [
        TDOACalibrationPhase(startsAfterSeconds: 0, position: .left, instruction: "0-15s: stand left of camera, face it, and speak naturally"),
        TDOACalibrationPhase(startsAfterSeconds: 15, position: .center, instruction: "15-30s: stand centered on camera, face it, and speak naturally"),
        TDOACalibrationPhase(startsAfterSeconds: 30, position: .right, instruction: "30-45s: stand right of camera, face it, and speak naturally")
    ]
}

private struct DeviceIdentity: Codable, Sendable {
    let name: String
    let uniqueID: String
    let modelID: String?
}

private struct VideoConfiguration {
    let requested: String
    let applied: Bool
    let detail: String
}

private struct RuntimeEvent: Encodable, Sendable {
    let event: String
    let monotonicNS: UInt64
    let source: String
    let state: String
    let message: String?
}

private struct BeliefEvent: Encodable, Sendable {
    let event = "subconscious.belief"
    let monotonicNS: UInt64
    let reason: String
    let belief: BeliefSnapshot
}

private struct VoiceEvent: Encodable, Sendable {
    let event = "voice.activity"
    let monotonicNS: UInt64
    let source: String
    let active: Bool
    let confidence: Double
    let levelDB: Double
}

private struct AudioDirectionEvent: Encodable, Sendable {
    let event = "audio.direction"
    let monotonicNS: UInt64
    let direction: AudioDirection
    let confidence: Double
    let lagSamples: Int
    let fractionalLagSamples: Double
    let delayMilliseconds: Double
    let correlation: Double
}

private struct VisionEvent: Encodable, Sendable {
    let event = "vision.observation"
    let monotonicNS: UInt64
    let source: VisualObservationSource
    let confidence: Double
    let captureToBeliefMS: Double
}

private struct MetricsEvent: Encodable, Sendable {
    let event = "subconscious.metrics"
    let monotonicNS: UInt64
    let videoCallbacks: Int
    let audioCallbacks: Int
    let visionUpdates: Int
    let visionMisses: Int
    let visionFramesSkipped: Int
    let videoFramesSuperseded: Int
    let audioVADFramesSuperseded: Int
    let neuralEngineInferences: Int
    let neuralFaceInferences: Int
    let neuralVADInferences: Int
    let maximumVideoCallbackMS: Double
    let maximumAudioCallbackMS: Double
    let averageVideoCallbackMS: Double
    let averageAudioCallbackMS: Double
    let maximumVideoFrameIntervalMS: Double
    let maximumAudioCallbackIntervalMS: Double
    let maximumVisionMS: Double
    let maximumCaptureToBeliefMS: Double
    let averageNeuralEngineMS: Double
    let maximumNeuralEngineMS: Double
    let averageNeuralVADMS: Double
    let maximumNeuralVADMS: Double
    let maximumVADWindowEndToEvidenceMS: Double
}

private protocol TraceEvent: Encodable, Sendable {
    var monotonicNS: UInt64 { get }
}

extension RuntimeEvent: TraceEvent {}
extension BeliefEvent: TraceEvent {}
extension VoiceEvent: TraceEvent {}
extension AudioDirectionEvent: TraceEvent {}
extension VisionEvent: TraceEvent {}
extension MetricsEvent: TraceEvent {}

private final class JSONLWriter: @unchecked Sendable {
    private struct PendingEvent {
        let monotonicNS: UInt64
        let data: Data
    }

    private let queue = DispatchQueue(label: "soma.subconscious.trace")
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private let reorderWindowNS: UInt64 = 20_000_000
    private var pending: [PendingEvent] = []
    private var greatestQueuedNS: UInt64 = 0
    private var lastWrittenNS: UInt64 = 0
    private var lateEventsDropped = 0

    init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw RuntimeError.invalidArgument("Output already exists: \(url.path). Choose a new trace path.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RuntimeError.configuration("Cannot create trace output: \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    func write<T: TraceEvent>(_ event: T) {
        queue.async { [weak self] in
            guard let self, var data = try? self.encoder.encode(event) else { return }
            data.append(0x0A)
            self.enqueue(PendingEvent(monotonicNS: event.monotonicNS, data: data))
        }
    }

    func close() {
        queue.sync {
            flush(through: UInt64.max)
            try? handle.close()
        }
    }

    func drain() -> Int {
        queue.sync {
            flush(through: UInt64.max)
            return lateEventsDropped
        }
    }

    private func enqueue(_ event: PendingEvent) {
        greatestQueuedNS = max(greatestQueuedNS, event.monotonicNS)
        pending.append(event)
        let cutoff = greatestQueuedNS > reorderWindowNS ? greatestQueuedNS - reorderWindowNS : 0
        flush(through: cutoff)
    }

    private func flush(through cutoff: UInt64) {
        pending.sort { $0.monotonicNS < $1.monotonicNS }
        var future: [PendingEvent] = []
        for event in pending {
            guard event.monotonicNS <= cutoff else {
                future.append(event)
                continue
            }
            guard event.monotonicNS >= lastWrittenNS else {
                lateEventsDropped += 1
                continue
            }
            try? handle.write(contentsOf: event.data)
            lastWrittenNS = event.monotonicNS
        }
        pending = future
    }
}

private final class LatencyCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var videoCallbacks = 0
    private var audioCallbacks = 0
    private var visionUpdates = 0
    private var visionMisses = 0
    private var visionFramesSkipped = 0
    private var supersededFrames = 0
    private var supersededAudioVADFrames = 0
    private var neuralEngineInferences = 0
    private var neuralFaceInferences = 0
    private var neuralVADInferences = 0
    private var previousVideoNS: UInt64?
    private var previousAudioNS: UInt64?
    private var maximumVideoCallbackMS = 0.0
    private var maximumAudioCallbackMS = 0.0
    private var totalVideoCallbackMS = 0.0
    private var totalAudioCallbackMS = 0.0
    private var maximumVideoFrameIntervalMS = 0.0
    private var maximumAudioCallbackIntervalMS = 0.0
    private var maximumVisionMS = 0.0
    private var maximumCaptureToBeliefMS = 0.0
    private var totalNeuralEngineMS = 0.0
    private var maximumNeuralEngineMS = 0.0
    private var totalNeuralVADMS = 0.0
    private var maximumNeuralVADMS = 0.0
    private var maximumVADWindowEndToEvidenceMS = 0.0

    func videoCallback(at now: UInt64, processingMS: Double) {
        lock.lock()
        defer { lock.unlock() }
        videoCallbacks += 1
        if let previousVideoNS { maximumVideoFrameIntervalMS = max(maximumVideoFrameIntervalMS, milliseconds(from: previousVideoNS, to: now)) }
        previousVideoNS = now
        maximumVideoCallbackMS = max(maximumVideoCallbackMS, processingMS)
        totalVideoCallbackMS += processingMS
    }

    func audioCallback(at now: UInt64, processingMS: Double) {
        lock.lock()
        defer { lock.unlock() }
        audioCallbacks += 1
        if let previousAudioNS { maximumAudioCallbackIntervalMS = max(maximumAudioCallbackIntervalMS, milliseconds(from: previousAudioNS, to: now)) }
        previousAudioNS = now
        maximumAudioCallbackMS = max(maximumAudioCallbackMS, processingMS)
        totalAudioCallbackMS += processingMS
    }

    func visionUpdate(inferenceMS: Double, captureToBeliefMS: Double) {
        lock.lock()
        visionUpdates += 1
        maximumVisionMS = max(maximumVisionMS, inferenceMS)
        maximumCaptureToBeliefMS = max(maximumCaptureToBeliefMS, captureToBeliefMS)
        lock.unlock()
    }

    func visionMiss(inferenceMS: Double, captureToBeliefMS: Double) {
        lock.lock()
        visionMisses += 1
        maximumVisionMS = max(maximumVisionMS, inferenceMS)
        maximumCaptureToBeliefMS = max(maximumCaptureToBeliefMS, captureToBeliefMS)
        lock.unlock()
    }

    func visionFrameSkipped() {
        lock.lock()
        visionFramesSkipped += 1
        lock.unlock()
    }

    func neuralEngineInference(inferenceMS: Double) {
        lock.lock()
        neuralEngineInferences += 1
        totalNeuralEngineMS += inferenceMS
        maximumNeuralEngineMS = max(maximumNeuralEngineMS, inferenceMS)
        lock.unlock()
    }

    func neuralFaceInference() {
        lock.lock()
        neuralFaceInferences += 1
        lock.unlock()
    }

    func neuralVADInference(inferenceMS: Double, windowEndToEvidenceMS: Double) {
        lock.lock()
        neuralVADInferences += 1
        totalNeuralVADMS += inferenceMS
        maximumNeuralVADMS = max(maximumNeuralVADMS, inferenceMS)
        maximumVADWindowEndToEvidenceMS = max(maximumVADWindowEndToEvidenceMS, windowEndToEvidenceMS)
        lock.unlock()
    }

    func supersedeFrame() {
        lock.lock()
        supersededFrames += 1
        lock.unlock()
    }

    func supersedeAudioVADFrame() {
        lock.lock()
        supersededAudioVADFrames += 1
        lock.unlock()
    }

    func snapshot(at now: UInt64) -> MetricsEvent {
        lock.lock()
        defer { lock.unlock() }
        return MetricsEvent(
            monotonicNS: now,
            videoCallbacks: videoCallbacks,
            audioCallbacks: audioCallbacks,
            visionUpdates: visionUpdates,
            visionMisses: visionMisses,
            visionFramesSkipped: visionFramesSkipped,
            videoFramesSuperseded: supersededFrames,
            audioVADFramesSuperseded: supersededAudioVADFrames,
            neuralEngineInferences: neuralEngineInferences,
            neuralFaceInferences: neuralFaceInferences,
            neuralVADInferences: neuralVADInferences,
            maximumVideoCallbackMS: maximumVideoCallbackMS,
            maximumAudioCallbackMS: maximumAudioCallbackMS,
            averageVideoCallbackMS: videoCallbacks == 0 ? 0 : totalVideoCallbackMS / Double(videoCallbacks),
            averageAudioCallbackMS: audioCallbacks == 0 ? 0 : totalAudioCallbackMS / Double(audioCallbacks),
            maximumVideoFrameIntervalMS: maximumVideoFrameIntervalMS,
            maximumAudioCallbackIntervalMS: maximumAudioCallbackIntervalMS,
            maximumVisionMS: maximumVisionMS,
            maximumCaptureToBeliefMS: maximumCaptureToBeliefMS,
            averageNeuralEngineMS: neuralEngineInferences == 0 ? 0 : totalNeuralEngineMS / Double(neuralEngineInferences),
            maximumNeuralEngineMS: maximumNeuralEngineMS,
            averageNeuralVADMS: neuralVADInferences == 0 ? 0 : totalNeuralVADMS / Double(neuralVADInferences),
            maximumNeuralVADMS: maximumNeuralVADMS,
            maximumVADWindowEndToEvidenceMS: maximumVADWindowEndToEvidenceMS
        )
    }
}

private final class VideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let captureNS: UInt64

    init(pixelBuffer: CVPixelBuffer, captureNS: UInt64) {
        self.pixelBuffer = pixelBuffer
        self.captureNS = captureNS
    }
}

private final class LatestFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: VideoFrame?
    private var signalPending = false

    func publish(_ frame: VideoFrame) -> (shouldWake: Bool, superseded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let superseded = latest != nil
        latest = frame
        if signalPending { return (false, superseded) }
        signalPending = true
        return (true, superseded)
    }

    func take() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        signalPending = false
        defer { latest = nil }
        return latest
    }
}

private final class BeliefPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: JSONLWriter
    private var lastPublishNS: UInt64 = 0
    private var lastPolicy: ActiveSensingPolicy?
    private var lastTargetStatus: TargetStatus?
    private var lastAttentionCue: AttentionCue?

    init(writer: JSONLWriter) {
        self.writer = writer
    }

    func publish(_ belief: BeliefSnapshot, reason: String, force: Bool = false) {
        lock.lock()
        guard belief.monotonicNS >= lastPublishNS else {
            lock.unlock()
            return
        }
        let changed = belief.policy != lastPolicy
            || belief.targetStatus != lastTargetStatus
            || belief.attentionCue != lastAttentionCue
        let due = belief.monotonicNS - lastPublishNS >= 100_000_000
        guard force || changed || due else {
            lock.unlock()
            return
        }
        lastPublishNS = belief.monotonicNS
        lastPolicy = belief.policy
        lastTargetStatus = belief.targetStatus
        lastAttentionCue = belief.attentionCue
        lock.unlock()
        writer.write(BeliefEvent(monotonicNS: belief.monotonicNS, reason: reason, belief: belief))
    }
}

private final class AudioVADFrame: @unchecked Sendable {
    let samples: [Float]
    let sampleRateHz: Double
    var continuous: Bool
    let captureNS: UInt64
    let levelDB: Double

    init(samples: [Float], sampleRateHz: Double, continuous: Bool, captureNS: UInt64, levelDB: Double) {
        self.samples = samples
        self.sampleRateHz = sampleRateHz
        self.continuous = continuous
        self.captureNS = captureNS
        self.levelDB = levelDB
    }
}

private final class LatestAudioVADMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: AudioVADFrame?
    private var signalPending = false
    private var accepting = true

    func publish(_ frame: AudioVADFrame) -> (shouldWake: Bool, superseded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return (false, false) }
        let superseded = latest != nil
        if superseded { frame.continuous = false }
        latest = frame
        if signalPending { return (false, superseded) }
        signalPending = true
        return (true, superseded)
    }

    func take() -> AudioVADFrame? {
        lock.lock()
        defer { lock.unlock() }
        signalPending = false
        defer { latest = nil }
        return latest
    }

    func stopAccepting() {
        lock.lock()
        accepting = false
        latest = nil
        lock.unlock()
    }
}

private final class AudioVADWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soma.subconscious.audio-vad", qos: .userInitiated)
    private let mailbox = LatestAudioVADMailbox()
    private let detector: NeuralVoiceActivityDetector
    private let stateLock = NSLock()
    private let onEvidence: (NeuralVoiceActivityEvidence, AudioVADFrame, UInt64) -> Void
    private let onError: (String) -> Void
    private var active = false
    private var errorReported = false

    let computeUnits: String
    let warmupMS: Double

    init(
        onEvidence: @escaping (NeuralVoiceActivityEvidence, AudioVADFrame, UInt64) -> Void,
        onError: @escaping (String) -> Void
    ) throws {
        detector = try NeuralVoiceActivityDetector()
        computeUnits = detector.computeUnits
        warmupMS = detector.warmupMS
        self.onEvidence = onEvidence
        self.onError = onError
    }

    func submit(_ frame: AudioVADFrame) -> Bool {
        let result = mailbox.publish(frame)
        guard !result.superseded else { return true }
        guard result.shouldWake else { return false }
        queue.async { [weak self] in self?.processAvailable() }
        return false
    }

    func currentActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return active
    }

    func stop() {
        mailbox.stopAccepting()
        queue.sync {}
    }

    private func processAvailable() {
        while let frame = mailbox.take() {
            do {
                let evidence = try detector.ingest(
                    samples: frame.samples,
                    sampleRateHz: frame.sampleRateHz,
                    continuous: frame.continuous,
                    at: frame.captureNS
                )
                for result in evidence {
                    stateLock.lock()
                    active = result.active
                    stateLock.unlock()
                    onEvidence(result, frame, monotonicNanoseconds())
                }
            } catch {
                detector.reset()
                stateLock.lock()
                active = false
                let shouldReport = !errorReported
                errorReported = true
                stateLock.unlock()
                if shouldReport { onError(error.localizedDescription) }
            }
        }
    }
}

private final class AudioAnalyzer: @unchecked Sendable {
    private var previousAudioEndPTS: CMTime?
    private var nextDirectionAnalysisNS: UInt64 = 0
    private var lastDirection: AudioDirection = .unknown
    private let worldModel: PredictiveWorldModel
    private let publisher: BeliefPublisher
    private let writer: JSONLWriter
    private let counters: LatencyCounters
    private let directionEstimator: StereoTDOAEstimator?
    private let calibrationRecorder: TDOACalibrationRecorder?
    private let voiceWorker: AudioVADWorker

    init(
        worldModel: PredictiveWorldModel,
        publisher: BeliefPublisher,
        writer: JSONLWriter,
        counters: LatencyCounters,
        voiceWorker: AudioVADWorker,
        directionEstimator: StereoTDOAEstimator?,
        calibrationRecorder: TDOACalibrationRecorder?
    ) {
        self.worldModel = worldModel
        self.publisher = publisher
        self.writer = writer
        self.counters = counters
        self.voiceWorker = voiceWorker
        self.directionEstimator = directionEstimator
        self.calibrationRecorder = calibrationRecorder
    }

    func ingest(_ sampleBuffer: CMSampleBuffer, at now: UInt64) {
        defer {
            counters.audioCallback(
                at: now,
                processingMS: milliseconds(from: now, to: monotonicNanoseconds())
            )
        }
        guard let audio = monoAudio(from: sampleBuffer) else { return }
        let continuous = audioPacketIsContinuous(sampleBuffer, durationNS: audio.durationNS)
        let frame = AudioVADFrame(
            samples: audio.samples,
            sampleRateHz: audio.sampleRateHz,
            continuous: continuous,
            captureNS: now,
            levelDB: audio.levelDB
        )
        if voiceWorker.submit(frame) { counters.supersedeAudioVADFrame() }
        if !continuous { lastDirection = .unknown }
        guard voiceWorker.currentActive(), now >= nextDirectionAnalysisNS else { return }
        nextDirectionAnalysisNS = now + 125_000_000
        let stereoOutcome = stereoSamples(from: sampleBuffer)
        if let calibrationRecorder {
            switch stereoOutcome {
            case let .samples(stereo):
                calibrationRecorder.record(
                    StereoTDOAEstimator.assess(left: stereo.left, right: stereo.right, sampleRateHz: stereo.sampleRateHz)
                )
            case let .rejected(reason): calibrationRecorder.record(.rejected(reason))
            }
        }
        guard case let .samples(stereo) = stereoOutcome else { return }
        guard let directionEstimator else { return }
        let direction = directionEstimator.estimate(left: stereo.left, right: stereo.right, sampleRateHz: stereo.sampleRateHz)
        guard direction.direction != .unknown,
              let lagSamples = direction.lagSamples,
              let fractionalLagSamples = direction.fractionalLagSamples,
              let delayMilliseconds = direction.delayMilliseconds,
              let correlation = direction.correlation else { return }
        let directionalBelief = worldModel.ingestAudioDirection(
            direction.direction,
            confidence: direction.confidence,
            at: now
        )
        publisher.publish(directionalBelief, reason: "audio_direction")
        if direction.direction != lastDirection {
            lastDirection = direction.direction
            writer.write(AudioDirectionEvent(
                monotonicNS: now,
                direction: direction.direction,
                confidence: direction.confidence,
                lagSamples: lagSamples,
                fractionalLagSamples: fractionalLagSamples,
                delayMilliseconds: delayMilliseconds,
                correlation: correlation
            ))
        }
    }

    func stop() {
        voiceWorker.stop()
    }

    private func audioPacketIsContinuous(_ sampleBuffer: CMSampleBuffer, durationNS: UInt64) -> Bool {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else {
            previousAudioEndPTS = nil
            return false
        }
        defer {
            previousAudioEndPTS = CMTimeAdd(
                presentationTime,
                CMTime(value: Int64(durationNS), timescale: 1_000_000_000)
            )
        }
        guard let previousAudioEndPTS else { return false }
        let delta = CMTimeGetSeconds(CMTimeSubtract(presentationTime, previousAudioEndPTS))
        let tolerance = max(0.004, Double(durationNS) / 1_000_000_000 * 0.25)
        return delta.isFinite && abs(delta) <= tolerance
    }
}

private final class TDOACalibrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var position: TDOACalibrationPosition = .left
    private var diagnostics = TDOACalibrationDiagnostics()

    func setPosition(_ position: TDOACalibrationPosition) {
        lock.lock()
        self.position = position
        lock.unlock()
    }

    func record(_ outcome: StereoTDOAMeasurementOutcome) {
        lock.lock()
        diagnostics.record(position: position, outcome: outcome)
        lock.unlock()
    }

    func makeCalibration() -> StereoDirectionCalibration? {
        lock.lock()
        let calibration = diagnostics.makeCalibration()
        lock.unlock()
        return calibration
    }

    func summary() -> String {
        lock.lock()
        let summary = TDOACalibrationPosition.allCases.map { position in
            let diagnostic = diagnostics.diagnostic(for: position)
            let medianLag = diagnostic.medianLagSamples.map(String.init) ?? "none"
            let fractionalLag = diagnostic.medianFractionalLagSamples.map { String(format: "%.3f", $0) } ?? "none"
            let zeroLagCorrelation = diagnostic.medianZeroLagCorrelation.map { String(format: "%.3f", $0) } ?? "none"
            return "\(position.rawValue){attempts=\(diagnostic.attempts),accepted=\(diagnostic.accepted),eligible=\(diagnostic.eligible),lag_median=\(medianLag),fractional_lag_median=\(fractionalLag),zero_lag_correlation_median=\(zeroLagCorrelation),ambiguous=\(diagnostic.ambiguous),low_energy=\(diagnostic.lowEnergy),invalid_input=\(diagnostic.invalidInput)}"
        }.joined(separator: ";")
        lock.unlock()
        return summary
    }
}

private final class ANEPersonDetector: @unchecked Sendable {
    let computeUnits: String
    let warmupMS: Double
    private let model: VNCoreMLModel

    init() throws {
        let modelURL: URL
        if let compiledURL = Bundle.module.url(forResource: "YOLOv3TinyFP16", withExtension: "mlmodelc") {
            modelURL = compiledURL
        } else if let sourceURL = Bundle.module.url(forResource: "YOLOv3TinyFP16", withExtension: "mlmodel") {
            modelURL = try MLModel.compileModel(at: sourceURL)
        } else {
            throw RuntimeError.configuration("Bundled Core ML person detector is missing")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        computeUnits = "cpu_and_neural_engine"
        let loadedModel = try MLModel(contentsOf: modelURL, configuration: configuration)
        model = try VNCoreMLModel(for: loadedModel)
        let startedNS = monotonicNanoseconds()
        try Self.warmUp(model)
        warmupMS = milliseconds(from: startedNS, to: monotonicNanoseconds())
    }

    func detect(in pixelBuffer: CVPixelBuffer) throws -> [VisualObservation] {
        try Self.detect(in: pixelBuffer, model: model)
    }

    private static func warmUp(_ model: VNCoreMLModel) throws {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            416,
            416,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer else {
            throw RuntimeError.configuration("Cannot allocate Core ML warmup frame")
        }
        _ = try detect(in: pixelBuffer, model: model)
    }

    private static func detect(in pixelBuffer: CVPixelBuffer, model: VNCoreMLModel) throws -> [VisualObservation] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        let results = request.results as? [VNRecognizedObjectObservation] ?? []
        return results.compactMap { observation in
            guard let person = observation.labels.first(where: { $0.identifier == "person" }),
                  person.confidence >= 0.35 else {
                return nil
            }
            return VisualObservation(
                rect: SOMACore.NormalizedRect(observation.boundingBox),
                confidence: Double(person.confidence),
                source: .neuralDetector
            )
        }
    }
}

private final class ANEFaceDetector: @unchecked Sendable {
    private struct Anchor {
        let x: Double
        let y: Double
    }

    let computeUnits: String
    let warmupMS: Double
    private let model: VNCoreMLModel
    private let anchors: [Anchor]

    init() throws {
        guard let modelURL = Bundle.module.url(forResource: "BlazeFaceShortRange", withExtension: "mlpackage") else {
            throw RuntimeError.configuration("Bundled Core ML face detector is missing")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        computeUnits = "cpu_and_neural_engine"
        let compiledURL = try MLModel.compileModel(at: modelURL)
        let loadedModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
        model = try VNCoreMLModel(for: loadedModel)
        anchors = Self.makeAnchors()
        let startedNS = monotonicNanoseconds()
        try Self.warmUp(model: model, anchors: anchors)
        warmupMS = milliseconds(from: startedNS, to: monotonicNanoseconds())
    }

    func detect(in pixelBuffer: CVPixelBuffer) throws -> [VisualObservation] {
        try Self.detect(in: pixelBuffer, model: model, anchors: anchors)
    }

    private static func warmUp(model: VNCoreMLModel, anchors: [Anchor]) throws {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            128,
            128,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer else {
            throw RuntimeError.configuration("Cannot allocate Core ML face warmup frame")
        }
        _ = try detect(in: pixelBuffer, model: model, anchors: anchors)
    }

    private static func detect(in pixelBuffer: CVPixelBuffer, model: VNCoreMLModel, anchors: [Anchor]) throws -> [VisualObservation] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        let features = request.results?.compactMap { $0 as? VNCoreMLFeatureValueObservation } ?? []
        let featureNames = features.map(\.featureName).joined(separator: ",")
        guard let rawBoxes = features.first(where: { $0.featureName == "raw_boxes" })?.featureValue.multiArrayValue,
              let rawScores = features.first(where: { $0.featureName == "raw_scores" })?.featureValue.multiArrayValue,
              isFloatingPointArray(rawBoxes),
              isFloatingPointArray(rawScores),
              anchors.count == 896 else {
            throw RuntimeError.configuration("Unexpected Core ML face detector output: \(featureNames)")
        }

        let boxStrides = rawBoxes.strides.map(\.intValue)
        let scoreStrides = rawScores.strides.map(\.intValue)
        guard boxStrides.count == 3, scoreStrides.count == 3 else {
            throw RuntimeError.configuration("Unexpected Core ML face detector output layout")
        }

        let crop = cropTransform(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        var candidates: [VisualObservation] = []
        for index in anchors.indices {
            let scoreOffset = index * scoreStrides[1]
            let score = sigmoid(Double(value(in: rawScores, at: scoreOffset)))
            guard score >= 0.75 else { continue }
            let boxOffset = index * boxStrides[1]
            let xCenter = Double(value(in: rawBoxes, at: boxOffset)) / 128 + anchors[index].x
            let yCenter = Double(value(in: rawBoxes, at: boxOffset + boxStrides[2])) / 128 + anchors[index].y
            let width = Double(value(in: rawBoxes, at: boxOffset + boxStrides[2] * 2)) / 128
            let height = Double(value(in: rawBoxes, at: boxOffset + boxStrides[2] * 3)) / 128
            guard width > 0, height > 0 else { continue }

            let top = yCenter - height / 2
            let left = xCenter - width / 2
            let mappedLeft = crop.offsetX + left * crop.scaleX
            let mappedTop = crop.offsetY + top * crop.scaleY
            let mappedWidth = width * crop.scaleX
            let mappedHeight = height * crop.scaleY
            let rect = SOMACore.NormalizedRect(
                x: max(0, mappedLeft),
                y: max(0, 1 - mappedTop - mappedHeight),
                width: min(mappedWidth, 1 - max(0, mappedLeft)),
                height: min(mappedHeight, 1 - max(0, 1 - mappedTop - mappedHeight))
            )
            guard rect.width > 0.02, rect.height > 0.02 else { continue }
            candidates.append(VisualObservation(rect: rect, confidence: score, source: .neuralFaceDetector))
        }
        return suppressOverlaps(candidates)
    }

    private static func makeAnchors() -> [Anchor] {
        let strides = [8, 16, 16, 16]
        var anchors: [Anchor] = []
        var layer = 0
        while layer < strides.count {
            var sameStrideLayers = 0
            while layer + sameStrideLayers < strides.count,
                  strides[layer + sameStrideLayers] == strides[layer] {
                sameStrideLayers += 1
            }
            let grid = 128 / strides[layer]
            for y in 0..<grid {
                for x in 0..<grid {
                    for _ in 0..<(sameStrideLayers * 2) {
                        anchors.append(Anchor(x: (Double(x) + 0.5) / Double(grid), y: (Double(y) + 0.5) / Double(grid)))
                    }
                }
            }
            layer += sameStrideLayers
        }
        return anchors
    }

    private static func isFloatingPointArray(_ array: MLMultiArray) -> Bool {
        array.dataType == .float32 || array.dataType == .float16
    }

    private static func value(in array: MLMultiArray, at offset: Int) -> Float {
        if array.dataType == .float16 {
            return Float(array.dataPointer.bindMemory(to: Float16.self, capacity: offset + 1)[offset])
        }
        return array.dataPointer.bindMemory(to: Float.self, capacity: offset + 1)[offset]
    }

    private static func cropTransform(width: Int, height: Int) -> (offsetX: Double, offsetY: Double, scaleX: Double, scaleY: Double) {
        guard width > 0, height > 0 else { return (0, 0, 1, 1) }
        if width > height {
            let scaleX = Double(height) / Double(width)
            return ((1 - scaleX) / 2, 0, scaleX, 1)
        }
        let scaleY = Double(width) / Double(height)
        return (0, (1 - scaleY) / 2, 1, scaleY)
    }

    private static func suppressOverlaps(_ candidates: [VisualObservation]) -> [VisualObservation] {
        let sorted = candidates.sorted { $0.confidence > $1.confidence }
        return sorted.reduce(into: []) { accepted, candidate in
            guard !accepted.contains(where: { intersectionOverUnion($0.rect, candidate.rect) > 0.3 }) else { return }
            accepted.append(candidate)
        }
    }

    private static func intersectionOverUnion(_ lhs: SOMACore.NormalizedRect, _ rhs: SOMACore.NormalizedRect) -> Double {
        let x1 = max(lhs.x, rhs.x)
        let y1 = max(lhs.y, rhs.y)
        let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }

    private static func sigmoid(_ value: Double) -> Double {
        1 / (1 + exp(-min(max(value, -100), 100)))
    }
}

private final class VisionWorker: @unchecked Sendable {
    private enum DetectionOutcome {
        case observation(VisualObservation)
        case miss
        case pendingFallback
    }

    private let mailbox = LatestFrameMailbox()
    private let wake = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "soma.subconscious.vision", qos: .userInitiated)
    private let worldModel: PredictiveWorldModel
    private let publisher: BeliefPublisher
    private let writer: JSONLWriter
    private let counters: LatencyCounters
    private let neuralPersonDetector: ANEPersonDetector?
    private let neuralFaceDetector: ANEFaceDetector?
    private let stateLock = NSLock()
    private var detectorCountdown = 0
    private var nextFaceNS: UInt64 = 0
    private var trackerRect: CGRect?
    private var stopped = false

    init(worldModel: PredictiveWorldModel, publisher: BeliefPublisher, writer: JSONLWriter, counters: LatencyCounters) {
        self.worldModel = worldModel
        self.publisher = publisher
        self.writer = writer
        self.counters = counters
        do {
            let detector = try ANEPersonDetector()
            neuralPersonDetector = detector
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "person_neural_engine",
                state: "configured",
                message: "model=YOLOv3TinyFP16; compute_units=\(detector.computeUnits); prewarm_ms=\(detector.warmupMS)"
            ))
        } catch {
            neuralPersonDetector = nil
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "person_neural_engine",
                state: "unavailable",
                message: error.localizedDescription
            ))
        }
        do {
            let detector = try ANEFaceDetector()
            neuralFaceDetector = detector
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "face_neural_engine",
                state: "configured",
                message: "model=BlazeFaceShortRange; compute_units=\(detector.computeUnits); prewarm_ms=\(detector.warmupMS); max_hz=6"
            ))
        } catch {
            neuralFaceDetector = nil
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "face_neural_engine",
                state: "unavailable",
                message: error.localizedDescription
            ))
        }
    }

    func start() {
        queue.async { [weak self] in self?.workLoop() }
    }

    func submit(pixelBuffer: CVPixelBuffer, captureNS: UInt64) {
        guard !isStopped else { return }
        let result = mailbox.publish(VideoFrame(pixelBuffer: pixelBuffer, captureNS: captureNS))
        if result.superseded { counters.supersedeFrame() }
        if result.shouldWake { wake.signal() }
    }

    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        wake.signal()
        queue.sync {}
    }

    private func workLoop() {
        while true {
            wake.wait()
            if isStopped { return }
            guard let frame = mailbox.take() else { continue }
            process(frame)
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func process(_ frame: VideoFrame) {
        let startedNS = monotonicNanoseconds()
        detectorCountdown -= 1
        let outcome: DetectionOutcome
        do {
            if neuralPersonDetector != nil {
                outcome = try detect(in: frame.pixelBuffer)
            } else if let trackerRect, detectorCountdown > 0,
               let tracked = try track(trackerRect, in: frame.pixelBuffer) {
                self.trackerRect = tracked.rect.cgRect
                outcome = .observation(tracked)
            } else if detectorCountdown <= 0 {
                detectorCountdown = 4
                outcome = try detect(in: frame.pixelBuffer)
                if case let .observation(observation) = outcome {
                    trackerRect = observation.rect.cgRect
                }
            } else {
                counters.visionFrameSkipped()
                return
            }
        } catch {
            outcome = .miss
        }

        let completedNS = monotonicNanoseconds()
        let inferenceMS = milliseconds(from: startedNS, to: completedNS)
        let captureToBeliefMS = milliseconds(from: frame.captureNS, to: completedNS)
        switch outcome {
        case let .observation(observation):
            let belief = worldModel.ingestVisual(observation, at: completedNS)
            counters.visionUpdate(inferenceMS: inferenceMS, captureToBeliefMS: captureToBeliefMS)
            writer.write(VisionEvent(
                monotonicNS: completedNS,
                source: observation.source,
                confidence: observation.confidence,
                captureToBeliefMS: captureToBeliefMS
            ))
            publisher.publish(belief, reason: observation.source.rawValue, force: true)
        case .miss:
            let belief = worldModel.ingestVisionMiss(at: completedNS)
            counters.visionMiss(inferenceMS: inferenceMS, captureToBeliefMS: captureToBeliefMS)
            publisher.publish(belief, reason: "vision_miss")
        case .pendingFallback:
            counters.visionFrameSkipped()
        }
    }

    private func track(_ rect: CGRect, in pixelBuffer: CVPixelBuffer) throws -> VisualObservation? {
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: rect))
        request.trackingLevel = .fast
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first as? VNDetectedObjectObservation,
              result.confidence >= 0.35 else {
            trackerRect = nil
            return nil
        }
        return VisualObservation(rect: SOMACore.NormalizedRect(result.boundingBox), confidence: Double(result.confidence), source: .tracker)
    }

    private func detect(in pixelBuffer: CVPixelBuffer) throws -> DetectionOutcome {
        if let neuralPersonDetector {
            let startedNS = monotonicNanoseconds()
            let candidates = try neuralPersonDetector.detect(in: pixelBuffer)
            counters.neuralEngineInference(inferenceMS: milliseconds(from: startedNS, to: monotonicNanoseconds()))
            if let neuralCandidate = chooseAttentionCandidate(candidates) {
                nextFaceNS = 0
                return .observation(neuralCandidate)
            }
        }
        guard let neuralFaceDetector else { return .miss }
        let now = monotonicNanoseconds()
        guard now >= nextFaceNS else { return .pendingFallback }
        nextFaceNS = now + 166_666_667
        let faces = try neuralFaceDetector.detect(in: pixelBuffer)
        counters.neuralFaceInference()
        if let face = chooseAttentionCandidate(faces) {
            return .observation(face)
        }
        return .miss
    }

    private func chooseAttentionCandidate(_ candidates: [VisualObservation]) -> VisualObservation? {
        guard !candidates.isEmpty else { return nil }
        let previousTarget = worldModel.snapshot(at: monotonicNanoseconds()).target?.rect
        return candidates.max { lhs, rhs in
            attentionScore(lhs, previousTarget: previousTarget) < attentionScore(rhs, previousTarget: previousTarget)
        }
    }

    private func attentionScore(_ observation: VisualObservation, previousTarget: SOMACore.NormalizedRect?) -> Double {
        let area = observation.rect.width * observation.rect.height
        let centrality = 1 - hypot(observation.rect.centerX - 0.5, observation.rect.centerY - 0.5)
        let continuity: Double
        if let previousTarget {
            continuity = 1 - min(1, hypot(observation.rect.centerX - previousTarget.centerX, observation.rect.centerY - previousTarget.centerY))
        } else {
            continuity = 0
        }
        return area * 1.6 + centrality * 0.12 + continuity * 0.70 + observation.confidence * 0.10
    }
}

private final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let stateLock = NSLock()
    private var accepting = true
    private let worldModel: PredictiveWorldModel
    private let publisher: BeliefPublisher
    private let visionWorker: VisionWorker
    private let audioAnalyzer: AudioAnalyzer
    private let counters: LatencyCounters
    private let videoOutput: AVCaptureVideoDataOutput
    private let audioOutput: AVCaptureAudioDataOutput

    init(
        worldModel: PredictiveWorldModel,
        publisher: BeliefPublisher,
        visionWorker: VisionWorker,
        audioAnalyzer: AudioAnalyzer,
        counters: LatencyCounters,
        videoOutput: AVCaptureVideoDataOutput,
        audioOutput: AVCaptureAudioDataOutput
    ) {
        self.worldModel = worldModel
        self.publisher = publisher
        self.visionWorker = visionWorker
        self.audioAnalyzer = audioAnalyzer
        self.counters = counters
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isAccepting else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let now = monotonicNanoseconds()
        if output === videoOutput, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            publisher.publish(worldModel.snapshot(at: now), reason: "fast_prediction")
            visionWorker.submit(pixelBuffer: pixelBuffer, captureNS: now)
            counters.videoCallback(
                at: now,
                processingMS: milliseconds(from: now, to: monotonicNanoseconds())
            )
        } else if output === audioOutput {
            audioAnalyzer.ingest(sampleBuffer, at: now)
        }
    }

    func stopAccepting() {
        stateLock.lock()
        accepting = false
        stateLock.unlock()
    }

    private var isAccepting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return accepting
    }
}

private final class SessionObserver: NSObject, @unchecked Sendable {
    private let writer: JSONLWriter
    private let stateLock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "soma.subconscious.session-observer")
    private var tokens: [NSObjectProtocol] = []
    private var accepting = true

    init(session: AVCaptureSession, writer: JSONLWriter, videoDevice: AVCaptureDevice, audioDevice: AVCaptureDevice) {
        self.writer = writer
        super.init()
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
                self?.write("session", "runtime_error", notification)
            },
            center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] notification in
                self?.write("session", "interrupted", notification)
            },
            center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] notification in
                self?.write("session", "interruption_ended", notification)
            },
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: videoDevice, queue: nil) { [weak self] notification in
                self?.write("video", "disconnected", notification)
            },
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: audioDevice, queue: nil) { [weak self] notification in
                self?.write("audio", "disconnected", notification)
            },
            center.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil) { [weak self] notification in
                guard let device = notification.object as? AVCaptureDevice else { return }
                if device.uniqueID == videoDevice.uniqueID { self?.write("video", "reconnected", notification) }
                if device.uniqueID == audioDevice.uniqueID { self?.write("audio", "reconnected", notification) }
            },
        ]
    }

    deinit { stop() }

    func stop() {
        stateLock.lock()
        let activeTokens = tokens
        tokens = []
        stateLock.unlock()
        activeTokens.forEach(NotificationCenter.default.removeObserver)
        deliveryQueue.sync { accepting = false }
    }

    private func write(_ source: String, _ state: String, _ notification: Notification) {
        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
        deliveryQueue.async { [weak self] in
            guard let self, accepting else { return }
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: source,
                state: state,
                message: message
            ))
        }
    }
}

private func run(_ options: Options) throws {
    guard let videoDevice = obsbotDevice(for: .video, uniqueID: options.videoID) else {
        throw RuntimeError.unavailable("The requested OBSBOT video device is unavailable")
    }
    guard let audioDevice = obsbotDevice(for: .audio, uniqueID: options.audioID) else {
        throw RuntimeError.unavailable("The requested OBSBOT microphone is unavailable")
    }
    try requestAccess(for: .video, label: "camera")
    try requestAccess(for: .audio, label: "microphone")

    let writer = try JSONLWriter(url: options.outputURL)
    defer { writer.close() }
    let loadedDirectionCalibration: StereoDirectionCalibration?
    if let calibrationURL = options.tdoaCalibrationURL {
        do {
            let calibration = try JSONDecoder().decode(StereoDirectionCalibration.self, from: Data(contentsOf: calibrationURL))
            guard calibration.schemaVersion == 1 else {
                throw RuntimeError.invalidArgument("Unsupported TDOA calibration schema: \(calibration.schemaVersion)")
            }
            loadedDirectionCalibration = calibration
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.invalidArgument("Cannot read TDOA calibration: \(error.localizedDescription)")
        }
    } else {
        loadedDirectionCalibration = nil
    }
    let calibrationRecorder = options.tdoaCalibrationOutputURL.map { _ in TDOACalibrationRecorder() }
    let worldModel = PredictiveWorldModel()
    let counters = LatencyCounters()
    let publisher = BeliefPublisher(writer: writer)
    let visionWorker = VisionWorker(worldModel: worldModel, publisher: publisher, writer: writer, counters: counters)
    let voiceWorker = try AudioVADWorker(
        onEvidence: { evidence, frame, completedNS in
            if evidence.inferenceMS > 0 {
                counters.neuralVADInference(
                    inferenceMS: evidence.inferenceMS,
                    windowEndToEvidenceMS: milliseconds(from: frame.captureNS, to: completedNS)
                )
            }
            let belief = worldModel.ingestVoice(
                active: evidence.active,
                confidence: evidence.probability,
                at: completedNS
            )
            guard evidence.changed else { return }
            writer.write(VoiceEvent(
                monotonicNS: completedNS,
                source: "coreml_vad",
                active: evidence.active,
                confidence: evidence.probability,
                levelDB: frame.levelDB
            ))
            publisher.publish(
                belief,
                reason: evidence.active ? "voice_onset" : "voice_offset",
                force: true
            )
        },
        onError: { message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "neural_vad",
                state: "runtime_error",
                message: message
            ))
        }
    )
    let audioAnalyzer = AudioAnalyzer(
        worldModel: worldModel,
        publisher: publisher,
        writer: writer,
        counters: counters,
        voiceWorker: voiceWorker,
        directionEstimator: loadedDirectionCalibration.map { StereoTDOAEstimator(calibration: $0) },
        calibrationRecorder: calibrationRecorder
    )
    let session = AVCaptureSession()

    let selectedFormat = try requestLowLatencyFormat(on: videoDevice)
    let videoInput = try AVCaptureDeviceInput(device: videoDevice)
    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]

    session.beginConfiguration()
    guard session.canAddInput(videoInput), session.canAddInput(audioInput),
          session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else {
        throw RuntimeError.configuration("Cannot create an OBSBOT video/audio capture session")
    }
    session.addInput(videoInput)
    session.addInput(audioInput)
    session.addOutput(videoOutput)
    session.addOutput(audioOutput)
    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }

    let delegate = CaptureDelegate(
        worldModel: worldModel,
        publisher: publisher,
        visionWorker: visionWorker,
        audioAnalyzer: audioAnalyzer,
        counters: counters,
        videoOutput: videoOutput,
        audioOutput: audioOutput
    )
    let videoQueue = DispatchQueue(label: "soma.subconscious.video", qos: .userInteractive)
    let audioQueue = DispatchQueue(label: "soma.subconscious.audio", qos: .userInteractive)
    videoOutput.setSampleBufferDelegate(delegate, queue: videoQueue)
    audioOutput.setSampleBufferDelegate(delegate, queue: audioQueue)
    session.commitConfiguration()
    let observer = SessionObserver(session: session, writer: writer, videoDevice: videoDevice, audioDevice: audioDevice)

    writer.write(RuntimeEvent(
        event: "source.health",
        monotonicNS: monotonicNanoseconds(),
        source: "video",
        state: selectedFormat.applied ? "selected" : "configuration_fallback",
        message: "\(identity(videoDevice).name); requested=\(selectedFormat.requested); \(selectedFormat.detail)"
    ))
    writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio", state: "selected", message: "\(identity(audioDevice).name)"))
    let neuralVADConfiguration = String(
        format: "model=silero_vad_unified_256ms_v6.2.1; compute_units=%@; warmup_ms=%.2f; window_ms=260; threshold=0.50",
        voiceWorker.computeUnits,
        voiceWorker.warmupMS
    )
    writer.write(RuntimeEvent(
        event: "source.health",
        monotonicNS: monotonicNanoseconds(),
        source: "neural_vad",
        state: "configured",
        message: neuralVADConfiguration
    ))
    if loadedDirectionCalibration != nil {
        writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio_tdoa", state: "configured", message: "calibrated_stereo_tdoa"))
    } else if calibrationRecorder != nil {
        writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio_tdoa", state: "calibrating", message: "three_positions=left,center,right"))
    } else {
        writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio_tdoa", state: "calibration_required", message: "direction remains unknown until a three-position calibration is supplied"))
    }
    visionWorker.start()
    session.startRunning()
    let startedNS = monotonicNanoseconds()
    if options.guidedScenario, let firstPhase = GuidedScenarioPhase.phases.first {
        writer.write(RuntimeEvent(
            event: "scenario.phase",
            monotonicNS: startedNS,
            source: "guided_scenario",
            state: firstPhase.state,
            message: firstPhase.instruction
        ))
    }
    if let calibrationRecorder, let firstPhase = TDOACalibrationPhase.phases.first {
        calibrationRecorder.setPosition(firstPhase.position)
        writer.write(RuntimeEvent(
            event: "scenario.phase",
            monotonicNS: startedNS,
            source: "tdoa_calibration",
            state: firstPhase.position.rawValue,
            message: firstPhase.instruction
        ))
    }
    var nextScenarioPhaseIndex = options.guidedScenario ? 1 : GuidedScenarioPhase.phases.count
    var nextTDOAPhaseIndex = calibrationRecorder == nil ? TDOACalibrationPhase.phases.count : 1
    let complete = DispatchSemaphore(value: 0)
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "soma.subconscious.metrics"))
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let now = monotonicNanoseconds()
        let elapsed = Double(now - startedNS) / 1_000_000_000
        while nextScenarioPhaseIndex < GuidedScenarioPhase.phases.count,
              elapsed >= GuidedScenarioPhase.phases[nextScenarioPhaseIndex].startsAfterSeconds {
            let phase = GuidedScenarioPhase.phases[nextScenarioPhaseIndex]
            writer.write(RuntimeEvent(
                event: "scenario.phase",
                monotonicNS: now,
                source: "guided_scenario",
                state: phase.state,
                message: phase.instruction
            ))
            nextScenarioPhaseIndex += 1
        }
        while nextTDOAPhaseIndex < TDOACalibrationPhase.phases.count,
              elapsed >= TDOACalibrationPhase.phases[nextTDOAPhaseIndex].startsAfterSeconds {
            let phase = TDOACalibrationPhase.phases[nextTDOAPhaseIndex]
            calibrationRecorder?.setPosition(phase.position)
            writer.write(RuntimeEvent(
                event: "scenario.phase",
                monotonicNS: now,
                source: "tdoa_calibration",
                state: phase.position.rawValue,
                message: phase.instruction
            ))
            nextTDOAPhaseIndex += 1
        }
        writer.write(counters.snapshot(at: now))
        publisher.publish(worldModel.snapshot(at: now), reason: "periodic")
        if elapsed >= options.duration {
            if options.guidedScenario {
                writer.write(RuntimeEvent(
                    event: "scenario.completed",
                    monotonicNS: now,
                    source: "guided_scenario",
                    state: "capture_accepting_stopped",
                    message: "scheduled_seconds=50"
                ))
            }
            delegate.stopAccepting()
            timer.cancel()
            complete.signal()
        }
    }
    timer.resume()
    complete.wait()
    session.stopRunning()
    delegate.stopAccepting()
    videoQueue.sync {}
    audioQueue.sync {}
    visionWorker.stop()
    audioAnalyzer.stop()
    observer.stop()
    let stoppedNS = monotonicNanoseconds()
    if let calibrationRecorder, let calibrationOutputURL = options.tdoaCalibrationOutputURL {
        let diagnosticSummary = calibrationRecorder.summary()
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: stoppedNS,
            source: "audio_tdoa",
            state: "calibration_summary",
            message: diagnosticSummary
        ))
        if let calibration = calibrationRecorder.makeCalibration() {
            try write(calibration, to: calibrationOutputURL)
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: stoppedNS,
                source: "audio_tdoa",
                state: "calibration_written",
                message: "\(calibrationOutputURL.path); sample_rate_hz=\(calibration.sampleRateHz)"
            ))
        } else {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: stoppedNS,
                source: "audio_tdoa",
                state: "calibration_failed",
                message: "Need at least three high-correlation speech measurements at left, center, and right; \(diagnosticSummary)"
            ))
        }
    }
    writer.write(counters.snapshot(at: stoppedNS))
    publisher.publish(worldModel.snapshot(at: stoppedNS), reason: "stopped", force: true)
    let lateEventsDropped = writer.drain()
    writer.write(RuntimeEvent(
        event: "source.health",
        monotonicNS: stoppedNS,
        source: "session",
        state: "stopped",
        message: "late_events_dropped=\(lateEventsDropped)"
    ))
    withExtendedLifetime(observer) {}
    print("Wrote subconscious trace: \(options.outputURL.path)")
}

private func write(_ calibration: StereoDirectionCalibration, to url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw RuntimeError.invalidArgument("TDOA calibration output already exists: \(url.path)")
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(calibration).write(to: url, options: .atomic)
}

private func requestLowLatencyFormat(on device: AVCaptureDevice) throws -> VideoConfiguration {
    let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, Int32, Int32, Double)? in
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let maximumFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        guard dimensions.width == 1280, dimensions.height == 720, maximumFPS >= 60 else { return nil }
        return (format, dimensions.width, dimensions.height, maximumFPS)
    }
    guard let selected = candidates.max(by: { $0.3 < $1.3 }) else {
        throw RuntimeError.configuration("The OBSBOT camera does not expose 1280x720 at 60 fps")
    }
    let requested = "\(selected.1)x\(selected.2)@60fps"
    do {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = selected.0
        let frameDuration = selected.0.videoSupportedFrameRateRanges
            .min(by: { abs($0.maxFrameRate - 60) < abs($1.maxFrameRate - 60) })?
            .minFrameDuration ?? CMTime(value: 1, timescale: 60)
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        return VideoConfiguration(requested: requested, applied: true, detail: "active_format_applied")
    } catch {
        return VideoConfiguration(
            requested: requested,
            applied: false,
            detail: "active_format_unavailable=\(error.localizedDescription)"
        )
    }
}

private func obsbotDevice(for mediaType: AVMediaType, uniqueID: String) -> AVCaptureDevice? {
    let matches: (AVCaptureDevice) -> Bool = {
        $0.uniqueID == uniqueID && $0.localizedName.range(of: "obsbot", options: .caseInsensitive) != nil
    }
    if mediaType == .video {
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown],
            mediaType: mediaType,
            position: .unspecified
        ).devices.first(where: matches)
    }
    if #available(macOS 14.0, *) {
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: mediaType,
            position: .unspecified
        ).devices.first(where: matches)
    }
    return AVCaptureDevice.devices(for: mediaType).first(where: matches)
}

private func requestAccess(for mediaType: AVMediaType, label: String) throws {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized:
        return
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        let result = AccessResult()
        AVCaptureDevice.requestAccess(for: mediaType) { granted in
            result.set(granted)
            semaphore.signal()
        }
        semaphore.wait()
        guard result.value else { throw RuntimeError.unauthorized("Access to the \(label) was not granted") }
    case .denied, .restricted:
        throw RuntimeError.unauthorized("Access to the \(label) is denied or restricted")
    @unknown default:
        throw RuntimeError.unauthorized("Access to the \(label) has an unknown authorization state")
    }
}

private final class AccessResult: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false
    func set(_ granted: Bool) { lock.lock(); self.granted = granted; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return granted }
}

private struct MonoAudio {
    let samples: [Float]
    let sampleRateHz: Double
    let durationNS: UInt64
    let levelDB: Double
}

private func monoAudio(from sampleBuffer: CMSampleBuffer) -> MonoAudio? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM,
          let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        return nil
    }
    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(
        blockBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer
    ) == kCMBlockBufferNoErr,
          let dataPointer,
          totalLength > 0 else {
        return nil
    }

    let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
    let bytesPerFrame = Int(asbd.mBytesPerFrame)
    guard bytesPerSample > 0, bytesPerFrame >= bytesPerSample else { return nil }
    let scalarStride = max(1, bytesPerFrame / bytesPerSample)
    let valuesPerFrame = min(max(1, Int(asbd.mChannelsPerFrame)), scalarStride)
    let frameCount = totalLength / bytesPerFrame
    guard frameCount > 0, asbd.mSampleRate > 0 else { return nil }
    let durationNS = UInt64((Double(frameCount) / asbd.mSampleRate * 1_000_000_000).rounded())
    guard durationNS > 0 else { return nil }

    let flags = asbd.mFormatFlags
    let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
    let raw = UnsafeRawPointer(dataPointer)
    var samples: [Float] = []
    samples.reserveCapacity(frameCount)
    if isFloat, asbd.mBitsPerChannel == 32 {
        let input = raw.bindMemory(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size)
        for frame in 0..<frameCount {
            let base = frame * scalarStride
            var sum: Float = 0
            for channel in 0..<valuesPerFrame {
                sum += input[base + channel]
            }
            samples.append(sum / Float(valuesPerFrame))
        }
    } else if isSignedInteger, asbd.mBitsPerChannel == 16 {
        let input = raw.bindMemory(to: Int16.self, capacity: totalLength / MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            let base = frame * scalarStride
            var sum: Float = 0
            for channel in 0..<valuesPerFrame {
                sum += Float(input[base + channel]) / Float(Int16.max)
            }
            samples.append(sum / Float(valuesPerFrame))
        }
    } else {
        return nil
    }
    guard !samples.isEmpty else { return nil }
    let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    return MonoAudio(
        samples: samples,
        sampleRateHz: asbd.mSampleRate,
        durationNS: durationNS,
        levelDB: 20 * log10(max(rms, 0.000_001))
    )
}

private struct StereoSamples {
    let left: [Float]
    let right: [Float]
    let sampleRateHz: Double
}

private enum StereoSampleOutcome {
    case samples(StereoSamples)
    case rejected(StereoTDOARejection)
}

private func stereoSamples(from sampleBuffer: CMSampleBuffer) -> StereoSampleOutcome {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM,
          asbd.mChannelsPerFrame >= 2,
          asbd.mSampleRate > 0,
          let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        return .rejected(.invalidInput)
    }
    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(
        blockBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
          totalLengthOut: &totalLength,
          dataPointerOut: &dataPointer
    ) == kCMBlockBufferNoErr,
          let dataPointer else {
        return .rejected(.invalidInput)
    }
    let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
    let bytesPerFrame = Int(asbd.mBytesPerFrame)
    guard bytesPerSample > 0, bytesPerFrame >= bytesPerSample * 2 else { return .rejected(.invalidInput) }
    let scalarStride = bytesPerFrame / bytesPerSample
    let frameCount = totalLength / bytesPerFrame
    guard scalarStride >= 2, frameCount >= 64 else { return .rejected(.invalidInput) }

    var left: [Float] = []
    var right: [Float] = []
    left.reserveCapacity(frameCount)
    right.reserveCapacity(frameCount)
    let raw = UnsafeRawPointer(dataPointer)
    let flags = asbd.mFormatFlags
    if (flags & kAudioFormatFlagIsFloat) != 0, asbd.mBitsPerChannel == 32 {
        let samples = raw.bindMemory(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size)
        for frame in 0..<frameCount {
            let offset = frame * scalarStride
            left.append(samples[offset])
            right.append(samples[offset + 1])
        }
    } else if (flags & kAudioFormatFlagIsSignedInteger) != 0, asbd.mBitsPerChannel == 16 {
        let samples = raw.bindMemory(to: Int16.self, capacity: totalLength / MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            let offset = frame * scalarStride
            left.append(Float(samples[offset]) / Float(Int16.max))
            right.append(Float(samples[offset + 1]) / Float(Int16.max))
        }
    } else {
        return .rejected(.invalidInput)
    }
    return .samples(StereoSamples(left: left, right: right, sampleRateHz: asbd.mSampleRate))
}

private extension SOMACore.NormalizedRect {
    init(_ rect: CGRect) {
        self.init(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width), height: Double(rect.height))
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

private func identity(_ device: AVCaptureDevice) -> DeviceIdentity {
    DeviceIdentity(name: device.localizedName, uniqueID: device.uniqueID, modelID: device.modelID)
}

private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

private func milliseconds(from earlier: UInt64, to later: UInt64) -> Double {
    guard later >= earlier else { return 0 }
    return Double(later - earlier) / 1_000_000
}

private func monotonicNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func printUsage() {
    print("Usage: soma-subconscious --video-id <OBSBOT video ID> --audio-id <OBSBOT audio ID> [--duration seconds] [--guided-scenario] [--tdoa-calibration calibration.json | --tdoa-calibrate calibration.json --duration 45] [--output trace.jsonl]")
}

do {
    try run(Options.parse(Array(CommandLine.arguments.dropFirst())))
} catch {
    fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
    Foundation.exit(EXIT_FAILURE)
}
