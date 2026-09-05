import Foundation
import SOMACore

enum AppServerLiveVoiceEvent: Sendable {
    case localHelperPrepared
    case localHelperUnavailable(reason: String)
    case launchRequested(authorization: String, personEntityID: UUID?)
    case active(threadID: String?, personEntityID: UUID?)
    case inputTransportStarted
    case outputPlaybackReady(mode: String, route: String, effectProfile: String)
    case audioPlayoutSourceSelected(source: String)
    case audioPlayoutStatus(
        state: String,
        sampleRate: Int,
        channels: Int,
        chunkDurationMilliseconds: Double,
        arrivalGapMilliseconds: Double?,
        queuedDurationMilliseconds: Double,
        underruns: Int
    )
    case naturalTurnTakingConfirmed
    case responseInterrupted
    case interruptedAudioCleared
    case proactiveOpeningTriggered
    case proactiveOpeningExtraOutputSuppressed
    case hermesReportOfferStarted(taskID: UUID)
    case hearingUser
    case hermesTaskResultAccepted(taskID: UUID)
    case hermesTaskResultRejected(taskID: UUID?, reason: String)
    case embodimentMCPCall(tool: String, status: String, error: String?)
    case inputAccepted(characters: Int)
    case realtimeEventType(type: String)
    case inputTranscriptionFailed(reason: String)
    case transcriptPartial(threadID: String?, turnGeneration: UInt64?, text: String)
    case transcriptFinalized(
        threadID: String?,
        turnGeneration: UInt64?,
        role: ConversationParticipantRole,
        text: String
    )
    case preparingResponse
    case responseStarted(latencyMilliseconds: Double)
    case assistantSpeechStarted
    case assistantSpeechEnded
    case assistantOutputReferenceReady(sampleRate: Int, samples: Int)
    case microphoneCaptureSuppressed
    case playbackEchoAssessed(relationship: LiveVoiceEchoRelationship, correlation: Double)
    case participantBargeInAdmitted(bufferedMilliseconds: Double)
    case acousticEchoDiscarded
    case responding
    case responseCompleted
    case ended(threadID: String?, personEntityID: UUID?, reason: String)
    case failed(threadID: String?, personEntityID: UUID?, reason: String)
}

private struct LiveVoiceHelperEvent: Decodable, Sendable {
    let event: String
    let threadID: String?
    let reason: String?
    let characters: Int?
    let role: String?
    let text: String?
    let tool: String?
    let status: String?
    let error: String?
    let taskID: String?
    let data: String?
    let sampleRate: Int?
    let samplesPerChannel: Int?
    let numChannels: Int?
    let resetReference: Bool?
    let mode: String?
    let route: String?
    let effectProfile: String?
    let source: String?
    let state: String?
    let chunkDurationMilliseconds: Double?
    let arrivalGapMilliseconds: Double?
    let queuedDurationMilliseconds: Double?
    let underruns: Int?
    let type: String?
    let turnGeneration: UInt64?

    enum CodingKeys: String, CodingKey {
        case event
        case threadID = "thread_id"
        case reason
        case characters
        case role
        case text
        case tool
        case status
        case error
        case taskID = "task_id"
        case data
        case sampleRate = "sample_rate"
        case samplesPerChannel = "samples_per_channel"
        case numChannels = "num_channels"
        case resetReference = "reset_reference"
        case mode
        case route
        case effectProfile = "effect_profile"
        case source
        case state
        case chunkDurationMilliseconds = "chunk_duration_ms"
        case arrivalGapMilliseconds = "arrival_gap_ms"
        case queuedDurationMilliseconds = "queued_ms"
        case underruns
        case type
        case turnGeneration = "turn_generation"
    }
}

private struct BufferedLiveAudio: Sendable {
    let data: String
    let sampleRate: Int
    let samplesPerChannel: Int
}

private struct CapturedLiveAudio: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let captureNS: UInt64
    let durationNS: UInt64
}

private enum LiveVoiceSessionTerminationError: LocalizedError {
    case noActiveSession
    case capabilityMismatch

    var errorDescription: String? {
        switch self {
        case .noActiveSession: "No active Live Voice session is available to end"
        case .capabilityMismatch: "The Live Voice capability does not own the active session"
        }
    }
}

final class AppServerLiveVoiceLauncher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soma.live-voice.app-server", qos: .userInitiated)
    private let projectDirectory: String
    private let voice: SOMARealtimeVoice
    private let voiceMode: SOMARealtimeVoiceMode
    private let audioOutputDeviceUID: String?
    private let embodimentSocketURL: URL?
    private let persistentAppServer: PersistentAppServerBroker?
    private let persistentSessionAuthorizer: (@Sendable (
        String,
        SOMASessionCapabilityScope,
        UInt64
    ) -> Result<Void, SOMASessionCapabilityError>)?
    private let requireVerifiedSpeakerForEveryTurn: Bool
    private let hermesAgentDelegationEnabled: Bool
    private let onEvent: @Sendable (AppServerLiveVoiceEvent) -> Void
    private var gate = LiveVoiceLaunchGate()
    private var inactivityGate = LiveVoiceSessionInactivityGate()
    private var inactivityTimer: DispatchWorkItem?
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var helperProcessGeneration: UInt64 = 0
    private var helperReady = false
    private var helperPrewarmFailureCount = 0
    private var helperPrewarmWorkItem: DispatchWorkItem?
    private var speakerEpisodeAudio = LiveVoiceTimestampedEpisodeBuffer<CapturedLiveAudio>(
        detectorHistoryNS: 2_000_000_000,
        maximumEpisodeDurationNS: 12_000_000_000
    )
    private var speakerEpisodeInProgress = false
    private var pendingLiveAudio: [BufferedLiveAudio] = []
    private var liveInputTrackReady = false
    private var capturingInitiatingTurn = false
    private var inputLeveler = LiveVoiceInputLeveler()
    private var duplexCaptureGate = LiveVoiceDuplexCaptureGate()
    private var echoReferenceMatcher = LiveVoiceEchoReferenceMatcher()
    private var acousticBargeInGate = LiveVoiceAcousticBargeInGate()
    private var bargeInEpisodeBoundary = LiveVoiceBargeInEpisodeBoundary()
    private var lastEchoRelationship: LiveVoiceEchoRelationship?
    private var outputReferenceReported = false
    private var duplexEpisodeInProgress = false
    private var duplexEpisodeAdmitted = false
    private var duplexSpeechActive = false
    private var duplexSpeakerCandidateVerified = false
    private var nextContinuousEchoAssessmentNS: UInt64 = 0
    private var inputTransportReported = false
    private var active = false
    private var activeTurnAudioAdmitted = false
    private var stopped = false
    private var generation: UInt64 = 0
    private var activePersonEntityID: UUID?
    private var activeThreadID: String?
    /// This stays only with the corresponding helper process. It prevents an
    /// older local MCP child from ending a newer participant's conversation.
    private var activeSessionCapability: String?
    private var latestParticipantTurnGeneration: UInt64 = 0
    private var awaitingAssistantResponseGeneration: UInt64?
    private var latestUserTranscriptNS: UInt64?
    private var assistantResponseGeneration: UInt64?
    private var assistantPlaybackGeneration: UInt64?
    private var participantContactOpening = false
    private var openingParticipantInputObserved = false
    private var proactiveOpeningAwaitingParticipant = false
    private var proactiveOpeningDelivered = false
    private var pendingHermesReportOfferTaskID: UUID?
    private var hermesResultAwaitingConfirmation = Set<UUID>()

    init(
        projectDirectory: String? = nil,
        voice: SOMARealtimeVoice = .maple,
        voiceMode: SOMARealtimeVoiceMode = .natural,
        audioOutputDeviceUID: String? = nil,
        embodimentSocketURL: URL? = nil,
        requireVerifiedSpeakerForEveryTurn: Bool = false,
        hermesAgentDelegationEnabled: Bool = true,
        inactivityTimeoutMilliseconds: UInt64 = 600_000,
        persistentAppServer: PersistentAppServerBroker? = nil,
        persistentSessionAuthorizer: (@Sendable (
            String,
            SOMASessionCapabilityScope,
            UInt64
        ) -> Result<Void, SOMASessionCapabilityError>)? = nil,
        onEvent: @escaping @Sendable (AppServerLiveVoiceEvent) -> Void
    ) {
        self.projectDirectory = projectDirectory
            ?? ProcessInfo.processInfo.environment["SOMA_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        self.voice = voice
        self.voiceMode = voiceMode
        self.audioOutputDeviceUID = SOMAControlSettings.normalizedDeviceUID(audioOutputDeviceUID)
        self.embodimentSocketURL = embodimentSocketURL
        self.requireVerifiedSpeakerForEveryTurn = requireVerifiedSpeakerForEveryTurn
        self.hermesAgentDelegationEnabled = hermesAgentDelegationEnabled
        inactivityGate = LiveVoiceSessionInactivityGate(
            timeoutMilliseconds: inactivityTimeoutMilliseconds
        )
        self.persistentAppServer = persistentAppServer
        self.persistentSessionAuthorizer = persistentSessionAuthorizer
        self.onEvent = onEvent
    }

    /// Warms only the local executable, audio output graph, and hidden
    /// WebView. The helper does not connect to App Server or create a Realtime
    /// session until it receives a session-specific start command.
    func prewarm() {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            if let reason = ensureLocalHelperRunning() {
                recordHelperPrewarmFailure(reason: reason)
            }
        }
    }

    func canStartHermesReportOffer(at monotonicNS: UInt64) -> Bool {
        queue.sync {
            !stopped
                && !active
                && gate.phase == .inactive
                && monotonicNS >= gate.retryAfterNS
        }
    }

    func startIfNeeded(
        authorization: String,
        context: CodexInteractionContext?,
        personEntityID: UUID? = nil,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            if active {
                return
            }
            guard gate.beginLaunch(at: monotonicNS) else { return }
            launch(
                authorization: String(authorization.prefix(64)),
                initialContext: context.map(Self.contextText) ?? "",
                sessionCapability: context?.sessionCapability,
                preferredLanguageTag: context?.preferredLanguageTag,
                languageStartInstruction: context?.languageStartInstruction,
                proactiveOpeningText: nil,
                personEntityID: personEntityID,
                personContextReference: context?.personEntityID,
                interactionAuthority: context?.interactionAuthority,
                at: monotonicNS
            )
        }
    }

    /// Starts the same account-backed Live session for an L1-authorized social
    /// opening. The directive is short-lived session context, not a stored
    /// transcript or a substitute for the normal conversation gate.
    func startProactiveOpening(
        context: CodexInteractionContext?,
        opening: L1PurposefulOpening,
        personEntityID: UUID,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            guard gate.beginLaunch(at: monotonicNS) else { return }
            let base = context.map(Self.contextText) ?? ""
            let exactOpening = opening.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !exactOpening.isEmpty else {
                gate.fail(at: monotonicNS)
                resetSessionEphemera(keepingAudioCapacity: false)
                return
            }
            let directive = "This is a closed-purpose L1-initiated interaction. The supplied objective and completion condition are private conversational orientation, never text to recite or a checklist to expose. L1 has already selected the one natural opening in the participant's preferred language. Deliver that exact opening once, then listen. After each reply, respond to what the participant actually said; let their answer determine the next conversational step. Surface a relevant information need only when it naturally fits the evolving conversation, and stop pursuing the objective once it is answered or declined. Do not dump multiple questions, narrate a plan, replace the opening with a generic greeting or offer of help, or invent another motive. If the purpose cannot be preserved, remain silent."
            launch(
                authorization: "l1_social_opening",
                initialContext: String([base, directive].filter { !$0.isEmpty }.joined(separator: "\n\n").prefix(24_000)),
                sessionCapability: context?.sessionCapability,
                preferredLanguageTag: context?.preferredLanguageTag,
                languageStartInstruction: context?.languageStartInstruction,
                proactiveOpeningText: String(exactOpening.prefix(1_024)),
                personEntityID: personEntityID,
                personContextReference: context?.personEntityID,
                interactionAuthority: context?.interactionAuthority,
                at: monotonicNS
            )
        }
    }

    /// A completed external task is a durable controller event, not synthetic
    /// participant speech. Offer it once to the currently recognized
    /// administrator and let L2 resolve the explicit yes/no answer through the
    /// task MCP before any result is disclosed.
    func startHermesReportOffer(
        context: CodexInteractionContext,
        task: HermesAgentTask,
        personEntityID: UUID,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped,
                  task.status == .completed,
                  task.reportedAt == nil,
                  task.reportOfferAt == nil,
                  gate.beginLaunch(at: monotonicNS) else { return }
            let base = Self.contextText(context)
            let directive = """
            This is a controller-authorized offer to report one completed Hermes task, not participant speech.
            pending_hermes_report_task_id: \(task.id.uuidString.lowercased())
            Ask the exact supplied opening once, then listen. Do not expose, summarize, or fetch the result before the administrator answers. After a clear acceptance, call resolve_hermes_report_offer once with this task ID and wants_report=true, then report only the returned actual result. After a clear decline, call it once with wants_report=false, acknowledge briefly, and do not reveal the result. If the answer is ambiguous, ask one concise clarification without calling the tool. Never delegate a new task for this offer.
            """
            pendingHermesReportOfferTaskID = task.id
            launch(
                authorization: "hermes_report_offer",
                initialContext: String([base, directive].filter { !$0.isEmpty }.joined(separator: "\n\n").prefix(24_000)),
                sessionCapability: context.sessionCapability,
                preferredLanguageTag: context.preferredLanguageTag,
                languageStartInstruction: context.languageStartInstruction,
                proactiveOpeningText: HermesReportOfferPrompt.question(
                    languageTag: context.preferredLanguageTag
                ),
                personEntityID: personEntityID,
                personContextReference: context.personEntityID,
                interactionAuthority: context.interactionAuthority,
                at: monotonicNS
            )
        }
    }

    /// Cancels only a participant-contact opening whose same-episode speaker
    /// attribution was conclusively contradicted before usable input reached
    /// Realtime. Missing gaze is not a revocation. L1-authorized proactive
    /// openings are unaffected.
    func revokeProvisionalParticipantOpening(reason: String) {
        queue.async { [weak self] in
            guard let self,
                  !stopped,
                  participantContactOpening,
                  !openingParticipantInputObserved,
                  active || gate.phase == .starting else {
                return
            }
            _ = closeSession(reason: String(reason.prefix(128)))
        }
    }

    func ingestAudio(
        samples: [Float],
        sampleRateHz: Double,
        captureNS: UInt64,
        durationNS: UInt64
    ) {
        guard !samples.isEmpty,
              sampleRateHz.isFinite,
              sampleRateHz >= 8_000,
              sampleRateHz <= 96_000,
              durationNS > 0 else { return }
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            routeAudioChunk(CapturedLiveAudio(
                samples: samples,
                sampleRate: Int(sampleRateHz.rounded()),
                captureNS: captureNS,
                durationNS: durationNS
            ))
        }
    }

    /// Releases the speech episode that caused the session to open into the
    /// same ordered input track used by every later turn. The local Worklet
    /// holds these samples until WebRTC connects, so the first turn needs no
    /// separate bootstrap item or replay path.
    func observeVoiceActivity(
        _ active: Bool,
        admitted: Bool = true,
        duplexSpeakerVerified: Bool = false,
        duplexSpeakerEvidenceNS: UInt64? = nil,
        discardBufferedEpisode: Bool = false,
        onsetCaptureNS: UInt64? = nil,
        assessedThroughCaptureNS: UInt64? = nil,
        preserveDetectorHistoryFromCaptureNS: UInt64? = nil,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            // VAD drives conditioning; speaker attribution controls only
            // transport. This preserves a quiet first utterance while the
            // bounded audiovisual attribution window is still pending.
            inputLeveler.observeVoiceActivity(active)
            let duplexVerificationRequired = self.active
                && duplexCaptureGate.requiresParticipantVerification(at: monotonicNS)
            duplexSpeechActive = active
            if active, let onsetCaptureNS {
                bargeInEpisodeBoundary.observeSpeechOnset(at: onsetCaptureNS)
            }
            duplexSpeakerCandidateVerified = active
                && duplexSpeakerVerified
                && !discardBufferedEpisode
                && (!duplexVerificationRequired || bargeInEpisodeBoundary.admitsSpeakerEvidence(
                    observedAt: duplexSpeakerEvidenceNS
                ))
            if active,
               let onsetCaptureNS,
               (!self.active || requireVerifiedSpeakerForEveryTurn || duplexVerificationRequired) {
                speakerEpisodeAudio.begin(
                    at: onsetCaptureNS,
                    splitting: Self.splitCapturedAudio
                )
                speakerEpisodeInProgress = true
                if duplexVerificationRequired {
                    duplexEpisodeInProgress = true
                    duplexEpisodeAdmitted = false
                }
            }
            let wasDuplexQuarantined = duplexCaptureGate.quarantinesMicrophone(at: monotonicNS)
            let echoAssessment = duplexVerificationRequired
                ? echoReferenceMatcher.assess()
                : nil
            if let echoAssessment,
               echoAssessment.relationship != lastEchoRelationship {
                lastEchoRelationship = echoAssessment.relationship
                onEvent(.playbackEchoAssessed(
                    relationship: echoAssessment.relationship,
                    correlation: echoAssessment.maximumCorrelation
                ))
            }
            let acousticAdmission = acousticBargeInGate.observe(
                speechActive: active,
                speakerVerified: duplexSpeakerCandidateVerified,
                relationship: echoAssessment?.relationship ?? .insufficientEvidence,
                at: monotonicNS
            )
            let effectiveDuplexSpeakerVerification = duplexSpeakerCandidateVerified
                && (!duplexVerificationRequired || acousticAdmission.admitted)
            duplexCaptureGate.observeParticipantSpeech(
                active: active,
                verified: effectiveDuplexSpeakerVerification,
                at: monotonicNS
            )
            if acousticAdmission.becameRevoked {
                duplexCaptureGate.revokeParticipantSpeechVerification(at: monotonicNS)
                activeTurnAudioAdmitted = false
            }
            let newlyReleasedBargeIn = wasDuplexQuarantined
                && !duplexCaptureGate.quarantinesMicrophone(at: monotonicNS)
            if self.active,
               active,
               effectiveDuplexSpeakerVerification,
               newlyReleasedBargeIn,
               let assessedThroughCaptureNS {
                let captured = speakerEpisodeAudio.take(
                    throughCaptureNS: assessedThroughCaptureNS,
                    splitting: Self.splitCapturedAudio
                )
                let durationMilliseconds = Double(captured.reduce(0) { $0 &+ $1.durationNS })
                    / 1_000_000
                for chunk in captured.map(makeBufferedAudio) { send(chunk) }
                duplexEpisodeAdmitted = true
                activeTurnAudioAdmitted = true
                onEvent(.participantBargeInAdmitted(
                    bufferedMilliseconds: durationMilliseconds
                ))
            }
            if active, admitted, !duplexVerificationRequired {
                activeTurnAudioAdmitted = true
            } else if !active {
                activeTurnAudioAdmitted = false
            }
            if discardBufferedEpisode {
                if let preserveDetectorHistoryFromCaptureNS {
                    speakerEpisodeAudio.end(
                        preservingDetectorHistoryFrom: preserveDetectorHistoryFromCaptureNS
                    )
                } else {
                    speakerEpisodeAudio.end()
                }
                speakerEpisodeInProgress = false
                if duplexEpisodeInProgress, !duplexEpisodeAdmitted {
                    onEvent(.acousticEchoDiscarded)
                }
                duplexEpisodeInProgress = false
                duplexEpisodeAdmitted = false
                capturingInitiatingTurn = false
                activeTurnAudioAdmitted = false
            }
            if !active, !discardBufferedEpisode {
                if let preserveDetectorHistoryFromCaptureNS {
                    speakerEpisodeAudio.end(
                        preservingDetectorHistoryFrom: preserveDetectorHistoryFromCaptureNS
                    )
                } else {
                    speakerEpisodeAudio.end()
                }
                speakerEpisodeInProgress = false
                if duplexEpisodeInProgress, !duplexEpisodeAdmitted {
                    onEvent(.acousticEchoDiscarded)
                }
                duplexEpisodeInProgress = false
                duplexEpisodeAdmitted = false
            }
            if self.active,
               duplexCaptureGate.quarantinesMicrophone(at: monotonicNS) {
                return
            }
            if self.active, requireVerifiedSpeakerForEveryTurn {
                if active, admitted, let assessedThroughCaptureNS {
                    let buffered = speakerEpisodeAudio
                        .take(
                            throughCaptureNS: assessedThroughCaptureNS,
                            splitting: Self.splitCapturedAudio
                        )
                        .map(makeBufferedAudio)
                    for chunk in buffered { send(chunk) }
                }
                return
            }
            guard gate.phase == .starting else { return }
            if active, admitted {
                if requireVerifiedSpeakerForEveryTurn {
                    guard let assessedThroughCaptureNS else { return }
                    let buffered = speakerEpisodeAudio
                        .take(
                            throughCaptureNS: assessedThroughCaptureNS,
                            splitting: Self.splitCapturedAudio
                        )
                        .map(makeBufferedAudio)
                    for chunk in buffered { send(chunk) }
                } else {
                    guard !capturingInitiatingTurn else { return }
                    capturingInitiatingTurn = true
                    let buffered = speakerEpisodeAudio.take().map(makeBufferedAudio)
                    for chunk in buffered { send(chunk) }
                }
            } else {
                capturingInitiatingTurn = false
            }
        }
    }

    private func routeAudioChunk(_ captured: CapturedLiveAudio) {
        echoReferenceMatcher.appendMicrophone(
            captured.samples,
            sampleRate: captured.sampleRate
        )
        if active,
           duplexSpeechActive,
           duplexCaptureGate.requiresParticipantVerification(at: captured.captureNS),
           captured.captureNS >= nextContinuousEchoAssessmentNS {
            let nextAssessment = captured.captureNS.addingReportingOverflow(100_000_000)
            nextContinuousEchoAssessmentNS = nextAssessment.overflow
                ? UInt64.max
                : nextAssessment.partialValue
            let wasQuarantined = duplexCaptureGate.quarantinesMicrophone(at: captured.captureNS)
            let assessment = echoReferenceMatcher.assess()
            if assessment.relationship != lastEchoRelationship {
                lastEchoRelationship = assessment.relationship
                onEvent(.playbackEchoAssessed(
                    relationship: assessment.relationship,
                    correlation: assessment.maximumCorrelation
                ))
            }
            let admission = acousticBargeInGate.observe(
                speechActive: true,
                speakerVerified: duplexSpeakerCandidateVerified,
                relationship: assessment.relationship,
                at: captured.captureNS
            )
            if admission.admitted {
                duplexCaptureGate.observeParticipantSpeech(
                    active: true,
                    verified: true,
                    at: captured.captureNS
                )
            } else if admission.becameRevoked {
                duplexCaptureGate.revokeParticipantSpeechVerification(at: captured.captureNS)
                activeTurnAudioAdmitted = false
            }
            if wasQuarantined,
               !duplexCaptureGate.quarantinesMicrophone(at: captured.captureNS) {
                let buffered = speakerEpisodeAudio.take()
                let durationMilliseconds = Double(buffered.reduce(0) { $0 &+ $1.durationNS })
                    / 1_000_000
                for chunk in buffered.map(makeBufferedAudio) { send(chunk) }
                duplexEpisodeAdmitted = true
                activeTurnAudioAdmitted = true
                onEvent(.participantBargeInAdmitted(
                    bufferedMilliseconds: durationMilliseconds
                ))
            }
        }
        if duplexCaptureGate.quarantinesMicrophone(at: captured.captureNS) {
            speakerEpisodeAudio.ingest(
                captured,
                captureNS: captured.captureNS,
                durationNS: captured.durationNS
            )
        } else if LiveVoiceAudioRoutingPolicy.forwards(
            sessionActive: active,
            requiresVerifiedSpeakerForEveryTurn: requireVerifiedSpeakerForEveryTurn,
            currentTurnAdmitted: activeTurnAudioAdmitted
        ), !requireVerifiedSpeakerForEveryTurn {
            send(makeBufferedAudio(captured))
        } else if capturingInitiatingTurn {
            send(makeBufferedAudio(captured))
        } else {
            speakerEpisodeAudio.ingest(
                captured,
                captureNS: captured.captureNS,
                durationNS: captured.durationNS
            )
        }
    }

    private func makeBufferedAudio(_ captured: CapturedLiveAudio) -> BufferedLiveAudio {
        let conditioned = inputLeveler.process(captured.samples)
        return BufferedLiveAudio(
            data: Self.pcm16Data(conditioned.samples).base64EncodedString(),
            sampleRate: captured.sampleRate,
            samplesPerChannel: captured.samples.count
        )
    }

    private func resetDuplexCaptureState() {
        duplexCaptureGate.reset()
        acousticBargeInGate.reset()
        bargeInEpisodeBoundary.reset()
        duplexEpisodeInProgress = false
        duplexEpisodeAdmitted = false
        duplexSpeechActive = false
        duplexSpeakerCandidateVerified = false
        nextContinuousEchoAssessmentNS = 0
    }

    private func resetSessionEphemera(keepingAudioCapacity: Bool) {
        activeTurnAudioAdmitted = false
        latestParticipantTurnGeneration = 0
        awaitingAssistantResponseGeneration = nil
        latestUserTranscriptNS = nil
        assistantResponseGeneration = nil
        assistantPlaybackGeneration = nil
        participantContactOpening = false
        openingParticipantInputObserved = false
        speakerEpisodeAudio.end(keepingCapacity: keepingAudioCapacity)
        speakerEpisodeInProgress = false
        pendingLiveAudio.removeAll(keepingCapacity: keepingAudioCapacity)
        liveInputTrackReady = false
        capturingInitiatingTurn = false
        inputLeveler.reset()
        resetDuplexCaptureState()
        inactivityTimer?.cancel()
        inactivityTimer = nil
        inactivityGate.close()
        proactiveOpeningAwaitingParticipant = false
        proactiveOpeningDelivered = false
        pendingHermesReportOfferTaskID = nil
    }

    private static func splitCapturedAudio(
        _ captured: CapturedLiveAudio,
        prefixDurationNS: UInt64
    ) -> (prefix: CapturedLiveAudio, suffix: CapturedLiveAudio)? {
        guard prefixDurationNS > 0,
              prefixDurationNS < captured.durationNS,
              captured.samples.count > 1 else { return nil }
        let requestedFraction = Double(prefixDurationNS) / Double(captured.durationNS)
        let prefixCount = min(
            captured.samples.count - 1,
            max(1, Int((Double(captured.samples.count) * requestedFraction).rounded()))
        )
        let suffixDurationNS = captured.durationNS - prefixDurationNS
        return (
            prefix: CapturedLiveAudio(
                samples: Array(captured.samples[..<prefixCount]),
                sampleRate: captured.sampleRate,
                captureNS: captured.captureNS - suffixDurationNS,
                durationNS: prefixDurationNS
            ),
            suffix: CapturedLiveAudio(
                samples: Array(captured.samples[prefixCount...]),
                sampleRate: captured.sampleRate,
                captureNS: captured.captureNS,
                durationNS: suffixDurationNS
            )
        )
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            let lifecycle: (threadID: String?, personEntityID: UUID?)? =
                active || activeThreadID != nil || activePersonEntityID != nil
                ? (activeThreadID, activePersonEntityID)
                : nil
            stopped = true
            generation &+= 1
            helperPrewarmWorkItem?.cancel()
            helperPrewarmWorkItem = nil
            _ = send(["type": "stop"], reportFailure: false)
            input = nil
            if let process, process.isRunning { process.terminate() }
            self.process = nil
            active = false
            activeThreadID = nil
            activePersonEntityID = nil
            activeSessionCapability = nil
            resetSessionEphemera(keepingAudioCapacity: false)
            if let lifecycle {
                onEvent(.failed(
                    threadID: lifecycle.threadID,
                    personEntityID: lifecycle.personEntityID,
                    reason: "service_shutdown"
                ))
            }
        }
    }

    /// The local MCP endpoint has already validated the capability's general
    /// scope. Match it to this particular helper before ending the session so
    /// a capability from an earlier conversation cannot affect a later one.
    func endCurrentSession(authorizedBy sessionCapability: String?) -> Result<Void, Error> {
        queue.sync {
            guard active else { return .failure(LiveVoiceSessionTerminationError.noActiveSession) }
            guard let activeSessionCapability,
                  let sessionCapability,
                  activeSessionCapability == sessionCapability
                    || persistentAppServer?.capability == sessionCapability else {
                return .failure(LiveVoiceSessionTerminationError.capabilityMismatch)
            }
            _ = closeActiveSession(reason: "participant_requested_end")
            return .success(())
        }
    }

    /// Delivers a completed background result into an already active L2
    /// conversation. It never opens a conversation on its own; otherwise the
    /// durable task remains pending for retrieval in a later session.
    func deliverHermesTaskResult(_ task: HermesAgentTask) -> Bool {
        queue.sync {
            sendHermesTaskResult(task)
        }
    }

    private func sendHermesTaskResult(_ task: HermesAgentTask) -> Bool {
        guard active,
              task.status == .completed,
              let result = task.result,
              hermesResultAwaitingConfirmation.insert(task.id).inserted else { return false }
        let envelope = """
        SOMA_HERMES_TASK_RESULT
        task_id: \(task.id.uuidString.lowercased())
        title: \(task.title)
        status: completed
        result:
        \(String(result.prefix(90_000)))
        """
        let sent = send([
            "type": "append_text",
            "taskID": task.id.uuidString.lowercased(),
            "data": envelope,
        ])
        if !sent { hermesResultAwaitingConfirmation.remove(task.id) }
        return sent
    }

    /// A dedicated persistent App Server owns one opaque boot capability. It
    /// never becomes an interaction grant by itself: each call is projected
    /// through the active session's short-lived grant while the Live helper is
    /// active, and returns nil for ordinary per-session tokens.
    func authorizePersistentBroker(
        token: String?,
        scope: SOMASessionCapabilityScope,
        at monotonicNS: UInt64
    ) -> Result<Void, SOMASessionCapabilityError>? {
        queue.sync {
            guard let persistentAppServer,
                  token == persistentAppServer.capability,
                  (active || gate.phase == .starting),
                  let activeSessionCapability,
                  let persistentSessionAuthorizer else {
                return nil
            }
            return persistentSessionAuthorizer(activeSessionCapability, scope, monotonicNS)
        }
    }

    private func launch(
        authorization: String,
        initialContext: String,
        sessionCapability: String?,
        preferredLanguageTag: String?,
        languageStartInstruction: String?,
        proactiveOpeningText: String?,
        personEntityID: UUID?,
        personContextReference: UUID?,
        interactionAuthority: SOMAInteractionAuthority?,
        at monotonicNS: UInt64
    ) {
        inputTransportReported = false
        pendingLiveAudio.removeAll(keepingCapacity: true)
        latestParticipantTurnGeneration = 0
        awaitingAssistantResponseGeneration = nil
        latestUserTranscriptNS = nil
        assistantResponseGeneration = nil
        assistantPlaybackGeneration = nil
        inputLeveler.reset()
        resetDuplexCaptureState()
        activeTurnAudioAdmitted = false
        participantContactOpening = proactiveOpeningText?.isEmpty != false
        openingParticipantInputObserved = false
        proactiveOpeningAwaitingParticipant = proactiveOpeningText?.isEmpty == false
        proactiveOpeningDelivered = false
        let persistentEndpoint: URL?
        if let persistentAppServer {
            switch persistentAppServer.ensureReady() {
            case let .success(endpoint):
                persistentEndpoint = endpoint
            case let .failure(error):
                gate.fail(at: monotonicNS)
                resetSessionEphemera(keepingAudioCapacity: false)
                onEvent(.failed(
                    threadID: nil,
                    personEntityID: personEntityID,
                    reason: String(error.localizedDescription.prefix(192))
                ))
                return
            }
        } else {
            persistentEndpoint = nil
        }
        if let reason = ensureLocalHelperRunning() {
            gate.fail(at: monotonicNS)
            resetSessionEphemera(keepingAudioCapacity: false)
            onEvent(.failed(
                threadID: nil,
                personEntityID: personEntityID,
                reason: reason
            ))
            return
        }
        activePersonEntityID = personEntityID
        activeSessionCapability = sessionCapability
        generation &+= 1
        let launchGeneration = generation
        let effectivePreferredLanguageTag = voiceMode.forcesEnglish
            ? "en"
            : (preferredLanguageTag ?? "")
        let effectiveLanguageStartInstruction = voiceMode.forcesEnglish
            ? ""
            : (languageStartInstruction ?? "")
        guard send([
            "type": "start",
            "initialContext": String(initialContext.prefix(24_000)),
            "sessionCapability": sessionCapability ?? "",
            "embodimentSocketPath": embodimentSocketURL?.path ?? "",
            "appServerURL": persistentEndpoint?.absoluteString ?? "",
            "preferredLanguageTag": effectivePreferredLanguageTag,
            "languageStartInstruction": effectiveLanguageStartInstruction,
            "proactiveOpeningText": proactiveOpeningText ?? "",
            "interactionAuthority": interactionAuthority?.rawValue ?? "",
            "personContextReference": personContextReference?.uuidString.lowercased() ?? "",
            "codexSandbox": somaEnvString("SOMA_L2_CODEX_SANDBOX", default: "danger-full-access"),
            "codexAdminOnly": somaEnvBool("SOMA_L2_CODEX_ADMIN_ONLY", default: false),
            "hermesAgentDelegationEnabled": hermesAgentDelegationEnabled,
        ], reportFailure: false) else {
            failCurrent(reason: "live_voice_start_transport_failed")
            return
        }
        onEvent(.launchRequested(authorization: authorization, personEntityID: personEntityID))
        if let taskID = pendingHermesReportOfferTaskID {
            onEvent(.hermesReportOfferStarted(taskID: taskID))
        }
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self,
                  generation == launchGeneration,
                  gate.phase == .starting else { return }
            failCurrent(reason: "live_voice_start_timeout")
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let event = try? JSONDecoder().decode(LiveVoiceHelperEvent.self, from: line) else {
                continue
            }
            switch event.event {
            case "ready":
                guard !helperReady else { continue }
                helperReady = true
                helperPrewarmFailureCount = 0
                helperPrewarmWorkItem?.cancel()
                helperPrewarmWorkItem = nil
                onEvent(.localHelperPrepared)
            case "active":
                guard !active else { continue }
                active = true
                if !requireVerifiedSpeakerForEveryTurn {
                    activeTurnAudioAdmitted = true
                }
                activeThreadID = event.threadID
                gate.observeActive()
                let activeNS = DispatchTime.now().uptimeNanoseconds
                armInactivityTimeout(at: activeNS)
                if !requireVerifiedSpeakerForEveryTurn || !speakerEpisodeInProgress {
                    speakerEpisodeAudio.end()
                }
                capturingInitiatingTurn = false
                onEvent(.active(threadID: event.threadID, personEntityID: activePersonEntityID))
            case "audio_input_ready":
                liveInputTrackReady = true
                let buffered = pendingLiveAudio
                pendingLiveAudio.removeAll(keepingCapacity: true)
                for chunk in buffered { _ = sendBufferedAudio(chunk) }
            case "audio_input_progress":
                guard !inputTransportReported else { continue }
                inputTransportReported = true
                onEvent(.inputTransportStarted)
            case "output_playback_ready":
                onEvent(.outputPlaybackReady(
                    mode: String((event.mode ?? "unknown").prefix(64)),
                    route: String((event.route ?? "unknown").prefix(128)),
                    effectProfile: String((event.effectProfile ?? "none").prefix(64))
                ))
            case "audio_playout_source_selected":
                onEvent(.audioPlayoutSourceSelected(
                    source: String((event.source ?? "unknown").prefix(64))
                ))
            case "audio_playout_status":
                onEvent(.audioPlayoutStatus(
                    state: String((event.state ?? "unknown").prefix(64)),
                    sampleRate: max(0, event.sampleRate ?? 0),
                    channels: max(0, event.numChannels ?? 0),
                    chunkDurationMilliseconds: max(0, event.chunkDurationMilliseconds ?? 0),
                    arrivalGapMilliseconds: event.arrivalGapMilliseconds,
                    queuedDurationMilliseconds: max(0, event.queuedDurationMilliseconds ?? 0),
                    underruns: max(0, event.underruns ?? 0)
                ))
            case "natural_turn_taking_confirmed":
                onEvent(.naturalTurnTakingConfirmed)
            case "response_interrupted":
                finishAssistantGeneration(
                    generation: event.turnGeneration,
                    at: DispatchTime.now().uptimeNanoseconds
                )
                onEvent(.responseInterrupted)
            case "interrupted_audio_cleared":
                finishAssistantPlayback(
                    generation: event.turnGeneration,
                    at: DispatchTime.now().uptimeNanoseconds
                )
                onEvent(.interruptedAudioCleared)
            case "proactive_opening_triggered":
                onEvent(.proactiveOpeningTriggered)
            case "input_speech_started":
                // Speech onset is enough to establish a participant turn for
                // the proactive-opening guard. The final transcript remains
                // the durable record, but an overlapping answer must not be
                // mistaken for unsolicited extra model speech.
                proactiveOpeningAwaitingParticipant = false
                if let turnGeneration = event.turnGeneration {
                    latestParticipantTurnGeneration = max(
                        latestParticipantTurnGeneration,
                        turnGeneration
                    )
                }
                observeOpeningParticipantInput()
                onEvent(.hearingUser)
            case "realtime_event_type":
                onEvent(.realtimeEventType(type: String((event.type ?? "unknown").prefix(128))))
            case "input_transcription_failed":
                onEvent(.inputTranscriptionFailed(
                    reason: String((event.reason ?? "realtime_input_transcription_failed").prefix(192))
                ))
            case "hermes_task_result_accepted":
                if let rawID = event.taskID, let taskID = UUID(uuidString: rawID) {
                    hermesResultAwaitingConfirmation.remove(taskID)
                    onEvent(.hermesTaskResultAccepted(taskID: taskID))
                }
            case "hermes_task_result_rejected":
                if let rawID = event.taskID, let taskID = UUID(uuidString: rawID) {
                    hermesResultAwaitingConfirmation.remove(taskID)
                }
                onEvent(.hermesTaskResultRejected(
                    taskID: event.taskID.flatMap(UUID.init(uuidString:)),
                    reason: String((event.reason ?? "unknown").prefix(192))
                ))
            case "embodiment_mcp_call":
                let tool = String((event.tool ?? "unknown").prefix(96))
                let status = String((event.status ?? "unknown").prefix(48))
                let error = event.error?.trimmingCharacters(in: .whitespacesAndNewlines)
                onEvent(.embodimentMCPCall(
                    tool: tool,
                    status: status,
                    error: error?.isEmpty == false ? String(error!.prefix(192)) : nil
                ))
            case "input_transcript_ready":
                if (event.characters ?? 0) > 0 {
                    observeOpeningParticipantInput()
                }
                onEvent(.inputAccepted(characters: max(0, event.characters ?? 0)))
            case "transcript_partial":
                guard let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                onEvent(.transcriptPartial(
                    threadID: event.threadID,
                    turnGeneration: event.turnGeneration,
                    text: String(text.prefix(4_096))
                ))
            case "transcript_finalized":
                guard let rawRole = event.role,
                      let role = ConversationParticipantRole(rawValue: rawRole),
                      let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                var resolvedTurnGeneration = event.turnGeneration
                if role == .assistant {
                    if proactiveOpeningAwaitingParticipant {
                        if proactiveOpeningDelivered {
                            onEvent(.proactiveOpeningExtraOutputSuppressed)
                            _ = closeActiveSession(reason: "proactive_opening_extra_output")
                            continue
                        }
                        proactiveOpeningDelivered = true
                    }
                } else {
                    observeOpeningParticipantInput()
                    proactiveOpeningAwaitingParticipant = false
                    let now = DispatchTime.now().uptimeNanoseconds
                    let turnGeneration: UInt64
                    if let supplied = event.turnGeneration {
                        turnGeneration = supplied
                    } else {
                        let next = latestParticipantTurnGeneration &+ 1
                        turnGeneration = next == 0 ? 1 : next
                    }
                    latestParticipantTurnGeneration = max(
                        latestParticipantTurnGeneration,
                        turnGeneration
                    )
                    resolvedTurnGeneration = turnGeneration
                    awaitingAssistantResponseGeneration = turnGeneration
                    latestUserTranscriptNS = now
                    recordUserActivity(at: now)
                    onEvent(.inputAccepted(characters: text.count))
                }
                onEvent(.transcriptFinalized(
                    threadID: event.threadID,
                    turnGeneration: resolvedTurnGeneration,
                    role: role,
                    text: String(text.prefix(8_192))
                ))
            case "response_preparing":
                // Realtime can create its response before publishing a separate
                // transcript event. Response creation itself proves that the
                // participant input was accepted; never terminate a valid native
                // Live turn because those asynchronous events arrived in the
                // opposite order.
                observeOpeningParticipantInput()
                guard beginAssistantGeneration(generation: event.turnGeneration) else { continue }
                onEvent(.preparingResponse)
            case "output_speech_started":
                observeOpeningParticipantInput()
                echoReferenceMatcher.reset()
                lastEchoRelationship = nil
                outputReferenceReported = false
                let outputStartedNS = DispatchTime.now().uptimeNanoseconds
                let turnGeneration = resolvedResponseGeneration(event.turnGeneration)
                guard beginAssistantPlayback(generation: turnGeneration) else { continue }
                duplexCaptureGate.beginAssistantOutput(at: outputStartedNS)
                bargeInEpisodeBoundary.beginAssistantOutput(at: outputStartedNS)
                onEvent(.microphoneCaptureSuppressed)
                onEvent(.assistantSpeechStarted)
                if awaitingAssistantResponseGeneration == turnGeneration,
                   let latestUserTranscriptNS {
                    let now = DispatchTime.now().uptimeNanoseconds
                    onEvent(.responseStarted(
                        latencyMilliseconds: elapsedMilliseconds(
                            from: latestUserTranscriptNS,
                            to: now
                        )
                    ))
                    awaitingAssistantResponseGeneration = nil
                    self.latestUserTranscriptNS = nil
                }
                onEvent(.responding)
            case "output_speech_ended":
                let outputEndedNS = DispatchTime.now().uptimeNanoseconds
                guard finishAssistantPlayback(
                    generation: event.turnGeneration ?? assistantPlaybackGeneration,
                    at: outputEndedNS
                ) else { continue }
                duplexCaptureGate.endAssistantOutput(at: outputEndedNS)
                bargeInEpisodeBoundary.endAssistantOutput()
                onEvent(.assistantSpeechEnded)
            case "assistant_output_reference":
                guard let data = event.data,
                      let sampleRate = event.sampleRate,
                      let channels = event.numChannels,
                      let expectedSamples = event.samplesPerChannel,
                      let samples = Self.decodePCM16(
                        data,
                        channels: channels,
                        expectedSamplesPerChannel: expectedSamples
                      ) else { continue }
                if event.resetReference == true {
                    echoReferenceMatcher.reset()
                    lastEchoRelationship = nil
                    outputReferenceReported = false
                }
                echoReferenceMatcher.appendReference(
                    samples,
                    sampleRate: sampleRate,
                    channels: channels
                )
                if !outputReferenceReported {
                    outputReferenceReported = true
                    onEvent(.assistantOutputReferenceReady(
                        sampleRate: sampleRate,
                        samples: expectedSamples
                    ))
                }
            case "response_completed":
                // Generation can complete before the remote playback buffer
                // drains, so microphone capture resumes only when playback
                // reports output_speech_ended.
                let completedCurrentTurn = finishAssistantResponseIfNeeded(
                    generation: event.turnGeneration,
                    at: DispatchTime.now().uptimeNanoseconds
                )
                if completedCurrentTurn { onEvent(.responseCompleted) }
            case "ended":
                guard active || gate.phase == .starting else { continue }
                let threadID = event.threadID ?? activeThreadID
                let personEntityID = activePersonEntityID
                active = false
                gate.observeEnded()
                process = nil
                input = nil
                activeThreadID = nil
                activePersonEntityID = nil
                activeSessionCapability = nil
                resetSessionEphemera(keepingAudioCapacity: false)
                scheduleHelperPrewarm()
                onEvent(.ended(
                    threadID: threadID,
                    personEntityID: personEntityID,
                    reason: String((event.reason ?? "session_ended").prefix(128))
                ))
            case "failed", "audio_rejected":
                let reason = event.reason ?? event.event
                if active || gate.phase == .starting {
                    failCurrent(reason: reason)
                } else {
                    if let process, process.isRunning { process.terminate() }
                    process = nil
                    input = nil
                    helperReady = false
                    recordHelperPrewarmFailure(reason: reason)
                }
            default:
                break
            }
        }
    }

    private func failCurrent(reason: String) {
        let threadID = activeThreadID
        let personEntityID = activePersonEntityID
        generation &+= 1
        active = false
        gate.fail(at: DispatchTime.now().uptimeNanoseconds)
        _ = send(["type": "stop"], reportFailure: false)
        if let process, process.isRunning { process.terminate() }
        self.process = nil
        input = nil
        activeThreadID = nil
        activePersonEntityID = nil
        activeSessionCapability = nil
        resetSessionEphemera(keepingAudioCapacity: false)
        scheduleHelperPrewarm()
        onEvent(.failed(
            threadID: threadID,
            personEntityID: personEntityID,
            reason: String(reason.prefix(192))
        ))
    }

    private func observeOpeningParticipantInput() {
        guard participantContactOpening,
              !openingParticipantInputObserved else { return }
        openingParticipantInputObserved = true
    }

    private func recordUserActivity(at monotonicNS: UInt64) {
        guard active, inactivityGate.recordUserActivity(at: monotonicNS) != nil else { return }
        armInactivityTimeout(at: monotonicNS)
    }

    private func resolvedResponseGeneration(_ supplied: UInt64?) -> UInt64 {
        supplied
            ?? awaitingAssistantResponseGeneration
            ?? assistantResponseGeneration
            ?? latestParticipantTurnGeneration
    }

    @discardableResult
    private func beginAssistantGeneration(generation supplied: UInt64?) -> Bool {
        let generation = resolvedResponseGeneration(supplied)
        guard generation >= latestParticipantTurnGeneration else { return false }
        assistantResponseGeneration = generation
        suspendUserSilenceTimeoutForAssistant()
        return true
    }

    @discardableResult
    private func beginAssistantPlayback(generation: UInt64) -> Bool {
        guard generation >= latestParticipantTurnGeneration else { return false }
        assistantPlaybackGeneration = generation
        suspendUserSilenceTimeoutForAssistant()
        return true
    }

    private func finishAssistantGeneration(generation: UInt64?, at monotonicNS: UInt64) {
        guard let generation, assistantResponseGeneration == generation else { return }
        assistantResponseGeneration = nil
        resumeUserSilenceTimeoutIfAssistantIdle(at: monotonicNS)
    }

    @discardableResult
    private func finishAssistantPlayback(generation: UInt64?, at monotonicNS: UInt64) -> Bool {
        guard let generation, assistantPlaybackGeneration == generation else { return false }
        assistantPlaybackGeneration = nil
        resumeUserSilenceTimeoutIfAssistantIdle(at: monotonicNS)
        return true
    }

    @discardableResult
    private func finishAssistantResponseIfNeeded(
        generation: UInt64?,
        at monotonicNS: UInt64
    ) -> Bool {
        guard let generation else { return false }
        if awaitingAssistantResponseGeneration == generation {
            awaitingAssistantResponseGeneration = nil
            latestUserTranscriptNS = nil
        }
        finishAssistantGeneration(generation: generation, at: monotonicNS)
        return generation == latestParticipantTurnGeneration
    }

    private func suspendUserSilenceTimeoutForAssistant() {
        guard active, inactivityGate.beginAssistantActivity() else { return }
        inactivityTimer?.cancel()
        inactivityTimer = nil
    }

    private func resumeUserSilenceTimeoutIfAssistantIdle(at monotonicNS: UInt64) {
        guard active,
              assistantResponseGeneration == nil,
              assistantPlaybackGeneration == nil,
              inactivityGate.endAssistantActivity(at: monotonicNS) != nil else { return }
        armInactivityTimeout(at: monotonicNS)
    }

    private func elapsedMilliseconds(from earlier: UInt64, to later: UInt64) -> Double {
        guard later >= earlier else { return 0 }
        return Double(later - earlier) / 1_000_000
    }

    private func armInactivityTimeout(at monotonicNS: UInt64) {
        let deadline = inactivityGate.deadlineNS ?? inactivityGate.activate(at: monotonicNS)
        inactivityTimer?.cancel()
        let remainingNS = deadline > monotonicNS ? deadline - monotonicNS : 0
        let work = DispatchWorkItem { [weak self] in
            self?.closeForUserSilence(at: DispatchTime.now().uptimeNanoseconds)
        }
        inactivityTimer = work
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(min(remainingNS, UInt64(Int.max)))),
            execute: work
        )
    }

    private func closeForUserSilence(at monotonicNS: UInt64) {
        guard active, inactivityGate.shouldClose(at: monotonicNS) else { return }
        _ = closeActiveSession(reason: "user_silence_timeout")
    }

    @discardableResult
    private func closeActiveSession(reason: String) -> Bool {
        guard active else { return false }
        return closeSession(reason: reason)
    }

    @discardableResult
    private func closeSession(reason: String) -> Bool {
        guard active || gate.phase == .starting else { return false }
        let threadID = activeThreadID
        let personEntityID = activePersonEntityID
        generation &+= 1
        active = false
        gate.observeEnded()
        _ = send(["type": "stop"], reportFailure: false)
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        activeThreadID = nil
        activePersonEntityID = nil
        activeSessionCapability = nil
        resetSessionEphemera(keepingAudioCapacity: false)
        scheduleHelperPrewarm()
        onEvent(.ended(
            threadID: threadID,
            personEntityID: personEntityID,
            reason: String(reason.prefix(128))
        ))
        return true
    }

    @discardableResult
    private func send(_ chunk: BufferedLiveAudio) -> Bool {
        guard liveInputTrackReady else {
            pendingLiveAudio.append(chunk)
            return false
        }
        return sendBufferedAudio(chunk)
    }

    @discardableResult
    private func sendBufferedAudio(_ chunk: BufferedLiveAudio) -> Bool {
        send([
            "type": "append_audio",
            "data": chunk.data,
            "sampleRate": chunk.sampleRate,
            "samplesPerChannel": chunk.samplesPerChannel,
        ])
    }

    @discardableResult
    private func send(_ object: [String: Any], reportFailure: Bool = true) -> Bool {
        guard let input,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        do {
            try input.write(contentsOf: data)
            try input.write(contentsOf: Data([0x0A]))
            return true
        } catch {
            guard reportFailure else { return false }
            let threadID = activeThreadID
            let personEntityID = activePersonEntityID
            self.input = nil
            active = false
            gate.fail(at: DispatchTime.now().uptimeNanoseconds)
            if let process, process.isRunning { process.terminate() }
            self.process = nil
            activeThreadID = nil
            activePersonEntityID = nil
            if !stopped {
                onEvent(.failed(
                    threadID: threadID,
                    personEntityID: personEntityID,
                    reason: "live_voice_control_pipe_failed"
                ))
            }
            return false
        }
    }

    private static func decodePCM16(
        _ encoded: String,
        channels: Int,
        expectedSamplesPerChannel: Int
    ) -> [Float]? {
        guard (1...8).contains(channels),
              (1...65_536).contains(expectedSamplesPerChannel),
              let data = Data(base64Encoded: encoded),
              data.count == expectedSamplesPerChannel * channels * 2 else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(expectedSamplesPerChannel * channels)
        for index in stride(from: 0, to: data.count, by: 2) {
            let bits = UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
            samples.append(Float(Int16(bitPattern: bits)) / 32_768)
        }
        return samples
    }

    /// Returns nil on success or a bounded diagnostic reason on failure.
    private func ensureLocalHelperRunning() -> String? {
        if let process, process.isRunning, input != nil {
            return nil
        }
        guard let helperURL = helperURL() else {
            return "live_voice_helper_not_found"
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = helperURL
        process.arguments = [
            "--cwd", projectDirectory,
            "--voice", voice.rawValue,
            "--voice-mode", voiceMode.rawValue,
        ]
        if let audioOutputDeviceUID {
            process.arguments?.append(contentsOf: ["--output-device-uid", audioOutputDeviceUID])
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        helperProcessGeneration &+= 1
        helperReady = false
        let processGeneration = helperProcessGeneration
        outputBuffer.removeAll(keepingCapacity: true)
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            queue.async {
                guard self.helperProcessGeneration == processGeneration,
                      self.process != nil else { return }
                self.consume(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            queue.async {
                guard self.helperProcessGeneration == processGeneration,
                      self.process === process,
                      !self.stopped else { return }
                let sessionWasStartingOrActive = self.active || self.gate.phase != .inactive
                let threadID = self.activeThreadID
                let personEntityID = self.activePersonEntityID
                self.process = nil
                self.input = nil
                self.active = false
                self.activeThreadID = nil
                self.activePersonEntityID = nil
                self.activeSessionCapability = nil
                self.helperReady = false
                self.resetSessionEphemera(keepingAudioCapacity: false)
                if sessionWasStartingOrActive {
                    self.gate.fail(at: DispatchTime.now().uptimeNanoseconds)
                    self.onEvent(.failed(
                        threadID: threadID,
                        personEntityID: personEntityID,
                        reason: "live_voice_helper_exited_\(process.terminationStatus)"
                    ))
                    self.scheduleHelperPrewarm()
                } else {
                    self.recordHelperPrewarmFailure(
                        reason: "live_voice_helper_exited_\(process.terminationStatus)"
                    )
                }
            }
        }
        do {
            try process.run()
        } catch {
            return String(error.localizedDescription.prefix(192))
        }
        self.process = process
        input = inputPipe.fileHandleForWriting
        return nil
    }

    private func scheduleHelperPrewarm(afterMilliseconds: Int = 350) {
        guard !stopped else { return }
        helperPrewarmWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !stopped, gate.phase == .inactive else { return }
            helperPrewarmWorkItem = nil
            if let reason = ensureLocalHelperRunning() {
                recordHelperPrewarmFailure(reason: reason)
            }
        }
        helperPrewarmWorkItem = work
        queue.asyncAfter(deadline: .now() + .milliseconds(afterMilliseconds), execute: work)
    }

    private func recordHelperPrewarmFailure(reason: String) {
        guard !stopped else { return }
        helperReady = false
        helperPrewarmFailureCount += 1
        onEvent(.localHelperUnavailable(reason: String(reason.prefix(192))))
        let retryDelaysMilliseconds = [750, 1_500, 3_000, 6_000, 12_000]
        guard helperPrewarmFailureCount <= retryDelaysMilliseconds.count else { return }
        scheduleHelperPrewarm(
            afterMilliseconds: retryDelaysMilliseconds[helperPrewarmFailureCount - 1]
        )
    }

    private func helperURL() -> URL? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SOMA_LIVE_VOICE_HELPER"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [
            executableURL.deletingLastPathComponent().appendingPathComponent("soma-live-voice"),
            executableURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Helpers/soma-live-voice"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func contextText(_ context: CodexInteractionContext) -> String {
        var lines = [
            "SOMA interaction context (machine observation, not user speech):",
            "privacy_scope: \(context.privacyScope)",
        ]
        if let value = context.situationSummary { lines.append("situation: \(value)") }
        if let value = context.identityReference { lines.append("identity: \(value)") }
        if context.personContextAvailable, let value = context.personEntityID {
            lines.append("person_context_reference: \(value.uuidString.lowercased())")
        }
        if let value = context.interactionAuthority { lines.append("interaction_authority: \(value.rawValue)") }
        if let value = context.personMemoryMission {
            lines.append("person_memory_mission_required: \(value.missingRequiredKeys.joined(separator: ","))")
        }
        if let value = context.preferredLanguageTag { lines.append("preferred_language: \(value)") }
        if let value = context.languageStartInstruction { lines.append("l1_language_instruction: \(value)") }
        if let value = context.rapportSummary { lines.append("rapport: \(value)") }
        if let value = context.embodimentSummary { lines.append("embodiment: \(value)") }
        if !context.activeTaskSummaries.isEmpty {
            lines.append("active_tasks: \(context.activeTaskSummaries.joined(separator: " | "))")
        }
        if !context.memorySummaries.isEmpty {
            lines.append("memory: \(context.memorySummaries.joined(separator: " | "))")
        }
        return String(lines.joined(separator: "\n").prefix(24_000))
    }

    private static func pcm16Data(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var value = Int16(
                max(Double(Int16.min), min(Double(Int16.max), Double(sample) * Double(Int16.max)))
            ).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}

func testAppServerLiveVoiceLauncher() -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let result = BlockingLiveVoiceTestResult()
    let launcher = AppServerLiveVoiceLauncher { event in
        switch event {
        case .active:
            if result.observeActive() { semaphore.signal() }
        case .naturalTurnTakingConfirmed:
            break
        case let .failed(_, _, reason):
            result.fail(reason)
            semaphore.signal()
        case .localHelperPrepared, .localHelperUnavailable,
             .launchRequested, .inputTransportStarted, .outputPlaybackReady,
             .audioPlayoutSourceSelected, .audioPlayoutStatus,
             .responseInterrupted, .interruptedAudioCleared, .proactiveOpeningTriggered,
             .proactiveOpeningExtraOutputSuppressed, .hermesReportOfferStarted, .hearingUser,
             .hermesTaskResultAccepted, .hermesTaskResultRejected, .embodimentMCPCall,
             .inputAccepted, .realtimeEventType, .inputTranscriptionFailed,
             .transcriptPartial, .transcriptFinalized, .preparingResponse, .responseStarted,
             .assistantSpeechStarted, .assistantSpeechEnded,
             .assistantOutputReferenceReady, .microphoneCaptureSuppressed,
             .playbackEchoAssessed, .participantBargeInAdmitted, .acousticEchoDiscarded,
             .responding, .responseCompleted, .ended:
            break
        }
    }
    launcher.startIfNeeded(
        authorization: "explicit_test",
        context: nil,
        at: DispatchTime.now().uptimeNanoseconds
    )
    _ = semaphore.wait(timeout: .now() + 25)
    let value = result.value ?? "timeout"
    launcher.stop()
    return value
}

private final class BlockingLiveVoiceTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var failureReason: String?

    func observeActive() -> Bool {
        lock.lock()
        active = true
        lock.unlock()
        return true
    }

    func fail(_ reason: String) {
        lock.lock()
        failureReason = reason
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        if let failureReason { return "failed:\(failureReason)" }
        if active { return "active" }
        return nil
    }
}
