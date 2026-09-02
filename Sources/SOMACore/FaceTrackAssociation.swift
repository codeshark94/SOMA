import Foundation

public enum FaceTrackAssociation {
    /// Returns a bounded association score when two face rectangles plausibly
    /// belong to the same moving track. IoU handles slow motion; normalized
    /// center displacement preserves continuity across faster frame-to-frame
    /// movement without matching faces whose apparent scale changed sharply.
    public static func score(
        previous: NormalizedRect,
        current: NormalizedRect
    ) -> Double? {
        let overlap = iou(previous, current)
        let previousDiagonal = hypot(previous.width, previous.height)
        let currentDiagonal = hypot(current.width, current.height)
        let referenceDiagonal = max((previousDiagonal + currentDiagonal) / 2, 0.02)
        let centerDistance = hypot(
            (previous.x + previous.width / 2) - (current.x + current.width / 2),
            (previous.y + previous.height / 2) - (current.y + current.height / 2)
        )
        let normalizedDistance = centerDistance / referenceDiagonal
        let largerArea = max(previous.width * previous.height, current.width * current.height)
        let smallerArea = min(previous.width * previous.height, current.width * current.height)
        let scaleConsistency = largerArea > 0 ? smallerArea / largerArea : 0

        guard overlap >= 0.12
                || (normalizedDistance <= 1.10 && scaleConsistency >= 0.45) else {
            return nil
        }
        let motionConsistency = max(0, 1 - normalizedDistance / 1.10)
        return min(max(0.60 * overlap + 0.28 * motionConsistency + 0.12 * scaleConsistency, 0), 1)
    }

    private static func iou(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let interX = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
        let interY = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
        let intersection = interX * interY
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }
}

public enum FaceIdentityTrackAuthority: Sendable {
    case enrolled
    case anonymous
}

public enum FaceIdentityTrackAction: Equatable, Sendable {
    case reuse
    case revalidate
}

/// Temporal identity continuity is evidence, not permanent authority. Enrolled
/// identities may bridge short recognition gaps, but every track is periodically
/// revalidated. Anonymous identities are never reused without a fresh match so
/// that a registered person can immediately recover from an initial open-set miss.
public struct FaceIdentityContinuityPolicy: Equatable, Sendable {
    public let enrolledRevalidationMilliseconds: UInt64
    public let enrolledMismatchGraceMilliseconds: UInt64

    public init(
        enrolledRevalidationMilliseconds: UInt64 = 1_000,
        enrolledMismatchGraceMilliseconds: UInt64 = 2_500
    ) {
        precondition(enrolledRevalidationMilliseconds > 0)
        precondition(enrolledMismatchGraceMilliseconds >= enrolledRevalidationMilliseconds)
        self.enrolledRevalidationMilliseconds = enrolledRevalidationMilliseconds
        self.enrolledMismatchGraceMilliseconds = enrolledMismatchGraceMilliseconds
    }

    public func action(
        for authority: FaceIdentityTrackAuthority,
        lastValidatedNS: UInt64,
        at monotonicNS: UInt64
    ) -> FaceIdentityTrackAction {
        guard authority == .enrolled,
              monotonicNS >= lastValidatedNS else {
            return .revalidate
        }
        let interval = enrolledRevalidationMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        guard !interval.overflow,
              monotonicNS - lastValidatedNS < interval.partialValue else {
            return .revalidate
        }
        return .reuse
    }

    public func mayBridgeMismatch(
        lastCorrelatedNS: UInt64,
        at monotonicNS: UInt64
    ) -> Bool {
        guard monotonicNS >= lastCorrelatedNS else { return false }
        let grace = enrolledMismatchGraceMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        guard !grace.overflow else { return false }
        return monotonicNS - lastCorrelatedNS <= grace.partialValue
    }
}
