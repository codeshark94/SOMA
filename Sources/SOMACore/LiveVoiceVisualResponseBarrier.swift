import Foundation

/// Coordinates the response ownership of a live turn that requires fresh
/// camera evidence. The presentation response may begin only after evidence
/// has been committed to the same realtime thread.
public struct LiveVoiceVisualResponseBarrier: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case settlingProvisionalResponse
        case awaitingReplacementResponse
        case presentingReplacementResponse
    }

    public enum Action: String, Equatable, Sendable {
        case closeOutput
        case acquireEvidence
        case cancelResponse
        case requestResponse
        case openOutput
    }

    public let episodeID: UUID
    public let participantTurnSequence: UInt64
    public let transcript: String
    public private(set) var phase: Phase
    public private(set) var evidenceCommitted: Bool
    public private(set) var provisionalResponseSettled: Bool
    public private(set) var replacementRequested: Bool
    public private(set) var presentationReleased: Bool
    public private(set) var provisionalResponseID: String?
    public private(set) var replacementResponseID: String?

    public init(
        episodeID: UUID = UUID(),
        participantTurnSequence: UInt64 = 0,
        transcript: String,
        provisionalResponseID: String? = nil
    ) {
        self.episodeID = episodeID
        self.participantTurnSequence = participantTurnSequence
        self.transcript = String(transcript.prefix(4_096))
        phase = .settlingProvisionalResponse
        evidenceCommitted = false
        provisionalResponseSettled = false
        replacementRequested = false
        presentationReleased = false
        self.provisionalResponseID = Self.normalizedResponseID(provisionalResponseID)
        replacementResponseID = nil
    }

    public var initialActions: [Action] {
        [.closeOutput, .acquireEvidence, .cancelResponse]
    }

    /// A response created before evidence is committed is provisional and must
    /// be cancelled. The response created by `requestResponse` owns the turn.
    public mutating func observeResponseStarted(responseID: String? = nil) -> [Action] {
        let responseID = Self.normalizedResponseID(responseID)
        if phase == .awaitingReplacementResponse,
           replacementRequested,
           responseID != nil {
            replacementResponseID = responseID
            phase = .presentingReplacementResponse
            return []
        }
        if phase == .presentingReplacementResponse { return [] }
        if provisionalResponseID == nil { provisionalResponseID = responseID }
        return []
    }

    public mutating func observePresentationStarted(responseID: String? = nil) -> [Action] {
        let responseID = Self.normalizedResponseID(responseID)
        guard phase == .presentingReplacementResponse,
              responseID != nil,
              responseID == replacementResponseID,
              !presentationReleased else { return [] }
        presentationReleased = true
        return [.openOutput]
    }

    /// Both successful camera evidence and a concrete capture failure are
    /// committed as evidence. This guarantees one grounded answer instead of
    /// allowing a silent deadlock on sensor failure.
    public mutating func observeEvidenceCommitted() -> [Action] {
        guard !evidenceCommitted else { return [] }
        evidenceCommitted = true
        return requestReplacementIfReady()
    }

    /// A successful cancellation, a no-active-response acknowledgement, or
    /// completion of the provisional response establishes the same ordering
    /// boundary. The replacement is requested only after this boundary and
    /// evidence commitment have both occurred.
    public mutating func observeProvisionalResponseSettled(
        responseID: String? = nil,
        cancellationAcknowledged: Bool = false
    ) -> [Action] {
        guard phase != .presentingReplacementResponse else { return [] }
        let responseID = Self.normalizedResponseID(responseID)
        if !cancellationAcknowledged {
            guard let provisionalResponseID,
                  responseID == provisionalResponseID else { return [] }
        }
        provisionalResponseSettled = true
        return requestReplacementIfReady()
    }

    public mutating func observeResponseEnded(responseID: String? = nil) -> [Action] {
        observeProvisionalResponseSettled(responseID: responseID)
    }

    public func ownsReplacementResponse(_ responseID: String?) -> Bool {
        guard let responseID = Self.normalizedResponseID(responseID),
              let replacementResponseID else { return false }
        return responseID == replacementResponseID
    }

    public var suppressesAssistantPresentation: Bool {
        !presentationReleased
    }

    private mutating func requestReplacementIfReady() -> [Action] {
        guard evidenceCommitted,
              provisionalResponseSettled,
              !replacementRequested else { return [] }
        replacementRequested = true
        phase = .awaitingReplacementResponse
        return [.requestResponse]
    }

    private static func normalizedResponseID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : String(normalized.prefix(256))
    }
}
