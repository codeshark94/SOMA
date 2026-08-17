import CoreImage
import CoreVideo
import Foundation
import SOMACore

private final class LiveDiagnosticsRetainedBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

/// Writes a compact, live-updating diagnostic bundle that the menu-bar
/// Diagnostic panel reads in real time:
///   live-frame.jpg        current downscaled camera frame
///   live-vision.json      latest scene candidates (boxes / labels / confidence)
///   live-thoughts.jsonl   recent L1 situation events (ring buffer)
/// Writing is active only while the menu bar keeps a `live-diagnostics.enabled`
/// flag file present, so idle runtime costs nothing.
final class LiveDiagnosticsWriter: @unchecked Sendable {

    struct Rect: Encodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Candidate: Encodable, Sendable {
        let label: String?
        let confidence: Double
        let rect: Rect
        let faceVerified: Bool
        let identity: String?
    }

    struct VisionSnapshot: Encodable, Sendable {
        let capturedAtNS: UInt64
        let candidates: [Candidate]
    }

    private struct IdentityInfo: Sendable {
        let rect: Rect
        let label: String
        let observedNS: UInt64
    }

    struct Thought: Encodable, Sendable {
        let monotonicNS: UInt64
        let state: String
        let message: String
    }

    private let rootURL: URL
    private let flagURL: URL
    private let frameURL: URL
    private let visionURL: URL
    private let thoughtsURL: URL

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "soma.subconscious.live-diagnostics", qos: .utility)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let frameIntervalNS: UInt64 = 100_000_000
    private let maxFrameDimension = 640.0
    private let maxThoughts = 400
    private let encoder = JSONEncoder()

    private var nextFrameNS: UInt64 = 0
    private var nextSnapshotNS: UInt64 = 0
    private var pendingFrame: LiveDiagnosticsRetainedBuffer?
    private var encoding = false
    private var latestCandidates: [Candidate] = []
    private var latestCaptureNS: UInt64 = 0
    private var latestIdentity: IdentityInfo?
    private var thoughts: [Thought] = []
    /// Set whenever the ring buffer gains events that have not been written to
    /// the thoughts file yet. The frame path refreshes the file from this flag
    /// at ~10Hz while the panel is open, so opening the panel shows the full
    /// buffered history even if no new L1 event fires afterwards.
    private var thoughtsDirty = false

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.flagURL = rootURL.appendingPathComponent("live-diagnostics.enabled")
        self.frameURL = rootURL.appendingPathComponent("live-frame.jpg")
        self.visionURL = rootURL.appendingPathComponent("live-vision.json")
        self.thoughtsURL = rootURL.appendingPathComponent("live-thoughts.jsonl")
    }

    /// Active only while the menu bar holds the flag file open.
    var isActive: Bool {
        FileManager.default.fileExists(atPath: flagURL.path)
    }

    func recordCameraFrame(_ pixelBuffer: CVPixelBuffer, at captureNS: UInt64) {
        guard isActive else { return }
        lock.lock()
        guard captureNS >= nextFrameNS else {
            lock.unlock()
            return
        }
        nextFrameNS = captureNS &+ frameIntervalNS
        pendingFrame = LiveDiagnosticsRetainedBuffer(pixelBuffer)
        let shouldStart = !encoding
        if shouldStart { encoding = true }
        lock.unlock()
        if shouldStart {
            queue.async { [weak self] in self?.drainFrames() }
        }
    }

    func recordSceneCandidates(_ candidates: [SceneCandidate], at captureNS: UInt64) {
        guard isActive else { return }
        // Show objects that are currently present. The scene field retains
        // persistent tracks, so "observed this frame" is far too strict (it is
        // true only on detector frames and leaves the overlay empty). Keep
        // anything seen within the last 1.5s and de-overlap stacked boxes.
        let current = candidates
            .filter { $0.lastSeenMilliseconds <= 1_500 }
            .sorted { $0.observation.confidence > $1.observation.confidence }
            .reduce(into: [SceneCandidate]()) { accepted, candidate in
                guard !accepted.contains(where: {
                    Self.iou($0.observation.rect, candidate.observation.rect) > 0.3
                }) else { return }
                accepted.append(candidate)
            }
        lock.lock()
        let identity = latestIdentity
        latestCandidates = current.map { candidate in
            let rect = candidate.observation.rect
            let identityLabel = matchedIdentityLabel(for: rect, identity: identity)
            let baseLabel = candidate.observation.label ?? candidate.observation.kind.rawValue
            // A box that carries a recognized identity is a person's body; YOLO
            // may still label it "unknown", which mislabels an identified human.
            let label = (identityLabel != nil && baseLabel != "face") ? "person" : baseLabel
            return Candidate(
                label: label,
                confidence: candidate.observation.confidence,
                rect: Rect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                faceVerified: candidate.faceVerificationEligible,
                identity: identityLabel
            )
        }
        latestCaptureNS = captureNS
        let shouldWrite = captureNS >= nextSnapshotNS
        if shouldWrite { nextSnapshotNS = captureNS &+ frameIntervalNS }
        let snapshotData = shouldWrite ? try? encoder.encode(VisionSnapshot(capturedAtNS: latestCaptureNS, candidates: latestCandidates)) : nil
        lock.unlock()
        if let snapshotData {
            try? snapshotData.write(to: visionURL, options: .atomic)
        }
    }

    /// Records the latest face-identity decision (from the identity runtime)
    /// so face boxes can be labeled with the recognized identity.
    func recordIdentity(
        rect: SOMACore.NormalizedRect,
        label: String,
        at monotonicNS: UInt64
    ) {
        guard isActive else { return }
        lock.lock()
        latestIdentity = IdentityInfo(
            rect: Rect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
            label: label,
            observedNS: monotonicNS
        )
        lock.unlock()
    }

    private func matchedIdentityLabel(
        for rect: SOMACore.NormalizedRect,
        identity: IdentityInfo?
    ) -> String? {
        guard let identity else { return nil }
        // "unknown" is the not-yet-recognized sentinel, not a real identity.
        // It must never be propagated as a person's identity.
        guard identity.label != "unknown" else { return nil }
        let idRect = SOMACore.NormalizedRect(
            x: identity.rect.x,
            y: identity.rect.y,
            width: identity.rect.width,
            height: identity.rect.height
        )
        // A person/body box that encloses the identified face carries the same
        // identity: the small face rect shares low IoU with the larger body
        // box, so overlap alone would leave the body box as "unknown".
        let idCenterX = idRect.x + idRect.width / 2
        let idCenterY = idRect.y + idRect.height / 2
        let containsFaceCenter = idCenterX >= rect.x
            && idCenterX <= rect.x + rect.width
            && idCenterY >= rect.y
            && idCenterY <= rect.y + rect.height
        guard containsFaceCenter || Self.iou(rect, idRect) > 0.3 else { return nil }
        return identity.label
    }

    private static func iou(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let x1 = max(lhs.x, rhs.x)
        let y1 = max(lhs.y, rhs.y)
        let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }

    func recordL1Event(state: String, message: String, at monotonicNS: UInt64) {
        // Always accumulate into the ring buffer, even while the panel is
        // closed, so opening the panel later shows the recent history instead
        // of starting from an empty log. Only the file write is gated on the
        // flag (the panel being open).
        lock.lock()
        thoughts.append(Thought(monotonicNS: monotonicNS, state: state, message: message))
        if thoughts.count > maxThoughts {
            thoughts.removeFirst(thoughts.count - maxThoughts)
        }
        thoughtsDirty = true
        let lines = thoughts.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
        let active = isActive
        lock.unlock()
        guard active else { return }
        queue.async { [weak self] in self?.writeThoughts(lines) }
    }

    // MARK: - Frame encoding

    private func drainFrames() {
        while let frame = takePendingFrame() {
            autoreleasepool { encodeFrame(frame) }
        }
    }

    private func takePendingFrame() -> LiveDiagnosticsRetainedBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let frame = pendingFrame else {
            encoding = false
            return nil
        }
        pendingFrame = nil
        return frame
    }

    private func encodeFrame(_ buffer: LiveDiagnosticsRetainedBuffer) {
        let source = CIImage(cvPixelBuffer: buffer.value)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return
        }
        let scale = min(1, maxFrameDimension / max(extent.width, extent.height))
        let image = scale < 1
            ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : source
        guard let jpeg = imageContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [:]
        ) else {
            return
        }
        try? jpeg.write(to: frameURL, options: Data.WritingOptions.atomic)
        writeVisionSnapshot()
    }

    // MARK: - JSON snapshots

    private func writeThoughts(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        try? lines.joined(separator: "\n").write(to: thoughtsURL, atomically: true, encoding: .utf8)
    }

    func writeVisionSnapshot() {
        lock.lock()
        let snapshot = VisionSnapshot(capturedAtNS: latestCaptureNS, candidates: latestCandidates)
        let data = try? encoder.encode(snapshot)
        let dirtyThoughts: [String]?
        if thoughtsDirty {
            dirtyThoughts = thoughts.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
            thoughtsDirty = false
        } else {
            dirtyThoughts = nil
        }
        lock.unlock()
        guard let data else { return }
        try? data.write(to: visionURL, options: .atomic)
        // Runs on the same serial queue as writeThoughts, so ordering is safe.
        if let dirtyThoughts {
            writeThoughts(dirtyThoughts)
        }
    }
}
