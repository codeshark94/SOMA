import Foundation

public enum CognitiveControlLayer: String, Codable, CaseIterable, Sendable {
    case l1
    case l2

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case Self.l1.rawValue:
            self = .l1
        case Self.l2.rawValue, "l3":
            // Earlier development builds split voice transport into a third
            // layer. Voice is now an L2 input channel, so old requests migrate to
            // the same L2 authority instead of creating a third control layer.
            self = .l2
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown cognitive control layer"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct EmbodimentLease: Codable, Equatable, Sendable {
    public let ownerID: String
    public let priority: UInt8
    public let issuedAtNS: UInt64
    public let durationMilliseconds: UInt64
    public let cancellationToken: String

    public init(
        ownerID: String,
        priority: UInt8,
        issuedAtNS: UInt64,
        durationMilliseconds: UInt64,
        cancellationToken: String
    ) {
        self.ownerID = String(ownerID.prefix(96))
        self.priority = min(priority, 100)
        self.issuedAtNS = issuedAtNS
        self.durationMilliseconds = durationMilliseconds
        self.cancellationToken = String(cancellationToken.prefix(128))
    }

    public var expiresAtNS: UInt64 {
        let durationNS = durationMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        guard !durationNS.overflow else { return UInt64.max }
        let expiry = issuedAtNS.addingReportingOverflow(durationNS.partialValue)
        return expiry.overflow ? UInt64.max : expiry.partialValue
    }
}

public struct SemanticTargetRegistration: Codable, Equatable, Sendable {
    public let targetReference: String
    public let sceneID: String?
    public let label: String
    public let aliases: [String]
    public let visualQuery: String?
    public let expectedKind: AttentionTargetKind?
    public let initialSelectionLogPrior: Double

    public init(
        targetReference: String,
        sceneID: String? = nil,
        label: String,
        aliases: [String] = [],
        visualQuery: String? = nil,
        expectedKind: AttentionTargetKind? = nil,
        initialSelectionLogPrior: Double = 0
    ) {
        self.targetReference = String(targetReference.prefix(96))
        self.sceneID = sceneID.map { String($0.prefix(96)) }
        self.label = String(label.prefix(96))
        self.aliases = Array(aliases.prefix(12)).map { String($0.prefix(96)) }
        self.visualQuery = visualQuery.map { String($0.prefix(240)) }
        self.expectedKind = expectedKind
        self.initialSelectionLogPrior = Self.logPrior(initialSelectionLogPrior)
    }

    private static func logPrior(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -12), 12)
    }
}

public struct TargetAttentionDirective: Codable, Equatable, Sendable {
    public let targetReference: String
    public let selectionLogPrior: Double
    public let trackingCommitment: Double

    public init(
        targetReference: String,
        selectionLogPrior: Double,
        trackingCommitment: Double
    ) {
        self.targetReference = String(targetReference.prefix(96))
        self.selectionLogPrior = selectionLogPrior.isFinite
            ? min(max(selectionLogPrior, -12), 12)
            : 0
        self.trackingCommitment = Self.probability(trackingCommitment)
    }

    private static func probability(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct AttentionPolicyGoal: Codable, Equatable, Sendable {
    public let targets: [TargetAttentionDirective]
    public let selectionTemperature: Double
    public let noveltyStrength: Double
    public let habituationStrength: Double
    public let minimumDwellMilliseconds: UInt64
    public let maximumDwellMilliseconds: UInt64

    public init(
        targets: [TargetAttentionDirective],
        selectionTemperature: Double = 1,
        noveltyStrength: Double = 0.5,
        habituationStrength: Double = 0.5,
        minimumDwellMilliseconds: UInt64 = 250,
        maximumDwellMilliseconds: UInt64 = 4_000
    ) {
        self.targets = Array(targets.prefix(64))
        self.selectionTemperature = selectionTemperature.isFinite
            ? min(max(selectionTemperature, 0.10), 5)
            : 1
        self.noveltyStrength = Self.probability(noveltyStrength)
        self.habituationStrength = Self.probability(habituationStrength)
        self.minimumDwellMilliseconds = minimumDwellMilliseconds
        self.maximumDwellMilliseconds = maximumDwellMilliseconds
    }

    /// Converts the supplied log-prior adjustments into a normalized
    /// distribution. Live sensor likelihoods are combined by L0 afterward.
    public var normalizedTargetPriors: [String: Double] {
        guard !targets.isEmpty else { return [:] }
        let maximum = targets.map(\.selectionLogPrior).max() ?? 0
        var massByTarget: [String: Double] = [:]
        for target in targets {
            massByTarget[target.targetReference, default: 0] += exp(target.selectionLogPrior - maximum)
        }
        let total = massByTarget.values.reduce(0, +)
        guard total > 0, total.isFinite else { return [:] }
        return massByTarget.mapValues { $0 / total }
    }

    private static func probability(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public enum EmbodimentMotionStyle: String, Codable, CaseIterable, Sendable {
    case precise
    case smooth
    case attentive
    case curious
    case playful
    case cautious
}

public struct TrackTargetGoal: Codable, Equatable, Sendable {
    public let targetReference: String
    public let framing: NormalizedRect?
    public let reacquireIfOccluded: Bool
    public let motionStyle: EmbodimentMotionStyle

    public init(
        targetReference: String,
        framing: NormalizedRect? = nil,
        reacquireIfOccluded: Bool = true,
        motionStyle: EmbodimentMotionStyle = .smooth
    ) {
        self.targetReference = String(targetReference.prefix(96))
        self.framing = framing
        self.reacquireIfOccluded = reacquireIfOccluded
        self.motionStyle = motionStyle
    }
}

public struct OrientGoal: Codable, Equatable, Sendable {
    public let bearing: GimbalRelativeBearing
    public let toleranceDegrees: Double
    public let motionStyle: EmbodimentMotionStyle

    public init(
        bearing: GimbalRelativeBearing,
        toleranceDegrees: Double = 3,
        motionStyle: EmbodimentMotionStyle = .smooth
    ) {
        self.bearing = bearing
        self.toleranceDegrees = toleranceDegrees.isFinite
            ? min(max(toleranceDegrees, 0.5), 30)
            : 3
        self.motionStyle = motionStyle
    }
}

public struct SphericalSearchRegion: Codable, Equatable, Sendable {
    public let center: GimbalRelativeBearing
    public let azimuthRadiusDegrees: Double
    public let elevationRadiusDegrees: Double
    public let preference: Double

    public init(
        center: GimbalRelativeBearing,
        azimuthRadiusDegrees: Double,
        elevationRadiusDegrees: Double,
        preference: Double = 1
    ) {
        self.center = center
        self.azimuthRadiusDegrees = Self.bound(azimuthRadiusDegrees, lower: 1, upper: 180, fallback: 30)
        self.elevationRadiusDegrees = Self.bound(elevationRadiusDegrees, lower: 1, upper: 90, fallback: 20)
        self.preference = Self.bound(preference, lower: -1, upper: 1, fallback: 0)
    }

    private static func bound(_ value: Double, lower: Double, upper: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, lower), upper)
    }
}

public struct DirectionalPreference: Codable, Equatable, Sendable {
    public let bearing: GimbalRelativeBearing
    public let concentration: Double
    public let weight: Double

    public init(bearing: GimbalRelativeBearing, concentration: Double, weight: Double) {
        self.bearing = bearing
        self.concentration = concentration.isFinite ? min(max(concentration, 0.1), 50) : 1
        self.weight = weight.isFinite ? max(weight, 0) : 0
    }
}

public enum ExplorationMode: String, Codable, CaseIterable, Sendable {
    case probabilisticCoverage = "probabilistic_coverage"
    case noveltySeeking = "novelty_seeking"
    case memoryGap = "memory_gap"
    case targetBiased = "target_biased"
    case directedSurvey = "directed_survey"
}

public struct ExplorationPolicyGoal: Codable, Equatable, Sendable {
    public let mode: ExplorationMode
    public let regions: [SphericalSearchRegion]
    public let preferredDirections: [DirectionalPreference]
    public let coverageStrength: Double
    public let noveltyStrength: Double
    public let memoryGapStrength: Double
    public let motionContinuity: Double
    public let tempo: Double
    public let dwellMilliseconds: UInt64

    public init(
        mode: ExplorationMode,
        regions: [SphericalSearchRegion] = [],
        preferredDirections: [DirectionalPreference] = [],
        coverageStrength: Double = 0.5,
        noveltyStrength: Double = 0.5,
        memoryGapStrength: Double = 0.5,
        motionContinuity: Double = 0.8,
        tempo: Double = 0.5,
        dwellMilliseconds: UInt64 = 350
    ) {
        self.mode = mode
        self.regions = Array(regions.prefix(32))
        self.preferredDirections = Array(preferredDirections.prefix(32))
        self.coverageStrength = Self.probability(coverageStrength)
        self.noveltyStrength = Self.probability(noveltyStrength)
        self.memoryGapStrength = Self.probability(memoryGapStrength)
        self.motionContinuity = Self.probability(motionContinuity)
        self.tempo = Self.probability(tempo)
        self.dwellMilliseconds = dwellMilliseconds
    }

    public var normalizedDirectionWeights: [Double] {
        let total = preferredDirections.reduce(0) { $0 + $1.weight }
        guard total > 0, total.isFinite else { return [] }
        return preferredDirections.map { $0.weight / total }
    }

    private static func probability(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public enum SocialGimbalExpression: String, Codable, CaseIterable, Sendable {
    case acknowledge
    case nod
    case attentiveReframe = "attentive_reframe"
    case thinkingGlance = "thinking_glance"
    case greeting
}

public struct CaptureViewGoal: Codable, Equatable, Sendable {
    public let targetReference: String?
    public let bearing: GimbalRelativeBearing?
    public let fieldOfViewDegrees: Double?
    /// Captures the next camera frame without moving the gimbal. This is a
    /// sensor read rather than a motor goal, so it never preempts L0 tracking.
    public let currentFrame: Bool?

    public init(
        targetReference: String? = nil,
        bearing: GimbalRelativeBearing? = nil,
        fieldOfViewDegrees: Double? = nil,
        currentFrame: Bool = false
    ) {
        self.targetReference = targetReference.map { String($0.prefix(96)) }
        self.bearing = bearing
        self.fieldOfViewDegrees = fieldOfViewDegrees.map {
            $0.isFinite ? min(max($0, 5), 120) : 70
        }
        self.currentFrame = currentFrame ? true : nil
    }

    public var requestsCurrentFrame: Bool { currentFrame == true }
}

public enum EmbodimentViewCaptureState: String, Codable, Sendable {
    case pendingAlignment = "pending_alignment"
    case awaitingFrame = "awaiting_frame"
    case encoding
    case ready
    case failed
    case expired
}

/// A short-lived local image handle produced by one explicit capture goal.
/// Pixels remain outside the scalar cognitive trace and are deleted after the
/// resource TTL or bounded-store eviction.
public struct EmbodimentViewResource: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let state: EmbodimentViewCaptureState
    public let imagePath: String?
    public let mimeType: String?
    public let width: Int?
    public let height: Int?
    public let capturedAtNS: UInt64?
    public let resourceExpiresAtNS: UInt64?
    public let targetReference: String?
    public let sceneID: String?
    public let bearing: GimbalRelativeBearing?
    public let cameraBearing: GimbalRelativeBearing?
    public let fieldOfViewDegrees: Double?
    public let failureReason: String?

    public init(
        requestID: String,
        state: EmbodimentViewCaptureState,
        imagePath: String? = nil,
        mimeType: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        capturedAtNS: UInt64? = nil,
        resourceExpiresAtNS: UInt64? = nil,
        targetReference: String? = nil,
        sceneID: String? = nil,
        bearing: GimbalRelativeBearing? = nil,
        cameraBearing: GimbalRelativeBearing? = nil,
        fieldOfViewDegrees: Double? = nil,
        failureReason: String? = nil
    ) {
        schemaVersion = 1
        self.requestID = String(requestID.prefix(96))
        self.state = state
        self.imagePath = imagePath.map { String($0.prefix(512)) }
        self.mimeType = mimeType.map { String($0.prefix(64)) }
        self.width = width
        self.height = height
        self.capturedAtNS = capturedAtNS
        self.resourceExpiresAtNS = resourceExpiresAtNS
        self.targetReference = targetReference.map { String($0.prefix(96)) }
        self.sceneID = sceneID.map { String($0.prefix(96)) }
        self.bearing = bearing
        self.cameraBearing = cameraBearing
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.failureReason = failureReason.map { String($0.prefix(240)) }
    }
}

public enum CognitiveEmbodimentOperation: Equatable, Sendable {
    case registerTarget(SemanticTargetRegistration)
    case removeTarget(String)
    case setAttentionPolicy(AttentionPolicyGoal)
    case trackTarget(TrackTargetGoal)
    case orient(OrientGoal)
    case explore(ExplorationPolicyGoal)
    case captureView(CaptureViewGoal)
    case express(SocialGimbalExpression)
    case release
}

extension CognitiveEmbodimentOperation: Codable {
    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum Kind: String, Codable {
        case registerTarget = "register_target"
        case removeTarget = "remove_target"
        case setAttentionPolicy = "set_attention_policy"
        case trackTarget = "track_target"
        case orient
        case explore
        case captureView = "capture_view"
        case express
        case release
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .registerTarget:
            self = .registerTarget(try values.decode(SemanticTargetRegistration.self, forKey: .payload))
        case .removeTarget:
            self = .removeTarget(try values.decode(String.self, forKey: .payload))
        case .setAttentionPolicy:
            self = .setAttentionPolicy(try values.decode(AttentionPolicyGoal.self, forKey: .payload))
        case .trackTarget:
            self = .trackTarget(try values.decode(TrackTargetGoal.self, forKey: .payload))
        case .orient:
            self = .orient(try values.decode(OrientGoal.self, forKey: .payload))
        case .explore:
            self = .explore(try values.decode(ExplorationPolicyGoal.self, forKey: .payload))
        case .captureView:
            self = .captureView(try values.decode(CaptureViewGoal.self, forKey: .payload))
        case .express:
            self = .express(try values.decode(SocialGimbalExpression.self, forKey: .payload))
        case .release:
            self = .release
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .registerTarget(payload):
            try values.encode(Kind.registerTarget, forKey: .type)
            try values.encode(payload, forKey: .payload)
        case let .removeTarget(payload):
            try values.encode(Kind.removeTarget, forKey: .type)
            try values.encode(payload, forKey: .payload)
        case let .setAttentionPolicy(payload):
            try values.encode(Kind.setAttentionPolicy, forKey: .type)
            try values.encode(payload, forKey: .payload)
        case let .trackTarget(payload):
            try values.encode(Kind.trackTarget, forKey: .type)
            try values.encode(payload, forKey: .payload)
        case let .orient(payload):
            try values.encode(Kind.orient, forKey: .type)
            try values.encode(payload, forKey: .payload)
        case let .explore(payload):
            try values.encode(Kind.explore, forKey: .type)
            try values.encode(payload, forKey: .payload)
        case let .captureView(payload):
            try values.encode(Kind.captureView, forKey: .type)
            try values.encode(payload, forKey: .payload)
        case let .express(payload):
            try values.encode(Kind.express, forKey: .type)
            try values.encode(payload, forKey: .payload)
        case .release:
            try values.encode(Kind.release, forKey: .type)
        }
    }
}

public struct CognitiveEmbodimentRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let layer: CognitiveControlLayer
    public let reason: String
    public let evidenceIDs: [String]
    public let lease: EmbodimentLease
    public let operation: CognitiveEmbodimentOperation

    public init(
        requestID: String,
        layer: CognitiveControlLayer,
        reason: String,
        evidenceIDs: [String],
        lease: EmbodimentLease,
        operation: CognitiveEmbodimentOperation
    ) {
        schemaVersion = 1
        self.requestID = String(requestID.prefix(96))
        self.layer = layer
        self.reason = String(reason.prefix(240))
        self.evidenceIDs = Array(evidenceIDs.prefix(16)).map { String($0.prefix(128)) }
        self.lease = lease
        self.operation = operation
    }

    public func validate() throws {
        func isNonBlank(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func isProbability(_ value: Double) -> Bool {
            value.isFinite && value >= 0 && value <= 1
        }
        func isBearing(_ value: GimbalRelativeBearing) -> Bool {
            value.azimuthDegrees.isFinite
                && value.azimuthDegrees > -180
                && value.azimuthDegrees <= 180
                && value.elevationDegrees.isFinite
                && value.elevationDegrees >= -90
                && value.elevationDegrees <= 90
        }
        func isNormalizedRect(_ value: NormalizedRect) -> Bool {
            value.x.isFinite && value.y.isFinite && value.width.isFinite && value.height.isFinite
                && value.x >= 0 && value.y >= 0
                && value.width > 0 && value.height > 0
                && value.x + value.width <= 1
                && value.y + value.height <= 1
        }
        guard schemaVersion == 1,
              requestID.count <= 96,
              isNonBlank(requestID),
              reason.count <= 240,
              isNonBlank(reason),
              evidenceIDs.count <= 16,
              evidenceIDs.allSatisfy({ $0.count <= 128 && isNonBlank($0) }),
              lease.ownerID.count <= 96,
              isNonBlank(lease.ownerID),
              lease.cancellationToken.count <= 128,
              isNonBlank(lease.cancellationToken),
              lease.durationMilliseconds > 0,
              lease.durationMilliseconds <= 600_000 else {
            throw CognitiveEmbodimentError.invalidRequest
        }
        switch operation {
        case let .registerTarget(target):
            guard target.targetReference.count <= 96,
                  isNonBlank(target.targetReference),
                  target.label.count <= 96,
                  isNonBlank(target.label),
                  target.aliases.count <= 12,
                  target.aliases.allSatisfy({ $0.count <= 96 && isNonBlank($0) }),
                  target.initialSelectionLogPrior.isFinite,
                  target.initialSelectionLogPrior >= -12,
                  target.initialSelectionLogPrior <= 12,
                  target.sceneID.map({ $0.count <= 96 && isNonBlank($0) }) == true
                    || target.visualQuery.map({ $0.count <= 240 && isNonBlank($0) }) == true else {
                throw CognitiveEmbodimentError.invalidTarget
            }
        case let .removeTarget(reference):
            guard reference.count <= 96, isNonBlank(reference) else {
                throw CognitiveEmbodimentError.invalidTarget
            }
        case let .setAttentionPolicy(policy):
            guard policy.targets.count <= 64,
                  policy.selectionTemperature.isFinite,
                  policy.selectionTemperature >= 0.10,
                  policy.selectionTemperature <= 5,
                  isProbability(policy.noveltyStrength),
                  isProbability(policy.habituationStrength),
                  policy.minimumDwellMilliseconds <= policy.maximumDwellMilliseconds,
                  policy.maximumDwellMilliseconds <= 60_000,
                  Set(policy.targets.map(\.targetReference)).count == policy.targets.count,
                  policy.targets.allSatisfy({
                      $0.targetReference.count <= 96
                        && isNonBlank($0.targetReference)
                        && $0.selectionLogPrior.isFinite
                        && $0.selectionLogPrior >= -12
                        && $0.selectionLogPrior <= 12
                        && isProbability($0.trackingCommitment)
                  }) else {
                throw CognitiveEmbodimentError.invalidAttentionPolicy
            }
        case let .trackTarget(goal):
            guard goal.targetReference.count <= 96,
                  isNonBlank(goal.targetReference),
                  goal.framing.map(isNormalizedRect) ?? true else {
                throw CognitiveEmbodimentError.invalidTarget
            }
        case let .orient(goal):
            guard isBearing(goal.bearing),
                  goal.toleranceDegrees.isFinite,
                  goal.toleranceDegrees >= 0.5,
                  goal.toleranceDegrees <= 30 else {
                throw CognitiveEmbodimentError.invalidRequest
            }
        case let .explore(policy):
            guard policy.regions.count <= 32,
                  policy.preferredDirections.count <= 32,
                  isProbability(policy.coverageStrength),
                  isProbability(policy.noveltyStrength),
                  isProbability(policy.memoryGapStrength),
                  isProbability(policy.motionContinuity),
                  isProbability(policy.tempo),
                  policy.dwellMilliseconds <= 60_000,
                  policy.regions.allSatisfy({
                      isBearing($0.center)
                        && $0.azimuthRadiusDegrees.isFinite
                        && $0.azimuthRadiusDegrees >= 1
                        && $0.azimuthRadiusDegrees <= 180
                        && $0.elevationRadiusDegrees.isFinite
                        && $0.elevationRadiusDegrees >= 1
                        && $0.elevationRadiusDegrees <= 90
                        && $0.preference.isFinite
                        && $0.preference >= -1
                        && $0.preference <= 1
                  }),
                  policy.preferredDirections.allSatisfy({
                      isBearing($0.bearing)
                        && $0.concentration.isFinite
                        && $0.concentration >= 0.1
                        && $0.concentration <= 50
                        && $0.weight.isFinite
                        && $0.weight > 0
                  }) else {
                throw CognitiveEmbodimentError.invalidExplorationPolicy
            }
        case let .captureView(goal):
            let hasTarget = goal.targetReference.map({ $0.count <= 96 && isNonBlank($0) }) == true
            let hasBearing = goal.bearing.map(isBearing) == true
            guard (goal.requestsCurrentFrame
                    ? !hasTarget && !hasBearing
                    : hasTarget || hasBearing),
                  goal.fieldOfViewDegrees.map({ $0.isFinite && $0 >= 5 && $0 <= 120 }) ?? true else {
                throw CognitiveEmbodimentError.invalidCaptureGoal
            }
        case .express, .release:
            break
        }
    }
}

public enum CognitiveEmbodimentError: Error, Equatable {
    case invalidRequest
    case invalidTarget
    case invalidAttentionPolicy
    case invalidExplorationPolicy
    case invalidCaptureGoal
}

public enum CognitiveEmbodimentOperationKind: String, Codable, CaseIterable, Sendable {
    case registerTarget = "register_target"
    case removeTarget = "remove_target"
    case setAttentionPolicy = "set_attention_policy"
    case trackTarget = "track_target"
    case orient
    case explore
    case captureView = "capture_view"
    case express
    case release
}

public extension CognitiveEmbodimentOperation {
    var kind: CognitiveEmbodimentOperationKind {
        switch self {
        case .registerTarget: .registerTarget
        case .removeTarget: .removeTarget
        case .setAttentionPolicy: .setAttentionPolicy
        case .trackTarget: .trackTarget
        case .orient: .orient
        case .explore: .explore
        case .captureView: .captureView
        case .express: .express
        case .release: .release
        }
    }

    var claimsMotorLease: Bool {
        switch self {
        case .trackTarget, .orient, .explore, .express:
            return true
        case let .captureView(goal):
            return !goal.requestsCurrentFrame
        case .registerTarget, .removeTarget, .setAttentionPolicy, .release:
            return false
        }
    }
}

public enum EmbodimentShadowStatus: String, Codable, Sendable {
    case accepted
    case rejected
    case released
}

public struct EmbodimentShadowTarget: Codable, Equatable, Sendable {
    public let targetReference: String
    public let label: String
    public let sceneID: String?
    public let ownerID: String
    public let layer: CognitiveControlLayer
    public let expiresAtNS: UInt64
}

public struct EmbodimentShadowSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let monotonicNS: UInt64
    public let mode: String
    public let physicalActuationEnabled: Bool
    public let activeRequestID: String?
    public let activeOwnerID: String?
    public let activeLayer: CognitiveControlLayer?
    public let activeOperation: CognitiveEmbodimentOperationKind?
    public let activeTargetReference: String?
    public let activePriority: UInt8?
    public let activeExpiresAtNS: UInt64?
    public let registeredTargets: [EmbodimentShadowTarget]
    public let attentionPolicyOwners: [String]
    public let sceneEntityCount: Int
    public let sceneEntities: [EmbodimentSceneEntity]
    public let targetBindings: [SemanticTargetBinding]
    public let spatialAtlas: SphericalSceneAtlasSnapshot
    public let panorama: PanoramaMapStatus?
}

public struct EmbodimentShadowDecision: Codable, Equatable, Sendable {
    public let requestID: String
    public let layer: CognitiveControlLayer
    public let operation: CognitiveEmbodimentOperationKind
    public let status: EmbodimentShadowStatus
    public let reason: String
    public let preemptedRequestID: String?
    public let snapshot: EmbodimentShadowSnapshot
}

/// Evaluates cognitive embodiment requests inside the L0 process. It owns only
/// semantic leases; an optional L0 motor adapter remains the sole component
/// allowed to translate accepted goals into actuator commands.
public final class ShadowEmbodimentArbiter: @unchecked Sendable {
    private struct OwnedTarget {
        let registration: SemanticTargetRegistration
        let ownerID: String
        let layer: CognitiveControlLayer
        let expiresAtNS: UInt64
    }

    private struct OwnedAttentionPolicy {
        let policy: AttentionPolicyGoal
        let expiresAtNS: UInt64
    }

    private struct ActiveMotorGoal {
        let requestID: String
        let layer: CognitiveControlLayer
        let operation: CognitiveEmbodimentOperationKind
        let targetReference: String?
        let lease: EmbodimentLease
    }

    private let lock = NSLock()
    private var targets: [String: OwnedTarget] = [:]
    private var attentionPolicies: [String: OwnedAttentionPolicy] = [:]
    private var activeMotorGoal: ActiveMotorGoal?
    private var bindingEngine = SemanticTargetBindingEngine()
    private var sceneEntities: [EmbodimentSceneEntity] = []
    private var totalSceneEntityCount = 0
    private var targetBindings: [SemanticTargetBinding] = []
    private var bindingFingerprints: [String: String] = [:]
    private let spatialAtlas: SphericalSceneAtlasStore
    private let panoramaStatus: PanoramaMapStatusStore
    private let physicalActuationEnabled: Bool
    private let maximumRegisteredTargets = 256
    private let maximumAttentionPolicyOwners = 32
    private let maximumSnapshotSceneEntities = 256

    public init(
        spatialAtlas: SphericalSceneAtlasStore = SphericalSceneAtlasStore(),
        panoramaStatus: PanoramaMapStatusStore = PanoramaMapStatusStore(),
        physicalActuationEnabled: Bool = false
    ) {
        self.spatialAtlas = spatialAtlas
        self.panoramaStatus = panoramaStatus
        self.physicalActuationEnabled = physicalActuationEnabled
    }

    public func submit(
        _ request: CognitiveEmbodimentRequest,
        at monotonicNS: UInt64
    ) -> EmbodimentShadowDecision {
        lock.lock()
        defer { lock.unlock() }
        expire(at: monotonicNS)

        do {
            try request.validate()
        } catch {
            return decision(
                request: request,
                status: .rejected,
                reason: "invalid_request",
                preemptedRequestID: nil,
                at: monotonicNS
            )
        }
        guard request.lease.issuedAtNS <= monotonicNS + 1_000_000_000,
              request.lease.expiresAtNS > monotonicNS else {
            return decision(
                request: request,
                status: .rejected,
                reason: "inactive_lease",
                preemptedRequestID: nil,
                at: monotonicNS
            )
        }

        switch request.operation {
        case let .registerTarget(registration):
            if let existing = targets[registration.targetReference],
               existing.ownerID != request.lease.ownerID {
                return decision(
                    request: request,
                    status: .rejected,
                    reason: "target_reference_owned_by_another_owner",
                    preemptedRequestID: nil,
                    at: monotonicNS
                )
            }
            guard targets[registration.targetReference] != nil
                    || targets.count < maximumRegisteredTargets else {
                return decision(
                    request: request,
                    status: .rejected,
                    reason: "target_capacity_reached",
                    preemptedRequestID: nil,
                    at: monotonicNS
                )
            }
            targets[registration.targetReference] = OwnedTarget(
                registration: registration,
                ownerID: request.lease.ownerID,
                layer: request.layer,
                expiresAtNS: request.lease.expiresAtNS
            )
            refreshTargetBindings()
            return decision(
                request: request,
                status: .accepted,
                reason: "target_registered_shadow",
                preemptedRequestID: nil,
                at: monotonicNS
            )
        case let .removeTarget(reference):
            guard let target = targets[reference], target.ownerID == request.lease.ownerID else {
                return decision(
                    request: request,
                    status: .rejected,
                    reason: "target_not_owned",
                    preemptedRequestID: nil,
                    at: monotonicNS
                )
            }
            targets.removeValue(forKey: reference)
            targetBindings.removeAll { $0.targetReference == reference }
            bindingFingerprints.removeValue(forKey: reference)
            if activeMotorGoal?.targetReference == reference { activeMotorGoal = nil }
            return decision(
                request: request,
                status: .accepted,
                reason: "target_removed_shadow",
                preemptedRequestID: nil,
                at: monotonicNS
            )
        case let .setAttentionPolicy(policy):
            let unknownReferences = policy.targets.map(\.targetReference).filter { targets[$0] == nil }
            guard unknownReferences.isEmpty else {
                return decision(
                    request: request,
                    status: .rejected,
                    reason: "attention_target_unknown",
                    preemptedRequestID: nil,
                    at: monotonicNS
                )
            }
            guard attentionPolicies[request.lease.ownerID] != nil
                    || attentionPolicies.count < maximumAttentionPolicyOwners else {
                return decision(
                    request: request,
                    status: .rejected,
                    reason: "attention_policy_owner_capacity_reached",
                    preemptedRequestID: nil,
                    at: monotonicNS
                )
            }
            attentionPolicies[request.lease.ownerID] = OwnedAttentionPolicy(
                policy: policy,
                expiresAtNS: request.lease.expiresAtNS
            )
            return decision(
                request: request,
                status: .accepted,
                reason: "attention_policy_active_shadow",
                preemptedRequestID: nil,
                at: monotonicNS
            )
        case let .trackTarget(goal):
            guard targets[goal.targetReference] != nil else {
                return decision(
                    request: request,
                    status: .rejected,
                    reason: "tracking_target_unknown",
                    preemptedRequestID: nil,
                    at: monotonicNS
                )
            }
            return claimMotor(request, at: monotonicNS)
        case let .captureView(goal) where goal.requestsCurrentFrame:
            return decision(
                request: request,
                status: .accepted,
                reason: "current_frame_capture_ready",
                preemptedRequestID: nil,
                at: monotonicNS
            )
        case .orient, .explore, .captureView, .express:
            return claimMotor(request, at: monotonicNS)
        case .release:
            let ownedActive = activeMotorGoal?.lease.ownerID == request.lease.ownerID
            if ownedActive { activeMotorGoal = nil }
            attentionPolicies.removeValue(forKey: request.lease.ownerID)
            let releasedReferences = Set(targets.values
                .filter { $0.ownerID == request.lease.ownerID }
                .map { $0.registration.targetReference })
            targets = targets.filter { $0.value.ownerID != request.lease.ownerID }
            targetBindings.removeAll { releasedReferences.contains($0.targetReference) }
            bindingFingerprints = bindingFingerprints.filter { !releasedReferences.contains($0.key) }
            return decision(
                request: request,
                status: .released,
                reason: ownedActive ? "owner_released_shadow" : "owner_state_cleared_shadow",
                preemptedRequestID: nil,
                at: monotonicNS
            )
        }
    }

    public func snapshot(at monotonicNS: UInt64) -> EmbodimentShadowSnapshot {
        lock.lock()
        defer { lock.unlock() }
        expire(at: monotonicNS)
        return makeSnapshot(at: monotonicNS)
    }

    /// Completes a one-shot motor goal without clearing the owner's registered
    /// targets or attention policy. Long-lived tracking/exploration still ends
    /// only through lease expiry, preemption, or an explicit owner release.
    @discardableResult
    public func completeMotorGoal(requestID: String, at monotonicNS: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        expire(at: monotonicNS)
        guard activeMotorGoal?.requestID == requestID else { return false }
        activeMotorGoal = nil
        return true
    }

    /// Updates the cognitive scene projection and returns only binding state
    /// transitions. Callers can therefore trace object permanence without
    /// persisting a high-rate duplicate of the scene field.
    public func updateScene(
        _ entities: [EmbodimentSceneEntity],
        at monotonicNS: UInt64
    ) -> [SemanticTargetBinding] {
        lock.lock()
        defer { lock.unlock() }
        expire(at: monotonicNS)
        totalSceneEntityCount = entities.count
        sceneEntities = Array(entities.sorted { lhs, rhs in
            if lhs.observedThisFrame != rhs.observedThisFrame {
                return lhs.observedThisFrame && !rhs.observedThisFrame
            }
            if lhs.lastSeenMilliseconds != rhs.lastSeenMilliseconds {
                return lhs.lastSeenMilliseconds < rhs.lastSeenMilliseconds
            }
            return lhs.sceneID < rhs.sceneID
        }.prefix(maximumSnapshotSceneEntities))
        refreshTargetBindings()
        spatialAtlas.updateScene(entities)
        var changed: [SemanticTargetBinding] = []
        for binding in targetBindings {
            let fingerprint = bindingFingerprint(binding)
            if bindingFingerprints[binding.targetReference] != fingerprint {
                bindingFingerprints[binding.targetReference] = fingerprint
                changed.append(binding)
            }
        }
        return changed
    }

    /// Resolve bindings whenever either side of the relation changes. This
    /// lets a registration bind to already-observed scene evidence immediately
    /// instead of waiting for a later camera frame.
    private func refreshTargetBindings() {
        let registrations = targets.values
            .map(\.registration)
            .sorted { $0.targetReference < $1.targetReference }
        targetBindings = bindingEngine.resolve(
            registrations: registrations,
            entities: sceneEntities
        )
        let activeReferences = Set(registrations.map(\.targetReference))
        bindingFingerprints = bindingFingerprints.filter { activeReferences.contains($0.key) }
    }

    private func claimMotor(
        _ request: CognitiveEmbodimentRequest,
        at monotonicNS: UInt64
    ) -> EmbodimentShadowDecision {
        let previous = activeMotorGoal
        if let previous,
           previous.lease.ownerID != request.lease.ownerID,
           request.lease.priority <= previous.lease.priority {
            return decision(
                request: request,
                status: .rejected,
                reason: "active_lease_has_equal_or_higher_priority",
                preemptedRequestID: nil,
                at: monotonicNS
            )
        }
        activeMotorGoal = ActiveMotorGoal(
            requestID: request.requestID,
            layer: request.layer,
            operation: request.operation.kind,
            targetReference: {
                if case let .trackTarget(goal) = request.operation { return goal.targetReference }
                if case let .captureView(goal) = request.operation { return goal.targetReference }
                return nil
            }(),
            lease: request.lease
        )
        return decision(
            request: request,
            status: .accepted,
            reason: physicalActuationEnabled
                ? "motor_goal_active_l0_adapter"
                : "motor_goal_active_shadow_no_actuation",
            preemptedRequestID: previous?.requestID,
            at: monotonicNS
        )
    }

    private func decision(
        request: CognitiveEmbodimentRequest,
        status: EmbodimentShadowStatus,
        reason: String,
        preemptedRequestID: String?,
        at monotonicNS: UInt64
    ) -> EmbodimentShadowDecision {
        EmbodimentShadowDecision(
            requestID: request.requestID,
            layer: request.layer,
            operation: request.operation.kind,
            status: status,
            reason: reason,
            preemptedRequestID: preemptedRequestID,
            snapshot: makeSnapshot(at: monotonicNS)
        )
    }

    private func expire(at monotonicNS: UInt64) {
        targets = targets.filter { $0.value.expiresAtNS > monotonicNS }
        attentionPolicies = attentionPolicies.filter { $0.value.expiresAtNS > monotonicNS }
        if let activeMotorGoal, activeMotorGoal.lease.expiresAtNS <= monotonicNS {
            self.activeMotorGoal = nil
        }
        if let activeMotorGoal,
           let targetReference = activeMotorGoal.targetReference,
           targets[targetReference] == nil {
            self.activeMotorGoal = nil
        }
        let activeReferences = Set(targets.keys)
        targetBindings.removeAll { !activeReferences.contains($0.targetReference) }
        bindingFingerprints = bindingFingerprints.filter { activeReferences.contains($0.key) }
    }

    private func bindingFingerprint(_ binding: SemanticTargetBinding) -> String {
        let probabilityBucket = Int((binding.posteriorProbability * 20).rounded())
        let entropyBucket = Int((binding.normalizedEntropy * 20).rounded())
        return [
            binding.status.rawValue,
            binding.sceneID ?? "none",
            binding.reason,
            binding.observedThisFrame ? "observed" : "offscreen",
            String(probabilityBucket),
            String(entropyBucket),
        ].joined(separator: "|")
    }

    private func makeSnapshot(at monotonicNS: UInt64) -> EmbodimentShadowSnapshot {
        let active = activeMotorGoal
        return EmbodimentShadowSnapshot(
            schemaVersion: 4,
            monotonicNS: monotonicNS,
            mode: physicalActuationEnabled ? "active" : "shadow",
            physicalActuationEnabled: physicalActuationEnabled,
            activeRequestID: active?.requestID,
            activeOwnerID: active?.lease.ownerID,
            activeLayer: active?.layer,
            activeOperation: active?.operation,
            activeTargetReference: active?.targetReference,
            activePriority: active?.lease.priority,
            activeExpiresAtNS: active?.lease.expiresAtNS,
            registeredTargets: targets.values.map {
                EmbodimentShadowTarget(
                    targetReference: $0.registration.targetReference,
                    label: $0.registration.label,
                    sceneID: $0.registration.sceneID,
                    ownerID: $0.ownerID,
                    layer: $0.layer,
                    expiresAtNS: $0.expiresAtNS
                )
            }.sorted { $0.targetReference < $1.targetReference },
            attentionPolicyOwners: attentionPolicies.keys.sorted(),
            sceneEntityCount: totalSceneEntityCount,
            sceneEntities: sceneEntities,
            targetBindings: targetBindings,
            spatialAtlas: spatialAtlas.snapshot(at: monotonicNS),
            panorama: panoramaStatus.snapshot()
        )
    }
}
