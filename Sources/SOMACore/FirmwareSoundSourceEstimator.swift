import Foundation

/// A room-relative source estimate recovered from the gimbal trajectory after
/// the camera firmware has oriented its microphone head toward a sound.
///
/// The firmware does not expose its instantaneous DOA bearing.  It does expose
/// the resulting motor motion through the SDK attitude stream, so the final
/// stable pose is the observable output of that closed-loop reflex.
public struct FirmwareSoundSourceEstimate: Equatable, Sendable {
    public let bearing: GimbalRelativeBearing
    public let startingPose: GimbalPose
    public let settledPose: GimbalPose
    public let displacementDegrees: Double
    public let stabilityDegrees: Double
    public let confidence: Double

    public init(
        bearing: GimbalRelativeBearing,
        startingPose: GimbalPose,
        settledPose: GimbalPose,
        displacementDegrees: Double,
        stabilityDegrees: Double,
        confidence: Double
    ) {
        self.bearing = bearing
        self.startingPose = startingPose
        self.settledPose = settledPose
        self.displacementDegrees = displacementDegrees
        self.stabilityDegrees = stabilityDegrees
        self.confidence = confidence
    }
}

public enum FirmwareSoundSourceEstimator {
    /// Infers a source bearing from measured SDK attitudes that follow a
    /// confirmed firmware sound-following activation.  The tail median rejects
    /// a single delayed poll without fabricating a source when no measured
    /// trajectory is available.
    public static func estimate(
        startingPose: GimbalPose,
        trajectory: [GimbalPose]
    ) -> FirmwareSoundSourceEstimate? {
        let samples = trajectory.filter {
            $0.monotonicNS >= startingPose.monotonicNS
                && $0.pitchDegrees.isFinite
                && $0.panDegrees.isFinite
        }
        guard samples.count >= 3 else { return nil }

        let tail = Array(samples.suffix(min(samples.count, 7)))
        let settledPitch = median(tail.map(\.pitchDegrees))
        let settledPan = median(tail.map(\.panDegrees))
        let settledPose = GimbalPose(
            pitchDegrees: settledPitch,
            panDegrees: settledPan,
            monotonicNS: tail.last!.monotonicNS
        )
        let displacementDegrees = hypot(
            settledPose.pitchDegrees - startingPose.pitchDegrees,
            settledPose.panDegrees - startingPose.panDegrees
        )
        let stabilityDegrees = tail.map {
            hypot(
                $0.pitchDegrees - settledPose.pitchDegrees,
                $0.panDegrees - settledPose.panDegrees
            )
        }.max() ?? .infinity
        let sampleSupport = min(1, Double(samples.count) / 6)
        let motionEvidence = min(1, displacementDegrees / 12)
        let stability = max(0, 1 - stabilityDegrees / 6)
        let confidence = min(1, 0.10 + 0.15 * sampleSupport + 0.60 * motionEvidence + 0.15 * stability)

        return FirmwareSoundSourceEstimate(
            bearing: GimbalRelativeBearing(
                azimuthDegrees: settledPose.panDegrees,
                elevationDegrees: settledPose.pitchDegrees
            ),
            startingPose: startingPose,
            settledPose: settledPose,
            displacementDegrees: displacementDegrees,
            stabilityDegrees: stabilityDegrees,
            confidence: confidence
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }
}
