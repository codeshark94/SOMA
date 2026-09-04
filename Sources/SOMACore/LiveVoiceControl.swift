import Foundation

/// Keeps a spoken interaction in the social frame established by the actual
/// participant turn. Assistance is one possible conversational mode, not the
/// default identity of the embodied agent.
public enum LiveVoiceConversationFrame {
    public static let socialStanceInstruction = """
    Conversational stance: SOMA is a socially embodied interlocutor, not a customer-service desk. Infer whether the participant's latest complete turn is social, informational, or task-oriented before choosing a response. Enter assistance mode only when the participant actually expresses a request, problem, or task. A greeting, acknowledgment, reaction, or incomplete fragment remains social contact: meet it at the same level, preserve conversational space, and never manufacture a generic offer of help as a fallback or closing question. Treat an acoustically uncertain, contextually contradictory, or semantically incomplete transcript as uncertain evidence. Ask one concise clarification in the participant's language instead of rationalizing a likely mistranscription into the prior topic. Do not repeat or embellish words that were not confidently understood.
    """

    public static func originInstruction(isProactiveSession: Bool) -> String {
        if isProactiveSession {
            return "This conversation was initiated by SOMA from a specific L1 social purpose, not by a participant request for help. Preserve that purpose privately across the exchange. After the exact opening, treat the participant's next utterance as an answer, reaction, or redirection of SOMA's opening unless they clearly make a separate request. Never reset into a generic service frame or act as though the participant opened this session. One opening earns one listening turn: before the participant speaks, do not add another thought, question, summary, or filler."
        }
        return "This conversation was initiated by the participant, but contact alone is not evidence of a service request. Classify the participant's most recent actual spoken message by its conversational function and respond to that function. Do not convert a greeting, acknowledgment, reaction, or unfinished fragment into an offer of assistance."
    }
}

public struct LiveVoiceLaunchGate: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case inactive
        case starting
        case active
    }

    public private(set) var phase: Phase = .inactive
    public private(set) var retryAfterNS: UInt64 = 0

    public init() {}

    public mutating func beginLaunch(at monotonicNS: UInt64) -> Bool {
        guard phase == .inactive, monotonicNS >= retryAfterNS else { return false }
        phase = .starting
        return true
    }

    public mutating func observeActive() {
        phase = .active
        retryAfterNS = 0
    }

    public mutating func observeEnded() {
        phase = .inactive
        retryAfterNS = 0
    }

    public mutating func fail(
        at monotonicNS: UInt64,
        retryMilliseconds: UInt64 = 5_000
    ) {
        phase = .inactive
        let delta = retryMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        if delta.overflow {
            retryAfterNS = UInt64.max
            return
        }
        let deadline = monotonicNS.addingReportingOverflow(delta.partialValue)
        retryAfterNS = deadline.overflow ? UInt64.max : deadline.partialValue
    }
}

public enum LiveVoiceOpeningOrigin: Equatable, Sendable {
    case participantContact
    case proactive
}

/// Releases one captured opening utterance only after the remote realtime
/// session and its WebRTC audio track are both active. This keeps prerecorded
/// PCM on the same transport as the rest of the participant's live speech.
public struct LiveVoiceOpeningAudioPlayoutGate: Equatable, Sendable {
    public private(set) var sessionActive = false
    public private(set) var inputTrackReady = false
    public private(set) var playoutAuthorized = false

    public init() {}

    public mutating func observeSessionActive() {
        sessionActive = true
    }

    public mutating func observeInputTrackReady() {
        inputTrackReady = true
    }

    public mutating func authorizePlayoutIfReady(hasBufferedAudio: Bool) -> Bool {
        guard hasBufferedAudio,
              sessionActive,
              inputTrackReady,
              !playoutAuthorized else { return false }
        playoutAuthorized = true
        return true
    }

    public mutating func reset() {
        sessionActive = false
        inputTrackReady = false
        playoutAuthorized = false
    }
}

public enum LiveVoiceOpeningAudioPolicy {
    /// Server-side turn detection needs an explicit acoustic offset after a
    /// buffered utterance. A finite silent tail on the WebRTC input track
    /// provides that boundary without converting or resynthesizing speech.
    public static let trailingSilenceMilliseconds = 480

    public static func trailingSilenceSampleCount(sampleRate: Int) -> Int? {
        guard (8_000...96_000).contains(sampleRate) else { return nil }
        let product = sampleRate.multipliedReportingOverflow(
            by: trailingSilenceMilliseconds
        )
        guard !product.overflow else { return nil }
        return product.partialValue / 1_000
    }
}

/// Classifies server-side realtime events that prove participant audio reached
/// the conversation backend. Transcript text may arrive later on the canonical
/// App Server notification stream, so admission must not depend on the data
/// channel event carrying a particular text payload shape.
public enum LiveVoiceRealtimeEventSemantics {
    public static func confirmsParticipantInput(type: String) -> Bool {
        switch type {
        case "input_audio_buffer.speech_started",
             "input_speech_started",
             "conversation.item.input_audio_transcription.delta",
             "conversation.item.input_audio_transcription.completed",
             "input_transcript.delta",
             "input_transcript.added",
             "input_transcript.completed":
            true
        default:
            false
        }
    }
}

public enum LiveVoiceWireTranscriptSource: String, Equatable, Sendable {
    case inputTranscript = "input_transcript"
    case delegation
}

/// A participant transcript recovered directly from the V3 realtime wire.
/// Frameless transcript additions are provisional display deltas. A client
/// delegation carries the authoritative utterance as `input_text` content.
/// Keeping the wire identity lets the conversation host reconcile later
/// app-server transcript notifications without creating a second turn.
public struct LiveVoiceWireTranscript: Equatable, Sendable {
    public let text: String
    public let itemID: String?
    public let turnID: String?
    public let source: LiveVoiceWireTranscriptSource
    public let authoritative: Bool

    public init(
        text: String,
        itemID: String?,
        turnID: String?,
        source: LiveVoiceWireTranscriptSource,
        authoritative: Bool
    ) {
        self.text = text
        self.itemID = itemID
        self.turnID = turnID
        self.source = source
        self.authoritative = authoritative
    }
}

public enum LiveVoiceWireTranscriptParser {
    public static func parse(_ event: [String: Any]) -> LiveVoiceWireTranscript? {
        guard let type = event["type"] as? String else { return nil }
        switch type {
        case "input_transcript.added", "input_transcript.completed":
            let item = event["item"] as? [String: Any]
            guard let text = normalizedText(
                (item?["text"] as? String)
                    ?? (event["transcript"] as? String)
                    ?? (event["text"] as? String)
            ) else { return nil }
            return LiveVoiceWireTranscript(
                text: text,
                itemID: identifier(item?["id"] ?? event["item_id"] ?? event["itemId"]),
                turnID: identifier(
                    item?["user_bidi_turn_id"]
                        ?? event["user_bidi_turn_id"]
                        ?? event["turn_id"]
                        ?? event["turnId"]
                ),
                source: .inputTranscript,
                authoritative: type == "input_transcript.completed"
            )
        case "delegation.created":
            guard let item = event["item"] as? [String: Any],
                  let text = delegationText(item) else {
                return nil
            }
            return LiveVoiceWireTranscript(
                text: text,
                itemID: identifier(item["id"]),
                turnID: identifier(item["user_bidi_turn_id"]),
                source: .delegation,
                authoritative: true
            )
        default:
            return nil
        }
    }

    private static func delegationText(_ item: [String: Any]) -> String? {
        if let legacy = normalizedText(item["input_transcript"] as? String) {
            return legacy
        }
        guard let content = item["content"] as? [[String: Any]] else { return nil }
        let combined = content
            .filter { ($0["type"] as? String) == "input_text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return normalizedText(combined)
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(8_192))
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : String(normalized.prefix(256))
    }
}

/// Realtime snapshots their available tools and startup instructions when the
/// session begins. The bounded capability barrier prevents the first spoken
/// turn from racing ahead with an "initializing" view of embodiment.
public enum LiveVoiceEmbodimentStartupPolicy {
    public static let verificationTimeoutMilliseconds: UInt64 = 5_000

    /// Local microphone/WebRTC offer preparation is safe to overlap with the
    /// capability snapshot because it does not create a remote Realtime
    /// session or consume a model turn.
    public static func permitsTransportPreparation(
        webViewReady: Bool,
        threadReady: Bool,
        transportAlreadyStarted: Bool
    ) -> Bool {
        webViewReady && threadReady && !transportAlreadyStarted
    }

    /// The remote session still waits for the bounded capability snapshot so
    /// its initial tool and instruction view cannot race MCP initialization.
    public static func permitsRealtimeStart(
        offerReady: Bool,
        capabilityVerificationFinished: Bool,
        realtimeAlreadyStarted: Bool
    ) -> Bool {
        offerReady
            && capabilityVerificationFinished
            && !realtimeAlreadyStarted
    }
}

public enum LiveVoiceHandoffResponseDisposition: Equatable, Sendable {
    case appendFinalSpeech
    case appendRecoverySpeech(LiveVoiceTurnRecoveryKind)
    case retainExistingRealtimeResponse
    case externalDelegationOwnsResponse
}

public enum LiveVoiceBackingTurnStatus: String, Equatable, Sendable {
    case completed
    case interrupted
    case failed
    case inProgress = "inProgress"

    public init(protocolValue: String?) {
        self = protocolValue.flatMap(Self.init(rawValue:)) ?? .failed
    }
}

public enum LiveVoiceTurnRecoveryKind: Equatable, Sendable {
    case failed
    case interrupted
    case emptyResult
    case timedOut
}

/// A deterministic voice-safe terminal response for infrastructure paths that
/// cannot produce their own agent message. This is deliberately separate from
/// model wording so a failed turn can never become silence.
public enum LiveVoiceTurnRecoveryResponse {
    public static func phrase(
        kind: LiveVoiceTurnRecoveryKind,
        languageTag: String?
    ) -> String {
        let language = languageTag?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return switch (languagePrefix(language), kind) {
        case ("ko", .failed):
            "요청을 처리하는 중 오류가 발생했습니다."
        case ("ko", .interrupted):
            "요청 처리가 중단됐습니다."
        case ("ko", .emptyResult):
            "요청은 들었지만 처리 결과를 만들지 못했습니다."
        case ("ko", .timedOut):
            "요청 처리가 지연되어 중단했습니다."
        case ("zh", .failed):
            "处理请求时发生了错误。"
        case ("zh", .interrupted):
            "请求处理已中断。"
        case ("zh", .emptyResult):
            "我收到了请求，但未能生成处理结果。"
        case ("zh", .timedOut):
            "请求处理超时，已停止。"
        case ("ja", .failed):
            "リクエストの処理中にエラーが発生しました。"
        case ("ja", .interrupted):
            "リクエストの処理が中断されました。"
        case ("ja", .emptyResult):
            "リクエストは受け取りましたが、処理結果を生成できませんでした。"
        case ("ja", .timedOut):
            "リクエストの処理がタイムアウトしたため停止しました。"
        case (_, .failed):
            "I encountered an error while processing that request."
        case (_, .interrupted):
            "That request was interrupted before it finished."
        case (_, .emptyResult):
            "I received the request but could not produce a result."
        case (_, .timedOut):
            "That request took too long, so I stopped it."
        }
    }

    private static func languagePrefix(_ value: String) -> String {
        if value.hasPrefix("ko") { return "ko" }
        if value.hasPrefix("zh") { return "zh" }
        if value.hasPrefix("ja") { return "ja" }
        return "en"
    }
}

/// Gives every participant turn an audible response owner. A grounded result
/// remains deliverable after a realtime preamble when tools performed work;
/// task delegation acknowledgements retain their dedicated controller path.
public enum LiveVoiceHandoffResponsePolicy {
    public static func disposition(
        hasAgentMessage: Bool,
        realtimeResponseSpoken: Bool,
        successfulExternalDelegation: Bool,
        containsAuthoritativeBackingWork: Bool,
        turnStatus: LiveVoiceBackingTurnStatus
    ) -> LiveVoiceHandoffResponseDisposition {
        if successfulExternalDelegation {
            return .externalDelegationOwnsResponse
        }
        if hasAgentMessage {
            // A realtime utterance made before a tool-backed result is only a
            // presentation preamble. The grounded Codex result must still be
            // delivered. With no backing work, retain the already-spoken
            // realtime answer so two equivalent answers are not voiced.
            if realtimeResponseSpoken && !containsAuthoritativeBackingWork {
                return .retainExistingRealtimeResponse
            }
            return .appendFinalSpeech
        }
        if realtimeResponseSpoken {
            return .retainExistingRealtimeResponse
        }
        return switch turnStatus {
        case .failed, .inProgress:
            .appendRecoverySpeech(.failed)
        case .interrupted:
            .appendRecoverySpeech(.interrupted)
        case .completed:
            .appendRecoverySpeech(.emptyResult)
        }
    }
}

/// Keeps the initial participant-contact authorization provisional until the
/// realtime transport confirms usable participant input. Proactive openings
/// have their own L1 authorization and are deliberately outside this rule.
public struct LiveVoiceInitialTurnValidation: Equatable, Sendable {
    public let transcriptTimeoutMilliseconds: UInt64
    public private(set) var origin: LiveVoiceOpeningOrigin?
    public private(set) var participantInputConfirmed = false
    public private(set) var transcriptDeadlineNS: UInt64?
    public private(set) var initialAudioSubmitted = false
    public private(set) var initialAudioTransportConfirmed = false
    public private(set) var serverSpeechDetected = false

    public init(transcriptTimeoutMilliseconds: UInt64 = 3_500) {
        precondition(transcriptTimeoutMilliseconds > 0)
        self.transcriptTimeoutMilliseconds = transcriptTimeoutMilliseconds
    }

    public mutating func begin(origin: LiveVoiceOpeningOrigin) {
        self.origin = origin
        participantInputConfirmed = false
        transcriptDeadlineNS = nil
        initialAudioSubmitted = false
        initialAudioTransportConfirmed = false
        serverSpeechDetected = false
    }

    @discardableResult
    public mutating func observeTransportActive(at monotonicNS: UInt64) -> UInt64? {
        guard origin == .participantContact,
              !participantInputConfirmed else {
            transcriptDeadlineNS = nil
            return nil
        }
        let delta = transcriptTimeoutMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        let deadline = monotonicNS.addingReportingOverflow(delta.partialValue)
        transcriptDeadlineNS = delta.overflow || deadline.overflow
            ? UInt64.max
            : deadline.partialValue
        return transcriptDeadlineNS
    }

    public mutating func confirmParticipantInput() {
        guard origin == .participantContact else { return }
        participantInputConfirmed = true
        transcriptDeadlineNS = nil
    }

    /// Confirms that the remote realtime transport, rather than only the
    /// local AudioWorklet, detected participant speech. Local PCM progress is
    /// a transport health signal and cannot establish a conversational turn.
    public mutating func observeServerSpeechDetected() {
        guard origin == .participantContact else { return }
        serverSpeechDetected = true
        confirmParticipantInput()
    }

    /// Tracks local transport health without treating it as evidence that the
    /// realtime service heard or understood a participant.
    public mutating func observeInitialAudioSubmitted() {
        guard origin == .participantContact else { return }
        initialAudioSubmitted = true
    }

    public mutating func observeInitialAudioTransportProgress() {
        guard origin == .participantContact else { return }
        initialAudioTransportConfirmed = true
    }

    public var isUnconfirmedParticipantOpening: Bool {
        origin == .participantContact && !participantInputConfirmed
    }

    public var shouldCloseWhenContactIsRevoked: Bool {
        isUnconfirmedParticipantOpening
    }

    public var permitsAssistantResponse: Bool {
        !isUnconfirmedParticipantOpening
    }

    public func shouldCloseForMissingTranscript(at monotonicNS: UInt64) -> Bool {
        guard isUnconfirmedParticipantOpening,
              let transcriptDeadlineNS else { return false }
        return monotonicNS >= transcriptDeadlineNS
    }

    public mutating func reset() {
        origin = nil
        participantInputConfirmed = false
        transcriptDeadlineNS = nil
        initialAudioSubmitted = false
        initialAudioTransportConfirmed = false
        serverSpeechDetected = false
    }
}

/// Owns the local lifetime of one active Live voice session. Only confirmed
/// user activity renews this lease; assistant speech must not keep an idle
/// microphone session alive indefinitely.
public struct LiveVoiceSessionInactivityGate: Equatable, Sendable {
    public let timeoutMilliseconds: UInt64
    public private(set) var deadlineNS: UInt64?
    public private(set) var assistantActivityInProgress = false

    public init(timeoutMilliseconds: UInt64 = 60_000) {
        precondition(timeoutMilliseconds > 0)
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    @discardableResult
    public mutating func activate(at monotonicNS: UInt64) -> UInt64 {
        renew(at: monotonicNS)
    }

    @discardableResult
    public mutating func recordUserActivity(at monotonicNS: UInt64) -> UInt64? {
        guard deadlineNS != nil else { return nil }
        return renew(at: monotonicNS)
    }

    /// Suspends user-silence expiry while the assistant is generating, using
    /// tools, or playing a response. This does not count assistant output as
    /// participant activity; it prevents SOMA from consuming the
    /// participant's listening window with its own turn.
    @discardableResult
    public mutating func beginAssistantActivity() -> Bool {
        guard deadlineNS != nil else { return false }
        assistantActivityInProgress = true
        return true
    }

    /// Starts a fresh participant-silence interval only after the entire
    /// assistant turn, including buffered playback, has finished.
    @discardableResult
    public mutating func endAssistantActivity(at monotonicNS: UInt64) -> UInt64? {
        guard deadlineNS != nil, assistantActivityInProgress else { return nil }
        assistantActivityInProgress = false
        return renew(at: monotonicNS)
    }

    public func shouldClose(at monotonicNS: UInt64) -> Bool {
        guard !assistantActivityInProgress, let deadlineNS else { return false }
        return monotonicNS >= deadlineNS
    }

    public mutating func close() {
        deadlineNS = nil
        assistantActivityInProgress = false
    }

    @discardableResult
    private mutating func renew(at monotonicNS: UInt64) -> UInt64 {
        let delta = timeoutMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        let result = monotonicNS.addingReportingOverflow(delta.partialValue)
        let deadline = delta.overflow || result.overflow ? UInt64.max : result.partialValue
        deadlineNS = deadline
        return deadline
    }
}

/// Keeps microphone turns from being assembled out of the assistant's own
/// rendered audio. The short trailing interval lets the microphone settle
/// after output playback ends without turning normal silence into a user turn.
public struct LiveVoicePlaybackCaptureGate: Sendable {
    private let trailingSuppressionNS: UInt64
    private var assistantOutputActive = false
    private var suppressUntilNS: UInt64 = 0

    public init(trailingSuppressionMilliseconds: UInt64 = 500) {
        precondition(trailingSuppressionMilliseconds > 0)
        trailingSuppressionNS = trailingSuppressionMilliseconds * 1_000_000
    }

    public mutating func beginAssistantOutput(at monotonicNS: UInt64) {
        assistantOutputActive = true
        suppressUntilNS = max(suppressUntilNS, monotonicNS)
    }

    public mutating func endAssistantOutput(at monotonicNS: UInt64) {
        assistantOutputActive = false
        let deadline = monotonicNS.addingReportingOverflow(trailingSuppressionNS)
        suppressUntilNS = deadline.overflow ? UInt64.max : max(suppressUntilNS, deadline.partialValue)
    }

    public func suppressesMicrophone(at monotonicNS: UInt64) -> Bool {
        assistantOutputActive || monotonicNS < suppressUntilNS
    }

    public mutating func reset() {
        assistantOutputActive = false
        suppressUntilNS = 0
    }
}

/// Resolves the participant evidence required to interrupt rendered assistant
/// audio. Direct gaze is an optional policy constraint; independent speaker
/// evidence remains necessary because ordinary VAD cannot distinguish a
/// participant from acoustic playback leaking into the camera microphone.
public enum LiveVoiceDuplexSpeakerPolicy {
    public static func verifiesParticipant(
        trackedFaceVisible: Bool,
        independentSpeakerEvidence: Bool,
        speechEvidenceQualified: Bool,
        directContactConfirmed: Bool,
        speakerAttributionRejected: Bool,
        requiresDirectGaze: Bool
    ) -> Bool {
        !speakerAttributionRejected
            && trackedFaceVisible
            && independentSpeakerEvidence
            && speechEvidenceQualified
            && (!requiresDirectGaze || directContactConfirmed)
    }
}

/// Quarantines microphone audio while remote speech is audible, while allowing
/// a verified participant to barge in without waiting for playback to finish.
/// Verification is sticky only for the current VAD episode.
public struct LiveVoiceDuplexCaptureGate: Sendable {
    private var playback: LiveVoicePlaybackCaptureGate
    private var participantSpeechActive = false
    private var verifiedParticipantSpeech = false
    private var unverifiedPlaybackEpisodeActive = false
    private var speechPredatesAssistantOutput = false

    public init(trailingSuppressionMilliseconds: UInt64 = 500) {
        playback = LiveVoicePlaybackCaptureGate(
            trailingSuppressionMilliseconds: trailingSuppressionMilliseconds
        )
    }

    public mutating func beginAssistantOutput(at monotonicNS: UInt64) {
        playback.beginAssistantOutput(at: monotonicNS)
        if participantSpeechActive {
            // The model may begin output before the local VAD publishes the
            // offset of the turn it just consumed. That continuing tail is not
            // a new barge-in episode and must never be submitted twice.
            speechPredatesAssistantOutput = true
            verifiedParticipantSpeech = false
            unverifiedPlaybackEpisodeActive = true
        }
    }

    public mutating func endAssistantOutput(at monotonicNS: UInt64) {
        playback.endAssistantOutput(at: monotonicNS)
    }

    public mutating func observeParticipantSpeech(
        active: Bool,
        verified: Bool,
        at monotonicNS: UInt64
    ) {
        if active,
           !participantSpeechActive,
           playback.suppressesMicrophone(at: monotonicNS) {
            speechPredatesAssistantOutput = false
            unverifiedPlaybackEpisodeActive = true
        }
        participantSpeechActive = active
        if !active {
            verifiedParticipantSpeech = false
            unverifiedPlaybackEpisodeActive = false
            speechPredatesAssistantOutput = false
        } else if verified, !speechPredatesAssistantOutput {
            verifiedParticipantSpeech = true
        }
    }

    public func requiresParticipantVerification(at monotonicNS: UInt64) -> Bool {
        playback.suppressesMicrophone(at: monotonicNS)
            || unverifiedPlaybackEpisodeActive
    }

    public func quarantinesMicrophone(at monotonicNS: UInt64) -> Bool {
        (playback.suppressesMicrophone(at: monotonicNS) || unverifiedPlaybackEpisodeActive)
            && !(participantSpeechActive && verifiedParticipantSpeech)
    }

    public mutating func revokeParticipantSpeechVerification(at monotonicNS: UInt64) {
        verifiedParticipantSpeech = false
        if participantSpeechActive, playback.suppressesMicrophone(at: monotonicNS) {
            unverifiedPlaybackEpisodeActive = true
        }
    }

    public mutating func reset() {
        playback.reset()
        participantSpeechActive = false
        verifiedParticipantSpeech = false
        unverifiedPlaybackEpisodeActive = false
        speechPredatesAssistantOutput = false
    }
}

public struct LiveVoiceConditionedAudio: Equatable, Sendable {
    public let samples: [Float]
    public let inputPeakDBFS: Double
    public let appliedGainDB: Double

    public init(samples: [Float], inputPeakDBFS: Double, appliedGainDB: Double) {
        self.samples = samples
        self.inputPeakDBFS = inputPeakDBFS
        self.appliedGainDB = appliedGainDB
    }
}

/// Aligns microphone speech admitted by the local VAD with the level expected
/// by the realtime conversation transport. Non-speech audio is never boosted;
/// a peak limiter bounds transitions from quiet to loud speech.
public struct LiveVoiceInputLeveler: Sendable {
    private let targetRMS: Float
    private let maximumGain: Float
    private let peakCeiling: Float
    private var voiceActive = false
    private var appliedGain: Float = 1

    public init(
        targetDBFS: Double = -26,
        maximumGainDB: Double = 24,
        peakCeiling: Float = 0.92
    ) {
        precondition(targetDBFS < 0)
        precondition(maximumGainDB >= 0)
        precondition(peakCeiling > 0 && peakCeiling <= 1)
        targetRMS = Float(pow(10, targetDBFS / 20))
        maximumGain = Float(pow(10, maximumGainDB / 20))
        self.peakCeiling = peakCeiling
    }

    public mutating func observeVoiceActivity(_ active: Bool) {
        voiceActive = active
        if !active { appliedGain = 1 }
    }

    public mutating func reset() {
        voiceActive = false
        appliedGain = 1
    }

    public mutating func process(_ samples: [Float]) -> LiveVoiceConditionedAudio {
        guard !samples.isEmpty else {
            return LiveVoiceConditionedAudio(
                samples: [],
                inputPeakDBFS: -.infinity,
                appliedGainDB: 0
            )
        }
        var squareSum: Double = 0
        var peak: Float = 0
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            peak = max(peak, abs(finite))
            squareSum += Double(finite * finite)
        }
        let rms = Float(sqrt(squareSum / Double(samples.count)))
        let inputPeakDBFS = peak > 0 ? 20 * log10(Double(peak)) : -.infinity
        guard voiceActive, rms > 0 else {
            appliedGain = 1
            return LiveVoiceConditionedAudio(
                samples: samples.map { $0.isFinite ? $0 : 0 },
                inputPeakDBFS: inputPeakDBFS,
                appliedGainDB: 0
            )
        }

        let speechGain = max(1, targetRMS / rms)
        let limiterGain = peak > 0 ? peakCeiling / peak : maximumGain
        let desiredGain = max(0.1, min(maximumGain, speechGain, limiterGain))
        // Quiet speech needs a fast attack. A sudden loud packet must reduce
        // gain immediately so the leveler cannot turn an ordinary transition
        // into clipping.
        if desiredGain < appliedGain {
            appliedGain = desiredGain
        } else {
            appliedGain += (desiredGain - appliedGain) * 0.85
        }
        let conditioned = samples.map { sample in
            max(-0.98, min(0.98, (sample.isFinite ? sample : 0) * appliedGain))
        }
        return LiveVoiceConditionedAudio(
            samples: conditioned,
            inputPeakDBFS: inputPeakDBFS,
            appliedGainDB: 20 * log10(Double(max(appliedGain, 0.000_001)))
        )
    }
}

public enum LiveVoiceAudioRoutingPolicy {
    public static func forwards(
        sessionActive: Bool,
        requiresVerifiedSpeakerForEveryTurn: Bool,
        currentTurnAdmitted: Bool
    ) -> Bool {
        sessionActive
            && (!requiresVerifiedSpeakerForEveryTurn || currentTurnAdmitted)
    }
}

/// Retains a short timestamped detector history, then cuts one bounded episode
/// at the VAD onset capture. This preserves audio queued while VAD inference is
/// in flight without admitting older inter-episode sound or duplicating the
/// onset frame.
public struct LiveVoiceTimestampedEpisodeBuffer<Element: Sendable>: Sendable {
    private struct Entry: Sendable {
        let value: Element
        let captureNS: UInt64
        let durationNS: UInt64
    }

    private let detectorHistoryNS: UInt64
    private let maximumEpisodeDurationNS: UInt64
    private var episodeActive = false
    private var detectorHistory: [Entry] = []
    private var episode: [Entry] = []
    private var episodeDurationNS: UInt64 = 0

    public init(
        detectorHistoryNS: UInt64,
        maximumEpisodeDurationNS: UInt64
    ) {
        precondition(detectorHistoryNS > 0)
        precondition(maximumEpisodeDurationNS > 0)
        self.detectorHistoryNS = detectorHistoryNS
        self.maximumEpisodeDurationNS = maximumEpisodeDurationNS
    }

    public mutating func ingest(
        _ value: Element,
        captureNS: UInt64,
        durationNS: UInt64
    ) {
        guard durationNS > 0 else { return }
        let entry = Entry(value: value, captureNS: captureNS, durationNS: durationNS)
        if episodeActive {
            appendToEpisode(entry)
            return
        }
        detectorHistory.append(entry)
        detectorHistory.removeAll {
            captureNS >= $0.captureNS && captureNS - $0.captureNS > detectorHistoryNS
        }
    }

    public mutating func begin(at onsetCaptureNS: UInt64) {
        episodeActive = true
        episode.removeAll(keepingCapacity: true)
        episodeDurationNS = 0
        for entry in detectorHistory where entry.captureNS >= onsetCaptureNS {
            appendToEpisode(entry)
        }
        detectorHistory.removeAll(keepingCapacity: true)
    }

    /// Starts an episode at an exact timestamp. If the onset falls inside a
    /// captured chunk, only the post-onset suffix enters the episode.
    public mutating func begin(
        at onsetCaptureNS: UInt64,
        splitting: (Element, UInt64) -> (prefix: Element, suffix: Element)?
    ) {
        episodeActive = true
        episode.removeAll(keepingCapacity: true)
        episodeDurationNS = 0
        for entry in detectorHistory where entry.captureNS > onsetCaptureNS {
            let startNS = entry.captureNS >= entry.durationNS
                ? entry.captureNS - entry.durationNS
                : 0
            if startNS < onsetCaptureNS,
               onsetCaptureNS < entry.captureNS {
                let prefixDurationNS = onsetCaptureNS - startNS
                if let split = splitting(entry.value, prefixDurationNS) {
                    appendToEpisode(Entry(
                        value: split.suffix,
                        captureNS: entry.captureNS,
                        durationNS: entry.durationNS - prefixDurationNS
                    ))
                }
            } else {
                appendToEpisode(entry)
            }
        }
        detectorHistory.removeAll(keepingCapacity: true)
    }

    public mutating func take() -> [Element] {
        let result = episode.map(\.value)
        episode.removeAll(keepingCapacity: true)
        episodeDurationNS = 0
        return result
    }

    public mutating func take(throughCaptureNS maximumCaptureNS: UInt64) -> [Element] {
        var boundary = 0
        while boundary < episode.count,
              episode[boundary].captureNS <= maximumCaptureNS {
            boundary += 1
        }
        guard boundary > 0 else { return [] }
        let released = Array(episode[..<boundary])
        episode.removeFirst(boundary)
        for entry in released { episodeDurationNS -= entry.durationNS }
        return released.map(\.value)
    }

    /// Releases exactly the portion covered by the latest detector result.
    /// A chunk crossing the boundary is split so a following offset or
    /// rejection cannot discard audio that has already been verified.
    public mutating func take(
        throughCaptureNS maximumCaptureNS: UInt64,
        splitting: (Element, UInt64) -> (prefix: Element, suffix: Element)?
    ) -> [Element] {
        var boundary = 0
        while boundary < episode.count,
              episode[boundary].captureNS <= maximumCaptureNS {
            boundary += 1
        }

        var released = boundary > 0 ? Array(episode[..<boundary]) : []
        if boundary > 0 {
            episode.removeFirst(boundary)
            for entry in released { episodeDurationNS -= entry.durationNS }
        }

        guard let crossing = episode.first else {
            return released.map(\.value)
        }
        let crossingStartNS = crossing.captureNS >= crossing.durationNS
            ? crossing.captureNS - crossing.durationNS
            : 0
        guard crossingStartNS < maximumCaptureNS,
              maximumCaptureNS < crossing.captureNS else {
            return released.map(\.value)
        }
        let prefixDurationNS = maximumCaptureNS - crossingStartNS
        guard prefixDurationNS < crossing.durationNS,
              let split = splitting(crossing.value, prefixDurationNS) else {
            return released.map(\.value)
        }
        let suffixDurationNS = crossing.durationNS - prefixDurationNS
        released.append(Entry(
            value: split.prefix,
            captureNS: maximumCaptureNS,
            durationNS: prefixDurationNS
        ))
        episode[0] = Entry(
            value: split.suffix,
            captureNS: crossing.captureNS,
            durationNS: suffixDurationNS
        )
        episodeDurationNS -= prefixDurationNS
        return released.map(\.value)
    }

    public mutating func end(keepingCapacity: Bool = true) {
        episodeActive = false
        episode.removeAll(keepingCapacity: keepingCapacity)
        detectorHistory.removeAll(keepingCapacity: keepingCapacity)
        episodeDurationNS = 0
    }

    public mutating func end(
        preservingDetectorHistoryFrom captureNS: UInt64,
        keepingCapacity: Bool = true
    ) {
        let preserved = (detectorHistory + episode).filter { $0.captureNS >= captureNS }
        episodeActive = false
        episode.removeAll(keepingCapacity: keepingCapacity)
        detectorHistory = preserved
        episodeDurationNS = 0
    }

    private mutating func appendToEpisode(_ entry: Entry) {
        episode.append(entry)
        let (sum, overflow) = episodeDurationNS.addingReportingOverflow(entry.durationNS)
        episodeDurationNS = overflow ? UInt64.max : sum
        while episodeDurationNS > maximumEpisodeDurationNS, episode.count > 1 {
            episodeDurationNS -= episode.removeFirst().durationNS
        }
    }
}
