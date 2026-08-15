import Foundation

/// Scalar wake contract emitted by the transition router. Audio pre-roll stays
/// in the local speech transport; this value only declares how much of its
/// bounded in-memory ring should accompany the live stream.
public struct HumanInteractionWakeRequest: Codable, Equatable, Sendable {
    public let eventID: String
    public let triggeredAtNS: UInt64
    public let evidenceIDs: [String]
    public let policyReason: CognitiveTransitionPolicyReason
    public let audioPreRollMilliseconds: UInt64
    public let prepareL1ContextInParallel: Bool
    public let bypassesL1Admission: Bool

    public init(
        decision: EventImportanceDecision,
        audioPreRollMilliseconds: UInt64
    ) throws {
        guard decision.dispatch.openHumanInteraction,
              audioPreRollMilliseconds > 0,
              audioPreRollMilliseconds <= 10_000 else {
            throw CognitiveInteractionError.invalidWakeRequest
        }
        eventID = decision.eventID
        triggeredAtNS = decision.monotonicNS
        evidenceIDs = decision.evidenceIDs
        policyReason = decision.policyReason
        self.audioPreRollMilliseconds = audioPreRollMilliseconds
        prepareL1ContextInParallel = decision.dispatch.wakeL1Context
        bypassesL1Admission = decision.dispatch.bypassesL1Admission
    }
}

/// One accepted user turn delivered to L2 Codex. Speech recognition is a
/// transport concern; this contract carries text and bounded context
/// references, never microphone samples.
public struct CodexInteractionTurn: Codable, Equatable, Sendable {
    public let interactionID: String
    public let turnID: String
    public let transcript: String
    public let languageTag: String?
    public let speechStartedAtNS: UInt64
    public let transcriptFinalizedAtNS: UInt64
    public let evidenceIDs: [String]
    public let contextPacketReference: String?

    public init(
        interactionID: String,
        turnID: String,
        transcript: String,
        languageTag: String? = nil,
        speechStartedAtNS: UInt64,
        transcriptFinalizedAtNS: UInt64,
        evidenceIDs: [String],
        contextPacketReference: String? = nil
    ) throws {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validIdentifier(interactionID),
              Self.validIdentifier(turnID),
              !normalizedTranscript.isEmpty,
              normalizedTranscript.count <= 32_768,
              transcriptFinalizedAtNS >= speechStartedAtNS,
              evidenceIDs.count <= 16,
              evidenceIDs.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
              languageTag.map({ !$0.isEmpty && $0.count <= 32 }) ?? true,
              contextPacketReference.map({ !$0.isEmpty && $0.count <= 128 }) ?? true else {
            throw CognitiveInteractionError.invalidCodexTurn
        }
        self.interactionID = interactionID
        self.turnID = turnID
        self.transcript = normalizedTranscript
        self.languageTag = languageTag
        self.speechStartedAtNS = speechStartedAtNS
        self.transcriptFinalizedAtNS = transcriptFinalizedAtNS
        self.evidenceIDs = evidenceIDs
        self.contextPacketReference = contextPacketReference
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 96
    }
}

public enum CognitiveInteractionError: Error, Equatable {
    case invalidWakeRequest
    case invalidCodexTurn
}
