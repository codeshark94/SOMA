import Testing
@testable import SOMACore

struct LandmarkGazeClassifierTests {
    @Test
    func directCameraGazeRequiresBilateralOpenCenteredEyes() {
        let state = LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: nil,
            leftEye: EyeLandmarkGeometry(
                pupilOffsetX: 0.028,
                pupilOffsetY: 0.195,
                signedPupilOffsetY: 0.195,
                apertureRatio: 0.309
            ),
            rightEye: EyeLandmarkGeometry(
                pupilOffsetX: 0.020,
                pupilOffsetY: 0.105,
                signedPupilOffsetY: 0.105,
                apertureRatio: 0.355
            )
        )

        #expect(state == .direct)
    }

    @Test
    func downwardPhoneGazeIsAvertedEvenWhenPupilsAppearCentered() {
        let state = LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: nil,
            leftEye: EyeLandmarkGeometry(
                pupilOffsetX: 0.147,
                pupilOffsetY: 0.007,
                signedPupilOffsetY: -0.007,
                apertureRatio: 0.265
            ),
            rightEye: EyeLandmarkGeometry(
                pupilOffsetX: 0.055,
                pupilOffsetY: 0.141,
                signedPupilOffsetY: -0.141,
                apertureRatio: 0.238
            )
        )

        #expect(state == .averted)
    }

    @Test
    func pronouncedFaceTurnCannotBecomeDirectGaze() {
        let openEye = EyeLandmarkGeometry(
            pupilOffsetX: 0.05,
            pupilOffsetY: 0.10,
            signedPupilOffsetY: 0.10,
            apertureRatio: 0.33
        )

        #expect(LandmarkGazeClassifier.classify(
            yaw: .pi / 4,
            pitch: nil,
            leftEye: openEye,
            rightEye: openEye
        ) == .averted)
    }

    @Test
    func missingHeadPoseRemainsUnavailable() {
        let openEye = EyeLandmarkGeometry(
            pupilOffsetX: 0.05,
            pupilOffsetY: 0.10,
            signedPupilOffsetY: 0.10,
            apertureRatio: 0.33
        )

        #expect(LandmarkGazeClassifier.classify(
            yaw: nil,
            pitch: nil,
            leftEye: openEye,
            rightEye: openEye
        ) == .unavailable)
    }

    @Test
    func slightlyStricterThresholdRejectsMarginalPupilCentering() {
        let marginalEye = EyeLandmarkGeometry(
            pupilOffsetX: 0.57,
            pupilOffsetY: 0.20,
            signedPupilOffsetY: 0.20,
            apertureRatio: 0.33
        )

        #expect(LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: 0,
            leftEye: marginalEye,
            rightEye: marginalEye,
            pupilCenteringScale: 1.0
        ) == .direct)
        #expect(LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: 0,
            leftEye: marginalEye,
            rightEye: marginalEye,
            pupilCenteringScale: 0.9
        ) == .averted)
    }

    @Test
    func sustainedDownwardPupilDisplacementCannotBecomeDirectGaze() {
        let downwardEye = EyeLandmarkGeometry(
            pupilOffsetX: 0.12,
            pupilOffsetY: 0.16,
            signedPupilOffsetY: -0.16,
            apertureRatio: 0.36
        )

        #expect(LandmarkGazeClassifier.classify(
            yaw: 0,
            pitch: nil,
            leftEye: downwardEye,
            rightEye: downwardEye
        ) == .averted)
    }
}
