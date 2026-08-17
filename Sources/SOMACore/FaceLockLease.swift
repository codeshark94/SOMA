import Foundation

/// A visual continuity latch for a currently observed face. It is not identity
/// recognition: it retains only transient scene geometry so ordinary L0
/// exploration cannot interrupt a confirmed social fixation.
public struct FaceLockLease: Sendable {
    private let durationNS: UInt64
    private let provisionalDurationNS: UInt64
    public private(set) var sceneID: String?
    private var rect: NormalizedRect?
    private var expiresNS: UInt64 = 0
    private var acquiredNS: UInt64 = 0
    private var verificationConfirmed = false
    // A raw face candidate gets one immediate provisional attempt. If it
    // stays geometrically unchanged until that attempt expires, it cannot
    // repeatedly reacquire the motor lease without either moving or receiving
    // independent verification. This is what keeps a face-shaped texture
    // from looking like a permanent person while preserving instant response
    // to a real face.
    private var staticRejectedSceneID: String?
    private var staticRejectedRect: NormalizedRect?

    public init(durationMilliseconds: UInt64 = 3_000, provisionalMilliseconds: UInt64 = 3_000) {
        durationNS = durationMilliseconds * 1_000_000
        provisionalDurationNS = provisionalMilliseconds * 1_000_000
    }

    /// During an active coverage pulse, camera motion can prevent both the
    /// landmark verifier and world-motion activity test from completing. Two
    /// consecutive detections of the same SceneField track may therefore open
    /// only the bounded provisional re-centering path. They do not grant
    /// persistent/native tracking authority by themselves.
    ///
    /// The confidence bar is deliberately lower than the verifier's own
    /// threshold: a real face seen while the gimbal is sweeping is motion
    /// blurred and off-axis, so its blended track confidence lands well below
    /// 0.90 even though the raw ANE detector score cleared its 0.75 gate. The
    /// `observationCount >= 2` requirement plus the bounded provisional lease
    /// (which still requires independent verification for full motor
    /// authority) keep a face-shaped texture from becoming a permanent person.
    public static func permitsProvisionalExplorationInterception(
        observationCount: Int,
        confidence: Double
    ) -> Bool {
        observationCount >= 2 && confidence >= 0.75
    }

    public mutating func record(sceneID: String, at monotonicNS: UInt64) {
        staticRejectedSceneID = nil
        staticRejectedRect = nil
        self.sceneID = sceneID
        rect = nil
        acquiredNS = monotonicNS
        verificationConfirmed = true
        expiresNS = .max
    }

    public mutating func record(sceneID: String, rect: NormalizedRect, at monotonicNS: UInt64) {
        staticRejectedSceneID = nil
        staticRejectedRect = nil
        self.sceneID = sceneID
        self.rect = rect
        acquiredNS = monotonicNS
        verificationConfirmed = true
        expiresNS = .max
    }

    /// Starts a short visual-awareness lease. An initial raw face may make a
    /// brief re-centering correction so a partially clipped real face can
    /// enter the verifier's view; only independent verification extends it.
    @discardableResult
    public mutating func observe(
        sceneID: String,
        rect: NormalizedRect,
        verified: Bool,
        at monotonicNS: UInt64
    ) -> Bool {
        if isStaticRejection(sceneID: sceneID, rect: rect), !verified {
            return false
        }
        if verified {
            staticRejectedSceneID = nil
            staticRejectedRect = nil
        }
        // Once independently confirmed, a face remains the social reference
        // across detector-ID and large image-position changes. A person can
        // move much farther than one box while the gimbal is catching up;
        // that is not evidence of departure. Explicit exit handling, not a
        // detector timeout, is responsible for releasing this latch.
        if isActive(at: monotonicNS), verificationConfirmed {
            self.sceneID = sceneID
            self.rect = rect
            expiresNS = .max
            return true
        }
        if !isActive(at: monotonicNS),
           self.sceneID != nil,
           !verificationConfirmed,
           !verified,
           holdsExpiredProvisional(sceneID: sceneID, rect: rect) {
            staticRejectedSceneID = sceneID
            staticRejectedRect = rect
            return false
        }
        guard holds(sceneID: sceneID, rect: rect, at: monotonicNS) else {
            self.sceneID = sceneID
            self.rect = rect
            acquiredNS = monotonicNS
            verificationConfirmed = verified
            expiresNS = verified ? .max : monotonicNS + provisionalDurationNS
            return true
        }
        self.sceneID = sceneID
        self.rect = rect
        if verified { verificationConfirmed = true }
        if verificationConfirmed {
            expiresNS = .max
        }
        return true
    }

    public func isActive(at monotonicNS: UInt64) -> Bool {
        sceneID != nil && monotonicNS < expiresNS
    }

    public func holds(sceneID: String, at monotonicNS: UInt64) -> Bool {
        isActive(at: monotonicNS) && self.sceneID == sceneID
    }

    /// A nearby, similarly sized face box may retain the lock across a
    /// detector-ID transition. This is deliberately short lived and purely
    /// geometric; it neither identifies a person nor survives an occlusion.
    public func holds(sceneID: String, rect: NormalizedRect, at monotonicNS: UInt64) -> Bool {
        guard isActive(at: monotonicNS) else { return false }
        if self.sceneID == sceneID { return true }
        guard let prior = self.rect else { return false }
        let centerDistance = hypot(prior.centerX - rect.centerX, prior.centerY - rect.centerY)
        let areaRatio = (rect.width * rect.height) / max(prior.width * prior.height, 0.000_001)
        // A fast head movement or the gimbal's own catch-up can move a face
        // farther than one detector box between delivered frames. This is
        // continuity, not identity: it remains short-lived and still expires
        // unless independent evidence/activity promotes it.
        return centerDistance <= 0.30 && areaRatio >= 0.30 && areaRatio <= 3.0
    }

    public func permitsMotor(at monotonicNS: UInt64) -> Bool {
        isActive(at: monotonicNS) && verificationConfirmed
    }

    /// A second raw face-shaped rectangle is not evidence that the confirmed
    /// face departed. Keep it in scene awareness, but do not let it stop or
    /// redirect the active social motor lease.
    public func suppressesCompetingFace(
        sceneID: String,
        rect: NormalizedRect,
        at monotonicNS: UInt64
    ) -> Bool {
        permitsMotor(at: monotonicNS)
            && !holds(sceneID: sceneID, rect: rect, at: monotonicNS)
    }

    /// A raw face candidate may move the camera only during its fixed
    /// provisional lease. A bounded native/external adapter may use this
    /// interval, but the face cannot renew it or outlive the independent-
    /// verification window.
    public func permitsInitialMotor(at monotonicNS: UInt64) -> Bool {
        isActive(at: monotonicNS)
    }

    public func isProvisional(at monotonicNS: UInt64) -> Bool {
        isActive(at: monotonicNS) && !verificationConfirmed
    }

    /// Releases a social lease after the motor controller detects that its
    /// own actuation has left the comfortable optical envelope. This is not a
    /// normal detector-gap path: it prevents a false face confirmation from
    /// continually driving the camera into an extreme pose.
    public mutating func invalidate() {
        sceneID = nil
        rect = nil
        expiresNS = 0
        acquiredNS = 0
        verificationConfirmed = false
    }

    private func isStaticRejection(sceneID: String, rect: NormalizedRect) -> Bool {
        guard let rejectedRect = staticRejectedRect else { return false }
        return staticRejectedSceneID == sceneID
            || isGeometricallyContinuous(rejectedRect, rect)
    }

    private func holdsExpiredProvisional(sceneID: String, rect: NormalizedRect) -> Bool {
        guard let prior = self.rect else { return self.sceneID == sceneID }
        return self.sceneID == sceneID || isGeometricallyContinuous(prior, rect)
    }

    private func isGeometricallyContinuous(_ prior: NormalizedRect, _ next: NormalizedRect) -> Bool {
        let centerDistance = hypot(prior.centerX - next.centerX, prior.centerY - next.centerY)
        let areaRatio = (next.width * next.height) / max(prior.width * prior.height, 0.000_001)
        return centerDistance <= 0.30 && areaRatio >= 0.30 && areaRatio <= 3.0
    }

    /// L0 ordinary object evidence cannot replace a live face lock. A future
    /// L1 may use a positive top-down weight for selection, not L0 motor control.
    public func suppressesNonHumanAttention(
        kind: AttentionTargetKind,
        attentionWeight: Double,
        at monotonicNS: UInt64
    ) -> Bool {
        isActive(at: monotonicNS)
            && kind != .human
            && attentionWeight <= 0
    }
}

/// Keeps a face-shaped detector result in visual awareness briefly while an
/// independent face detector has time to confirm it. A result that never
/// receives that confirmation is excluded for the rest of this live session;
/// a later independently verified face may always clear the exclusion.
public struct UnverifiedFaceRejectionGate: Sendable {
    private struct Pending: Sendable {
        var rect: NormalizedRect
        let firstSeenNS: UInt64
    }

    private struct Validated: Sendable {
        var rect: NormalizedRect
        var lastSeenNS: UInt64
    }

    private var pending: [Pending] = []
    private var rejected: [NormalizedRect] = []
    private var validated: [Validated] = []
    private let confirmationWindowNS: UInt64
    private let exitAbsenceNS: UInt64

    public init(confirmationMilliseconds: UInt64 = 700, exitAbsenceMilliseconds: UInt64 = 2_000) {
        confirmationWindowNS = confirmationMilliseconds * 1_000_000
        exitAbsenceNS = exitAbsenceMilliseconds * 1_000_000
    }

    public mutating func admits(
        rect: NormalizedRect,
        independentlyVerified: Bool,
        at monotonicNS: UInt64
    ) -> Bool {
        if independentlyVerified {
            pending.removeAll { Self.matches($0.rect, rect) }
            rejected.removeAll { Self.matches($0, rect) }
            if let index = validated.firstIndex(where: { Self.matches($0.rect, rect) }) {
                validated[index] = Validated(rect: rect, lastSeenNS: monotonicNS)
            } else {
                validated.append(Validated(rect: rect, lastSeenNS: monotonicNS))
            }
            return true
        }
        if let index = validated.firstIndex(where: { Self.matches($0.rect, rect) }) {
            validated[index] = Validated(rect: rect, lastSeenNS: monotonicNS)
            return true
        }
        if rejected.contains(where: { Self.matches($0, rect) }) {
            return false
        }
        if let index = pending.firstIndex(where: { Self.matches($0.rect, rect) }) {
            if monotonicNS >= pending[index].firstSeenNS,
               monotonicNS - pending[index].firstSeenNS >= confirmationWindowNS {
                rejected.append(rect)
                pending.remove(at: index)
                return false
            }
            pending[index].rect = rect
            return true
        }
        pending.append(Pending(rect: rect, firstSeenNS: monotonicNS))
        return true
    }

    /// A promoted face survives individual verifier failures. It is released
    /// only after every face route has been absent continuously long enough to
    /// represent a physical exit rather than a dropped detector frame.
    public mutating func recordNoFace(at monotonicNS: UInt64) {
        validated.removeAll {
            monotonicNS >= $0.lastSeenNS
                && monotonicNS - $0.lastSeenNS >= exitAbsenceNS
        }
    }

    public func isValidated(_ rect: NormalizedRect) -> Bool {
        validated.contains { Self.matches($0.rect, rect) }
    }

    private static func matches(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Bool {
        let centreDistance = hypot(lhs.centerX - rhs.centerX, lhs.centerY - rhs.centerY)
        let areaRatio = (rhs.width * rhs.height) / max(lhs.width * lhs.height, 0.000_001)
        return centreDistance <= 0.20 && areaRatio >= 0.35 && areaRatio <= 2.8
    }
}
