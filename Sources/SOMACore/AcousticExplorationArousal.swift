import Foundation

public struct AcousticExplorationMotionProfile: Equatable, Sendable {
    public let intensity: Double
    public let speedMultiplier: Double
    public let accelerationMultiplier: Double
    public let samplingTemperatureMultiplier: Double
    public let waypointLookAheadBoostDegrees: Double

    public init(
        intensity: Double,
        speedMultiplier: Double,
        accelerationMultiplier: Double,
        samplingTemperatureMultiplier: Double,
        waypointLookAheadBoostDegrees: Double
    ) {
        self.intensity = min(max(intensity, 0), 1)
        self.speedMultiplier = max(1, speedMultiplier)
        self.accelerationMultiplier = max(1, accelerationMultiplier)
        self.samplingTemperatureMultiplier = max(1, samplingTemperatureMultiplier)
        self.waypointLookAheadBoostDegrees = max(0, waypointLookAheadBoostDegrees)
    }

    public static let neutral = AcousticExplorationMotionProfile(
        intensity: 0,
        speedMultiplier: 1,
        accelerationMultiplier: 1,
        samplingTemperatureMultiplier: 1,
        waypointLookAheadBoostDegrees: 0
    )
}

/// Converts an unlocalized acoustic onset into a horizontal attention shift.
/// Without a measured bearing there is no evidence for changing elevation, so
/// the current measured pitch remains authoritative while the coverage field
/// supplies a novel azimuth.
public enum AcousticExplorationResamplePolicy {
    public static func horizontalBearing(
        sampled: SpatialCoverageDirection,
        currentPose: GimbalPose
    ) -> GimbalRelativeBearing {
        GimbalRelativeBearing(
            azimuthDegrees: sampled.bearing.azimuthDegrees,
            elevationDegrees: currentPose.pitchDegrees
        )
    }
}

/// Projects a salient acoustic onset into a short-lived exploration arousal.
/// It does not own the motor or start exploration: it can only modulate an
/// already active L0 coverage trajectory. Exponential decay makes the motion
/// settle naturally instead of relying on a fixed behavioral cooldown.
public struct AcousticExplorationArousal: Sendable {
    private let minimumConfidence: Double
    private let halfLifeNS: UInt64
    private var peakIntensity = 0.0
    private var activatedNS: UInt64?

    public init(
        minimumConfidence: Double = 0.80,
        halfLifeMilliseconds: UInt64 = 1_500
    ) {
        precondition((0...1).contains(minimumConfidence))
        precondition(halfLifeMilliseconds > 0)
        precondition(halfLifeMilliseconds <= UInt64.max / 1_000_000)
        self.minimumConfidence = minimumConfidence
        halfLifeNS = halfLifeMilliseconds * 1_000_000
    }

    /// Admits only a loud onset while L0 is already exploring. Voice-session
    /// admission remains a separate channel and cannot activate this state.
    @discardableResult
    public mutating func observe(
        _ evidence: AuditoryOnsetEvidence,
        explorationActive: Bool,
        at monotonicNS: UInt64
    ) -> AcousticExplorationMotionProfile? {
        guard explorationActive,
              evidence.confidence >= minimumConfidence else {
            return nil
        }
        let excessDB = max(0, evidence.levelDB - evidence.thresholdDB)
        let levelIntensity = min(max((excessDB - 6) / 12, 0), 1)
        let intensity = min(max(max(evidence.confidence, levelIntensity), 0), 1)
        peakIntensity = intensity
        activatedNS = monotonicNS
        return profile(at: monotonicNS)
    }

    public mutating func profile(at monotonicNS: UInt64) -> AcousticExplorationMotionProfile {
        guard let activatedNS else { return .neutral }
        let elapsedNS = monotonicNS >= activatedNS ? monotonicNS - activatedNS : 0
        let decay = pow(0.5, Double(elapsedNS) / Double(halfLifeNS))
        let intensity = peakIntensity * decay
        guard intensity >= 0.05 else {
            clear()
            return .neutral
        }
        return AcousticExplorationMotionProfile(
            intensity: intensity,
            speedMultiplier: 1 + 2.5 * intensity,
            accelerationMultiplier: 1 + 2.0 * intensity,
            samplingTemperatureMultiplier: 1 + 1.2 * intensity,
            waypointLookAheadBoostDegrees: 10 * intensity
        )
    }

    public mutating func clear() {
        peakIntensity = 0
        activatedNS = nil
    }
}
