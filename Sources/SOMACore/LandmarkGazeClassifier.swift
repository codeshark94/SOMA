import Foundation

/// Camera-independent geometry extracted from one eye landmark set.
public struct EyeLandmarkGeometry: Equatable, Sendable {
    /// Absolute pupil displacement from the eye contour centre, normalized by
    /// half of the contour width.
    public let pupilOffsetX: Double
    /// Absolute pupil displacement from the eye contour centre, normalized by
    /// half of the contour height.
    public let pupilOffsetY: Double
    /// Eye-contour height divided by width. A downward glance compresses this
    /// aperture even when a landmark detector recentres the pupil and contour
    /// together.
    public let apertureRatio: Double

    public init(pupilOffsetX: Double, pupilOffsetY: Double, apertureRatio: Double) {
        self.pupilOffsetX = pupilOffsetX
        self.pupilOffsetY = pupilOffsetY
        self.apertureRatio = apertureRatio
    }
}

/// Reduces bilateral eye geometry and face pose into transient gaze evidence.
/// Pupil centring alone is insufficient because eyelid motion can translate
/// the measured pupil and eye contour together during a downward glance.
public enum LandmarkGazeClassifier {
    public static func classify(
        yaw: Double?,
        pitch: Double?,
        leftEye: EyeLandmarkGeometry,
        rightEye: EyeLandmarkGeometry,
        pupilCenteringScale: Double = 1,
        minimumMeanEyeAperture: Double = 0.27
    ) -> VisualGazeEvidence {
        let values = [
            leftEye.pupilOffsetX,
            leftEye.pupilOffsetY,
            leftEye.apertureRatio,
            rightEye.pupilOffsetX,
            rightEye.pupilOffsetY,
            rightEye.apertureRatio,
            pupilCenteringScale,
            minimumMeanEyeAperture,
        ]
        guard values.allSatisfy(\.isFinite),
              pupilCenteringScale > 0,
              minimumMeanEyeAperture > 0,
              let yaw,
              yaw.isFinite else {
            return .unavailable
        }

        if abs(yaw) > 0.65 { return .averted }
        if let pitch, pitch.isFinite, abs(pitch) > 0.45 { return .averted }

        let pupilIsCentered = [leftEye, rightEye].allSatisfy { eye in
            eye.pupilOffsetX <= 0.60 * pupilCenteringScale
                && eye.pupilOffsetY <= 0.50 * pupilCenteringScale
        }
        guard pupilIsCentered else { return .averted }

        let meanAperture = (leftEye.apertureRatio + rightEye.apertureRatio) / 2
        let minimumBilateralAperture = minimumMeanEyeAperture * 0.70
        guard meanAperture >= minimumMeanEyeAperture,
              min(leftEye.apertureRatio, rightEye.apertureRatio) >= minimumBilateralAperture else {
            return .averted
        }
        return .direct
    }
}
