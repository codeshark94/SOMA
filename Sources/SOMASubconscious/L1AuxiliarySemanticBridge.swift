import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import SOMACore

private final class L1AuxiliaryPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

private final class L1AuxiliaryWeakBridge: @unchecked Sendable {
    weak var value: L1AuxiliarySemanticBridge?

    init(_ value: L1AuxiliarySemanticBridge) {
        self.value = value
    }
}

private struct L1AuxiliaryWorkerRequest: Encodable {
    let type = "infer"
    let requestID: UInt64
    let context: L1AuxiliaryFrameContext
    let imageJPEGBase64: String
}

private struct L1AuxiliaryWorkerEnvelope: Decodable {
    let type: String
    let state: String?
    let message: String?
    let model: String?
    let loadMS: Double?
    let requestID: UInt64?
    let captureNS: UInt64?
    let source: String?
    let summary: String?
    let novelty: Double?
    let socialPresence: Double?
    let attentionHint: L1AuxiliaryAttentionHint?
    let situation: L1AuxiliarySituation?
    let wakeReason: L1AuxiliaryWakeReason?
    let wakeScore: Double?
    let confidence: Double?
    let eyeContact: Double?
    let engagement: Double?
    let bodyLanguage: L1AuxiliaryBodyLanguage?
    let gesture: L1AuxiliaryGesture?
    let approach: L1AuxiliaryApproach?
    let reaction: L1AuxiliaryReaction?
    let conversationValue: Double?
    let objectLabel: String?
    let inferenceMS: Double?
}

/// Local visual helper owned by L1. Frames are JPEG-encoded on a utility queue,
/// sent to one persistent MLX worker, and never written to disk. It can propose
/// L1 context updates and wake proposals but has no L0 display or motor path.
final class L1AuxiliarySemanticBridge: @unchecked Sendable {
    private struct Pending: Sendable {
        let pixelBuffer: L1AuxiliaryPixelBuffer
        let context: L1AuxiliaryFrameContext
    }

    private let queue = DispatchQueue(label: "soma.l1.auxiliary-vlm", qos: .utility)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private let onHealth: @Sendable (String, String) -> Void
    private let onCue: @Sendable (L1AuxiliarySemanticCue) -> Void
    private let onInterrupt: @Sendable (L1AuxiliarySemanticInterrupt) -> Void
    private var admission = L1AuxiliarySemanticAdmissionGate()
    private var interruptGate: L1AuxiliarySemanticInterruptGate
    private var temporalSituationGate = L1AuxiliaryTemporalSituationGate()
    private var pending: Pending?
    private var inFlightContext: L1AuxiliaryFrameContext?
    private var inFlight = false
    private var ready = false
    private var accepting = true
    private var requestSequence: UInt64 = 0
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var supersededFrames = 0
    private var intentionallyStopped = false
    // Camera callbacks must never enqueue one retained IOSurface per frame.
    // This mailbox admits only the newest buffer to the utility queue; the
    // semantic admission gate still decides whether it becomes inference work.
    private let submissionLock = NSLock()
    private var latestSubmission: Pending?
    private var submissionDrainScheduled = false
    private var acceptingSubmissions = true
    private var ingressSupersededFrames = 0
    private let frameLock = NSLock()
    private var lastJPEG: Data?

    /// The most recently JPEG-encoded frame sent to the worker. Used by L1's
    /// object-recognition path to reverse-image-search a presented object.
    func latestFrameJPEG() -> Data? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return lastJPEG
    }

    init(
        pythonURL: URL,
        workerURL: URL,
        model: String,
        wakeMinimumScore: Double = 0.65,
        wakeMinimumConfidence: Double = 0.55,
        wakeRepeatIntervalMilliseconds: UInt64 = 5_000,
        onHealth: @escaping @Sendable (String, String) -> Void,
        onCue: @escaping @Sendable (L1AuxiliarySemanticCue) -> Void,
        onInterrupt: @escaping @Sendable (L1AuxiliarySemanticInterrupt) -> Void
    ) throws {
        self.onHealth = onHealth
        self.onCue = onCue
        self.onInterrupt = onInterrupt
        interruptGate = L1AuxiliarySemanticInterruptGate(
            minimumWakeScore: wakeMinimumScore,
            minimumConfidence: wakeMinimumConfidence,
            repeatIntervalMilliseconds: wakeRepeatIntervalMilliseconds
        )
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
        process.executableURL = pythonURL
        process.arguments = [workerURL.path, "--model", model]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let weakBridge = L1AuxiliaryWeakBridge(self)
        process.terminationHandler = { completed in
            weakBridge.value?.queue.async {
                guard let self = weakBridge.value else { return }
                self.ready = false
                self.accepting = false
                guard !self.intentionallyStopped else { return }
                let diagnostic = self.stderrBuffer
                    .split(separator: "\n")
                    .suffix(2)
                    .joined(separator: " | ")
                self.onHealth(
                    "stopped_unexpectedly",
                    "termination_status=\(completed.terminationStatus); stderr=\(diagnostic.prefix(300))"
                )
            }
        }
        try process.run()
        output.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            weakBridge.value?.queue.async { weakBridge.value?.consumeStdout(data) }
        }
        errorOutput.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            weakBridge.value?.queue.async { weakBridge.value?.consumeStderr(data) }
        }
        onHealth("starting", "model=\(model); transport=jsonl_base64_jpeg; mailbox_capacity=1; pending_capacity=1")
    }

    func submit(pixelBuffer: CVPixelBuffer, context: L1AuxiliaryFrameContext) {
        let submission = Pending(
            pixelBuffer: L1AuxiliaryPixelBuffer(pixelBuffer),
            context: context
        )
        submissionLock.lock()
        guard acceptingSubmissions else {
            submissionLock.unlock()
            return
        }
        if latestSubmission != nil { ingressSupersededFrames += 1 }
        latestSubmission = submission
        guard !submissionDrainScheduled else {
            submissionLock.unlock()
            return
        }
        submissionDrainScheduled = true
        submissionLock.unlock()
        queue.async { [weak self] in self?.drainSubmittedFrames() }
    }

    func stop() {
        submissionLock.lock()
        acceptingSubmissions = false
        latestSubmission = nil
        submissionLock.unlock()
        queue.sync {
            guard accepting else { return }
            accepting = false
            intentionallyStopped = true
            pending = nil
            let shutdown = Data("{\"type\":\"shutdown\"}\n".utf8)
            try? input.write(contentsOf: shutdown)
            try? input.close()
            output.readabilityHandler = nil
            errorOutput.readabilityHandler = nil
            submissionLock.lock()
            let totalSuperseded = supersededFrames + ingressSupersededFrames
            submissionLock.unlock()
            onHealth("stopped", "superseded_frames=\(totalSuperseded)")
        }
        guard process.isRunning else { return }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { process.terminate() }
    }

    private func drainSubmittedFrames() {
        while true {
            submissionLock.lock()
            guard acceptingSubmissions, let submission = latestSubmission else {
                submissionDrainScheduled = false
                submissionLock.unlock()
                return
            }
            latestSubmission = nil
            submissionLock.unlock()

            guard accepting, admission.admit(submission.context) else { continue }
            if pending != nil { supersededFrames += 1 }
            pending = submission
            pump()
        }
    }

    private func pump() {
        guard accepting, ready, !inFlight, let pending else { return }
        self.pending = nil
        inFlight = true
        inFlightContext = pending.context
        requestSequence += 1
        let requestID = requestSequence
        let jpeg: Data? = autoreleasepool {
            let image = CIImage(cvPixelBuffer: pending.pixelBuffer.value)
                .transformed(by: CGAffineTransform(scaleX: 0.4, y: 0.4))
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                return nil
            }
            return imageContext.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: [:]
            )
        }
        guard let jpeg else {
            inFlight = false
            inFlightContext = nil
            onHealth("encode_error", "request_id=\(requestID)")
            pump()
            return
        }
        frameLock.lock()
        lastJPEG = jpeg
        frameLock.unlock()
        let request = L1AuxiliaryWorkerRequest(
            requestID: requestID,
            context: pending.context,
            imageJPEGBase64: jpeg.base64EncodedString()
        )
        do {
            var data = try JSONEncoder().encode(request)
            data.append(0x0A)
            try input.write(contentsOf: data)
        } catch {
            inFlight = false
            inFlightContext = nil
            onHealth("transport_error", String(error.localizedDescription.prefix(200)))
            pump()
        }
    }

    private func consumeStdout(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        stdoutBuffer.append(chunk)
        while let newline = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            consumeWorkerLine(line)
        }
    }

    private func consumeWorkerLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(L1AuxiliaryWorkerEnvelope.self, from: data) else {
            onHealth("protocol_error", String(line.prefix(200)))
            return
        }
        switch envelope.type {
        case "health":
            if envelope.state == "ready" {
                ready = true
                onHealth(
                    "ready",
                    String(format: "model=%@; load_ms=%.2f", envelope.model ?? "unknown", envelope.loadMS ?? 0)
                )
                pump()
            } else {
                onHealth(envelope.state ?? "worker", envelope.message ?? "")
            }
        case "result":
            defer {
                inFlight = false
                inFlightContext = nil
                pump()
            }
            guard let requestID = envelope.requestID,
                  let captureNS = envelope.captureNS,
                  let source = envelope.source,
                  let summary = envelope.summary,
                  let novelty = envelope.novelty,
                  let socialPresence = envelope.socialPresence,
                  let attentionHint = envelope.attentionHint,
                  let situation = envelope.situation,
                  let wakeReason = envelope.wakeReason,
                  let wakeScore = envelope.wakeScore,
                  let confidence = envelope.confidence,
                  let inferenceMS = envelope.inferenceMS else {
                onHealth("protocol_error", "incomplete_result")
                return
            }
            guard let requestContext = inFlightContext,
                  requestContext.captureNS == captureNS else {
                onHealth("protocol_error", "result_capture_mismatch")
                return
            }
            let cue = L1AuxiliarySemanticCue(
                requestID: requestID,
                captureNS: captureNS,
                completedNS: DispatchTime.now().uptimeNanoseconds,
                source: source,
                summary: summary,
                novelty: novelty,
                socialPresence: socialPresence,
                targetID: requestContext.targetID,
                attentionHint: attentionHint,
                situation: situation,
                wakeReason: wakeReason,
                wakeScore: wakeScore,
                confidence: confidence,
                eyeContact: envelope.eyeContact ?? 0,
                engagement: envelope.engagement ?? 0,
                bodyLanguage: envelope.bodyLanguage ?? .none,
                gesture: envelope.gesture ?? .none,
                approach: envelope.approach ?? .none,
                reaction: envelope.reaction ?? .none,
                conversationValue: envelope.conversationValue ?? 0,
                objectLabel: envelope.objectLabel ?? "",
                inferenceMS: inferenceMS
            )
            onCue(cue)
            if let recommendation = interruptGate.recommend(cue) {
                temporalSituationGate.markHandled(cue)
                onInterrupt(recommendation)
            } else if let recommendation = temporalSituationGate.recommend(cue) {
                onInterrupt(recommendation)
            }
        case "error":
            inFlight = false
            inFlightContext = nil
            onHealth("runtime_error", envelope.message ?? "worker_error")
            pump()
        default:
            onHealth("protocol_error", "unknown_type=\(envelope.type)")
        }
    }

    private func consumeStderr(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        stderrBuffer.append(chunk)
        if stderrBuffer.count > 4_096 { stderrBuffer.removeFirst(stderrBuffer.count - 4_096) }
        while let newline = stderrBuffer.firstIndex(of: "\n") {
            stderrBuffer.removeSubrange(...newline)
        }
    }
}
