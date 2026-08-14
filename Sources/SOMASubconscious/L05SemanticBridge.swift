import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import SOMACore

private final class L05PixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

private final class L05WeakBridge: @unchecked Sendable {
    weak var value: L05SemanticBridge?

    init(_ value: L05SemanticBridge) {
        self.value = value
    }
}

private struct L05WorkerRequest: Encodable {
    let type = "infer"
    let requestID: UInt64
    let context: L05FrameContext
    let imageJPEGBase64: String
}

private struct L05WorkerEnvelope: Decodable {
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
    let attentionHint: L05AttentionHint?
    let situation: L05Situation?
    let wakeReason: L05WakeReason?
    let wakeScore: Double?
    let confidence: Double?
    let inferenceMS: Double?
}

/// Optional local-only L0.5 transport. Frames are JPEG-encoded on a utility
/// queue, sent to one persistent MLX worker, and never written to disk. At most
/// one inference and one replaceable pending frame exist at a time.
final class L05SemanticBridge: @unchecked Sendable {
    private struct Pending: Sendable {
        let pixelBuffer: L05PixelBuffer
        let context: L05FrameContext
    }

    private let queue = DispatchQueue(label: "soma.subconscious.l05-vlm", qos: .utility)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private let onHealth: @Sendable (String, String) -> Void
    private let onCue: @Sendable (L05SemanticCue) -> Void
    private let onInterrupt: @Sendable (L05SemanticInterrupt) -> Void
    private var admission = L05SemanticAdmissionGate()
    private var interruptGate = L05SemanticInterruptGate()
    private var pending: Pending?
    private var inFlight = false
    private var ready = false
    private var accepting = true
    private var requestSequence: UInt64 = 0
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var supersededFrames = 0
    private var intentionallyStopped = false

    init(
        pythonURL: URL,
        workerURL: URL,
        model: String,
        onHealth: @escaping @Sendable (String, String) -> Void,
        onCue: @escaping @Sendable (L05SemanticCue) -> Void,
        onInterrupt: @escaping @Sendable (L05SemanticInterrupt) -> Void
    ) throws {
        self.onHealth = onHealth
        self.onCue = onCue
        self.onInterrupt = onInterrupt
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
        let weakBridge = L05WeakBridge(self)
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

    func submit(pixelBuffer: CVPixelBuffer, context: L05FrameContext) {
        let sendablePixelBuffer = L05PixelBuffer(pixelBuffer)
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
        let request = L05WorkerRequest(
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
              let envelope = try? JSONDecoder().decode(L05WorkerEnvelope.self, from: data) else {
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
            let cue = L05SemanticCue(
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
