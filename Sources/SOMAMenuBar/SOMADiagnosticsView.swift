import AppKit
import Foundation
import SOMACore
import SwiftUI

/// Live diagnostic panel model. Polls the files that the runtime's
/// `LiveDiagnosticsWriter` emits while the panel is open. One manifest names
/// the image and detections from the same capture, so the panel never overlays
/// a delayed inference on a newer image.
final class SOMADiagnosticsModel: ObservableObject {
    struct Rect: Decodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Candidate: Decodable, Identifiable, Sendable {
        let label: String?
        let confidence: Double
        let rect: Rect
        let faceVerified: Bool
        let identity: String?
        var id: String { "\(label ?? "?"):\(rect.x):\(rect.y)" }
    }

    struct VisionSnapshot: Decodable, Sendable {
        let capturedAtNS: UInt64
        let candidates: [Candidate]
    }

    struct Thought: Decodable, Identifiable, Sendable {
        struct Presentation: Sendable {
            let category: String
            let title: String
            let detail: String
        }

        let monotonicNS: UInt64
        let state: String
        let message: String
        // One L1 completion emits both a compact decision and its reflection
        // at the same monotonic instant.  The time alone therefore is not a
        // valid SwiftUI list identity: duplicate IDs make LazyVStack reuse the
        // wrong card and can leave an apparent blank gap before the following
        // behavior proposal.
        var id: String { "\(monotonicNS):\(state):\(message)" }

        var presentation: Presentation {
            switch state {
            case "configured":
                return .init(category: "L1 STATUS", title: "Situation model ready", detail: "Memory and visual context are available.")
            case "wake":
                let cause = value(for: "cause")
                let title: String
                switch cause {
                case "recognized_person": title = "Recognized person triggered deliberation"
                case "behavior_awareness": title = "Reviewing current attention state"
                case "auxiliary_wake": title = "Reconsidering a visual event"
                case "temporal_context": title = "Reconsidering an evolving situation"
                default: title = "Reviewing a new situation"
                }
                return .init(category: "L1 WAKE", title: title, detail: "Comparing relationship memory with the current scene.")
            case "deliberating":
                return .init(category: "L1 PROCESSING", title: "Interpreting situation and memory", detail: "Comparing current evidence with accumulated context.")
            case "model_response_received":
                return .init(category: "L1 RESPONSE", title: "Model judgment received", detail: "Checking evidence, schema, and authority.")
            case "tool_call":
                return .init(category: "L1 TOOL", title: "Reviewing a context request", detail: "Checking request scope and authority.")
            case "tool_round":
                return .init(category: "L1 TOOL", title: "Interpreting tool results", detail: "Folding new context into the next judgment.")
            case "completed":
                let uncertainty = value(for: "uncertainty").flatMap(Double.init)
                let detail = uncertainty.map { "Situation uncertainty: \(Int(($0 * 100).rounded()))%" } ?? "Applied the current situation judgment."
                return .init(category: "L1 COMPLETE", title: "Situation judgment applied", detail: detail)
            case "failed":
                return .init(category: "L1 FAILED", title: "Current judgment not applied", detail: "The next cycle will retry after a model or validation failure.")
            case "frame":
                return .init(category: "SOCIAL DECISION", title: socialDecisionTitle, detail: humanizedThought(message))
            case "thought":
                return .init(category: "BEHAVIOR DECISION", title: "Current attention and next action", detail: humanizedThought(message))
            case "reflection":
                return .init(category: "L1 REFLECTION", title: "Continuous situational thought", detail: message)
            case "behavior_directive":
                return .init(category: "BEHAVIOR PROPOSAL", title: humanizedDirective(value(for: "action") ?? "none"), detail: "L0 may execute only within current perception and safety conditions.")
            case "l1_memory_proposals":
                let count = value(for: "count").flatMap(Int.init) ?? 0
                return .init(category: "MEMORY", title: "Reviewing memory candidates", detail: "Memory candidates to review: \(max(0, count))")
            case "memory_updated":
                return .init(category: "MEMORY", title: "Memory updated", detail: "Preserved information meaningful to the current situation.")
            case "memory_deferred":
                return .init(category: "MEMORY", title: "Memory update deferred", detail: "Will retry when persistent storage is available.")
            case "visual_followup":
                return .init(category: "VISUAL CONTEXT", title: "Requested additional visual context", detail: "Checking scene detail needed for the current judgment.")
            case "visual_request_unavailable":
                return .init(category: "VISUAL CONTEXT", title: "Additional visual context unavailable", detail: "Continuing with currently observed evidence.")
            case "discarded", "decision_rejected", "opening_suppressed":
                return .init(category: "HELD", title: "Social action not taken", detail: "The current relationship context or policy does not support it.")
            default:
                return .init(category: "L1", title: "Unclassified internal transition", detail: "Only structured cognitive state is shown here.")
            }
        }

        private var socialDecisionTitle: String {
            switch value(for: "action") {
            case "spoken_opening": return "Considering a purposeful conversation opening"
            case "nonverbal_invitation": return "Considering a nonverbal invitation"
            case "remain_silent": return "Remaining quietly observant"
            default: return "Updating social judgment"
            }
        }

        private func value(for key: String) -> String? {
            message
                .split(whereSeparator: { $0 == ";" || $0 == "·" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.hasPrefix("\(key)=") }
                .map { String($0.dropFirst(key.count + 1)) }
        }

        private func readableMetadata(excluding keys: Set<String> = []) -> String {
            let items = message
                .split(whereSeparator: { $0 == ";" || $0 == "·" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { item in
                    guard let key = item.split(separator: "=", maxSplits: 1).first else { return true }
                    return !keys.contains(String(key))
                }
            return items.isEmpty ? "No additional detail" : String(items.joined(separator: " · ").prefix(600))
        }

        private func humanizedThought(_ text: String) -> String {
            let parts = text
                .split(separator: "·", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap(humanizedThoughtField)
            return parts.isEmpty ? "No decision variables" : parts.joined(separator: " · ")
        }

        private func humanizedThoughtField(_ field: String) -> String? {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return field }
            let key = String(pair[0])
            let value = String(pair[1])
            switch key {
            case "mode":
                return nil
            case "action":
                return "Decision: \(humanizedAction(value))"
            case "directive":
                return "Action: \(humanizedDirective(value))"
            case "uncertainty":
                return percentage(value, label: "Situation uncertainty")
            case "social_availability":
                return percentage(value, label: "Social availability")
            case "curiosity_pressure":
                return percentage(value, label: "Curiosity pressure")
            case "interruption_cost":
                return percentage(value, label: "Interruption cost")
            case "relationship_uncertainty":
                return percentage(value, label: "Relationship uncertainty")
            default:
                return field
            }
        }

        private func percentage(_ value: String, label: String) -> String {
            guard let scalar = Double(value) else { return "\(label): \(value)" }
            return "\(label): \(Int((scalar * 100).rounded()))%"
        }

        private func humanizedAction(_ action: String) -> String {
            switch action {
            case "remain_silent": return "Remain quietly observant"
            case "nonverbal_invitation": return "Nonverbal invitation"
            case "spoken_opening": return "Open conversation"
            default: return action.replacingOccurrences(of: "_", with: " ")
            }
        }

        private func humanizedDirective(_ action: String) -> String {
            switch action {
            case "keep_observing": "Keep observing"
            case "resume_scanning": "Resume scanning"
            case "seek_people": "Seek people"
            case "acknowledge_person": "Briefly acknowledge person"
            default: "No new action"
            }
        }

        private func humanizedFailure(_ text: String) -> String {
            text
                .replacingOccurrences(of: "reason=", with: "Reason: ")
                .replacingOccurrences(of: "details=", with: "Details: ")
                .replacingOccurrences(of: "invalid_response", with: "Model response schema mismatch")
                .replacingOccurrences(of: "deadline_exceeded", with: "Response deadline exceeded")
                .replacingOccurrences(of: "unavailable", with: "Model connection unavailable")
                .prefix(800)
                .description
        }
    }

    private struct FileStamp: Equatable {
        let size: Int64
        let modifiedAt: TimeInterval
    }

    @Published var isLive = false
    @Published var frameImage: NSImage?
    @Published var candidates: [Candidate] = []
    @Published var thoughts: [Thought] = []
    @Published var captureLagSeconds: Double = 0

    /// The diagnostic panel deliberately exposes curated cognitive cards rather
    /// than its raw runtime JSON. Copy the same presentation that is on screen
    /// so a shared report cannot accidentally contain hidden fields.
    var displayedThoughtLog: String {
        thoughts
            .map { thought in
                let presentation = thought.presentation
                return [presentation.category, presentation.title, presentation.detail]
                    .joined(separator: " · ")
            }
            .joined(separator: "\n\n")
    }

    private let manifestURL: URL
    private let frameDirectoryURL: URL
    private let thoughtsURL: URL
    private var timer: Timer?
    /// Max log lines kept in memory for the panel.
    private let maxThoughts = 300
    private var manifestStamp: FileStamp?
    private var thoughtsStamp: FileStamp?

    init(runtimeRoot: URL) {
        self.manifestURL = runtimeRoot.appendingPathComponent("live-diagnostic-frame.json")
        self.frameDirectoryURL = runtimeRoot.appendingPathComponent("live-diagnostic-frames", isDirectory: true)
        self.thoughtsURL = runtimeRoot.appendingPathComponent("live-thoughts.jsonl")
    }

    func start() {
        stop()
        refresh()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Called when the runtime is stopped or the panel reappears, so a stale
    /// camera frame and old logs are never shown.
    func clearContent() {
        frameImage = nil
        candidates = []
        thoughts = []
        captureLagSeconds = 0
        manifestStamp = nil
        thoughtsStamp = nil
    }

    func refresh() {
        let manifest = stamp(of: manifestURL)
        // The writer commits the manifest only after it has written both the
        // image and the vision data for one capture.
        let live: Bool
        if let manifest {
            live = manifest.size > 0 && (Date().timeIntervalSince1970 - manifest.modifiedAt) < 3.0
        } else {
            live = false
        }
        if live != isLive {
            isLive = live
            if !live { clearContent() }
        }
        guard live else { return }

        if manifest != manifestStamp {
            manifestStamp = manifest
            loadDiagnosticFramePair()
        }
        if let thought = stamp(of: thoughtsURL), thought != thoughtsStamp {
            thoughtsStamp = thought
            thoughts = loadThoughts()
        }
    }

    private func loadDiagnosticFramePair() {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(LiveDiagnosticsFrameManifest.self, from: data),
              manifest.containsOnlyFilenames,
              manifest.filenamesMatchGeneration else {
            return
        }
        let frameURL = frameDirectoryURL.appendingPathComponent(manifest.frameFilename)
        let visionURL = frameDirectoryURL.appendingPathComponent(manifest.visionFilename)
        guard let image = NSImage(contentsOf: frameURL),
              let snapshotData = try? Data(contentsOf: visionURL),
              let snapshot = try? JSONDecoder().decode(VisionSnapshot.self, from: snapshotData),
              snapshot.capturedAtNS == manifest.capturedAtNS else {
            return
        }
        frameImage = image
        candidates = snapshot.candidates
        if manifest.capturedAtNS > 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            captureLagSeconds = Double(now - manifest.capturedAtNS) / 1_000_000_000
        }
    }

    private func stamp(of url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              let date = attrs[.modificationDate] as? Date else { return nil }
        return FileStamp(size: size.int64Value, modifiedAt: date.timeIntervalSince1970)
    }

    private func loadThoughts() -> [Thought] {
        // Read only the tail of the file instead of the whole (potentially
        // large) log on every refresh.
        let decoder = JSONDecoder()
        return tail(of: thoughtsURL, bytes: 128 * 1024, lines: maxThoughts)
            .compactMap { line in
                guard let data = line.data(using: .utf8),
                      let thought = try? decoder.decode(Thought.self, from: data) else { return nil }
                return thought
            }
    }

    /// Returns the last `lines` complete lines from the tail of the file,
    /// reading at most `bytes` from the end so cost stays bounded regardless
    /// of how large the log has grown.
    private func tail(of url: URL, bytes: Int, lines: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // Guard against UInt64 underflow when the file is smaller than `bytes`.
        let readOffset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: readOffset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let raw = text.split(separator: "\n", omittingEmptySubsequences: false)
        // Drop the first line if we started mid-line.
        let complete: [Substring]
        if readOffset == 0 {
            complete = Array(raw)
        } else {
            complete = Array(raw.dropFirst())
        }
        return complete.suffix(lines).map(String.init)
    }
}

/// Diagnostic panel: current camera frame with detection/identity boxes
/// overlaid, and a live tail of the L1 situation stream below.
struct SOMADiagnosticsView: View {
    @ObservedObject var model: SOMADiagnosticsModel
    @State private var didInitialScroll = false
    @State private var didCopyThoughtLog = false

    private static let aspect: CGFloat = 16.0 / 9.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOMA Diagnostic")
                .font(.headline)
                .padding([.top, .horizontal])
            Text("Current camera and detection boxes · green marks an independently verified face · below is the L1 cognitive stream")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            cameraView
                .frame(height: 340)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gray.opacity(0.4)))

            HStack {
                Text("Cognitive stream · latest \(model.thoughts.count) events")
                    .font(.subheadline)
                Spacer()
                Button {
                    copyDisplayedThoughtLog()
                } label: {
                    Image(systemName: didCopyThoughtLog ? "checkmark" : "doc.on.doc")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Copy displayed log")
                .accessibilityLabel("Copy displayed log")
                .disabled(model.thoughts.isEmpty)
            }
            .padding(.horizontal)

            thoughtLog
        }
        .frame(width: 760, height: 640)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.thoughts.last?.id) { _ in
            didCopyThoughtLog = false
        }
    }

    private var cameraView: some View {
        GeometryReader { geo in
            ZStack {
                if let image = model.frameImage {
                    // Draw the whole frame without cropping and place every
                    // box inside the actual image rect. With .fill the frame
                    // was cropped to the view's wider aspect ratio, so the
                    // normalized box coordinates no longer mapped to the pixels
                    // the user saw.
                    let size = image.size
                    let drawRect = drawRect(for: size, in: geo.size)
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: drawRect.width, height: drawRect.height)
                            .position(x: drawRect.midX, y: drawRect.midY)
                        ForEach(model.candidates) { candidate in
                            let color: Color = candidate.faceVerified ? .green : .yellow
                            let x = drawRect.minX + CGFloat(candidate.rect.x) * drawRect.width
                            // Scene rects are normalized top-left (y=0 at the
                            // image top), matching SwiftUI's own origin. No
                            // vertical flip: flipping would draw the box at the
                            // mirror position and it would move opposite to the
                            // tracked object.
                            let y = drawRect.minY + candidate.rect.y * drawRect.height
                            let w = max(2, CGFloat(candidate.rect.width) * drawRect.width)
                            let h = max(2, CGFloat(candidate.rect.height) * drawRect.height)
                            Rectangle()
                                .stroke(color, lineWidth: 2)
                                .frame(width: w, height: h)
                                .position(x: x + w / 2, y: y + h / 2)
                            if let label = candidate.label, !label.isEmpty {
                                let identity = candidate.identity ?? label
                                Text(identity)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .background(Color.black.opacity(0.6))
                                    .position(
                                        x: x + w / 2,
                                        y: max(drawRect.minY + 12, y - 6)
                                    )
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                } else {
                    Rectangle().fill(Color.black)
                    if model.isLive {
                        Text("Waiting for camera frame…")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isLive && model.captureLagSeconds > 0 {
                Text(String(format: "Frame lag %.1fs", model.captureLagSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
        }
    }

    /// Aspect-fit rect of the image inside the view, so overlay boxes land on
    /// the actual pixels instead of the cropped/letterboxed frame.
    private func drawRect(for size: CGSize, in viewSize: CGSize) -> CGRect {
        let imageAspect = size.width / max(1, size.height)
        let viewAspect = viewSize.width / max(1, viewSize.height)
        if imageAspect >= viewAspect {
            let h = viewSize.width / imageAspect
            return CGRect(x: 0, y: (viewSize.height - h) / 2, width: viewSize.width, height: h)
        } else {
            let w = viewSize.height * imageAspect
            return CGRect(x: (viewSize.width - w) / 2, y: 0, width: w, height: viewSize.height)
        }
    }

    private var thoughtLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.thoughts.enumerated()), id: \.element.id) { _, thought in
                        let presentation = thought.presentation
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(presentation.category)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(color(for: thought.state))
                                Text(presentation.title)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer(minLength: 0)
                            }
                            Text(presentation.detail)
                                .font(.system(size: 11))
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(color(for: thought.state).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 4)
                            .id(thought.id)
                    }
                }
            }
            .background(Color.black.opacity(0.06))
            // Open already at the most recent log instead of the backlog, so
            // enabling diagnostics does not scroll through old entries. The
            // first load (backlog) jumps straight to the bottom without
            // animation; only later live updates animate.
            .onAppear {
                if let last = model.thoughts.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                    didInitialScroll = true
                }
            }
            .onChange(of: model.thoughts.last?.id) { _ in
                guard let last = model.thoughts.last else { return }
                if didInitialScroll {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo(last.id, anchor: .bottom)
                    didInitialScroll = true
                }
            }
        }
    }

    private func copyDisplayedThoughtLog() {
        let text = model.displayedThoughtLog
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopyThoughtLog = true
    }

    private func color(for state: String) -> Color {
        switch state {
        case "wake": .blue
        case "deliberating": .orange
        case "completed": .green
        case "discarded", "decision_rejected", "opening_suppressed": .red
        default: .primary
        }
    }
}
