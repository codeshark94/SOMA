import Foundation

/// Scalar scene evidence exposed to the cognitive embodiment boundary. It is
/// deliberately free of pixels, embeddings, landmarks, and biometric data.
public struct EmbodimentSceneEntity: Codable, Equatable, Sendable {
    public let sceneID: String
    public let kind: AttentionTargetKind
    public let label: String?
    public let confidence: Double
    public let observedThisFrame: Bool
    public let actionEligible: Bool
    public let bearing: GimbalRelativeBearing?
    public let spatialConfidence: Double
    public let lastSeenMilliseconds: Double

    public init(
        sceneID: String,
        kind: AttentionTargetKind,
        label: String?,
        confidence: Double,
        observedThisFrame: Bool,
        actionEligible: Bool,
        bearing: GimbalRelativeBearing?,
        spatialConfidence: Double,
        lastSeenMilliseconds: Double
    ) {
        self.sceneID = String(sceneID.prefix(96))
        self.kind = kind
        self.label = label.map { String($0.prefix(96)) }
        self.confidence = Self.probability(confidence)
        self.observedThisFrame = observedThisFrame
        self.actionEligible = actionEligible
        self.bearing = bearing
        self.spatialConfidence = Self.probability(spatialConfidence)
        self.lastSeenMilliseconds = max(0, lastSeenMilliseconds.isFinite ? lastSeenMilliseconds : 0)
    }

    public init(_ candidate: SceneCandidate) {
        self.init(
            sceneID: candidate.id,
            kind: candidate.observation.kind,
            label: candidate.observation.label,
            confidence: candidate.observation.confidence,
            observedThisFrame: candidate.observedThisFrame,
            actionEligible: candidate.isActionEligible,
            bearing: candidate.bearing,
            spatialConfidence: candidate.spatialConfidence,
            lastSeenMilliseconds: candidate.lastSeenMilliseconds
        )
    }

    private static func probability(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public enum SemanticTargetBindingStatus: String, Codable, Sendable {
    case bound
    case retained
    case ambiguous
    case unresolved
}

/// A posterior over the association between one semantic target reference and
/// the persistent scene field. This is not identity recognition: ambiguity is
/// surfaced instead of silently naming one of several compatible entities.
public struct SemanticTargetBinding: Codable, Equatable, Sendable {
    public let targetReference: String
    public let sceneID: String?
    public let status: SemanticTargetBindingStatus
    public let posteriorProbability: Double
    public let normalizedEntropy: Double
    public let reason: String
    public let observedThisFrame: Bool
}

public struct SemanticTargetBindingEngine: Sendable {
    private var previousSceneIDByTarget: [String: String] = [:]

    public init() {}

    public mutating func resolve(
        registrations: [SemanticTargetRegistration],
        entities: [EmbodimentSceneEntity]
    ) -> [SemanticTargetBinding] {
        let activeReferences = Set(registrations.map(\.targetReference))
        previousSceneIDByTarget = previousSceneIDByTarget.filter { activeReferences.contains($0.key) }
        let byID = Dictionary(entities.map { ($0.sceneID, $0) }, uniquingKeysWith: { current, replacement in
            replacement.observedThisFrame && !current.observedThisFrame ? replacement : current
        })
        return registrations
            .map { resolve($0, entities: entities, byID: byID) }
            .sorted { $0.targetReference < $1.targetReference }
    }

    private mutating func resolve(
        _ registration: SemanticTargetRegistration,
        entities: [EmbodimentSceneEntity],
        byID: [String: EmbodimentSceneEntity]
    ) -> SemanticTargetBinding {
        if let requestedSceneID = registration.sceneID {
            guard let entity = byID[requestedSceneID] else {
                previousSceneIDByTarget.removeValue(forKey: registration.targetReference)
                return unresolved(registration, reason: "registered_scene_unavailable")
            }
            guard kindMatches(registration.expectedKind, entity.kind) else {
                previousSceneIDByTarget.removeValue(forKey: registration.targetReference)
                return unresolved(registration, reason: "registered_scene_kind_mismatch")
            }
            previousSceneIDByTarget[registration.targetReference] = entity.sceneID
            return SemanticTargetBinding(
                targetReference: registration.targetReference,
                sceneID: entity.sceneID,
                status: entity.observedThisFrame ? .bound : .retained,
                posteriorProbability: 1,
                normalizedEntropy: 0,
                reason: entity.observedThisFrame ? "explicit_scene_binding" : "explicit_scene_retained",
                observedThisFrame: entity.observedThisFrame
            )
        }

        let acceptedLabels = Set(([registration.label] + registration.aliases).map(Self.normalizedLabel))
        let priorSceneID = previousSceneIDByTarget[registration.targetReference]
        let compatible = entities.filter { entity in
            guard kindMatches(registration.expectedKind, entity.kind),
                  let label = entity.label else { return false }
            return acceptedLabels.contains(Self.normalizedLabel(label))
        }
        guard !compatible.isEmpty else {
            previousSceneIDByTarget.removeValue(forKey: registration.targetReference)
            let reason = registration.visualQuery == nil
                ? "no_compatible_scene_entity"
                : "visual_query_requires_grounded_candidate"
            return unresolved(registration, reason: reason)
        }

        let candidateLogWeights = compatible.map { entity -> Double in
            let presence = entity.observedThisFrame ? 1.0 : 0.30
            let confidence = max(entity.confidence, 0.02)
            let spatialEvidence = entity.bearing == nil ? 0.45 : max(entity.spatialConfidence, 0.10)
            let continuity = entity.sceneID == priorSceneID ? 2.8 : 1.0
            let kindEvidence = registration.expectedKind == nil || registration.expectedKind == .unknown
                ? 1.0
                : 1.35
            return registration.initialSelectionLogPrior
                + log(presence)
                + log(confidence)
                + log(spatialEvidence)
                + log(continuity)
                + log(kindEvidence)
        }
        // The unresolved hypothesis carries unit mass. A negative top-down
        // prior can therefore keep a weak descriptor from becoming identity.
        let allLogWeights = candidateLogWeights + [0]
        let maximum = allLogWeights.max() ?? 0
        let masses = allLogWeights.map { exp($0 - maximum) }
        let total = masses.reduce(0, +)
        let probabilities = masses.map { $0 / total }
        let candidateProbabilities = Array(probabilities.dropLast())
        let entropy = Self.normalizedEntropy(probabilities)
        guard let bestIndex = candidateProbabilities.indices.max(by: {
            candidateProbabilities[$0] < candidateProbabilities[$1]
        }) else {
            return unresolved(registration, reason: "no_compatible_scene_entity")
        }
        let bestProbability = candidateProbabilities[bestIndex]
        let runnerUp = candidateProbabilities.indices
            .filter { $0 != bestIndex }
            .map { candidateProbabilities[$0] }
            .max() ?? 0
        let unresolvedProbability = probabilities.last ?? 1
        let best = compatible[bestIndex]
        guard bestProbability >= 0.55,
              bestProbability - max(runnerUp, unresolvedProbability) >= 0.15 else {
            previousSceneIDByTarget.removeValue(forKey: registration.targetReference)
            return SemanticTargetBinding(
                targetReference: registration.targetReference,
                sceneID: nil,
                status: .ambiguous,
                posteriorProbability: bestProbability,
                normalizedEntropy: entropy,
                reason: "descriptor_binding_ambiguous",
                observedThisFrame: false
            )
        }
        previousSceneIDByTarget[registration.targetReference] = best.sceneID
        return SemanticTargetBinding(
            targetReference: registration.targetReference,
            sceneID: best.sceneID,
            status: best.observedThisFrame ? .bound : .retained,
            posteriorProbability: bestProbability,
            normalizedEntropy: entropy,
            reason: best.observedThisFrame ? "descriptor_binding" : "descriptor_binding_retained",
            observedThisFrame: best.observedThisFrame
        )
    }

    private func unresolved(
        _ registration: SemanticTargetRegistration,
        reason: String
    ) -> SemanticTargetBinding {
        SemanticTargetBinding(
            targetReference: registration.targetReference,
            sceneID: nil,
            status: .unresolved,
            posteriorProbability: 0,
            normalizedEntropy: 0,
            reason: reason,
            observedThisFrame: false
        )
    }

    private func kindMatches(_ expected: AttentionTargetKind?, _ observed: AttentionTargetKind) -> Bool {
        guard let expected, expected != .unknown else { return true }
        return expected == observed
    }

    private static func normalizedLabel(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedEntropy(_ probabilities: [Double]) -> Double {
        guard probabilities.count > 1 else { return 0 }
        let entropy = -probabilities.reduce(0) { partial, probability in
            probability > 0 ? partial + probability * log(probability) : partial
        }
        return entropy / log(Double(probabilities.count))
    }
}
