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
    private var pending: Pending?
    private var inFlight = false
    private var ready = false
    private var accepting = true
    private var requestSequence: UInt64 = 0
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var supersededFrames = 0
    private var intentionallyStopped = false
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
        onHealth("starting", "model=\(model); transport=jsonl_base64_jpeg; pending_capacity=1")
    }

    func submit(pixelBuffer: CVPixelBuffer, context: L1AuxiliaryFrameContext) {
        let sendablePixelBuffer = L1AuxiliaryPixelBuffer(pixelBuffer)
        queue.async { [weak self] in
            guard let self, self.accepting, self.admission.admit(context) else { return }
            if self.pending != nil { self.supersededFrames += 1 }
            self.pending = Pending(pixelBuffer: sendablePixelBuffer, context: context)
            self.pump()
        }
    }

    func stop() {
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
            onHealth("stopped", "superseded_frames=\(supersededFrames)")
        }
        guard process.isRunning else { return }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { process.terminate() }
    }

    private func pump() {
        guard accepting, ready, !inFlight, let pending else { return }
        self.pending = nil
        inFlight = true
        requestSequence += 1
        let requestID = requestSequence
        let image = CIImage(cvPixelBuffer: pending.pixelBuffer.value)
            .transformed(by: CGAffineTransform(scaleX: 0.4, y: 0.4))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = imageContext.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: [:]
              ) else {
            inFlight = false
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
            let cue = L1AuxiliarySemanticCue(
                requestID: requestID,
                captureNS: captureNS,
                completedNS: DispatchTime.now().uptimeNanoseconds,
                source: source,
                summary: summary,
                novelty: novelty,
                socialPresence: socialPresence,
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
                onInterrupt(recommendation)
            }
        case "error":
            inFlight = false
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
