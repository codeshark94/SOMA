import Foundation

public enum ConversationOpeningAuthorization: String, Equatable, Sendable {
    case voiceActivity = "voice_activity"
    case activeConversation = "active_conversation"
}

public struct ConversationContactConfiguration: Equatable, Sendable {
    public let conversationInactivityMilliseconds: UInt64

    public init(
        conversationInactivityMilliseconds: UInt64 = 60_000
    ) {
        precondition(conversationInactivityMilliseconds > 0)
        self.conversationInactivityMilliseconds = conversationInactivityMilliseconds
    }
}

/// Owns the temporal boundary between a validated direct-contact event and an
/// interaction. A user-initiated conversation always requires fresh direct
/// contact; an already-open conversation carries its own inactivity lease.
public struct ConversationContactGate: Sendable {
    public let configuration: ConversationContactConfiguration
    private var conversationExpiresAtNS: UInt64?

    public init(configuration: ConversationContactConfiguration = .init()) {
        self.configuration = configuration
    }

    public mutating func authorizeSpeechOnset(
        at monotonicNS: UInt64,
        directContact: Bool
    ) -> ConversationOpeningAuthorization? {
        expire(at: monotonicNS)
        if let conversationExpiresAtNS, monotonicNS < conversationExpiresAtNS {
            return .activeConversation
        }
        guard directContact else { return nil }
        return .voiceActivity
    }

    public mutating func markConversationOpened(at monotonicNS: UInt64) {
        conversationExpiresAtNS = addingMilliseconds(
            configuration.conversationInactivityMilliseconds,
            to: monotonicNS
        )
    }

    public mutating func recordConversationActivity(at monotonicNS: UInt64) {
        expire(at: monotonicNS)
        guard conversationExpiresAtNS != nil else { return }
        conversationExpiresAtNS = addingMilliseconds(
            configuration.conversationInactivityMilliseconds,
            to: monotonicNS
        )
    }

    public mutating func closeConversation() {
        conversationExpiresAtNS = nil
    }

    public mutating func expire(at monotonicNS: UInt64) {
        if let conversationExpiresAtNS, monotonicNS >= conversationExpiresAtNS {
            self.conversationExpiresAtNS = nil
        }
    }

    private func addingMilliseconds(_ milliseconds: UInt64, to monotonicNS: UInt64) -> UInt64 {
        let nanoseconds = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        guard !nanoseconds.overflow else { return UInt64.max }
        let result = monotonicNS.addingReportingOverflow(nanoseconds.partialValue)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

/// The visual half of a user-initiated Live Voice opening. A face detector can
/// report direct gaze while L0 is already moving away on a coverage route; that
/// observation is useful social evidence, but it is not yet an interaction
/// anchor. This gate accepts a new conversation only while L0 has an actively
/// verified face fixation for the current frame sequence.
public struct L0FaceFixationAdmission: Sendable {
    public enum State: String, Equatable, Sendable {
        case absent
        case averted
        case direct
    }

    private struct Anchor: Sendable {
        let sceneID: String
        let directContact: Bool
        let observedNS: UInt64
    }

    private let freshnessNS: UInt64
    private var anchor: Anchor?

    public init(freshnessMilliseconds: UInt64 = 500) {
        precondition(freshnessMilliseconds > 0)
        freshnessNS = freshnessMilliseconds * 1_000_000
    }

    /// Records L0's accepted, independently verified face fixation. This is
    /// intentionally fed after the motor controller has cancelled exploration,
    /// rather than directly from raw detector candidates.
    public mutating func observeVerifiedFixation(
        sceneID: String,
        directContact: Bool,
        at monotonicNS: UInt64
    ) {
        anchor = Anchor(
            sceneID: sceneID,
            directContact: directContact,
            observedNS: monotonicNS
        )
    }

    public mutating func clear() {
        anchor = nil
    }

    public mutating func state(at monotonicNS: UInt64) -> State {
        guard let anchor,
              monotonicNS >= anchor.observedNS,
              monotonicNS - anchor.observedNS <= freshnessNS else {
            if let anchor, monotonicNS >= anchor.observedNS {
                self.anchor = nil
            }
            return .absent
        }
        return anchor.directContact ? .direct : .averted
    }

    public mutating func permitsNewSession(at monotonicNS: UInt64) -> Bool {
        state(at: monotonicNS) == .direct
    }
}

/// Defines when a detected voice can be attributed to the person SOMA is
/// currently addressing. Speech alone is sufficient to request a response,
/// but a new live conversation must be visually anchored to the current
/// verified human fixation rather than an arbitrary sound in the room.
public enum LiveConversationVisualAdmission {
    public static func permitsNewSession(for belief: BeliefSnapshot) -> Bool {
        guard belief.targetStatus == .tracked,
              let target = belief.target else {
            return false
        }
        return target.isFaceMotorTarget
    }
}

/// Keeps the LED invitation stable across brief landmark-gaze dropouts without
/// changing the much shorter eye-contact requirement for opening a voice turn.
/// The owner clears this lease when visual contact is conclusively lost.
public struct EyeContactIndicatorLease: Sendable {
    private let holdNS: UInt64
    private let aversionConfirmationNS: UInt64
    private var observedNS: UInt64?
    private var sceneID: String?
    private var aversionStartedNS: UInt64?
    private var lastAvertedObservationNS: UInt64?
    private var consecutiveAvertedObservations = 0

    public init(
        holdMilliseconds: UInt64 = 3_000,
        aversionConfirmationMilliseconds: UInt64 = 750
    ) {
        precondition(holdMilliseconds > 0)
        precondition(aversionConfirmationMilliseconds > 0)
        holdNS = holdMilliseconds * 1_000_000
        aversionConfirmationNS = aversionConfirmationMilliseconds * 1_000_000
    }

    public mutating func observe(at monotonicNS: UInt64) {
        observedNS = monotonicNS
        sceneID = nil
        resetAversionEvidence()
    }

    /// Starts a contact-ready indication for a particular face reference.
    /// Subsequent current observations of that same reference may maintain the
    /// indication even when the landmark gaze classifier momentarily drops.
    public mutating func observe(sceneID: String, at monotonicNS: UInt64) {
        self.sceneID = sceneID
        observedNS = monotonicNS
        resetAversionEvidence()
    }

    /// Reports whether the established social contact may survive a brief
    /// missing-gaze measurement for the same locked face. Only a new direct
    /// observation renews the lease; otherwise a continuous stream of absent
    /// pupil landmarks would turn one past eye-contact event into a permanent
    /// invitation.
    @discardableResult
    public mutating func maintain(sceneID: String, at monotonicNS: UInt64) -> Bool {
        guard isActive(at: monotonicNS) else {
            clear()
            return false
        }
        // The scene tracker may replace a face's transient ID while the face
        // remains continuously in view. That is not evidence that attention
        // was withdrawn, so the lease may bridge the ID change but cannot be
        // renewed without a new direct-gaze observation.
        return self.sceneID == sceneID || observedNS != nil
    }

    /// Reduces the three-state gaze measurement for the currently associated
    /// face into one contact-ready decision. Face geometry may establish human
    /// presence, but only a direct landmark measurement may start or renew the
    /// invitation. Missing landmarks can bridge a short measurement gap;
    /// measured aversion accumulates contradictory evidence instead.
    @discardableResult
    public mutating func update(
        gazeEvidence: VisualGazeEvidence,
        sceneID: String,
        at monotonicNS: UInt64
    ) -> Bool {
        switch gazeEvidence {
        case .direct:
            observe(sceneID: sceneID, at: monotonicNS)
            return true
        case .averted:
            return observeAverted(sceneID: sceneID, at: monotonicNS)
        case .unavailable:
            return maintain(sceneID: sceneID, at: monotonicNS)
        }
    }

    /// A landmark gaze estimate is noisy enough that one `averted` frame is
    /// not a meaningful social withdrawal. Keep the current indication while
    /// the contradiction is brief, but clear it after sustained averted
    /// evidence for this same face reference.
    @discardableResult
    public mutating func observeAverted(sceneID: String, at monotonicNS: UInt64) -> Bool {
        guard observedNS != nil else {
            return false
        }
        guard isActive(at: monotonicNS) else {
            clear()
            return false
        }
        // The caller has already associated this measurement with the current
        // FaceLockLease. SceneField IDs are transient and can change while the
        // same physical face remains locked, so they must not suppress valid
        // negative gaze evidence.
        _ = sceneID
        if let lastAvertedObservationNS,
           monotonicNS > lastAvertedObservationNS,
           monotonicNS - lastAvertedObservationNS > holdNS {
            // Evidence older than the entire contact lease cannot belong to
            // one continuous withdrawal episode.
            aversionStartedNS = monotonicNS
            consecutiveAvertedObservations = 1
        } else if aversionStartedNS == nil {
            aversionStartedNS = monotonicNS
            consecutiveAvertedObservations = 1
        } else {
            consecutiveAvertedObservations += 1
        }
        lastAvertedObservationNS = monotonicNS
        if let aversionStartedNS,
           monotonicNS >= aversionStartedNS,
           monotonicNS - aversionStartedNS >= aversionConfirmationNS,
           consecutiveAvertedObservations >= 2 {
            clear()
            return false
        }
        return true
    }

    public mutating func clear() {
        observedNS = nil
        sceneID = nil
        resetAversionEvidence()
    }

    public func isActive(at monotonicNS: UInt64) -> Bool {
        guard let observedNS, monotonicNS >= observedNS else { return false }
        return monotonicNS - observedNS <= holdNS
    }

    private mutating func resetAversionEvidence() {
        aversionStartedNS = nil
        lastAvertedObservationNS = nil
        consecutiveAvertedObservations = 0
    }
}

public enum SubconsciousIndicatorState: String, CaseIterable, Codable, Hashable, Sendable {
    case exploring
    case humanDetected = "human_detected"
    case contactReady = "contact_ready"
    case conversation
    case working
    /// Legacy settings values. They decode so existing owner settings migrate
    /// without loss, but they resolve to the single Conversation LED signal.
    case listening
    case speaking

    public static let configurationStates: [Self] = [
        .exploring,
        .humanDetected,
        .contactReady,
        .conversation,
    ]

    public var configurationState: Self {
        switch self {
        case .working, .listening, .speaking: .conversation
        default: self
        }
    }
}

public struct SubconsciousIndicatorPhase: Equatable, Sendable {
    public let illuminated: Bool
    public let durationMilliseconds: UInt64?

    public init(illuminated: Bool, durationMilliseconds: UInt64?) {
        precondition(durationMilliseconds.map { $0 > 0 } ?? true)
        self.illuminated = illuminated
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct SubconsciousIndicatorPattern: Equatable, Sendable {
    public let name: String
    public let phases: [SubconsciousIndicatorPhase]

    public init(name: String, phases: [SubconsciousIndicatorPhase]) {
        precondition(!name.isEmpty)
        precondition(!phases.isEmpty)
        precondition(phases[0].illuminated)
        precondition(phases.count == 1 || phases.allSatisfy { $0.durationMilliseconds != nil })
        self.name = name
        self.phases = phases
    }
}

public extension SubconsciousIndicatorState {
    /// What a nearby person should infer and do next. This is deliberately
    /// phrased as an interaction affordance rather than an internal component
    /// status.
    var humanMeaning: String {
        switch self {
        case .exploring: return "not_ready_looking_for_contact"
        case .humanDetected: return "person_visible"
        case .contactReady: return "ready_speak_now"
        case .conversation, .working, .listening, .speaking: return "conversation_active"
        }
    }
}

public enum SubconsciousIndicatorVisualState: String, Equatable, Sendable {
    case none
    case humanDetected = "human_detected"
    case eyeContact = "eye_contact"
}

public enum SubconsciousIndicatorInteractionState: String, Equatable, Sendable {
    case idle
    case conversation
    case preparingReply = "preparing_reply"
}

/// Visual contact is cleared only when L0 confirms its loss. Interaction
/// state remains available to the runtime, while hardware presentation is
/// derived from the visual state and may apply a separate session overlay.
public struct SubconsciousIndicatorInputs: Equatable, Sendable {
    public var visualState: SubconsciousIndicatorVisualState
    public var interactionState: SubconsciousIndicatorInteractionState

    public init(
        humanDetected: Bool = false,
        contactReady: Bool = false,
        conversation: Bool = false,
        working: Bool = false
    ) {
        visualState = contactReady
            ? .eyeContact
            : (humanDetected ? .humanDetected : .none)
        interactionState = working
            ? .preparingReply
            : (conversation ? .conversation : .idle)
    }

    public init(
        visualState: SubconsciousIndicatorVisualState = .none,
        interactionState: SubconsciousIndicatorInteractionState = .idle
    ) {
        self.visualState = visualState
        self.interactionState = interactionState
    }

    /// A fresh human observation is sufficient to communicate that SOMA has
    /// noticed someone. Face lock, motor motion, and conversation admission
    /// each retain their own stricter evidence requirements.
    public mutating func observeHumanVisualPresence() {
        if visualState == .none {
            visualState = .humanDetected
        }
    }

    public var humanDetected: Bool {
        get { visualState != .none }
        set {
            if newValue {
                if visualState == .none { visualState = .humanDetected }
            } else {
                visualState = .none
            }
        }
    }

    public var contactReady: Bool {
        get { visualState == .eyeContact }
        set {
            if newValue {
                visualState = .eyeContact
            } else if visualState == .eyeContact {
                visualState = .humanDetected
            }
        }
    }

    public var conversation: Bool {
        get { interactionState == .conversation }
        set {
            if newValue {
                interactionState = .conversation
            } else if interactionState == .conversation {
                interactionState = .idle
            }
        }
    }

    public var working: Bool {
        get { interactionState == .preparingReply }
        set {
            if newValue {
                interactionState = .preparingReply
            } else if interactionState == .preparingReply {
                interactionState = .idle
            }
        }
    }

    public var resolvedState: SubconsciousIndicatorState {
        switch interactionState {
        case .preparingReply:
            return .working
        case .conversation:
            return .conversation
        case .idle:
            switch visualState {
            case .eyeContact: return .contactReady
            case .humanDetected: return .humanDetected
            case .none: return .exploring
            }
        }
    }

    public var visualPresentationState: SubconsciousIndicatorState {
        // A live conversation is the sole interaction state that overrides
        // the visual layer. Preparing a response must not make the person
        // lose the visible-contact signal.
        if interactionState == .conversation {
            return .conversation
        }
        switch visualState {
        case .eyeContact: return .contactReady
        case .humanDetected: return .humanDetected
        case .none: return .exploring
        }
    }
}
