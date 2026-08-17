import AppKit
import Foundation
import SwiftUI

/// Live diagnostic panel model. Polls the files that the runtime's
/// `LiveDiagnosticsWriter` emits while the panel is open. Each file is only
/// decoded again when its content actually changed, and the panel goes fully
/// blank when the runtime is stopped.
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
        let monotonicNS: UInt64
        let state: String
        let message: String
        var id: UInt64 { monotonicNS }
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

    private let frameURL: URL
    private let visionURL: URL
    private let thoughtsURL: URL
    private var timer: Timer?
    /// Max log lines kept in memory for the panel.
    private let maxThoughts = 300
    private var frameStamp: FileStamp?
    private var visionStamp: FileStamp?
    private var thoughtsStamp: FileStamp?

    init(runtimeRoot: URL) {
        self.frameURL = runtimeRoot.appendingPathComponent("live-frame.jpg")
        self.visionURL = runtimeRoot.appendingPathComponent("live-vision.json")
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
        frameStamp = nil
        visionStamp = nil
        thoughtsStamp = nil
    }

    func refresh() {
        let frame = stamp(of: frameURL)
        // The runtime writes a fresh frame continuously while live. A frame
        // file missing or untouched for ~3s means SOMA is stopped.
        let live: Bool
        if let frame {
            live = frame.size > 0 && (Date().timeIntervalSince1970 - frame.modifiedAt) < 3.0
        } else {
            live = false
        }
        if live != isLive {
            isLive = live
            if !live { clearContent() }
        }
        guard live else { return }

        if frame != frameStamp {
            frameStamp = frame
            frameImage = NSImage(contentsOf: frameURL)
        }
        if let vision = stamp(of: visionURL), vision != visionStamp {
            visionStamp = vision
            if let data = try? Data(contentsOf: visionURL),
               let snapshot = try? JSONDecoder().decode(VisionSnapshot.self, from: data) {
                candidates = snapshot.candidates
                if snapshot.capturedAtNS > 0 {
                    let now = DispatchTime.now().uptimeNanoseconds
                    captureLagSeconds = Double(now - snapshot.capturedAtNS) / 1_000_000_000
                }
            }
        }
        if let thought = stamp(of: thoughtsURL), thought != thoughtsStamp {
            thoughtsStamp = thought
            thoughts = loadThoughts()
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

    private static let aspect: CGFloat = 16.0 / 9.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOMA Diagnostic")
                .font(.headline)
                .padding([.top, .horizontal])
            Text("Camera + detection boxes (green = verified face) · live L1 situation stream")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            cameraView
                .frame(height: 340)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gray.opacity(0.4)))

            HStack {
                Text("Thought stream · \(model.thoughts.count) events")
                    .font(.subheadline)
                Spacer()
                if model.isLive && model.captureLagSeconds > 0 {
                    Text(String(format: "frame lag %.1fs", model.captureLagSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            thoughtLog
        }
        .frame(width: 760, height: 640)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
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
                            // Vision/CoreML boxes are bottom-origin (y=0 at the
                            // image bottom), while SwiftUI places y=0 at the top.
                            // Flip the axis so a box tracks the actual object
                            // instead of its vertical mirror image.
                            let y = drawRect.maxY - (candidate.rect.y + candidate.rect.height) * drawRect.height
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
                        Text(thought.message)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(color(for: thought.state))
                            .frame(maxWidth: .infinity, alignment: .leading)
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
