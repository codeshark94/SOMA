import Foundation
import SOMACore

protocol L1ThoughtStreaming: AnyObject, Sendable {
    func observe(_ decision: FaceIdentityRuntimeDecision, label: String?, at monotonicNS: UInt64)
    func depart(_ entityID: UUID)
    func invalidateMemoryContext(for entityID: UUID)
    func recordNonverbalInvitation(with entityID: UUID, at monotonicNS: UInt64)
    func wakeFromAuxiliary(_ interrupt: L1AuxiliarySemanticInterrupt)
    func stop()
}

/// The sole process-level owner of SOMA's L1 working consciousness. Sensor and
/// memory inputs become evidence first; model calls are consequences of
/// workspace transitions rather than direct interrupt handlers.
final class PersistentConsciousnessStream: L1ThoughtStreaming, @unchecked Sendable {
    typealias SocialDecisionHandler = @Sendable (
        L1ExecutiveRequest,
        L1SocialDecision,
        KnownPersonPresence,
        UInt64
    ) -> Bool

    private enum IdentityKind: Equatable, Sendable {
        case enrolled
        case pseudonymous
    }

    private struct PresenceState {
        var presence: KnownPersonPresence
        var lastObservedNS: UInt64
        let identityKind: IdentityKind
        let label: String?
        let episodeID: UUID
        var opportunity: L1SocialOpportunity?
    }

    private struct PendingObservation {
        let similarity: Double
        let monotonicNS: UInt64
        let identityKind: IdentityKind
        let label: String?
    }

    private struct CachedMemoryContext {
        let context: L1MemoryContext
        let fetchedAtNS: UInt64
    }

    private let queue = DispatchQueue(label: "soma.l1.persistent-consciousness", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let workspace: PersistentMentalWorkspace
    private let checkpointStore: MentalWorkspaceCheckpointStore
    private var reasoner: GemmaConsciousnessRuntime!

    private let onHealth: @Sendable (String, String) -> Void
    private let onSocialDecision: SocialDecisionHandler
    private let currentPresenceValidator: (@Sendable (UUID, UInt64) -> Bool)?
    private let onAttentionAction: @Sendable (L1ExecutiveAction, String, UInt64) -> Bool
    private let behaviorContextProvider: @Sendable () -> L1BehaviorContext?
    private let memoryContext: L1MemoryContextProvider
    private let runtimeContext: @Sendable () -> L1SituationRuntimeContext
    private let socialAvailability: @Sendable () -> L1SocialAvailability
    private let visualResourceResolver: @Sendable ([String]) -> [L1VisualResource]
    private let currentFrameProvider: @Sendable () -> L1VisualResource?
    private let socialContactPatternProvider: @Sendable () -> L1ContactPattern?
    private let curiosityContextProvider: @Sendable () -> String?
    private let onCuriosityNeeds: @Sendable ([L1InformationNeed]) -> Void
    private let onMemoryProposals: @Sendable ([L1MemoryProposal], UUID?) -> Void
    private let activeLanguageProvider: @Sendable () -> String?
    private let toolExecutor: @Sendable (String, String) -> String

    private var scheduler = KnownPersonSocialOpportunityScheduler()
    private var presences: [UUID: PresenceState] = [:]
    private var cachedMemoryContexts: [UUID: CachedMemoryContext] = [:]
    private var pendingObservations: [UUID: PendingObservation] = [:]
    private var contextLookupsInFlight: Set<UUID> = []
    private var evidenceQueue: [MentalEvidenceEvent] = []
    private var forcedPeriodicEvidenceIDs: Set<String> = []
    private var evidenceInFlight = false
    private var contactIntegrator = L1SocialContactTemporalIntegrator()
    private var lastSocialAvailability = L1SocialAvailability()
    private var lastBehaviorSignature: String?
    private var stopped = false
    private var awarenessTimer: DispatchSourceTimer?
    private var consolidationTimer: DispatchSourceTimer?
    private let awarenessSamplingSeconds = 1.0
    private let memoryContextRefreshNS: UInt64 = 60_000_000_000
    private let presenceCurrentNS: UInt64 = 3_000_000_000

    private var consolidationIntervalSeconds: Double {
        min(max(somaEnvDouble("SOMA_L1_CONSOLIDATION_SECONDS", default: 600), 60), 3_600)
    }

    init(
        memoryContext: L1MemoryContextProvider,
        runtimeContext: @escaping @Sendable () -> L1SituationRuntimeContext = { .init() },
        socialAvailability: @escaping @Sendable () -> L1SocialAvailability = { .init() },
        visualResourceResolver: @escaping @Sendable ([String]) -> [L1VisualResource] = { _ in [] },
        currentFrameProvider: @escaping @Sendable () -> L1VisualResource? = { nil },
        socialContactPatternProvider: @escaping @Sendable () -> L1ContactPattern? = { nil },
        curiosityContextProvider: @escaping @Sendable () -> String? = { nil },
        onHealth: @escaping @Sendable (String, String) -> Void,
        onSocialDecision: @escaping SocialDecisionHandler,
        currentPresenceValidator: (@Sendable (UUID, UInt64) -> Bool)? = nil,
        behaviorContextProvider: @escaping @Sendable () -> L1BehaviorContext? = { nil },
        onAttentionAction: @escaping @Sendable (L1ExecutiveAction, String, UInt64) -> Bool = { _, _, _ in false },
        toolExecutor: @escaping @Sendable (String, String) -> String = { _, _ in "{}" },
        onCuriosityNeeds: @escaping @Sendable ([L1InformationNeed]) -> Void = { _ in },
        onMemoryProposals: @escaping @Sendable ([L1MemoryProposal], UUID?) -> Void = { _, _ in },
        activeLanguageProvider: @escaping @Sendable () -> String? = { nil }
    ) throws {
        queue.setSpecific(key: queueKey, value: 1)
        self.memoryContext = memoryContext
        self.runtimeContext = runtimeContext
        self.socialAvailability = socialAvailability
        self.visualResourceResolver = visualResourceResolver
        self.currentFrameProvider = currentFrameProvider
        self.socialContactPatternProvider = socialContactPatternProvider
        self.curiosityContextProvider = curiosityContextProvider
        self.onHealth = onHealth
        self.onSocialDecision = onSocialDecision
        self.currentPresenceValidator = currentPresenceValidator
        self.behaviorContextProvider = behaviorContextProvider
        self.onAttentionAction = onAttentionAction
        self.onCuriosityNeeds = onCuriosityNeeds
        self.onMemoryProposals = onMemoryProposals
        self.activeLanguageProvider = activeLanguageProvider
        self.toolExecutor = toolExecutor

        let memoryDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SOMA/memory", isDirectory: true)
        let key = try OwnerOnlyInstallationSecret.loadOrCreate(
            in: memoryDirectory,
            filename: "installation-key-v1.bin"
        )
        let restored = try MentalWorkspaceCheckpointStore.loadSelective(
            directoryURL: memoryDirectory,
            encryptionKey: key,
            at: Date()
        )
        let quietInterval = min(max(
            somaEnvDouble("SOMA_L1_REASONING_CADENCE_SECONDS", default: 150),
            30
        ), 600)
        workspace = PersistentMentalWorkspace(
            snapshot: restored ?? MentalWorkspaceSnapshot(updatedAt: Date()),
            policy: MentalDynamicsPolicy(quietExpectedThoughtIntervalSeconds: quietInterval),
            randomSeed: UInt64.random(in: 1 ... UInt64.max)
        )
        checkpointStore = try MentalWorkspaceCheckpointStore(
            directoryURL: memoryDirectory,
            encryptionKey: key
        )
        reasoner = try GemmaConsciousnessRuntime(
            onHealth: onHealth,
            thoughtCompletion: { [weak self] request, result, completedNS in
                self?.receiveThought(request: request, result: result, at: completedNS)
            },
            executiveCompletion: { [weak self] request, result, completedNS in
                self?.receiveExecutive(request: request, result: result, at: completedNS)
            }
        )
        if restored != nil {
            onHealth("workspace_restored", "selective=true; transient_context=stale")
        } else {
            onHealth("workspace_created", "revision=0")
        }
        startAwarenessTimer()
        startConsolidationTimer()
    }

    func observe(_ decision: FaceIdentityRuntimeDecision, label: String?, at monotonicNS: UInt64) {
        let entityID: UUID
        let similarity: Double
        let identityKind: IdentityKind
        switch decision {
        case let .known(id, value, _):
            entityID = id
            similarity = value
            identityKind = .enrolled
        case let .anonymous(id, _, value, _):
            entityID = id
            similarity = value
            identityKind = .pseudonymous
        case let .unknownCandidate(handle, confirmations):
            guard somaEnvBool("SOMA_L1_OPEN_WITH_UNKNOWN", default: false) else { return }
            entityID = FaceIdentityRuntime.pseudonymousEntityID(for: handle)
            similarity = min(Double(confirmations) / 3, 0.99)
            identityKind = .pseudonymous
        case .knownCandidate:
            return
        }
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            let observation = PendingObservation(
                similarity: similarity,
                monotonicNS: monotonicNS,
                identityKind: identityKind,
                label: label
            )
            if let cached = cachedMemoryContexts[entityID],
               monotonicNS >= cached.fetchedAtNS,
               monotonicNS - cached.fetchedAtNS < memoryContextRefreshNS {
                process(observation, for: entityID, with: cached.context)
                return
            }
            pendingObservations[entityID] = observation
            guard contextLookupsInFlight.insert(entityID).inserted else { return }
            Task { [weak self] in
                guard let self else { return }
                let placeAffiliation = self.runtimeContext().spatialContext?.placeAffiliation
                let context = await memoryContext.context(
                    for: entityID,
                    createPseudonymousEntity: identityKind == .pseudonymous,
                    placeAffiliation: placeAffiliation
                )
                queue.async { [weak self] in
                    guard let self, !stopped else { return }
                    contextLookupsInFlight.remove(entityID)
                    cachedMemoryContexts[entityID] = CachedMemoryContext(
                        context: context,
                        fetchedAtNS: DispatchTime.now().uptimeNanoseconds
                    )
                    guard let latest = pendingObservations.removeValue(forKey: entityID) else { return }
                    process(latest, for: entityID, with: context)
                }
            }
        }
    }

    func depart(_ entityID: UUID) {
        queue.async { [weak self] in
            guard let self, let removed = presences.removeValue(forKey: entityID) else { return }
            scheduler.endPresence(for: entityID)
            let remaining = Array(presences.keys)
            enqueueEvidence(MentalEvidenceEvent(
                id: "presence:\(removed.episodeID.uuidString.lowercased()):departed",
                kind: .personDeparted,
                summary: "A previously present person departed.",
                subjectEntityID: entityID,
                confidence: 1,
                novelty: 0.9,
                contextPatch: MentalContextPatch(
                    presentEntityIDs: remaining,
                    eyeContactActive: remaining.isEmpty ? false : nil,
                    participantSpeaking: remaining.isEmpty ? false : nil,
                    socialAvailability: remaining.isEmpty ? 0 : nil
                ),
                driveSignal: MentalDriveSignal(socialInterest: -0.25, interruptionPressure: -1)
            ))
        }
    }

    func invalidateMemoryContext(for entityID: UUID) {
        let remove = { [weak self] in _ = self?.cachedMemoryContexts.removeValue(forKey: entityID) }
        if DispatchQueue.getSpecific(key: queueKey) != nil { remove() } else { queue.sync(execute: remove) }
    }

    func recordNonverbalInvitation(with entityID: UUID, at monotonicNS: UInt64) {
        Task { [weak self] in
            await self?.memoryContext.recordSocialContact(
                .nonverbalInvitation,
                with: entityID,
                purpose: "L1 made a brief nonverbal invitation."
            )
        }
    }

    func wakeFromAuxiliary(_ interrupt: L1AuxiliarySemanticInterrupt) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            let kind: MentalEvidenceKind
            switch interrupt.situation {
            case .socialBid: kind = .directSocialBid
            case .objectPresentation: kind = .objectPresentation
            case .sceneTransition: kind = .sceneTransition
            case .ambient, .uncertain: kind = .ordinaryObservation
            }
            let hypothesisKind: MentalHypothesisKind
            switch interrupt.situation {
            case .socialBid: hypothesisKind = .social
            case .objectPresentation: hypothesisKind = .perceptual
            case .sceneTransition, .ambient, .uncertain: hypothesisKind = .situational
            }
            enqueueEvidence(MentalEvidenceEvent(
                id: "auxiliary:\(interrupt.requestID)",
                observedAt: Date(),
                kind: kind,
                summary: interrupt.evidence,
                confidence: interrupt.confidence,
                novelty: interrupt.score,
                hypothesis: interrupt.evidence.isEmpty ? nil : MentalHypothesisSeed(
                    kind: hypothesisKind,
                    content: interrupt.evidence,
                    confidence: interrupt.confidence,
                    salience: interrupt.score
                ),
                driveSignal: MentalDriveSignal(
                    curiosity: interrupt.reason == .ambiguity ? interrupt.score * 0.5 : 0,
                    socialInterest: interrupt.reason == .directSocialBid ? interrupt.score * 0.7 : 0,
                    interruptionPressure: interrupt.reason == .directSocialBid ? interrupt.score : 0
                )
            ))
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            awarenessTimer?.cancel()
            awarenessTimer = nil
            consolidationTimer?.cancel()
            consolidationTimer = nil
            reasoner.stop()
            presences.removeAll()
            pendingObservations.removeAll()
            evidenceQueue.removeAll()
        }
    }

    private func process(
        _ observation: PendingObservation,
        for entityID: UUID,
        with memory: L1MemoryContext
    ) {
        let availability = socialAvailability()
        let presence = KnownPersonPresence(
            entityID: entityID,
            recognitionConfidence: min(max(observation.similarity, 0), 1),
            proactiveContactPreference: memory.proactiveContactPreference,
            isSpeaking: availability.participantSpeaking,
            conversationActive: availability.conversationActive
        )
        if var existing = presences[entityID] {
            existing.presence = presence
            existing.lastObservedNS = observation.monotonicNS
            if let opportunity = scheduler.observe(
                presence,
                at: observation.monotonicNS,
                unitIntervalDraw: Double.random(in: 0 ... 1)
            ),
               existing.opportunity == nil {
                existing.opportunity = opportunity
                presences[entityID] = existing
                enqueueEvidence(socialAvailabilityEvidence(for: existing, memory: memory))
            } else {
                presences[entityID] = existing
            }
            return
        }

        let episodeID = UUID()
        var state = PresenceState(
            presence: presence,
            lastObservedNS: observation.monotonicNS,
            identityKind: observation.identityKind,
            label: observation.label,
            episodeID: episodeID,
            opportunity: nil
        )
        state.opportunity = scheduler.observe(
            presence,
            at: observation.monotonicNS,
            unitIntervalDraw: Double.random(in: 0 ... 1)
        )
        presences[entityID] = state
        let relationshipUncertainty = canonicalRelationshipUncertainty(memory.rapport)
        let identityDescription: String
        switch observation.identityKind {
        case .enrolled:
            if let label = observation.label, !label.isEmpty, label != "unknown" {
                identityDescription = "The enrolled person \(label) arrived; this supplied label is already their identity."
            } else {
                identityDescription = "An enrolled person arrived."
            }
        case .pseudonymous:
            identityDescription = "A locally pseudonymous recurring person arrived."
        }
        enqueueEvidence(MentalEvidenceEvent(
            id: "presence:\(episodeID.uuidString.lowercased()):arrived",
            kind: .personArrived,
            summary: identityDescription,
            subjectEntityID: entityID,
            confidence: presence.recognitionConfidence,
            novelty: 0.9,
            contextPatch: MentalContextPatch(
                presentEntityIDs: Array(presences.keys),
                participantSpeaking: availability.participantSpeaking,
                conversationActive: availability.conversationActive,
                socialAvailability: state.opportunity == nil ? 0 : 1,
                relationshipUncertainty: relationshipUncertainty
            ),
            driveSignal: MentalDriveSignal(socialInterest: 0.35)
        ))
        if state.opportunity != nil {
            enqueueEvidence(socialAvailabilityEvidence(for: state, memory: memory))
        }
    }

    private func socialAvailabilityEvidence(
        for state: PresenceState,
        memory: L1MemoryContext
    ) -> MentalEvidenceEvent {
        MentalEvidenceEvent(
            id: "presence:\(state.episodeID.uuidString.lowercased()):socially_available",
            kind: .ordinaryObservation,
            summary: "The current person is now eligible for a bounded social executive decision.",
            subjectEntityID: state.presence.entityID,
            confidence: state.presence.recognitionConfidence,
            novelty: 0.6,
            contextPatch: MentalContextPatch(
                presentEntityIDs: Array(presences.keys),
                socialAvailability: 1,
                relationshipUncertainty: canonicalRelationshipUncertainty(memory.rapport)
            ),
            driveSignal: MentalDriveSignal(socialInterest: 0.2)
        )
    }

    private func enqueueEvidence(_ event: MentalEvidenceEvent) {
        guard !event.id.isEmpty else { return }
        if evidenceQueue.contains(where: { $0.id == event.id }) { return }
        evidenceQueue.append(event)
        drainEvidenceQueue()
    }

    private func drainEvidenceQueue() {
        guard !stopped, !evidenceInFlight, !evidenceQueue.isEmpty else { return }
        evidenceInFlight = true
        let event = evidenceQueue.removeFirst()
        let forcedPeriodic = forcedPeriodicEvidenceIDs.remove(event.id) != nil
        Task { [weak self] in
            guard let self else { return }
            let transition = await workspace.ingest(event)
            queue.async { [weak self] in
                guard let self, !stopped else { return }
                evidenceInFlight = false
                record(transition, event: event)
                if transition.changed {
                    persist(transition.after)
                }
                if transition.delta.meaningfulTransition || forcedPeriodic {
                    submitThought(
                        for: event,
                        snapshot: transition.after,
                        wakeKind: forcedPeriodic ? .periodic : .event
                    )
                }
                drainEvidenceQueue()
            }
        }
    }

    private func submitThought(
        for event: MentalEvidenceEvent,
        snapshot: MentalWorkspaceSnapshot,
        wakeKind: L1ThoughtWakeKind
    ) {
        let entityID = event.subjectEntityID ?? snapshot.context.presentEntityIDs.first
        let memory = entityID.flatMap { cachedMemoryContexts[$0]?.context }
        let environment = runtimeContext()
        // Periodic cognition evaluates the persistent workspace; attaching a
        // fresh frame when no semantic transition occurred invites the model to
        // narrate pixels again. Event-driven thought may use the current view,
        // while periodic thought must explicitly request visual evidence if its
        // existing hypotheses genuinely require it.
        let visual = wakeKind == .event ? currentFrameProvider() : nil
        let state = entityID.flatMap { presences[$0] }
        let request = L1ThoughtRequest(
            observedAt: Date(),
            wakeKind: wakeKind,
            workspace: snapshot,
            evidence: [event],
            beliefSummary: event.summary,
            presentEntityIDs: snapshot.context.presentEntityIDs,
            memory: memory?.projections ?? [],
            informationNeeds: memory?.informationNeeds ?? [],
            rapport: memory?.rapport,
            preferredLanguageTag: memory.flatMap(effectiveLanguageTag),
            contactHistory: memory?.contactHistory ?? [],
            spatialContext: environment.spatialContext,
            dailyWorldMemory: environment.dailyWorldMemory,
            visualResourceOffers: environment.visualResourceOffers,
            visuals: [visual].compactMap { $0 },
            socialOpportunity: state?.opportunity,
            contactPattern: contactIntegrator.snapshot(at: DispatchTime.now().uptimeNanoseconds),
            behaviorContext: behaviorContextProvider(),
            curiosityContext: curiosityContextProvider(),
            personPreferences: memory?.personPreferences,
            spokenOpeningTendency: min(max(somaEnvDouble("SOMA_L1_SPOKEN_OPENING_TENDENCY", default: 0.7), 0), 1),
            recalledEpisodes: memory?.recalledEpisodes ?? [],
            perceptionAgeSeconds: perceptionAgeSeconds(of: visual)
        )
        onHealth(
            "thought_wake",
            "cause=\(wakeKind.rawValue); evidence=\(event.kind.rawValue); revision=\(snapshot.revision); cycle=\(request.cycleID.uuidString.lowercased())"
        )
        reasoner.submitThought(request)
    }

    private func receiveThought(
        request: L1ThoughtRequest,
        result: Result<L1ThoughtUpdate, Error>,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            guard case let .success(update) = result else {
                if case let .failure(error) = result {
                    onHealth("thought_held", "reason=\(String(error.localizedDescription.prefix(240)))")
                }
                return
            }
            if request.visuals.isEmpty, !update.requestedVisualResourceIDs.isEmpty {
                let resources = visualResourceResolver(update.requestedVisualResourceIDs)
                if !resources.isEmpty {
                    let followup = request.continuing(with: resources)
                    onHealth("visual_followup", "resources=\(resources.count); revision=\(request.workspace.revision)")
                    reasoner.submitThought(followup)
                    return
                }
                onHealth("visual_request_unavailable", "resources=\(update.requestedVisualResourceIDs.count)")
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let transition = try await workspace.applyThoughtUpdate(update, at: Date())
                    queue.async { [weak self] in
                        guard let self, !stopped else { return }
                        persist(transition.after)
                        handleAppliedThought(
                            request: request,
                            update: update,
                            transition: transition,
                            at: monotonicNS
                        )
                    }
                } catch {
                    queue.async { [weak self] in
                        if case let PersistentMentalWorkspaceError.staleRevision(expected, actual) = error {
                            self?.onHealth(
                                "thought_superseded",
                                "expected_revision=\(expected); actual_revision=\(actual); pending_evidence_is_coalesced=true"
                            )
                        } else {
                            self?.onHealth("thought_held", "reason=\(String(error.localizedDescription.prefix(240)))")
                        }
                    }
                }
            }
        }
    }

    private func handleAppliedThought(
        request: L1ThoughtRequest,
        update: L1ThoughtUpdate,
        transition: WorkspaceTransition,
        at monotonicNS: UInt64
    ) {
        onHealth(
            "foreground_thought",
            "revision=\(transition.after.revision); channel=\(update.channel.rawValue); continuity=\(update.continuity.rawValue); text=\(update.innerMonologue)"
        )
        if !update.memoryProposals.isEmpty {
            onMemoryProposals(update.memoryProposals, request.socialOpportunity?.entityID)
        }
        if !request.informationNeeds.isEmpty { onCuriosityNeeds(request.informationNeeds) }
        guard let intention = update.intention,
              intention.pressure > 0,
              let foreground = transition.after.foregroundThought else {
            return
        }
        let actions = availableActions(for: request, intention: intention)
        let executive = L1ExecutiveRequest(
            observedAt: Date(),
            workspaceRevision: transition.after.revision,
            intention: intention,
            foregroundThought: foreground,
            relatedHypotheses: transition.after.hypotheses.filter {
                foreground.hypothesisIDs.contains($0.id)
            },
            context: transition.after.context,
            availableActions: actions,
            socialOpportunity: request.socialOpportunity,
            behaviorContext: request.behaviorContext,
            informationNeeds: request.informationNeeds,
            contactHistory: request.contactHistory,
            rapport: request.rapport,
            preferredLanguageTag: request.preferredLanguageTag,
            personPreferences: request.personPreferences,
            memorySummaries: request.memory.map(\.summary),
            recalledEpisodes: request.recalledEpisodes,
            evidenceIDs: intention.evidenceIDs
        )
        onHealth(
            "executive_wake",
            "revision=\(executive.workspaceRevision); intention=\(intention.id.uuidString.lowercased()); pressure=\(String(format: "%.2f", intention.pressure)); actions=\(actions.map(\.rawValue).joined(separator: ","))"
        )
        reasoner.submitExecutive(executive)
    }

    private func receiveExecutive(
        request: L1ExecutiveRequest,
        result: Result<L1ExecutiveDecision, Error>,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            guard case let .success(decision) = result else {
                if case let .failure(error) = result {
                    onHealth("executive_held", "reason=\(String(error.localizedDescription.prefix(240)))")
                }
                return
            }
            onHealth(
                "executive_decision",
                "revision=\(decision.expectedRevision); intention=\(decision.intentionEpisodeID.uuidString.lowercased()); action=\(decision.action.rawValue); confidence=\(String(format: "%.2f", decision.confidence)); rationale=\(decision.rationale)"
            )
            Task { [weak self] in
                guard let self else { return }
                let snapshot = await workspace.currentSnapshot()
                queue.async { [weak self] in
                    guard let self, !stopped else { return }
                    guard snapshot.revision == request.workspaceRevision,
                          snapshot.context.conversationActive == false else {
                        onHealth("executive_held", "reason=stale_workspace_or_conversation; expected=\(request.workspaceRevision); actual=\(snapshot.revision)")
                        return
                    }
                    let applied = applyExecutive(decision, request: request, at: monotonicNS)
                    onHealth(
                        applied ? "action_applied" : "action_held",
                        "action=\(decision.action.rawValue); intention=\(decision.intentionEpisodeID.uuidString.lowercased()); rationale=\(decision.rationale)"
                    )
                    guard applied else { return }
                    Task { [weak self] in
                        guard let self else { return }
                        if await workspace.markIntentionExecuted(decision.intentionEpisodeID, at: Date()) {
                            let saved = await workspace.currentSnapshot()
                            try? await checkpointStore.save(saved)
                        }
                    }
                }
            }
        }
    }

    private func applyExecutive(
        _ decision: L1ExecutiveDecision,
        request: L1ExecutiveRequest,
        at monotonicNS: UInt64
    ) -> Bool {
        switch decision.action {
        case .noAction:
            return true
        case .resumeScanning, .seekPeople, .acknowledgePerson:
            return onAttentionAction(decision.action, decision.rationale, monotonicNS)
        case .inspectAttentionTarget:
            return executeInspectionIntention(request.intention)
        case .nonverbalInvitation, .spokenOpening:
            guard let opportunity = request.socialOpportunity,
                  var state = presences[opportunity.entityID],
                  currentPresenceValidator?(opportunity.entityID, monotonicNS) ?? true,
                  !socialAvailability().conversationActive else {
                return false
            }
            state.lastObservedNS = monotonicNS
            presences[opportunity.entityID] = state
            let socialAction: L1SocialAction = decision.action == .spokenOpening
                ? .spokenOpening : .nonverbalInvitation
            let opening: ProactiveOpeningContent?
            if decision.action == .spokenOpening,
               let motiveID = decision.motiveID,
               let text = decision.opening, !text.isEmpty {
                opening = .question(motiveID: motiveID, text: text)
            } else {
                opening = nil
            }
            let socialDecision = L1SocialDecision(
                opportunityID: opportunity.id,
                entityID: opportunity.entityID,
                action: socialAction,
                confidence: decision.confidence,
                rationale: decision.rationale,
                evidenceIDs: request.evidenceIDs,
                openingContent: opening
            )
            return onSocialDecision(request, socialDecision, state.presence, monotonicNS)
        }
    }

    private func availableActions(
        for request: L1ThoughtRequest,
        intention: MentalIntention
    ) -> [L1ExecutiveAction] {
        var result: [L1ExecutiveAction] = [.noAction]
        if let opportunity = request.socialOpportunity {
            if opportunity.availableActions.contains(.nonverbalInvitation) {
                result.append(.nonverbalInvitation)
            }
            if opportunity.availableActions.contains(.spokenOpening),
               request.informationNeeds.contains(where: \.permitsProactiveSpokenOpening) {
                result.append(.spokenOpening)
            }
        }
        if let behavior = request.behaviorContext {
            if !behavior.scanActive { result.append(.resumeScanning) }
            if behavior.recognizedIdentity == nil { result.append(.seekPeople) }
            if behavior.acknowledgmentPending == true { result.append(.acknowledgePerson) }
        }
        if let target = intention.attentionTargetLabel,
           request.behaviorContext?.targetLabel?.caseInsensitiveCompare(target) == .orderedSame {
            result.append(.inspectAttentionTarget)
        }
        return result
    }

    private func executeInspectionIntention(_ intention: MentalIntention) -> Bool {
        guard let requestedLabel = intention.attentionTargetLabel?.nilIfEmpty,
              let inventory = executeTool(
                  "inspect_scene",
                  ["reason": "Ground the current inspection intention in fresh L0 scene evidence."]
              ),
              inventory["ok"] as? Bool == true,
              let entities = inventory["scene_entities"] as? [[String: Any]] else {
            return false
        }
        let candidates = entities.filter {
            ($0["observed_now"] as? Bool) == true
                && ($0["action_eligible"] as? Bool) == true
                && (($0["label"] as? String)?.caseInsensitiveCompare(requestedLabel) == .orderedSame)
        }
        guard let entity = candidates.max(by: {
            ($0["confidence"] as? Double ?? 0) < ($1["confidence"] as? Double ?? 0)
        }),
        let sceneID = entity["scene_id"] as? String,
        let label = entity["label"] as? String else {
            return false
        }
        let targetReference = "l1-intention:\(intention.id.uuidString.lowercased())"
        let reason = String(intention.objective.prefix(320))
        guard executeTool(
            "register_attention_target",
            [
                "target_reference": targetReference,
                "scene_id": sceneID,
                "label": label,
                "expected_kind": entity["kind"] as? String ?? "unknown",
                "selection_log_prior": -2 + intention.pressure * 8,
                "reason": reason,
            ]
        )?["ok"] as? Bool == true else {
            return false
        }
        _ = executeTool(
            "set_target_attention",
            [
                "target_reference": targetReference,
                "selection_log_prior": -2 + intention.pressure * 8,
                "tracking_commitment": 0.4 + intention.pressure * 0.55,
                "selection_temperature": 1.2 - intention.pressure * 0.7,
                "novelty_strength": 0.5,
                "habituation_strength": 0.5,
                "reason": reason,
            ]
        )
        return executeTool(
            "track_attention_target",
            [
                "target_reference": targetReference,
                "motion_style": "attentive",
                "reacquire_if_occluded": true,
                "lease_ms": 15_000,
                "reason": reason,
            ]
        )?["ok"] as? Bool == true
    }

    private func executeTool(_ name: String, _ arguments: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else {
            return nil
        }
        let response = toolExecutor(name, String(decoding: data, as: UTF8.self))
        guard let responseData = response.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    }


    private func startAwarenessTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + awarenessSamplingSeconds, repeating: awarenessSamplingSeconds)
        timer.setEventHandler { [weak self] in self?.awarenessTick() }
        timer.resume()
        awarenessTimer = timer
    }

    private func awarenessTick() {
        guard !stopped else { return }
        let nowNS = DispatchTime.now().uptimeNanoseconds
        reassessPresences(at: nowNS)
        observeContactAndBehavior(at: nowNS)
        guard !evidenceInFlight else { return }
        Task { [weak self] in
            guard let self else { return }
            let now = Date()
            let shouldThink = await workspace.shouldInitiatePeriodicThought(
                at: now,
                samplingWindowSeconds: awarenessSamplingSeconds
            )
            guard shouldThink else { return }
            let event = MentalEvidenceEvent(
                id: "elapsed:\(UUID().uuidString.lowercased())",
                observedAt: now,
                kind: .elapsedTime,
                summary: "Time passed without a new external transition; evaluate, associate, decay, self-correct, or explicitly remain idle.",
                confidence: 1,
                novelty: 0
            )
            queue.async { [weak self] in
                guard let self, !stopped else { return }
                forcedPeriodicEvidenceIDs.insert(event.id)
                enqueueEvidence(event)
            }
        }
    }

    private func reassessPresences(at monotonicNS: UInt64) {
        let availability = socialAvailability()
        for (entityID, var state) in presences {
            guard monotonicNS >= state.lastObservedNS,
                  monotonicNS - state.lastObservedNS <= presenceCurrentNS else { continue }
            state.presence = KnownPersonPresence(
                entityID: entityID,
                recognitionConfidence: state.presence.recognitionConfidence,
                proactiveContactPreference: state.presence.proactiveContactPreference,
                isSpeaking: availability.participantSpeaking,
                conversationActive: availability.conversationActive
            )
            if state.opportunity == nil,
               let opportunity = scheduler.observe(
                   state.presence,
                   at: monotonicNS,
                   unitIntervalDraw: Double.random(in: 0 ... 1)
               ),
               let memory = cachedMemoryContexts[entityID]?.context {
                state.opportunity = opportunity
                presences[entityID] = state
                enqueueEvidence(socialAvailabilityEvidence(for: state, memory: memory))
            } else {
                presences[entityID] = state
            }
        }
    }

    private func observeContactAndBehavior(at monotonicNS: UInt64) {
        let contact = socialContactPatternProvider()
        let availability = socialAvailability()
        let transition = contactIntegrator.observe(
            rawEyeContactActive: contact?.eyeContactActive ?? false,
            at: monotonicNS
        )
        if let transition {
            let active = transition == .began
            enqueueEvidence(MentalEvidenceEvent(
                id: "contact:\(monotonicNS):\(active ? "eye_on" : "eye_off")",
                kind: active ? .directSocialBid : .ordinaryObservation,
                summary: active ? "Current eye contact began." : "Current eye contact ended.",
                subjectEntityID: presences.keys.first,
                confidence: 1,
                novelty: active ? 0.85 : 0.55,
                contextPatch: MentalContextPatch(
                    presentEntityIDs: Array(presences.keys),
                    eyeContactActive: active,
                    participantSpeaking: availability.participantSpeaking,
                    conversationActive: availability.conversationActive
                ),
                driveSignal: MentalDriveSignal(
                    socialInterest: active ? 0.25 : -0.1,
                    interruptionPressure: active ? 0.5 : -0.5
                )
            ))
        }

        if availability.conversationActive != lastSocialAvailability.conversationActive {
            let active = availability.conversationActive
            enqueueEvidence(MentalEvidenceEvent(
                id: "conversation:\(monotonicNS):\(active ? "active" : "inactive")",
                kind: .conversationOutcome,
                summary: active
                    ? "A live conversation session began."
                    : "The live conversation session ended.",
                subjectEntityID: presences.keys.first,
                confidence: 1,
                novelty: 0.75,
                contextPatch: MentalContextPatch(
                    presentEntityIDs: Array(presences.keys),
                    participantSpeaking: active ? availability.participantSpeaking : false,
                    conversationActive: active
                ),
                driveSignal: MentalDriveSignal(
                    socialInterest: active ? 0.1 : -0.1,
                    interruptionPressure: active ? -1 : -0.5
                )
            ))
        }
        lastSocialAvailability = availability

        guard let behavior = behaviorContextProvider() else { return }
        let signature = [
            behavior.attentionState,
            behavior.targetLabel ?? "none",
            behavior.isFaceTarget ? "face" : "not_face",
            behavior.scanActive ? "scan" : "held",
            behavior.recognizedIdentity ?? "anonymous",
            behavior.acknowledgmentPending == true ? "ack_pending" : "ack_clear",
        ].joined(separator: "|")
        guard signature != lastBehaviorSignature else { return }
        lastBehaviorSignature = signature
        enqueueEvidence(MentalEvidenceEvent(
            id: "behavior:\(monotonicNS):\(signature)",
            kind: .ordinaryObservation,
            summary: "L0 attention state changed: \(signature).",
            subjectEntityID: presences.keys.first,
            confidence: max(behavior.targetConfidence, 0.6),
            novelty: 0.45,
            driveSignal: MentalDriveSignal(
                concern: behavior.idleSeconds > 0 && !behavior.scanActive ? 0.1 : -0.05,
                boredom: !behavior.scanActive && !behavior.isFaceTarget ? 0.15 : -0.1
            )
        ))
    }

    private func startConsolidationTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + consolidationIntervalSeconds,
            repeating: consolidationIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            guard let self, !stopped else { return }
            Task { [weak self] in await self?.memoryContext.consolidateEpisodes() }
        }
        timer.resume()
        consolidationTimer = timer
    }

    private func persist(_ snapshot: MentalWorkspaceSnapshot) {
        Task { [checkpointStore] in try? await checkpointStore.save(snapshot) }
    }

    private func record(_ transition: WorkspaceTransition, event: MentalEvidenceEvent) {
        onHealth(
            "evidence",
            "id=\(event.id); kind=\(event.kind.rawValue); confidence=\(String(format: "%.2f", event.confidence)); novelty=\(String(format: "%.2f", event.novelty)); summary=\(event.summary)"
        )
        let changed = transition.delta.changedFields.isEmpty
            ? "none" : transition.delta.changedFields.joined(separator: ",")
        onHealth(
            "state_delta",
            "revision=\(transition.before.revision)->\(transition.after.revision); changed=\(changed); meaningful=\(transition.delta.meaningfulTransition); duplicate=\(transition.delta.duplicateEvidence)"
        )
        recordHypothesisLifecycle(before: transition.before, after: transition.after)
    }

    private func recordHypothesisLifecycle(
        before: MentalWorkspaceSnapshot,
        after: MentalWorkspaceSnapshot
    ) {
        let previous = Dictionary(uniqueKeysWithValues: before.hypotheses.map { ($0.id, $0) })
        for hypothesis in after.hypotheses {
            guard let prior = previous[hypothesis.id] else {
                onHealth("hypothesis_created", "id=\(hypothesis.id.uuidString.lowercased()); confidence=\(String(format: "%.2f", hypothesis.confidence)); text=\(hypothesis.content)")
                continue
            }
            guard prior != hypothesis else { continue }
            let state = prior.status == hypothesis.status
                ? "hypothesis_updated" : "hypothesis_\(hypothesis.status.rawValue)"
            onHealth(state, "id=\(hypothesis.id.uuidString.lowercased()); confidence=\(String(format: "%.2f", prior.confidence))->\(String(format: "%.2f", hypothesis.confidence)); text=\(hypothesis.content)")
        }
    }

    private func canonicalRelationshipUncertainty(_ rapport: L1RapportContext?) -> Double {
        guard let rapport else { return 1 }
        return 1 - (rapport.familiarity + rapport.interactionComfort + rapport.communicationAlignment) / 3
    }

    private func effectiveLanguageTag(for context: L1MemoryContext) -> String? {
        if let tag = context.preferredLanguageTag, !tag.isEmpty { return tag }
        if let tag = activeLanguageProvider(), !tag.isEmpty { return tag }
        let fallback = somaEnvString("SOMA_L1_DEFAULT_LANGUAGE", default: "ko")
        return fallback.isEmpty ? nil : fallback
    }

    private func perceptionAgeSeconds(of resource: L1VisualResource?) -> Double {
        guard let resource else { return 0 }
        if let capturedAt = resource.capturedAt { return max(0, Date().timeIntervalSince(capturedAt)) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resource.localPath),
              let date = attributes[.modificationDate] as? Date else { return 0 }
        return max(0, Date().timeIntervalSince(date))
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
