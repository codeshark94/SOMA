import Foundation

public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }

    func blended(toward other: NormalizedRect, weight: Double) -> NormalizedRect {
        let w = clamp(weight)
        return NormalizedRect(
            x: x + (other.x - x) * w,
            y: y + (other.y - y) * w,
            width: width + (other.width - width) * w,
            height: height + (other.height - height) * w
        )
    }

    func advanced(byX velocityX: Double, y velocityY: Double, seconds: Double) -> NormalizedRect {
        let nextX = min(max(x + velocityX * seconds, 0), max(0, 1 - width))
        let nextY = min(max(y + velocityY * seconds, 0), max(0, 1 - height))
        return NormalizedRect(x: nextX, y: nextY, width: width, height: height)
    }
}

public enum VisualObservationSource: String, Codable, Hashable, Sendable {
    case neuralDetector = "coreml_ane"
    case neuralFaceDetector = "coreml_ane_face"
    case systemFaceDetector = "system_vision_face"
    case systemSaliency = "system_saliency"
    case tracker
}

public enum AttentionTargetKind: String, Codable, Equatable, Sendable {
    case human
    case object
    case unknown
}

public struct VisualObservation: Sendable {
    public let rect: NormalizedRect
    public let confidence: Double
    public let source: VisualObservationSource
    public let kind: AttentionTargetKind
    public let label: String?
    public let attentionWeight: Double
    public let posteriorProbability: Double
    public let sceneID: String?
    public let stabilityMilliseconds: Double
    public let isActionEligible: Bool
    /// Independent System Vision confirmation for a face candidate. It is
    /// transient L0 validation, not identity data.
    public let isFaceVerified: Bool

    public init(
        rect: NormalizedRect,
        confidence: Double,
        source: VisualObservationSource,
        kind: AttentionTargetKind? = nil,
        label: String? = nil,
        attentionWeight: Double = 0,
        posteriorProbability: Double = 0,
        sceneID: String? = nil,
        stabilityMilliseconds: Double = 0,
        isActionEligible: Bool = false,
        isFaceVerified: Bool = false
    ) {
        self.rect = rect
        self.confidence = clamp(confidence)
        self.source = source
        self.kind = kind ?? ((source == .neuralFaceDetector || source == .systemFaceDetector) ? .human : .unknown)
        self.label = label
        self.attentionWeight = clamp(attentionWeight)
        self.posteriorProbability = clamp(posteriorProbability)
        self.sceneID = sceneID
        self.stabilityMilliseconds = max(0, stabilityMilliseconds)
        self.isActionEligible = isActionEligible
        self.isFaceVerified = isFaceVerified
    }
}

public enum InteractionHypothesis: String, Codable, Sendable {
    case idle
    case observing
    case ready
}

public enum ActiveSensingPolicy: String, Codable, Sendable {
    case hold
    case reacquire
    case maintainTarget = "maintain_target"
    case observeTarget = "observe_target"
    case handoffCandidate = "handoff_candidate"
}

public enum TargetStatus: String, Codable, Sendable {
    case none
    case tracked
}

public enum AttentionRoute: String, Codable, Sendable {
    case idle
    case visual
    case auditory
    case audiovisual
}

public struct AttentionCue: Codable, Equatable, Sendable {
    public let route: AttentionRoute
    public let direction: AudioDirection
    public let confidence: Double

    public init(route: AttentionRoute, direction: AudioDirection, confidence: Double) {
        self.route = route
        self.direction = direction
        self.confidence = clamp(confidence)
    }
}

public struct AttentionTarget: Codable, Equatable, Sendable {
    public let id: String
    public let rect: NormalizedRect
    public let confidence: Double
    public let velocityX: Double
    public let velocityY: Double
    public let kind: AttentionTargetKind
    public let label: String?
    public let attentionWeight: Double
    public let posteriorProbability: Double
    public let stabilityMilliseconds: Double
    public let isActionEligible: Bool

    /// L0 has no identity or task-level intent. It may physically fixate only
    /// on current face evidence. Attention weights remain reasoning evidence.
    public var isFaceMotorTarget: Bool {
        isActionEligible && kind == .human && label == "face"
    }

    public var permitsL0MotorControl: Bool {
        isFaceMotorTarget
    }
}

public struct BeliefSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let monotonicNS: UInt64
    public let targetStatus: TargetStatus
    public let target: AttentionTarget?
    public let presenceProbability: Double
    public let voiceProbability: Double
    public let uncertainty: Double
    public let surprise: Double
    public let informationGain: Double
    public let idleProbability: Double
    public let observingProbability: Double
    public let readyProbability: Double
    public let attentionCue: AttentionCue
    public let policy: ActiveSensingPolicy
}

public final class PredictiveWorldModel: @unchecked Sendable {
    private struct TargetState {
        var rect: NormalizedRect
        var previousObservedRect: NormalizedRect
        var confidence: Double
        var velocityX: Double
        var velocityY: Double
        var lastObservationNS: UInt64
        var kind: AttentionTargetKind
        var label: String?
        var attentionWeight: Double
        var posteriorProbability: Double
        var sceneID: String?
        var stabilityMilliseconds: Double
        var isActionEligible: Bool
    }

    private struct AuditoryFocus {
        var direction: AudioDirection
        var confidence: Double
    }

    private let lock = NSLock()
    private var target: TargetState?
    private var auditoryFocus: AuditoryFocus?
    private var voiceProbability = 0.0
    private var uncertainty = 1.0
    private var surprise = 0.0
    private var lastUpdatedNS: UInt64?

    public init() {}

    @discardableResult
    public func ingestVisual(_ observation: VisualObservation, at monotonicNS: UInt64) -> BeliefSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !isStale(monotonicNS) else { return currentSnapshot() }
        let effectiveNS = orderedTimestamp(monotonicNS)
        advance(to: effectiveNS)

        if var current = target {
            let observationInterval = seconds(from: current.lastObservationNS, to: effectiveNS)
            let predictionDistance = distance(
                current.rect.centerX,
                current.rect.centerY,
                observation.rect.centerX,
                observation.rect.centerY
            )
            surprise = clamp(predictionDistance / 0.16)

            if observationInterval > 0.001 {
                let measuredVelocityX = (observation.rect.centerX - current.previousObservedRect.centerX) / observationInterval
                let measuredVelocityY = (observation.rect.centerY - current.previousObservedRect.centerY) / observationInterval
                current.velocityX = current.velocityX * 0.55 + measuredVelocityX * 0.45
                current.velocityY = current.velocityY * 0.55 + measuredVelocityY * 0.45
            }
            current.rect = current.rect.blended(toward: observation.rect, weight: 0.78)
            current.previousObservedRect = observation.rect
            current.confidence = clamp(current.confidence * 0.45 + observation.confidence * 0.55)
            current.lastObservationNS = effectiveNS
            if observation.kind != .unknown {
                current.kind = observation.kind
                current.label = observation.label
            }
            current.attentionWeight = observation.attentionWeight
            current.posteriorProbability = clamp(current.posteriorProbability * 0.35 + observation.posteriorProbability * 0.65)
            current.sceneID = observation.sceneID ?? current.sceneID
            current.stabilityMilliseconds = observation.stabilityMilliseconds
            current.isActionEligible = observation.isActionEligible
            target = current
        } else {
            target = TargetState(
                rect: observation.rect,
                previousObservedRect: observation.rect,
                confidence: observation.confidence,
                velocityX: 0,
                velocityY: 0,
                lastObservationNS: effectiveNS,
                kind: observation.kind,
                label: observation.label,
                attentionWeight: observation.attentionWeight,
                posteriorProbability: observation.posteriorProbability,
                sceneID: observation.sceneID,
                stabilityMilliseconds: observation.stabilityMilliseconds,
                isActionEligible: observation.isActionEligible
            )
            surprise = 0.15
        }

        uncertainty = max(0.03, uncertainty * 0.45 + surprise * 0.25)
        return makeSnapshot(at: effectiveNS)
    }

    @discardableResult
    public func ingestVisionMiss(at monotonicNS: UInt64) -> BeliefSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !isStale(monotonicNS) else { return currentSnapshot() }
        let effectiveNS = orderedTimestamp(monotonicNS)
        advance(to: effectiveNS)
        uncertainty = min(1, uncertainty + 0.10)
        surprise = max(surprise, 0.35)
        return makeSnapshot(at: effectiveNS)
    }

    @discardableResult
    public func ingestVoice(active: Bool, confidence: Double, at monotonicNS: UInt64) -> BeliefSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !isStale(monotonicNS) else { return currentSnapshot() }
        let effectiveNS = orderedTimestamp(monotonicNS)
        advance(to: effectiveNS)
        let evidence = clamp(confidence)
        voiceProbability = active
            ? max(voiceProbability * 0.65, evidence)
            : voiceProbability * 0.70
        return makeSnapshot(at: effectiveNS)
    }

    @discardableResult
    public func ingestAudioDirection(
        _ direction: AudioDirection,
        confidence: Double,
        at monotonicNS: UInt64
    ) -> BeliefSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard direction != .unknown, !isStale(monotonicNS) else { return currentSnapshot() }
        let effectiveNS = orderedTimestamp(monotonicNS)
        advance(to: effectiveNS)
        let evidence = clamp(confidence)
        guard evidence > 0 else { return makeSnapshot(at: effectiveNS) }

        if let current = auditoryFocus, current.direction == direction {
            auditoryFocus = AuditoryFocus(
                direction: direction,
                confidence: max(current.confidence * 0.70, evidence)
            )
        } else {
            auditoryFocus = AuditoryFocus(direction: direction, confidence: evidence)
        }

        if let target, directionForVisual(target.rect) != direction {
            surprise = max(surprise, evidence * 0.55)
            uncertainty = min(1, uncertainty * 0.82 + evidence * 0.18)
        } else {
            uncertainty = max(0.03, uncertainty * 0.88 - evidence * 0.08)
        }
        return makeSnapshot(at: effectiveNS)
    }

    @discardableResult
    public func snapshot(at monotonicNS: UInt64) -> BeliefSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !isStale(monotonicNS) else { return currentSnapshot() }
        let effectiveNS = orderedTimestamp(monotonicNS)
        advance(to: effectiveNS)
        return makeSnapshot(at: effectiveNS)
    }

    private func orderedTimestamp(_ candidate: UInt64) -> UInt64 {
        guard let lastUpdatedNS else { return candidate }
        return max(candidate, lastUpdatedNS)
    }

    private func isStale(_ candidate: UInt64) -> Bool {
        guard let lastUpdatedNS else { return false }
        return candidate < lastUpdatedNS
    }

    private func currentSnapshot() -> BeliefSnapshot {
        makeSnapshot(at: lastUpdatedNS ?? 0)
    }

    private func advance(to monotonicNS: UInt64) {
        guard let previous = lastUpdatedNS else {
            lastUpdatedNS = monotonicNS
            return
        }
        guard monotonicNS > previous else { return }
        let elapsed = seconds(from: previous, to: monotonicNS)
        let predictionSeconds = min(elapsed, 0.25)
        lastUpdatedNS = monotonicNS

        if var current = target {
            current.rect = current.rect.advanced(
                byX: current.velocityX,
                y: current.velocityY,
                seconds: predictionSeconds
            )
            current.confidence *= exp(-elapsed / 1.15)
            let observationAge = seconds(from: current.lastObservationNS, to: monotonicNS)
            if observationAge > 1.5 || current.confidence < 0.10 {
                target = nil
                uncertainty = min(1, uncertainty + 0.18)
            } else {
                target = current
            }
        }

        voiceProbability *= exp(-elapsed / 0.42)
        if var focus = auditoryFocus {
            focus.confidence *= exp(-elapsed / 0.65)
            auditoryFocus = focus.confidence < 0.08 ? nil : focus
        }
        uncertainty = min(1, uncertainty + elapsed * 0.20)
        surprise *= exp(-elapsed / 0.30)
    }

    private func makeSnapshot(at monotonicNS: UInt64) -> BeliefSnapshot {
        let presence = target?.confidence ?? 0
        let voice = voiceProbability
        let attentionCue = makeAttentionCue()
        let idleScore = (1 - presence) * 2.2 + uncertainty * 0.30
        let observingScore = presence * 1.55 - voice * 0.35 - uncertainty * 0.15
        let readyEvidence = attentionCue.route == .audiovisual
            ? max(voice, attentionCue.confidence)
            : voice
        let readyScore = presence * readyEvidence * 3.2 + surprise * 0.35 - uncertainty * 0.35
        let probabilities = softmax([idleScore, observingScore, readyScore])
        let informationGain = clamp(
            uncertainty * presence * 0.75 + voice * presence * 0.45 + attentionCue.confidence * 0.25 + surprise * 0.35
        )

        let policy: ActiveSensingPolicy
        if attentionCue.route == .auditory {
            policy = .reacquire
        } else if target == nil {
            policy = .hold
        } else if uncertainty > 0.68 {
            policy = .reacquire
        } else if probabilities[2] >= 0.58 {
            policy = .handoffCandidate
        } else if voice >= 0.28 {
            policy = .observeTarget
        } else {
            policy = .maintainTarget
        }

        let attentionTarget = target.map {
            AttentionTarget(
                id: $0.sceneID ?? "track-1",
                rect: $0.rect,
                confidence: $0.confidence,
                velocityX: $0.velocityX,
                velocityY: $0.velocityY,
                kind: $0.kind,
                label: $0.label,
                attentionWeight: $0.attentionWeight,
                posteriorProbability: $0.posteriorProbability,
                stabilityMilliseconds: $0.stabilityMilliseconds,
                isActionEligible: $0.isActionEligible
            )
        }
        return BeliefSnapshot(
            schemaVersion: 2,
            monotonicNS: monotonicNS,
            targetStatus: attentionTarget == nil ? .none : .tracked,
            target: attentionTarget,
            presenceProbability: presence,
            voiceProbability: voice,
            uncertainty: uncertainty,
            surprise: surprise,
            informationGain: informationGain,
            idleProbability: probabilities[0],
            observingProbability: probabilities[1],
            readyProbability: probabilities[2],
            attentionCue: attentionCue,
            policy: policy
        )
    }

    private func makeAttentionCue() -> AttentionCue {
        let visualDirection = target.map { directionForVisual($0.rect) }
        let visualConfidence = target?.confidence ?? 0
        let auditoryDirection = auditoryFocus?.direction ?? .unknown
        let auditoryConfidence = auditoryFocus?.confidence ?? 0

        guard auditoryDirection != .unknown, auditoryConfidence >= 0.20 else {
            if let visualDirection {
                return AttentionCue(route: .visual, direction: visualDirection, confidence: visualConfidence)
            }
            return AttentionCue(route: .idle, direction: .unknown, confidence: 0)
        }
        guard let visualDirection else {
            return AttentionCue(route: .auditory, direction: auditoryDirection, confidence: auditoryConfidence)
        }
        if visualDirection == auditoryDirection {
            return AttentionCue(
                route: .audiovisual,
                direction: visualDirection,
                confidence: 1 - (1 - visualConfidence) * (1 - auditoryConfidence)
            )
        }
        if auditoryConfidence > visualConfidence + 0.18 {
            return AttentionCue(route: .auditory, direction: auditoryDirection, confidence: auditoryConfidence)
        }
        return AttentionCue(route: .visual, direction: visualDirection, confidence: visualConfidence)
    }

    private func directionForVisual(_ rect: NormalizedRect) -> AudioDirection {
        if rect.centerX < 0.38 { return .left }
        if rect.centerX > 0.62 { return .right }
        return .center
    }
}

private func seconds(from earlier: UInt64, to later: UInt64) -> Double {
    guard later > earlier else { return 0 }
    return Double(later - earlier) / 1_000_000_000
}

private func distance(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
    hypot(x2 - x1, y2 - y1)
}

private func softmax(_ values: [Double]) -> [Double] {
    let maximum = values.max() ?? 0
    let exponentials = values.map { exp($0 - maximum) }
    let total = exponentials.reduce(0, +)
    return exponentials.map { $0 / total }
}

private func clamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
}
