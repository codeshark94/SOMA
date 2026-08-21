import Foundation

/// Detects and tracks the current physical space (room) the robot is in, in a
/// way analogous to anonymous-identity determination: it accumulates stable
/// background evidence (empty-room frames), then once enough has accumulated it
/// asks L1 (Gemma vision) to classify the room, and it detects when the space
/// changes. The resulting "current space" ID is what recognized objects bind to
/// before an owner is learned.
final class SpaceCoordinator: @unchecked Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let id: UUID
        var label: String?
        var lastClassifiedAt: Date
    }

    private struct PersistedState: Codable {
        var currentSpaceID: UUID
        var currentLabel: String?
        var lastClassifiedAt: Date
        var accumulatedFrames: Int
    }

    private let url: URL
    private let onHealth: @Sendable (String, String) -> Void
    private let classifySpace: @Sendable (Data) -> String
    private let lock = NSLock()
    private var state: PersistedState
    private var pendingBackground: Data?
    private var classifying = false

    /// Empty-room frames required before a classification is attempted.
    private let accumulationThreshold = 12
    /// Minimum interval between classifications (seconds).
    private let reclassifyInterval: TimeInterval = 300

    init(
        directoryURL: URL,
        onHealth: @escaping @Sendable (String, String) -> Void,
        classifySpace: @escaping @Sendable (Data) -> String
    ) {
        self.url = directoryURL.appendingPathComponent("space-identity.json")
        self.onHealth = onHealth
        self.classifySpace = classifySpace
        let initial = PersistedState(
            currentSpaceID: L1MemoryContextProvider.homeSpaceEntityID,
            currentLabel: nil,
            lastClassifiedAt: .distantPast,
            accumulatedFrames: 0
        )
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            self.state = decoded
        } else {
            self.state = initial
            persistLocked()
        }
    }

    var currentSpaceID: UUID {
        lock.lock(); defer { lock.unlock() }
        return state.currentSpaceID
    }

    var currentSpaceLabel: String? {
        lock.lock(); defer { lock.unlock() }
        return state.currentLabel
    }

    var isStable: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.currentLabel != nil
    }

    /// Reads the room identity atomically so a cognitive packet cannot combine
    /// a room ID from one transition with a label from another.
    var currentIdentity: Identity {
        lock.lock(); defer { lock.unlock() }
        return Identity(
            id: state.currentSpaceID,
            label: state.currentLabel,
            lastClassifiedAt: state.lastClassifiedAt
        )
    }

    /// Called on each empty-room cue with the current background frame. Feeds
    /// the accumulation window and, once enough stable background has built up
    /// and the reclassify interval has elapsed, triggers an L1 classification.
    func observeBackground(jpeg: Data, at date: Date) {
        lock.lock()
        pendingBackground = jpeg
        state.accumulatedFrames += 1
        let eligible = state.accumulatedFrames >= accumulationThreshold
            && date.timeIntervalSince(state.lastClassifiedAt) >= reclassifyInterval
            && !classifying
        if eligible { classifying = true }
        lock.unlock()
        if eligible { classifyNow(at: date) }
    }

    private func classifyNow(at date: Date) {
        let jpeg: Data? = {
            lock.lock(); defer { lock.unlock() }
            return pendingBackground
        }()
        guard let jpeg else {
            lock.lock(); classifying = false; lock.unlock()
            return
        }
        let raw = classifySpace(jpeg)
        var label: String?
        if let data = raw.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let l = obj["label"] as? String, !l.isEmpty {
                label = String(l.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
            } else if let l = obj["room"] as? String, !l.isEmpty {
                label = String(l.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
            }
        }

        lock.lock()
        classifying = false
        state.accumulatedFrames = 0
        if let label {
            let changed = label != state.currentLabel
            if changed {
                // New/different room: open a fresh space identity.
                state.currentSpaceID = UUID()
                state.currentLabel = label
                state.lastClassifiedAt = date
                persistLocked()
                let id = state.currentSpaceID
                lock.unlock()
                onHealth(
                    "space_transition",
                    "space=\(id.uuidString.lowercased()); label=\(label)"
                )
                return
            } else {
                // Same room: refresh the label/timestamp only.
                state.currentLabel = label
                state.lastClassifiedAt = date
                persistLocked()
                lock.unlock()
                onHealth("space_confirmed", "label=\(label)")
                return
            }
        }
        // Classification failed or was unparseable — do not change the space.
        state.lastClassifiedAt = date
        persistLocked()
        lock.unlock()
        onHealth("space_classify_failed", "raw=\(String(raw.prefix(120)).replacingOccurrences(of: "\"", with: "'"))")
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
