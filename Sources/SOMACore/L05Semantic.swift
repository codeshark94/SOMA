import Foundation

public enum L05AttentionHint: String, Codable, CaseIterable, Sendable {
    case person
    case object
    case soundSource = "sound_source"
    case explore
    case none
}

/// Scalar context accompanying one in-memory L0.5 keyframe. It deliberately
/// excludes pixels; the transport owns the ephemeral image payload.
public struct L05FrameContext: Codable, Equatable, Sendable {
    public let captureNS: UInt64
    public let trigger: String
    public let surprise: Double
    public let informationGain: Double
    public let presenceProbability: Double
    public let voiceProbability: Double
    public let targetKind: AttentionTargetKind?
    public let targetLabel: String?
    public let targetProbability: Double
    public let targetStatus: TargetStatus

    public init(captureNS: UInt64, trigger: String, belief: BeliefSnapshot) {
        self.captureNS = captureNS
        self.trigger = trigger
        surprise = belief.surprise
        informationGain = belief.informationGain
        presenceProbability = belief.presenceProbability
        voiceProbability = belief.voiceProbability
        targetKind = belief.target?.kind
        targetLabel = belief.target?.label
        targetProbability = belief.target?.posteriorProbability ?? 0
        targetStatus = belief.targetStatus
    }

    public init(
        captureNS: UInt64,
        trigger: String,
        surprise: Double,
        informationGain: Double,
        presenceProbability: Double,
        voiceProbability: Double,
        targetKind: AttentionTargetKind?,
        targetLabel: String?,
        targetProbability: Double,
        targetStatus: TargetStatus
    ) {
        self.captureNS = captureNS
        self.trigger = trigger
        self.surprise = surprise
        self.informationGain = informationGain
        self.presenceProbability = presenceProbability
        self.voiceProbability = voiceProbability
        self.targetKind = targetKind
        self.targetLabel = targetLabel
        self.targetProbability = targetProbability
        self.targetStatus = targetStatus
    }

    public var targetSignature: String {
        "\(targetStatus.rawValue)|\(targetKind?.rawValue ?? "none")|\(targetLabel ?? "none")"
    }
}

public struct L05SemanticCue: Codable, Equatable, Sendable {
    public let requestID: UInt64
    public let captureNS: UInt64
    public let completedNS: UInt64
    public let source: String
    public let summary: String
    public let novelty: Double
    public let socialPresence: Double
    public let attentionHint: L05AttentionHint
    public let confidence: Double
    public let inferenceMS: Double

    public init(
        requestID: UInt64,
        captureNS: UInt64,
        completedNS: UInt64,
        source: String,
        summary: String,
        novelty: Double,
        socialPresence: Double,
        attentionHint: L05AttentionHint,
        confidence: Double,
        inferenceMS: Double
    ) {
        self.requestID = requestID
        self.captureNS = captureNS
        self.completedNS = completedNS
        self.source = source
        self.summary = String(summary.prefix(160))
        self.novelty = min(max(novelty, 0), 1)
        self.socialPresence = min(max(socialPresence, 0), 1)
        self.attentionHint = attentionHint
        self.confidence = min(max(confidence, 0), 1)
        self.inferenceMS = max(0, inferenceMS)
    }
}

/// Event-driven admission for a slow semantic side loop. A changed target or
/// high-surprise frame may run at most once per second; an unchanged scene gets
/// a sparse five-second refresh. This gate never delays the L0 capture thread.
public struct L05SemanticAdmissionGate: Sendable {
    private let eventIntervalNS: UInt64
    private let refreshIntervalNS: UInt64
    private let salienceThreshold: Double
    private var lastAcceptedNS: UInt64?
    private var lastTargetSignature: String?

    public init(
        eventIntervalMilliseconds: UInt64 = 1_000,
        refreshIntervalMilliseconds: UInt64 = 5_000,
        salienceThreshold: Double = 0.65
    ) {
        eventIntervalNS = eventIntervalMilliseconds * 1_000_000
        refreshIntervalNS = refreshIntervalMilliseconds * 1_000_000
        self.salienceThreshold = min(max(salienceThreshold, 0), 1)
    }

    public mutating func admit(_ context: L05FrameContext) -> Bool {
        guard let lastAcceptedNS else {
            accept(context)
            return true
        }
        guard context.captureNS >= lastAcceptedNS else { return false }
        let elapsed = context.captureNS - lastAcceptedNS
        let targetChanged = context.targetSignature != lastTargetSignature
        let salient = max(context.surprise, context.informationGain) >= salienceThreshold
        guard elapsed >= refreshIntervalNS || (elapsed >= eventIntervalNS && (targetChanged || salient)) else {
            return false
        }
        accept(context)
        return true
    }

    private mutating func accept(_ context: L05FrameContext) {
        lastAcceptedNS = context.captureNS
        lastTargetSignature = context.targetSignature
    }
}
