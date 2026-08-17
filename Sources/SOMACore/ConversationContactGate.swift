import Foundation

public enum ConversationOpeningAuthorization: String, Equatable, Sendable {
    case eyeContact = "eye_contact"
    case botInitiatedPulseResponse = "bot_initiated_pulse_response"
    case activeConversation = "active_conversation"
}

public struct ConversationContactConfiguration: Equatable, Sendable {
    public let eyeContactFreshnessMilliseconds: UInt64
    public let socialPulseResponseMilliseconds: UInt64
    public let conversationInactivityMilliseconds: UInt64

    public init(
        eyeContactFreshnessMilliseconds: UInt64 = 450,
        socialPulseResponseMilliseconds: UInt64 = 8_000,
        conversationInactivityMilliseconds: UInt64 = 60_000
    ) {
        precondition(eyeContactFreshnessMilliseconds > 0)
        precondition(socialPulseResponseMilliseconds > 0)
        precondition(conversationInactivityMilliseconds > 0)
        self.eyeContactFreshnessMilliseconds = eyeContactFreshnessMilliseconds
        self.socialPulseResponseMilliseconds = socialPulseResponseMilliseconds
        self.conversationInactivityMilliseconds = conversationInactivityMilliseconds
    }
}

/// Owns the boundary between ambient speech and an interaction addressed to
/// SOMA. The first human turn needs fresh directed eye-contact evidence unless
/// SOMA has just emitted an explicit social invitation. Follow-up turns use a
/// bounded conversation lease and therefore do not repeatedly demand gaze.
public struct ConversationContactGate: Sendable {
    public let configuration: ConversationContactConfiguration
    private var lastEyeContactNS: UInt64?
    private var socialPulseExpiresAtNS: UInt64?
    private var conversationExpiresAtNS: UInt64?

    public init(configuration: ConversationContactConfiguration = .init()) {
        self.configuration = configuration
    }

    public mutating func observeEyeContact(at monotonicNS: UInt64) {
        lastEyeContactNS = monotonicNS
    }

    public mutating func issueSocialPulse(at monotonicNS: UInt64) {
        socialPulseExpiresAtNS = addingMilliseconds(
            configuration.socialPulseResponseMilliseconds,
            to: monotonicNS
        )
    }

    public mutating func authorizeSpeechOnset(
        at monotonicNS: UInt64
    ) -> ConversationOpeningAuthorization? {
        expire(at: monotonicNS)
        if let conversationExpiresAtNS, monotonicNS < conversationExpiresAtNS {
            return .activeConversation
        }
        if isFresh(
            lastEyeContactNS,
            at: monotonicNS,
            maximumAgeMilliseconds: configuration.eyeContactFreshnessMilliseconds
        ) {
            return .eyeContact
        }
        if let socialPulseExpiresAtNS, monotonicNS < socialPulseExpiresAtNS {
            // One invitation authorizes one opening attempt. A persistent
            // exception would silently degrade into ambient wake-word mode.
            self.socialPulseExpiresAtNS = nil
            return .botInitiatedPulseResponse
        }
        return nil
    }

    public mutating func markConversationOpened(at monotonicNS: UInt64) {
        conversationExpiresAtNS = addingMilliseconds(
            configuration.conversationInactivityMilliseconds,
            to: monotonicNS
        )
        socialPulseExpiresAtNS = nil
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
        if let socialPulseExpiresAtNS, monotonicNS >= socialPulseExpiresAtNS {
            self.socialPulseExpiresAtNS = nil
        }
        if let conversationExpiresAtNS, monotonicNS >= conversationExpiresAtNS {
            self.conversationExpiresAtNS = nil
        }
    }

    private func isFresh(
        _ observedNS: UInt64?,
        at monotonicNS: UInt64,
        maximumAgeMilliseconds: UInt64
    ) -> Bool {
        guard let observedNS, monotonicNS >= observedNS else { return false }
        return monotonicNS - observedNS <= maximumAgeMilliseconds * 1_000_000
    }

    private func addingMilliseconds(_ milliseconds: UInt64, to monotonicNS: UInt64) -> UInt64 {
        let nanoseconds = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        guard !nanoseconds.overflow else { return UInt64.max }
        let result = monotonicNS.addingReportingOverflow(nanoseconds.partialValue)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

/// Keeps the LED invitation stable across brief landmark-gaze dropouts without
/// changing the much shorter eye-contact requirement for opening a voice turn.
/// The owner clears this lease when visual contact is conclusively lost.
public struct EyeContactIndicatorLease: Sendable {
    private let holdNS: UInt64
    private var observedNS: UInt64?
    private var sceneID: String?

    public init(holdMilliseconds: UInt64 = 3_000) {
        precondition(holdMilliseconds > 0)
        holdNS = holdMilliseconds * 1_000_000
    }

    public mutating func observe(at monotonicNS: UInt64) {
        observedNS = monotonicNS
        sceneID = nil
    }

    /// Starts a contact-ready indication for a particular face reference.
    /// Subsequent current observations of that same reference may maintain the
    /// indication even when the landmark gaze classifier momentarily drops.
    public mutating func observe(sceneID: String, at monotonicNS: UInt64) {
        self.sceneID = sceneID
        observedNS = monotonicNS
    }

    /// Extends an already-established social contact only for the same locked
    /// face. This intentionally does not affect the separate fresh-gaze gate
    /// required to authorize a spoken opening.
    @discardableResult
    public mutating func maintain(sceneID: String, at monotonicNS: UInt64) -> Bool {
        guard self.sceneID == sceneID else { return false }
        observedNS = monotonicNS
        return true
    }

    public mutating func clear() {
        observedNS = nil
        sceneID = nil
    }

    public func isActive(at monotonicNS: UInt64) -> Bool {
        guard let observedNS, monotonicNS >= observedNS else { return false }
        return monotonicNS - observedNS <= holdNS
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
        .working,
    ]

    public var configurationState: Self {
        switch self {
        case .listening, .speaking: .conversation
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
        case .conversation, .listening, .speaking: return "conversation_active"
        case .working: return "please_wait_preparing_reply"
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

/// The single semantic source for the LED. Visual contact is cleared only
/// when L0 confirms its loss; an open voice session cannot keep a visual
/// invitation asserted on its own.
public struct SubconsciousIndicatorInputs: Equatable, Sendable {
    public var visualState: SubconsciousIndicatorVisualState
    public var interactionState: SubconsciousIndicatorInteractionState
    /// E2B's simple "person present" control signal. It is OR'd with the
    /// face-detection visualState so E2B can add human detection (e.g. a person
    /// turned away that the face detector misses) without ever clearing a real
    /// face observation. E2B sets it on every cue: engage -> true, else false.
    public var auxiliaryHumanDetected: Bool

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
        auxiliaryHumanDetected = false
    }

    public init(
        visualState: SubconsciousIndicatorVisualState = .none,
        interactionState: SubconsciousIndicatorInteractionState = .idle
    ) {
        self.visualState = visualState
        self.interactionState = interactionState
        auxiliaryHumanDetected = false
    }

    /// Apply E2B's proportional reaction as a simple L0 control signal.
    public mutating func applyAuxiliaryReaction(_ reaction: L1AuxiliaryReaction) {
        switch reaction {
        case .engage:
            auxiliaryHumanDetected = true
        case .orient, .observe, .none:
            auxiliaryHumanDetected = false
        }
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
            case .none: return auxiliaryHumanDetected ? .humanDetected : .exploring
            }
        }
    }
}
