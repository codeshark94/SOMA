import Foundation

public struct AttentionDistribution: Sendable {
    public let selected: VisualObservation?
    public let selectedProbability: Double
    /// In the same order as the candidates supplied to the selector.
    public let candidateProbabilities: [Double]
    public let noTargetProbability: Double
    public let normalizedEntropy: Double

    public init(
        selected: VisualObservation?,
        selectedProbability: Double,
        candidateProbabilities: [Double],
        noTargetProbability: Double,
        normalizedEntropy: Double
    ) {
        self.selected = selected
        self.selectedProbability = selectedProbability
        self.candidateProbabilities = candidateProbabilities
        self.noTargetProbability = noTargetProbability
        self.normalizedEntropy = normalizedEntropy
    }
}

/// Produces a normalized local attention posterior rather than choosing the
/// highest hand-tuned score. A current human is a hard dominance constraint:
/// objects and saliency remain in the posterior, but cannot outrank a person
/// or face. The posterior otherwise remains probabilistic.
public enum ProbabilisticAttentionSelector {
    public static func infer(
        candidates: [VisualObservation],
        previousTarget: AttentionTarget?
    ) -> AttentionDistribution {
        guard !candidates.isEmpty else {
            return AttentionDistribution(
                selected: nil,
                selectedProbability: 0,
                candidateProbabilities: [],
                noTargetProbability: 1,
                normalizedEntropy: 0
            )
        }

        let noveltyLikelihoods = candidates.map(noveltyLikelihood)
        let baseLogWeights = candidates.indices.map { index in
            let candidate = candidates[index]
            return log(max(candidate.confidence, 0.02))
                + log(kindPrior(candidate.kind))
                + log(socialEngagementLikelihood(candidate))
                + log(continuityLikelihood(candidate, previousTarget: previousTarget))
                + log(noveltyLikelihoods[index])
                + candidate.attentionWeight * 1.6
        }
        let logWeights = enforceHumanDominance(baseLogWeights, candidates: candidates)
        let noTargetLogWeight = log(noTargetLikelihood(
            candidates,
            noveltyLikelihoods: noveltyLikelihoods,
            previousTarget: previousTarget
        ))
        let maximum = max(logWeights.max() ?? noTargetLogWeight, noTargetLogWeight)
        let candidateWeights = logWeights.map { exp($0 - maximum) }
        let noTargetWeight = exp(noTargetLogWeight - maximum)
        let total = candidateWeights.reduce(noTargetWeight, +)
        let probabilities = candidateWeights.map { $0 / total }
        let noTargetProbability = noTargetWeight / total
        let entropy = normalizedEntropy(probabilities + [noTargetProbability])

        let maximumCandidateProbability = probabilities.max() ?? 0
        let selectedIndex: Int?
        if let previousTarget,
           let retained = candidates.indices
            .filter({ candidateIndex in
                let candidate = candidates[candidateIndex]
                let spatialDistance = hypot(
                    candidate.rect.centerX - previousTarget.rect.centerX,
                    candidate.rect.centerY - previousTarget.rect.centerY
                )
                return candidate.sceneID == previousTarget.id
                    || (candidate.kind == previousTarget.kind
                        && candidate.label == previousTarget.label
                        && spatialDistance <= 0.28)
            })
            .max(by: { probabilities[$0] < probabilities[$1] }),
           probabilities[retained] >= 0.18,
           probabilities[retained] >= maximumCandidateProbability,
           probabilities[retained] > noTargetProbability {
            selectedIndex = retained
        } else if let strongest = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }),
                  probabilities[strongest] > noTargetProbability {
            selectedIndex = strongest
        } else {
            selectedIndex = nil
        }

        guard let selectedIndex else {
            return AttentionDistribution(
                selected: nil,
                selectedProbability: 0,
                candidateProbabilities: probabilities,
                noTargetProbability: noTargetProbability,
                normalizedEntropy: entropy
            )
        }
        let selected = candidates[selectedIndex]
        return AttentionDistribution(
            selected: VisualObservation(
                rect: selected.rect,
                confidence: selected.confidence,
                source: selected.source,
                kind: selected.kind,
                label: selected.label,
                attentionWeight: selected.attentionWeight,
                posteriorProbability: probabilities[selectedIndex],
                sceneID: selected.sceneID,
                stabilityMilliseconds: selected.stabilityMilliseconds,
                isActionEligible: selected.isActionEligible
            ),
            selectedProbability: probabilities[selectedIndex],
            candidateProbabilities: probabilities,
            noTargetProbability: noTargetProbability,
            normalizedEntropy: entropy
        )
    }

    private static func kindPrior(_ kind: AttentionTargetKind) -> Double {
        switch kind {
        case .human: return 1.8
        case .object: return 1.0
        case .unknown: return 0.90
        }
    }

    private static func enforceHumanDominance(
        _ baseLogWeights: [Double],
        candidates: [VisualObservation]
    ) -> [Double] {
        let humanIndices = candidates.indices.filter { candidates[$0].kind == .human }
        let nonHumanIndices = candidates.indices.filter { candidates[$0].kind != .human }
        guard let weakestHuman = humanIndices.map({ baseLogWeights[$0] }).min(),
              let strongestNonHuman = nonHumanIndices.map({ baseLogWeights[$0] }).max(),
              weakestHuman <= strongestNonHuman else {
            return baseLogWeights
        }
        let boost = strongestNonHuman - weakestHuman + 0.001
        return baseLogWeights.enumerated().map { index, weight in
            humanIndices.contains(index) ? weight + boost : weight
        }
    }

    private static func socialEngagementLikelihood(_ candidate: VisualObservation) -> Double {
        guard candidate.kind == .human else { return 1 }
        return isFace(candidate) ? 2.4 : 1
    }

    private static func isFace(_ candidate: VisualObservation) -> Bool {
        candidate.kind == .human
            && (candidate.label == "face" || candidate.source == .neuralFaceDetector)
    }

    private static func continuityLikelihood(_ candidate: VisualObservation, previousTarget: AttentionTarget?) -> Double {
        guard let previousTarget else { return 1 }
        let distance = hypot(
            candidate.rect.centerX - previousTarget.rect.centerX,
            candidate.rect.centerY - previousTarget.rect.centerY
        )
        let spatial = exp(-(distance * distance) / (2 * 0.18 * 0.18))
        let sameSocialTarget = candidate.kind == .human
            && previousTarget.kind == .human
            && distance <= 0.28
        let identity = sameSocialTarget || (candidate.kind == previousTarget.kind && candidate.label == previousTarget.label)
            ? 1.35
            : 0.75
        return max(0.08, spatial * identity)
    }

    /// Repeated unchanging non-human evidence should yield to no-target or
    /// newer evidence. Current human evidence does not habituate at L0.
    private static func noveltyLikelihood(_ candidate: VisualObservation) -> Double {
        let (timeConstantMS, floor): (Double, Double)
        switch candidate.kind {
        case .human:
            return 1
        case .object:
            (timeConstantMS, floor) = (4_500, 0.08)
        case .unknown:
            (timeConstantMS, floor) = (3_500, 0.05)
        }
        return max(floor, exp(-candidate.stabilityMilliseconds / timeConstantMS))
    }

    private static func noTargetLikelihood(
        _ candidates: [VisualObservation],
        noveltyLikelihoods: [Double],
        previousTarget: AttentionTarget?
    ) -> Double {
        let strongestNovelEvidence = zip(candidates, noveltyLikelihoods)
            .map { $0.confidence * $1 }
            .max() ?? 0
        let base = max(0.03, 1 - strongestNovelEvidence)
        return previousTarget == nil ? base : base * 0.35
    }

    private static func normalizedEntropy(_ probabilities: [Double]) -> Double {
        guard probabilities.count > 1 else { return 0 }
        let entropy = -probabilities.reduce(0) { partial, probability in
            probability > 0 ? partial + probability * log(probability) : partial
        }
        return entropy / log(Double(probabilities.count))
    }
}
