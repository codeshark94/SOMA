@preconcurrency import AVFoundation
import AudioToolbox
import CoreML
import CoreMedia
import CoreVideo
import Foundation
import SOMACore
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

    static func parse(_ arguments: [String]) throws -> Options {
        var duration: TimeInterval = 60
        var videoID: String?
        var audioID: String?
        var outputURL = defaultOutputURL()
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
        return Options(duration: duration, videoID: videoID, audioID: audioID, outputURL: outputURL)
    }

    private static func defaultOutputURL() -> URL {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/subconscious/subconscious-\(stamp).jsonl")
    }
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
    let active: Bool
    let confidence: Double
    let levelDB: Double
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
    let neuralEngineInferences: Int
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
}

private protocol TraceEvent: Encodable, Sendable {
    var monotonicNS: UInt64 { get }
}

extension RuntimeEvent: TraceEvent {}
extension BeliefEvent: TraceEvent {}
extension VoiceEvent: TraceEvent {}
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
    private var neuralEngineInferences = 0
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

    func supersedeFrame() {
        lock.lock()
        supersededFrames += 1
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
            neuralEngineInferences: neuralEngineInferences,
            maximumVideoCallbackMS: maximumVideoCallbackMS,
            maximumAudioCallbackMS: maximumAudioCallbackMS,
            averageVideoCallbackMS: videoCallbacks == 0 ? 0 : totalVideoCallbackMS / Double(videoCallbacks),
            averageAudioCallbackMS: audioCallbacks == 0 ? 0 : totalAudioCallbackMS / Double(audioCallbacks),
            maximumVideoFrameIntervalMS: maximumVideoFrameIntervalMS,
            maximumAudioCallbackIntervalMS: maximumAudioCallbackIntervalMS,
            maximumVisionMS: maximumVisionMS,
            maximumCaptureToBeliefMS: maximumCaptureToBeliefMS,
            averageNeuralEngineMS: neuralEngineInferences == 0 ? 0 : totalNeuralEngineMS / Double(neuralEngineInferences),
            maximumNeuralEngineMS: maximumNeuralEngineMS
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

    init(writer: JSONLWriter) {
        self.writer = writer
    }

    func publish(_ belief: BeliefSnapshot, reason: String, force: Bool = false) {
        lock.lock()
        guard belief.monotonicNS >= lastPublishNS else {
            lock.unlock()
            return
        }
        let changed = belief.policy != lastPolicy || belief.targetStatus != lastTargetStatus
        let due = belief.monotonicNS - lastPublishNS >= 100_000_000
        guard force || changed || due else {
            lock.unlock()
            return
        }
        lastPublishNS = belief.monotonicNS
        lastPolicy = belief.policy
        lastTargetStatus = belief.targetStatus
        lock.unlock()
        writer.write(BeliefEvent(monotonicNS: belief.monotonicNS, reason: reason, belief: belief))
    }
}

private final class AdaptiveVoiceActivityDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var noiseFloorDB = -60.0
    private var holdUntilNS: UInt64 = 0

    func ingest(rms: Double, at now: UInt64) -> (active: Bool, confidence: Double, levelDB: Double, changed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let levelDB = 20 * log10(max(rms, 0.000_001))
        if !active {
            noiseFloorDB = noiseFloorDB * 0.985 + levelDB * 0.015
        }
        let threshold = max(noiseFloorDB + 11, -45)
        let previous = active
        if levelDB >= threshold {
            active = true
            holdUntilNS = now + 260_000_000
        } else if now >= holdUntilNS {
            active = false
        }
        let confidence = clamp((levelDB - threshold + 12) / 24)
        return (active, confidence, levelDB, active != previous)
    }
}

private final class AudioAnalyzer: @unchecked Sendable {
    private let detector = AdaptiveVoiceActivityDetector()
    private let worldModel: PredictiveWorldModel
    private let publisher: BeliefPublisher
    private let writer: JSONLWriter
    private let counters: LatencyCounters

    init(worldModel: PredictiveWorldModel, publisher: BeliefPublisher, writer: JSONLWriter, counters: LatencyCounters) {
        self.worldModel = worldModel
        self.publisher = publisher
        self.writer = writer
        self.counters = counters
    }

    func ingest(_ sampleBuffer: CMSampleBuffer, at now: UInt64) {
        defer {
            counters.audioCallback(
                at: now,
                processingMS: milliseconds(from: now, to: monotonicNanoseconds())
            )
        }
        guard let rms = audioRMS(from: sampleBuffer) else { return }
        let activity = detector.ingest(rms: rms, at: now)
        let belief = worldModel.ingestVoice(active: activity.active, confidence: activity.confidence, at: now)
        if activity.changed {
            writer.write(VoiceEvent(
                monotonicNS: now,
                active: activity.active,
                confidence: activity.confidence,
                levelDB: activity.levelDB
            ))
            publisher.publish(belief, reason: activity.active ? "voice_onset" : "voice_offset", force: true)
        }
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

private final class VisionWorker: @unchecked Sendable {
    private let mailbox = LatestFrameMailbox()
    private let wake = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "soma.subconscious.vision", qos: .userInitiated)
    private let worldModel: PredictiveWorldModel
    private let publisher: BeliefPublisher
    private let writer: JSONLWriter
    private let counters: LatencyCounters
    private let neuralDetector: ANEPersonDetector?
    private let stateLock = NSLock()
    private var detectorCountdown = 0
    private var trackerRect: CGRect?
    private var stopped = false

    init(worldModel: PredictiveWorldModel, publisher: BeliefPublisher, writer: JSONLWriter, counters: LatencyCounters) {
        self.worldModel = worldModel
        self.publisher = publisher
        self.writer = writer
        self.counters = counters
        do {
            let detector = try ANEPersonDetector()
            neuralDetector = detector
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "neural_engine",
                state: "configured",
                message: "model=YOLOv3TinyFP16; compute_units=\(detector.computeUnits); prewarm_ms=\(detector.warmupMS)"
            ))
        } catch {
            neuralDetector = nil
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "neural_engine",
                state: "fallback_system_vision",
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
        let observation: VisualObservation?
        do {
            if neuralDetector != nil {
                observation = try detect(in: frame.pixelBuffer)
            } else if let trackerRect, detectorCountdown > 0,
               let tracked = try track(trackerRect, in: frame.pixelBuffer) {
                self.trackerRect = tracked.rect.cgRect
                observation = tracked
            } else if detectorCountdown <= 0 {
                detectorCountdown = 4
                observation = try detect(in: frame.pixelBuffer)
                trackerRect = observation?.rect.cgRect
            } else {
                counters.visionFrameSkipped()
                return
            }
        } catch {
            observation = nil
        }

        let completedNS = monotonicNanoseconds()
        let inferenceMS = milliseconds(from: startedNS, to: completedNS)
        let captureToBeliefMS = milliseconds(from: frame.captureNS, to: completedNS)
        if let observation {
            let belief = worldModel.ingestVisual(observation, at: completedNS)
            counters.visionUpdate(inferenceMS: inferenceMS, captureToBeliefMS: captureToBeliefMS)
            writer.write(VisionEvent(
                monotonicNS: completedNS,
                source: observation.source,
                confidence: observation.confidence,
                captureToBeliefMS: captureToBeliefMS
            ))
            publisher.publish(belief, reason: observation.source.rawValue, force: true)
        } else {
            let belief = worldModel.ingestVisionMiss(at: completedNS)
            counters.visionMiss(inferenceMS: inferenceMS, captureToBeliefMS: captureToBeliefMS)
            publisher.publish(belief, reason: "vision_miss")
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

    private func detect(in pixelBuffer: CVPixelBuffer) throws -> VisualObservation? {
        if let neuralDetector {
            let startedNS = monotonicNanoseconds()
            let candidates = try neuralDetector.detect(in: pixelBuffer)
            counters.neuralEngineInference(inferenceMS: milliseconds(from: startedNS, to: monotonicNanoseconds()))
            return chooseAttentionCandidate(candidates)
        }
        let humanRequest = VNDetectHumanRectanglesRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([humanRequest, faceRequest])
        let humans = (humanRequest.results ?? []).map { VisualObservation(rect: SOMACore.NormalizedRect($0.boundingBox), confidence: Double($0.confidence), source: .detector) }
        let faces = (faceRequest.results ?? []).map { VisualObservation(rect: SOMACore.NormalizedRect($0.boundingBox), confidence: Double($0.confidence), source: .detector) }
        let candidates = !humans.isEmpty ? humans : faces
        return chooseAttentionCandidate(candidates)
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
    let worldModel = PredictiveWorldModel()
    let counters = LatencyCounters()
    let publisher = BeliefPublisher(writer: writer)
    let visionWorker = VisionWorker(worldModel: worldModel, publisher: publisher, writer: writer, counters: counters)
    let audioAnalyzer = AudioAnalyzer(worldModel: worldModel, publisher: publisher, writer: writer, counters: counters)
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
    visionWorker.start()
    session.startRunning()
    let startedNS = monotonicNanoseconds()
    let complete = DispatchSemaphore(value: 0)
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "soma.subconscious.metrics"))
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let now = monotonicNanoseconds()
        writer.write(counters.snapshot(at: now))
        publisher.publish(worldModel.snapshot(at: now), reason: "periodic")
        if Double(now - startedNS) / 1_000_000_000 >= options.duration {
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
    observer.stop()
    let stoppedNS = monotonicNanoseconds()
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
        let frameDuration = CMTime(value: 1, timescale: 60)
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

private func audioRMS(from sampleBuffer: CMSampleBuffer) -> Double? {
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
    guard frameCount > 0 else { return nil }

    let flags = asbd.mFormatFlags
    let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
    let raw = UnsafeRawPointer(dataPointer)
    var sumSquares = 0.0
    var count = 0
    if isFloat, asbd.mBitsPerChannel == 32 {
        let samples = raw.bindMemory(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size)
        for frame in 0..<frameCount {
            let base = frame * scalarStride
            for channel in 0..<valuesPerFrame {
                let sample = Double(samples[base + channel])
                sumSquares += sample * sample
                count += 1
            }
        }
    } else if isSignedInteger, asbd.mBitsPerChannel == 16 {
        let samples = raw.bindMemory(to: Int16.self, capacity: totalLength / MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            let base = frame * scalarStride
            for channel in 0..<valuesPerFrame {
                let sample = Double(samples[base + channel]) / Double(Int16.max)
                sumSquares += sample * sample
                count += 1
            }
        }
    } else {
        return nil
    }
    guard count > 0 else { return nil }
    return sqrt(sumSquares / Double(count))
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
    print("Usage: soma-subconscious --video-id <OBSBOT video ID> --audio-id <OBSBOT audio ID> [--duration seconds] [--output trace.jsonl]")
}

do {
    try run(Options.parse(Array(CommandLine.arguments.dropFirst())))
} catch {
    fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
    Foundation.exit(EXIT_FAILURE)
}
