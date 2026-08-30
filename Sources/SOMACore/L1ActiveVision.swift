import Foundation

/// One stream-lifetime cancellation signal shared by all active-sensing work.
/// Cancelling it prevents queued inspections from starting and interrupts the
/// bounded L0 capture wait so removing the semantic target also releases the
/// active motor goal.
public final class L1ActiveVisionCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Grounding policy for one L1-initiated visual inspection. It deliberately
/// selects only a currently observed, motor-eligible scene entity with a
/// measured spherical bearing; remembered or ambiguous objects remain evidence
/// but cannot move the camera.
public struct L1ActiveVisionPolicy: Equatable, Sendable {
    public let fieldOfViewDegrees: Double

    public init(fieldOfViewDegrees: Double = 65) {
        self.fieldOfViewDegrees = fieldOfViewDegrees.isFinite
            ? min(max(fieldOfViewDegrees, 5), 86)
            : 65
    }

    public func selectTarget(
        label: String,
        from entities: [EmbodimentSceneEntity]
    ) -> EmbodimentSceneEntity? {
        let normalizedLabel = Self.normalized(label)
        guard !normalizedLabel.isEmpty else { return nil }
        return entities
            .filter { entity in
                entity.observedThisFrame
                    && entity.actionEligible
                    && entity.bearing != nil
                    && entity.label.map(Self.normalized) == normalizedLabel
            }
            .max { lhs, rhs in
                let left = evidenceScore(lhs)
                let right = evidenceScore(rhs)
                if left != right { return left < right }
                if lhs.lastSeenMilliseconds != rhs.lastSeenMilliseconds {
                    return lhs.lastSeenMilliseconds > rhs.lastSeenMilliseconds
                }
                return lhs.sceneID > rhs.sceneID
            }
    }

    private func evidenceScore(_ entity: EmbodimentSceneEntity) -> Double {
        0.65 * entity.confidence + 0.35 * entity.spatialConfidence
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
