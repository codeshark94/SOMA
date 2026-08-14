import Foundation

/// Requires two recent, geometrically continuous face-landmark observations
/// before granting motor authority. This is a motor gate, not identity
/// recognition and not a frame store.
public struct FaceConfirmationLease: Sendable {
    private struct Confirmation: Sendable {
        var rect: NormalizedRect
        var count: Int
        var lastSeenNS: UInt64
    }

    private var confirmations: [Confirmation] = []
    private var recordedNS: UInt64?
    private let maximumAgeNS: UInt64

    public init(maximumAgeMilliseconds: UInt64 = 220) {
        maximumAgeNS = maximumAgeMilliseconds * 1_000_000
    }

    public mutating func record(_ rectangles: [NormalizedRect], at monotonicNS: UInt64) {
        confirmations = rectangles.map { rect in
            if let previous = confirmations.first(where: { matches(rect, $0.rect) }),
               monotonicNS >= previous.lastSeenNS,
               monotonicNS - previous.lastSeenNS <= maximumAgeNS {
                return Confirmation(rect: rect, count: previous.count + 1, lastSeenNS: monotonicNS)
            }
            return Confirmation(rect: rect, count: 1, lastSeenNS: monotonicNS)
        }
        recordedNS = monotonicNS
    }

    public func permits(_ face: NormalizedRect, at monotonicNS: UInt64) -> Bool {
        guard let recordedNS,
              monotonicNS >= recordedNS,
              monotonicNS - recordedNS <= maximumAgeNS else {
            return false
        }
        return confirmations.contains { confirmation in
            confirmation.count >= 2 && matches(face, confirmation.rect)
        }
    }

    private func matches(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Bool {
        let overlap = intersectionOverUnion(lhs, rhs)
        if overlap >= 0.10 { return true }
        let centreDistance = hypot(lhs.centerX - rhs.centerX, lhs.centerY - rhs.centerY)
        let areaRatio = (lhs.width * lhs.height) / max(rhs.width * rhs.height, 0.000_001)
        return centreDistance <= 0.12 && areaRatio >= 0.50 && areaRatio <= 2.0
    }

    private func intersectionOverUnion(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let x1 = max(lhs.x, rhs.x)
        let y1 = max(lhs.y, rhs.y)
        let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }
}

/// Keeps a verified face's geometric trajectory alive through brief misses in
/// the independent validator. It has no identity semantics and cannot start a
/// motor lock by itself.
public struct FaceMotorContinuityLease: Sendable {
    private var rect: NormalizedRect?
    private var verifiedNS: UInt64?
    private let maximumAgeNS: UInt64

    public init(maximumAgeMilliseconds: UInt64 = 700) {
        maximumAgeNS = maximumAgeMilliseconds * 1_000_000
    }

    public mutating func record(_ rect: NormalizedRect, at monotonicNS: UInt64) {
        self.rect = rect
        verifiedNS = monotonicNS
    }

    public func permits(_ face: NormalizedRect, at monotonicNS: UInt64) -> Bool {
        guard let rect, let verifiedNS,
              monotonicNS >= verifiedNS,
              monotonicNS - verifiedNS <= maximumAgeNS else {
            return false
        }
        let overlap = intersectionOverUnion(rect, face)
        if overlap >= 0.08 { return true }
        let centreDistance = hypot(rect.centerX - face.centerX, rect.centerY - face.centerY)
        let areaRatio = (face.width * face.height) / max(rect.width * rect.height, 0.000_001)
        return centreDistance <= 0.18 && areaRatio >= 0.40 && areaRatio <= 2.5
    }

    private func intersectionOverUnion(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let x1 = max(lhs.x, rhs.x)
        let y1 = max(lhs.y, rhs.y)
        let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }
}
