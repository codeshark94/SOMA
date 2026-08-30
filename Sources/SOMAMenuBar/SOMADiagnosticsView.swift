import AppKit
import Foundation
import SOMACore
import SwiftUI

/// Live diagnostic panel model. Polls the files that the runtime's
/// `LiveDiagnosticsWriter` emits while the panel is open. One manifest names
/// the image and detections from the same capture, so the panel never overlays
/// a delayed inference on a newer image.
@MainActor
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
        let trackingHold: Bool
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
        let recordedAtEpochMS: Int64?
        let state: String
        let message: String
        // One L1 completion emits both a compact decision and its reflection
        // at the same monotonic instant.  The time alone therefore is not a
        // valid SwiftUI list identity: duplicate IDs make LazyVStack reuse the
        // wrong row and can leave an apparent blank gap before the next event.
        var id: String { "\(monotonicNS):\(state):\(message)" }

        var timeLabel: String {
            guard let recordedAtEpochMS else { return "--:--:--.---" }
            let seconds = TimeInterval(recordedAtEpochMS) / 1_000
            let date = Date(timeIntervalSince1970: seconds)
            let components = Calendar.current.dateComponents(
                [.hour, .minute, .second],
                from: date
            )
            let milliseconds = Int(recordedAtEpochMS % 1_000)
            return String(
                format: "%02d:%02d:%02d.%03d",
                components.hour ?? 0,
                components.minute ?? 0,
                components.second ?? 0,
                milliseconds
            )
        }

        var presentation: Presentation {
            switch state {
            case "workspace_ready":
                return .init(category: "MENTAL WORKSPACE", title: "Persistent consciousness ready", detail: message)
            case "workspace_created":
                return .init(category: "MENTAL WORKSPACE", title: "Started a new mental workspace", detail: message)
            case "workspace_restored":
                return .init(category: "MENTAL WORKSPACE", title: "Restored durable mental state", detail: "Hypotheses, curiosity, and intentions were restored. Presence and gaze require new evidence.")
            case "evidence":
                return .init(category: "EVIDENCE", title: evidenceTitle, detail: trailingValue(for: "summary") ?? readableMetadata(excluding: ["summary"]))
            case "state_delta":
                return .init(category: "STATE DELTA", title: "Workspace revision evaluated", detail: readableMetadata())
            case "hypothesis_created":
                return .init(category: "HYPOTHESIS", title: "Created a grounded hypothesis", detail: trailingValue(for: "text") ?? readableMetadata())
            case "hypothesis_updated", "hypothesis_active":
                return .init(category: "HYPOTHESIS", title: "Updated hypothesis support", detail: trailingValue(for: "text") ?? readableMetadata())
            case "hypothesis_dormant":
                return .init(category: "HYPOTHESIS", title: "Hypothesis became dormant", detail: trailingValue(for: "text") ?? readableMetadata())
            case "hypothesis_abandoned":
                return .init(category: "SELF-CORRECTION", title: "Abandoned an unsupported hypothesis", detail: trailingValue(for: "text") ?? readableMetadata())
            case "hypothesis_resolved":
                return .init(category: "HYPOTHESIS", title: "Resolved a hypothesis", detail: trailingValue(for: "text") ?? readableMetadata())
            case "thought_wake":
                return .init(category: "L1A WAKE", title: "Reflection requested", detail: readableMetadata())
            case "model_started":
                return .init(category: "MODEL", title: "L1 reasoning started", detail: readableMetadata())
            case "foreground_thought":
                return .init(category: "FOREGROUND THOUGHT", title: foregroundTitle, detail: trailingValue(for: "text") ?? "")
            case "executive_wake":
                return .init(category: "L1B WAKE", title: "Action pressure reached the executive", detail: readableMetadata())
            case "executive_decision":
                return .init(category: "EXECUTIVE DECISION", title: humanizedExecutiveAction(value(for: "action") ?? "no_action"), detail: trailingValue(for: "rationale") ?? readableMetadata())
            case "action_applied":
                return .init(category: "APPLIED", title: humanizedExecutiveAction(value(for: "action") ?? "no_action"), detail: trailingValue(for: "rationale") ?? "Current L0 and social authority accepted the decision.")
            case "action_held", "executive_held", "thought_held":
                return .init(category: "HELD", title: "Result was not applied", detail: trailingValue(for: "reason") ?? readableMetadata())
            case "thought_superseded":
                return .init(category: "COALESCED", title: "A newer evidence transaction replaced this thought", detail: readableMetadata())
            case "model_retry":
                return .init(category: "MODEL", title: "Retrying a malformed or failed response", detail: trailingValue(for: "reason") ?? readableMetadata())
            case "model_failed":
                return .init(category: "MODEL FAILED", title: "Reasoning result unavailable", detail: trailingValue(for: "reason") ?? readableMetadata())
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

        private var evidenceTitle: String {
            let kind = value(for: "kind")?.replacingOccurrences(of: "_", with: " ") ?? "observation"
            return kind.prefix(1).uppercased() + kind.dropFirst()
        }

        private var foregroundTitle: String {
            let channel = value(for: "channel")?.replacingOccurrences(of: "_", with: " ") ?? "thought"
            let continuity = value(for: "continuity")?.replacingOccurrences(of: "_", with: " ") ?? "update"
            return "\(channel.capitalized) · \(continuity)"
        }

        private func value(for key: String) -> String? {
            message
                .split(whereSeparator: { $0 == ";" || $0 == "·" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.hasPrefix("\(key)=") }
                .map { String($0.dropFirst(key.count + 1)) }
        }

        /// Model prose is always the last named field. Read the complete tail
        /// so punctuation inside the original English text is not truncated.
        private func trailingValue(for key: String) -> String? {
            guard let range = message.range(of: "\(key)=") else { return nil }
            let value = message[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : String(value)
        }

        private func humanizedExecutiveAction(_ action: String) -> String {
            switch action {
            case "no_action": "No external action"
            case "nonverbal_invitation": "Offer a nonverbal invitation"
            case "spoken_opening": "Open a purposeful conversation"
            case "resume_scanning": "Resume active exploration"
            case "seek_people": "Search for people"
            case "inspect_attention_target": "Inspect the current attention target"
            default: action.replacingOccurrences(of: "_", with: " ").capitalized
            }
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

    /// Copy exactly the compact, human-readable stream shown in the panel.
    var displayedThoughtLog: String {
        thoughts
            .map { thought in
                let presentation = thought.presentation
                return "\(thought.timeLabel) [\(presentation.category)] \(presentation.title) · \(presentation.detail)"
            }
            .joined(separator: "\n")
    }

    private let manifestURL: URL
    private let frameDirectoryURL: URL
    private let thoughtsURL: URL
    private var timer: Timer?
    /// Max log lines kept in memory for the panel.
    private let maxThoughts = 3_000
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
            Task { @MainActor in
                self?.refresh()
            }
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
        // The runtime owns a bounded 3,000-event ring and atomically rewrites
        // this snapshot. Reading the complete bounded file guarantees that an
        // unusually long monologue cannot reduce the visible event count.
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: thoughtsURL, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(maxThoughts)
            .compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let thought = try? decoder.decode(Thought.self, from: data) else { return nil }
                return thought
            }
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
                                .stroke(
                                    color,
                                    style: StrokeStyle(
                                        lineWidth: 2,
                                        dash: candidate.trackingHold ? [5, 3] : []
                                    )
                                )
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.thoughts.enumerated()), id: \.element.id) { _, thought in
                        logLine(for: thought)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .lineSpacing(0)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
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

    private func logLine(for thought: SOMADiagnosticsModel.Thought) -> Text {
        let presentation = thought.presentation
        let timestamp = Text("\(thought.timeLabel) ").foregroundColor(.secondary)
        let category = Text("[\(presentation.category)] ")
            .fontWeight(.semibold)
            .foregroundColor(color(for: thought.state))
        let message = Text("\(presentation.title) · \(presentation.detail)")
        return timestamp + category + message
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
        case "thought_wake", "executive_wake": .blue
        case "model_started", "model_retry", "thought_superseded": .orange
        case "foreground_thought", "action_applied": .green
        case "model_failed", "action_held", "executive_held", "thought_held",
             "discarded", "decision_rejected", "opening_suppressed": .red
        default: .primary
        }
    }
}
