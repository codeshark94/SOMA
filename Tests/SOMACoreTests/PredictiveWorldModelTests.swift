#if canImport(XCTest)
import XCTest
@testable import SOMACore

final class PredictiveWorldModelTests: XCTestCase {
    func testNormalizedRectClipsAnEdgeFaceForDeviceTargetSelection() throws {
        let clipped = try XCTUnwrap(
            NormalizedRect(x: 0.817559, y: 0.086867, width: 0.189736, height: 0.416614)
                .clippedToUnitSquare()
        )

        XCTAssertEqual(clipped.x, 0.817559, accuracy: 0.000_001)
        XCTAssertEqual(clipped.y, 0.086867, accuracy: 0.000_001)
        XCTAssertEqual(clipped.width, 0.182441, accuracy: 0.000_001)
        XCTAssertEqual(clipped.height, 0.416614, accuracy: 0.000_001)
        XCTAssertNil(NormalizedRect(x: 1.2, y: 0.2, width: 0.1, height: 0.1).clippedToUnitSquare())
    }

    func testOpticalZoomNarrowsProjectionWithoutDiscardingCalibration() throws {
        let calibrated = CameraProjectionModel(
            focalXNormalized: 0.70,
            focalYNormalized: 1.24,
            principalXNormalized: 0.492,
            principalYNormalized: 0.517,
            cameraToIdealRotation: [
                0, -1, 0,
                1, 0, 0,
                0, 0, 1,
            ],
            radialK1: 0.04,
            radialK2: -0.01
        )

        let zoomed = try XCTUnwrap(calibrated.withOpticalZoom(1.25))

        XCTAssertEqual(zoomed.focalXNormalized, 0.875, accuracy: 0.000_001)
        XCTAssertEqual(zoomed.focalYNormalized, 1.55, accuracy: 0.000_001)
        XCTAssertEqual(zoomed.principalXNormalized, calibrated.principalXNormalized, accuracy: 0.000_001)
        XCTAssertEqual(zoomed.principalYNormalized, calibrated.principalYNormalized, accuracy: 0.000_001)
        XCTAssertEqual(zoomed.cameraToIdealRotation, calibrated.cameraToIdealRotation)
        XCTAssertEqual(zoomed.radialK1, calibrated.radialK1)
        XCTAssertEqual(zoomed.radialK2, calibrated.radialK2)
        XCTAssertLessThan(
            zoomed.horizontalFieldOfViewDegrees,
            calibrated.horizontalFieldOfViewDegrees
        )
        XCTAssertNil(calibrated.withOpticalZoom(0.99))
        XCTAssertNil(calibrated.withOpticalZoom(2.01))
    }

    func testDiagonalCameraFOVConvertsToActiveHorizontalAndVerticalAngles() {
        let aspect = 16.0 / 9.0
        XCTAssertEqual(
            CameraFieldOfView.horizontalDegrees(diagonalDegrees: 86, aspectRatio: aspect) ?? 0,
            78.205,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CameraFieldOfView.verticalDegrees(diagonalDegrees: 86, aspectRatio: aspect) ?? 0,
            49.137,
            accuracy: 0.001
        )
        XCTAssertNil(CameraFieldOfView.horizontalDegrees(diagonalDegrees: 180, aspectRatio: aspect))
        XCTAssertNil(CameraFieldOfView.horizontalDegrees(diagonalDegrees: 86, aspectRatio: 0))
    }

    func testTiny2LiteFOVModesResolveAgainstPhysicalWideOptics() {
        XCTAssertEqual(
            OBSBOTTiny2LiteOptics.horizontalDegrees(forFOVMode: 86) ?? 0,
            67.2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            OBSBOTTiny2LiteOptics.horizontalDegrees(forFOVMode: 78) ?? 0,
            59.966,
            accuracy: 0.001
        )
        XCTAssertEqual(
            OBSBOTTiny2LiteOptics.horizontalDegrees(forFOVMode: 65) ?? 0,
            48.827,
            accuracy: 0.001
        )
        XCTAssertNil(OBSBOTTiny2LiteOptics.horizontalDegrees(forFOVMode: 70))
    }

    func testCameraGeometryCalibrationRequiresIndependentValidation() {
        let projection = CameraProjectionModel(
            focalXNormalized: 0.824,
            focalYNormalized: 1.408,
            principalXNormalized: 0.490,
            principalYNormalized: 0.537
        )
        let calibration = CameraGeometryCalibration(
            deviceProfile: "obsbot_tiny_2_lite",
            fovMode: 86,
            imageWidth: 1920,
            imageHeight: 1080,
            projection: projection,
            capturedFrames: 29,
            fittedPairs: 15,
            fittedMatches: 837,
            validationPairs: 5,
            validationMatches: 270,
            initialRMSEPixels: 23.44,
            calibratedRMSEPixels: 5.96,
            calibratedP90Pixels: 9.37,
            generatedAt: "2026-08-15T00:00:00Z"
        )
        XCTAssertTrue(calibration.isValid)
        XCTAssertEqual(projection.horizontalFieldOfViewDegrees, 62.493, accuracy: 0.001)
        let centre = SphericalPanoramaProjection.sourceCoordinate(
            for: GimbalRelativeBearing(azimuthDegrees: -20, elevationDegrees: -5),
            cameraPose: GimbalPose(pitchDegrees: 5, panDegrees: 20, monotonicNS: 1),
            horizontalFieldOfViewDegrees: 67.2,
            poseProjection: .obsbotTiny2Lite,
            cameraProjectionModel: projection
        )
        XCTAssertEqual(centre?.normalizedX ?? 0, 0.490, accuracy: 0.001)
        XCTAssertEqual(centre?.normalizedY ?? 0, 0.537, accuracy: 0.001)
        var sceneField = SceneField()
        let upperImageCandidate = sceneField.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.45, y: 0.15, width: 0.10, height: 0.10),
                confidence: 0.9,
                source: .neuralDetector,
                kind: .object,
                label: "test"
            )],
            at: 1,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1),
            horizontalFieldOfViewDegrees: 67.2,
            cameraSettled: true,
            poseProjection: .identity,
            cameraProjectionModel: projection
        ).first
        XCTAssertGreaterThan(upperImageCandidate?.bearing?.elevationDegrees ?? -90, 0)
        let unvalidated = CameraGeometryCalibration(
            deviceProfile: "obsbot_tiny_2_lite",
            fovMode: 86,
            imageWidth: 1920,
            imageHeight: 1080,
            projection: projection,
            capturedFrames: 29,
            fittedPairs: 15,
            fittedMatches: 837,
            validationPairs: 1,
            validationMatches: 40,
            initialRMSEPixels: 23.44,
            calibratedRMSEPixels: 5.96,
            calibratedP90Pixels: 9.37,
            generatedAt: "2026-08-15T00:00:00Z"
        )
        XCTAssertFalse(unvalidated.isValid)
    }

    func testRadialCameraProjectionRoundTripsAnOffAxisRay() {
        let projection = CameraProjectionModel(
            focalXNormalized: 0.825,
            focalYNormalized: 1.431,
            principalXNormalized: 0.481,
            principalYNormalized: 0.560,
            radialK1: 0.065,
            radialK2: 0.035
        )
        let ideal = (0.31, -0.18, 1.0)
        let actual = projection.idealToActual(ideal)
        let recovered = projection.actualToIdeal(actual)
        XCTAssertEqual(recovered.0 / recovered.2, ideal.0, accuracy: 0.000_001)
        XCTAssertEqual(recovered.1 / recovered.2, ideal.1, accuracy: 0.000_001)
    }

    func testSquareScaleFitRestoresSourceAspectRatioAfterLetterboxing() {
        let transform = NormalizedSquareScaleFit(sourceWidth: 1920, sourceHeight: 1080)
        let source = NormalizedRect(x: 0.22, y: 0.18, width: 0.20, height: 0.36)
        let model = transform.squareRect(for: source)
        XCTAssertEqual(model?.width ?? 0, 0.20, accuracy: 0.000_001)
        XCTAssertEqual(model?.height ?? 0, 0.2025, accuracy: 0.000_001)
        let restored = model.flatMap(transform.sourceRect(for:))
        XCTAssertEqual(restored?.x ?? 0, source.x, accuracy: 0.000_001)
        XCTAssertEqual(restored?.y ?? 0, source.y, accuracy: 0.000_001)
        XCTAssertEqual(restored?.width ?? 0, source.width, accuracy: 0.000_001)
        XCTAssertEqual(restored?.height ?? 0, source.height, accuracy: 0.000_001)
    }

    func testFaceConfirmationLeaseRequiresFreshOverlappingGeometry() {
        let face = NormalizedRect(x: 0.42, y: 0.28, width: 0.12, height: 0.14)
        var lease = FaceConfirmationLease()
        lease.record([face], at: 1_000_000_000)
        XCTAssertFalse(lease.permits(face, at: 1_060_000_000), "one landmark result must not start motor control")
        lease.record([face], at: 1_060_000_000)
        XCTAssertTrue(lease.permits(face, at: 1_280_000_000))
        XCTAssertFalse(lease.permits(face, at: 1_280_000_001))
        lease.record([face], at: 2_000_000_000)
        lease.record([face], at: 2_060_000_000)
        XCTAssertFalse(
            lease.permits(NormalizedRect(x: 0.72, y: 0.28, width: 0.12, height: 0.14), at: 2_100_000_000)
        )
        lease.record([face], at: 3_000_000_000)
        lease.record([face], at: 3_221_000_000)
        XCTAssertFalse(lease.permits(face, at: 3_221_000_000), "stale face confirmation was reused")
        lease.record([face], at: 3_281_000_000)
        XCTAssertTrue(lease.permits(face, at: 3_281_000_000), "fresh face confirmation did not restart after stale gap")

        var continuity = FaceMotorContinuityLease()
        continuity.record(face, at: 4_000_000_000)
        XCTAssertTrue(continuity.permits(NormalizedRect(x: 0.45, y: 0.28, width: 0.12, height: 0.14), at: 4_500_000_000))
        XCTAssertFalse(continuity.permits(face, at: 4_700_000_001))
        XCTAssertFalse(continuity.permits(NormalizedRect(x: 0.78, y: 0.28, width: 0.12, height: 0.14), at: 4_080_000_000))
    }

    func testPoseSpaceBearingAndCompositionUseTheMeasuredImageAxisDirection() {
        let projection = CameraProjectionModel.pinhole(horizontalFieldOfViewDegrees: 72)
        let target = GimbalRelativeBearing(azimuthDegrees: 0, elevationDegrees: 0)
        let leftFraming = NormalizedRect(x: 0.15, y: 0.44, width: 0.10, height: 0.12)
        let composition = projection.cameraBearing(
            placing: target,
            at: leftFraming,
            poseProjection: .identity
        )
        XCTAssertLessThan(
            composition?.azimuthDegrees ?? .infinity,
            0,
            "A left composition point must command the SDK attitude that moves a fixed subject left in image space"
        )

        var field = SceneField()
        let leftFace = VisualObservation(
            rect: leftFraming,
            confidence: 0.95,
            source: .systemFaceDetector,
            kind: .human,
            label: "face",
            isActionEligible: true,
            isFaceVerified: true
        )
        let candidate = field.ingest(
            [leftFace],
            at: 1_000_000_000,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000_000_000),
            horizontalFieldOfViewDegrees: 72,
            cameraSettled: true,
            poseProjection: .identity,
            cameraProjectionModel: projection
        ).first
        XCTAssertGreaterThan(
            candidate?.bearing?.azimuthDegrees ?? -.infinity,
            0,
            "A subject left of centre requires an increasing SDK pan attitude when positive attitude moves image points right"
        )

        var verticalField = SceneField()
        let upperFace = VisualObservation(
            rect: NormalizedRect(x: 0.45, y: 0.10, width: 0.10, height: 0.12),
            confidence: 0.95,
            source: .systemFaceDetector,
            kind: .human,
            label: "face",
            isActionEligible: true,
            isFaceVerified: true
        )
        let verticalCandidate = verticalField.ingest(
            [upperFace],
            at: 1_000_000_000,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000_000_000),
            horizontalFieldOfViewDegrees: 72,
            cameraSettled: true,
            poseProjection: .identity,
            cameraProjectionModel: projection
        ).first
        XCTAssertGreaterThan(
            verticalCandidate?.bearing?.elevationDegrees ?? -.infinity,
            0,
            "An upper-image target must retain its upward ray when projected into attitude space"
        )
    }

    func testFacePersonFusionKeepsFaceGeometryAndBridgesOnlyBriefly() {
        var fusion = FacePersonFusion()
        let person = VisualObservation(
            rect: NormalizedRect(x: 0.20, y: 0.15, width: 0.50, height: 0.70),
            confidence: 0.85,
            source: .neuralDetector,
            kind: .human,
            label: "person"
        )
        let face = VisualObservation(
            rect: NormalizedRect(x: 0.43, y: 0.28, width: 0.12, height: 0.14),
            confidence: 0.92,
            source: .neuralFaceDetector,
            kind: .human,
            label: "face"
        )
        let fused = fusion.fuse([person, face], at: 1_000_000_000)
        XCTAssertEqual(fused.filter { $0.label == "face" }.count, 1)
        XCTAssertFalse(fused.contains { $0.label == "person" }, "a matched body box must not displace the face target")
        XCTAssertTrue(fused.first(where: { $0.label == "face" })?.isActionEligible ?? false)

        let landmarkVerifiedFace = VisualObservation(
            rect: face.rect,
            confidence: face.confidence,
            source: .systemFaceDetector,
            kind: .human,
            label: "face",
            isActionEligible: true,
            isFaceVerified: true,
            isEyeContactEligible: true
        )
        var landmarkFusion = FacePersonFusion()
        let landmarkFused = landmarkFusion.fuse([person, landmarkVerifiedFace], at: 1_020_000_000)
        let preservedVerification = landmarkFused.first(where: { $0.label == "face" })
        XCTAssertTrue(preservedVerification?.isFaceVerified ?? false, "person fusion must preserve landmark verification")
        XCTAssertTrue(preservedVerification?.isEyeContactEligible ?? false, "person fusion must preserve fresh gaze evidence")
        XCTAssertEqual(
            preservedVerification?.source,
            .systemFaceDetector,
            "person corroboration must not relabel landmark geometry as an ANE measurement"
        )

        let faceCadenceFrame = fusion.fuse([face], at: 1_040_000_000)
        XCTAssertTrue(
            faceCadenceFrame.first(where: { $0.label == "face" })?.isActionEligible ?? false,
            "a matching face may use the bounded person corroboration lease"
        )

        let shiftedPerson = VisualObservation(
            rect: NormalizedRect(x: 0.30, y: 0.15, width: 0.50, height: 0.70),
            confidence: 0.88,
            source: .neuralDetector,
            kind: .human,
            label: "person"
        )
        let bridged = fusion.fuse([shiftedPerson], at: 1_080_000_000)
        guard let bridgedFace = bridged.first(where: { $0.label == "face" }) else {
            return XCTFail("person evidence did not bridge the face-model cadence gap")
        }
        XCTAssertEqual(bridgedFace.source, .tracker)
        XCTAssertTrue(bridgedFace.isActionEligible)
        XCTAssertGreaterThan(bridgedFace.rect.centerX, face.rect.centerX)
        XCTAssertLessThan(bridgedFace.rect.centerX - face.rect.centerX, 0.10)

        let finalBridge = fusion.fuse([shiftedPerson], at: 1_320_000_000)
        XCTAssertTrue(finalBridge.contains { $0.label == "face" }, "the 320 ms bridge boundary should remain inclusive")
        let expired = fusion.fuse([shiftedPerson], at: 1_321_000_000)
        XCTAssertFalse(expired.contains { $0.label == "face" }, "face bridging must expire without fresh face evidence")
        XCTAssertTrue(expired.contains { $0.label == "person" })

        let loneFace = fusion.fuse([face], at: 1_400_000_000)
        XCTAssertTrue(loneFace.contains { $0.label == "face" })
        XCTAssertFalse(loneFace.first(where: { $0.label == "face" })?.isActionEligible ?? true)
        let noStaleBridge = fusion.fuse([shiftedPerson], at: 1_420_000_000)
        XCTAssertFalse(noStaleBridge.contains { $0.label == "face" }, "an unpaired fresh face must not reuse an old person bridge")

        var persistentFusion = FacePersonFusion()
        _ = persistentFusion.fuse([person, face], at: 2_000_000_000)
        persistentFusion.promoteValidatedFace(face.rect, at: 2_060_000_000)
        let persistentBridge = persistentFusion.fuse([shiftedPerson], at: 3_000_000_000)
        XCTAssertTrue(persistentBridge.first(where: { $0.label == "face" })?.isFaceVerified ?? false)
        XCTAssertFalse(persistentFusion.fuse([], at: 5_001_000_000).contains { $0.label == "face" })
    }

    func testFaceActivityRequiresSelfMotionWhileCameraIsSettled() {
        var field = SceneField(requiresFaceActivity: true)
        let start: UInt64 = 1_000_000_000
        let pose = GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start)
        let face = VisualObservation(
            rect: NormalizedRect(x: 0.38, y: 0.35, width: 0.16, height: 0.20),
            confidence: 0.95,
            source: .neuralFaceDetector,
            kind: .human,
            label: "face",
            isActionEligible: true
        )
        let stationary = field.ingest([face], at: start, cameraPose: pose, cameraSettled: true)[0]
        XCTAssertTrue(stationary.isActionEligible, "current confirmed face evidence was discarded")
        XCTAssertFalse(stationary.faceActivityEligible, "a stationary face must not acquire motor control")
        let singleJitter = VisualObservation(
            rect: NormalizedRect(x: 0.393, y: 0.35, width: 0.16, height: 0.20),
            confidence: 0.95,
            source: .neuralFaceDetector,
            kind: .human,
            label: "face",
            isActionEligible: true
        )
        let jittered = field.ingest(
            [singleJitter],
            at: start + 100_000_000,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + 100_000_000),
            cameraSettled: true
        )
        XCTAssertFalse(jittered[0].faceActivityEligible, "one detector jitter acquired motor authority")
        let movedFace = VisualObservation(
            rect: NormalizedRect(x: 0.43, y: 0.35, width: 0.16, height: 0.20),
            confidence: 0.95,
            source: .neuralFaceDetector,
            kind: .human,
            label: "face",
            isActionEligible: true
        )
        let active = field.ingest(
            [movedFace],
            at: start + 200_000_000,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + 200_000_000),
            cameraSettled: true
        )
        XCTAssertTrue(active[0].isActionEligible, "current confirmed face evidence was discarded")
        XCTAssertTrue(active[0].faceActivityEligible, "consistent real face motion did not acquire motor authority")
        let expired = field.ingest(
            [movedFace],
            at: start + 1_700_000_001,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + 1_700_000_001),
            cameraSettled: true
        )
        XCTAssertTrue(expired[0].isActionEligible, "current confirmed face evidence was discarded")
        XCTAssertFalse(expired[0].faceActivityEligible, "inactive face retained acquisition authority")
    }

    func testVoiceReweightsPersistentVisualTargetTowardReadyInteraction() {
        let model = PredictiveWorldModel()
        let start: UInt64 = 1_000_000_000
        _ = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3),
                confidence: 0.95,
                source: .neuralFaceDetector
            ),
            at: start
        )
        let belief = model.ingestVoice(active: true, confidence: 0.95, at: start + 20_000_000)

        XCTAssertEqual(belief.targetStatus, .tracked)
        XCTAssertGreaterThan(belief.readyProbability, belief.observingProbability)
        XCTAssertEqual(belief.policy, .handoffCandidate)
    }

    func testPredictionRetainsTargetBrieflyThenReportsLoss() {
        let model = PredictiveWorldModel()
        let start: UInt64 = 2_000_000_000
        _ = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2),
                confidence: 0.9,
                source: .neuralFaceDetector
            ),
            at: start
        )
        _ = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.3, y: 0.2, width: 0.2, height: 0.2),
                confidence: 0.9,
                source: .tracker
            ),
            at: start + 100_000_000
        )

        let predicted = model.snapshot(at: start + 300_000_000)
        XCTAssertEqual(predicted.targetStatus, .tracked)
        XCTAssertGreaterThan(predicted.target?.velocityX ?? 0, 0)

        let lost = model.snapshot(at: start + 2_000_000_000)
        XCTAssertEqual(lost.targetStatus, .none)
        XCTAssertEqual(lost.policy, .hold)
    }

    func testBeliefProbabilitiesRemainNormalized() {
        let model = PredictiveWorldModel()
        let belief = model.snapshot(at: 3_000_000_000)
        XCTAssertEqual(
            belief.idleProbability + belief.observingProbability + belief.readyProbability,
            1,
            accuracy: 0.000_001
        )
    }

    func testDelayedVisionCanMergeAtCurrentBeliefTimestamp() {
        let model = PredictiveWorldModel()
        let start: UInt64 = 3_500_000_000
        _ = model.ingestVoice(active: false, confidence: 0, at: start + 200_000_000)
        let visionCompleted: UInt64 = start + 150_000_000
        let alignedTime = max(visionCompleted, model.snapshot(at: visionCompleted).monotonicNS)
        let belief = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.65, y: 0.25, width: 0.20, height: 0.25),
                confidence: 0.8,
                source: .systemSaliency
            ),
            at: alignedTime
        )
        XCTAssertEqual(belief.targetStatus, .tracked)
    }

    func testAudiovisualCueFusesOnlyWhenDirectionsAgree() {
        let model = PredictiveWorldModel()
        let start: UInt64 = 4_000_000_000
        _ = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.1, y: 0.3, width: 0.2, height: 0.3),
                confidence: 0.75,
                source: .neuralFaceDetector
            ),
            at: start
        )

        let fused = model.ingestAudioDirection(.left, confidence: 0.8, at: start + 20_000_000)
        XCTAssertEqual(fused.attentionCue.route, .audiovisual)
        XCTAssertEqual(fused.attentionCue.direction, .left)

        let conflicting = model.ingestAudioDirection(.right, confidence: 0.8, at: start + 40_000_000)
        XCTAssertEqual(conflicting.attentionCue.route, .visual)
        XCTAssertEqual(conflicting.targetStatus, .tracked)
    }

    func testEmbodiedAttentionKeepsOwnersExclusive() {
        let model = PredictiveWorldModel()
        let belief = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.70, y: 0.30, width: 0.20, height: 0.30),
                confidence: 0.90,
                source: .neuralFaceDetector,
                label: "face",
                isActionEligible: true
            ),
            at: 5_000_000_000
        )
        let policy = EmbodiedAttentionPolicy()

        let native = policy.directive(for: belief, owner: .nativeAI)
        XCTAssertEqual(native.state, .orient)
        XCTAssertTrue(native.nativeHumanTrackingRequested)
        XCTAssertEqual(native.externalPanSpeed, 0)

        let external = policy.directive(for: belief, owner: .external)
        XCTAssertEqual(external.route, .externalVisualControl)
        XCTAssertFalse(external.stopRequested)
        XCTAssertEqual(external.externalPanSpeed, 0)

        var arbiter = CameraOwnerArbiter()
        XCTAssertTrue(arbiter.request(.nativeAI))
        XCTAssertFalse(arbiter.request(.external))
        arbiter.recordFault()
        XCTAssertEqual(arbiter.owner, .fault)
        XCTAssertTrue(arbiter.confirmManualStop())
        XCTAssertEqual(arbiter.owner, .manual)
    }

    func testHumanAlwaysOutranksObjectForL0Attention() {
        let human = VisualObservation(
            rect: NormalizedRect(x: 0.2, y: 0.3, width: 0.2, height: 0.3),
            confidence: 0.75,
            source: .neuralDetector,
            kind: .human,
            label: "person"
        )
        let object = VisualObservation(
            rect: NormalizedRect(x: 0.6, y: 0.3, width: 0.2, height: 0.3),
            confidence: 0.80,
            source: .neuralDetector,
            kind: .object,
            label: "book",
            attentionWeight: 0.90
        )

        let distribution = ProbabilisticAttentionSelector.infer(candidates: [human, object], previousTarget: nil)
        XCTAssertEqual(distribution.selected?.label, "person")
        XCTAssertGreaterThan(
            distribution.candidateProbabilities[0],
            distribution.candidateProbabilities[1],
            "a current person must retain a higher posterior than any object"
        )
        XCTAssertGreaterThan(distribution.selectedProbability, 0)
        XCTAssertLessThan(distribution.selectedProbability, 1)
        XCTAssertEqual(
            distribution.candidateProbabilities.reduce(distribution.noTargetProbability, +),
            1,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(distribution.normalizedEntropy, 0)

        let boundedDominance = ProbabilisticAttentionSelector.infer(
            candidates: [
                VisualObservation(rect: human.rect, confidence: 0, source: .neuralDetector, kind: .human, label: "person"),
                VisualObservation(rect: object.rect, confidence: 1, source: .neuralDetector, kind: .object, label: "book", attentionWeight: 1)
            ],
            previousTarget: nil
        )
        XCTAssertEqual(boundedDominance.selected?.kind, .human)
        XCTAssertGreaterThan(boundedDominance.candidateProbabilities[0], boundedDominance.candidateProbabilities[1])

        let ordinaryObject = VisualObservation(
            rect: NormalizedRect(x: 0.6, y: 0.3, width: 0.2, height: 0.3),
            confidence: 0.95,
            source: .neuralDetector,
            kind: .object,
            label: "cup"
        )
        XCTAssertEqual(
            ProbabilisticAttentionSelector.infer(candidates: [human, ordinaryObject], previousTarget: nil).selected?.label,
            "person"
        )
        let face = VisualObservation(
            rect: NormalizedRect(x: 0.42, y: 0.32, width: 0.16, height: 0.20),
            confidence: 0.90,
            source: .neuralFaceDetector,
            kind: .human,
            label: "face"
        )
        XCTAssertEqual(
            ProbabilisticAttentionSelector.infer(candidates: [human, face], previousTarget: nil).selected?.label,
            "face"
        )
        let explicitObjectOverFace = VisualObservation(
            rect: NormalizedRect(x: 0.6, y: 0.3, width: 0.2, height: 0.3),
            confidence: 0.80,
            source: .neuralDetector,
            kind: .object,
            label: "book",
            attentionWeight: 1.0
        )
        XCTAssertEqual(
            ProbabilisticAttentionSelector.infer(candidates: [face, explicitObjectOverFace], previousTarget: nil).selected?.label,
            "face"
        )

        var socialLease = SocialAttentionLease()
        socialLease.recordEligibleHuman(at: 3_000_000_000)
        let defaultObject = VisualObservation(
            rect: NormalizedRect(x: 0.6, y: 0.3, width: 0.2, height: 0.3),
            confidence: 0.95,
            source: .neuralDetector,
            kind: .object,
            label: "book",
            isActionEligible: true
        )
        XCTAssertTrue(socialLease.suppressesDefaultNonHumanAttention(candidates: [defaultObject], at: 5_499_000_000))
        XCTAssertFalse(socialLease.suppressesDefaultNonHumanAttention(candidates: [defaultObject], at: 5_500_000_000))
        let explicitObject = VisualObservation(
            rect: defaultObject.rect,
            confidence: defaultObject.confidence,
            source: defaultObject.source,
            kind: .object,
            label: "book",
            attentionWeight: 0.10,
            isActionEligible: true
        )
        XCTAssertFalse(socialLease.suppressesDefaultNonHumanAttention(candidates: [explicitObject], at: 3_100_000_000))

        var faceLock = FaceLockLease()
        let lockedRect = NormalizedRect(x: 0.42, y: 0.28, width: 0.12, height: 0.14)
        faceLock.record(sceneID: "face-1", rect: lockedRect, at: 3_000_000_000)
        XCTAssertTrue(faceLock.holds(sceneID: "face-1", at: 5_999_000_000))
        XCTAssertTrue(
            faceLock.holds(
                sceneID: "face-2",
                rect: NormalizedRect(x: 0.46, y: 0.29, width: 0.12, height: 0.14),
                at: 3_100_000_000
            ),
            "a geometrically continuous detector-ID change broke face lock"
        )
        XCTAssertFalse(
            faceLock.holds(
                sceneID: "face-3",
                rect: NormalizedRect(x: 0.76, y: 0.29, width: 0.12, height: 0.14),
                at: 3_100_000_000
            ),
            "a distant face replaced the current face lock"
        )
        XCTAssertTrue(faceLock.suppressesNonHumanAttention(kind: .object, attentionWeight: 0, at: 3_100_000_000))
        XCTAssertFalse(faceLock.suppressesNonHumanAttention(kind: .object, attentionWeight: 0.1, at: 3_100_000_000))
        XCTAssertTrue(faceLock.isActive(at: 33_000_000_000), "a confirmed face lock must not expire on a detector timeout")
        let rapidMove = NormalizedRect(x: 0.76, y: 0.48, width: 0.12, height: 0.14)
        XCTAssertTrue(faceLock.observe(sceneID: "face-rapid-move", rect: rapidMove, verified: false, at: 3_200_000_000))
        XCTAssertTrue(faceLock.holds(sceneID: "face-rapid-move", rect: rapidMove, at: 3_200_000_000))

        var provisionalLock = FaceLockLease(durationMilliseconds: 3_000, provisionalMilliseconds: 1_200)
        provisionalLock.observe(sceneID: "face-1", rect: lockedRect, verified: false, at: 7_000_000_000)
        XCTAssertTrue(provisionalLock.permitsInitialMotor(at: 7_100_000_000), "a raw face could not make its bounded re-centering correction")
        XCTAssertFalse(provisionalLock.permitsMotor(at: 7_100_000_000), "raw face detector evidence started persistent motor authority")
        XCTAssertFalse(provisionalLock.permitsInitialMotor(at: 8_200_000_000), "unverified face outlived its fixed re-centering window")
        provisionalLock.observe(sceneID: "face-1", rect: lockedRect, verified: false, at: 7_500_000_000)
        XCTAssertFalse(provisionalLock.permitsMotor(at: 8_200_000_000), "unverified face renewed motor authority")
        provisionalLock.observe(sceneID: "face-1", rect: lockedRect, verified: true, at: 8_200_000_000)
        XCTAssertFalse(provisionalLock.isProvisional(at: 8_200_000_000))
        XCTAssertTrue(provisionalLock.permitsMotor(at: 11_100_000_000), "independent verification did not promote face lock")
        XCTAssertTrue(provisionalLock.permitsMotor(at: 37_000_000_000), "a promoted face lock expired during detector loss")

        var staticLock = FaceLockLease(durationMilliseconds: 3_000, provisionalMilliseconds: 3_000)
        XCTAssertTrue(staticLock.observe(sceneID: "static", rect: lockedRect, verified: false, at: 12_000_000_000))
        XCTAssertFalse(staticLock.observe(sceneID: "static", rect: lockedRect, verified: false, at: 15_000_000_000))
        XCTAssertFalse(staticLock.permitsMotor(at: 15_000_000_000))
        XCTAssertTrue(
            staticLock.observe(
                sceneID: "static",
                rect: lockedRect,
                verified: true,
                at: 15_050_000_000
            )
        )
        XCTAssertTrue(staticLock.permitsMotor(at: 15_050_000_000))

        var unverifiedFaceRejection = UnverifiedFaceRejectionGate(confirmationMilliseconds: 700)
        XCTAssertTrue(unverifiedFaceRejection.admits(rect: lockedRect, independentlyVerified: false, at: 16_000_000_000))
        XCTAssertTrue(unverifiedFaceRejection.admits(rect: lockedRect, independentlyVerified: false, at: 16_699_000_000))
        XCTAssertFalse(unverifiedFaceRejection.admits(rect: lockedRect, independentlyVerified: false, at: 16_700_000_000))
        XCTAssertFalse(unverifiedFaceRejection.admits(rect: lockedRect, independentlyVerified: false, at: 16_900_000_000))
        XCTAssertTrue(unverifiedFaceRejection.admits(rect: lockedRect, independentlyVerified: true, at: 16_900_000_000))
        XCTAssertTrue(unverifiedFaceRejection.admits(rect: lockedRect, independentlyVerified: false, at: 18_000_000_000))
        XCTAssertTrue(unverifiedFaceRejection.isValidated(lockedRect))
        unverifiedFaceRejection.recordNoFace(at: 19_999_000_000)
        XCTAssertTrue(unverifiedFaceRejection.admits(rect: lockedRect, independentlyVerified: false, at: 20_000_000_000))
        unverifiedFaceRejection.recordNoFace(at: 22_000_000_000)
        XCTAssertFalse(unverifiedFaceRejection.isValidated(lockedRect))
        XCTAssertTrue(unverifiedFaceRejection.admits(rect: lockedRect, independentlyVerified: false, at: 22_000_000_000))
        XCTAssertFalse(unverifiedFaceRejection.admits(rect: lockedRect, independentlyVerified: false, at: 22_700_000_000))

        var rejectedFaceSceneField = SceneField()
        let rejectedFace = VisualObservation(
            rect: lockedRect,
            confidence: 0.85,
            source: .neuralFaceDetector,
            kind: .human,
            label: "face",
            isFaceVerified: false
        )
        XCTAssertTrue(rejectedFaceSceneField.ingest([rejectedFace], at: 17_000_000_000).contains { $0.observation.label == "face" })
        rejectedFaceSceneField.invalidateUnverifiedFaceTracks(matching: [lockedRect])
        XCTAssertFalse(rejectedFaceSceneField.ingest([], at: 17_001_000_000).contains { $0.observation.label == "face" })

        var transientRawFaceSceneField = SceneField()
        let firstTransientFace = transientRawFaceSceneField.ingest([rejectedFace], at: 17_100_000_000)
            .first { $0.observation.label == "face" }
        XCTAssertNotNil(firstTransientFace)
        let transientGap = transientRawFaceSceneField.ingest([], at: 17_200_000_000)
            .first { $0.observation.label == "face" }
        XCTAssertEqual(transientGap?.id, firstTransientFace?.id)
        XCTAssertFalse(transientGap?.isActionEligible ?? true)
        let resumedTransientFace = transientRawFaceSceneField.ingest([rejectedFace], at: 17_210_000_000)
            .first { $0.observation.label == "face" }
        XCTAssertEqual(resumedTransientFace?.id, firstTransientFace?.id)
        XCTAssertEqual(resumedTransientFace?.observationCount, 2)
        XCTAssertFalse(transientRawFaceSceneField.ingest([], at: 17_461_000_000).contains { $0.observation.label == "face" })

        var continuity = VisualEvidenceContinuity()
        continuity.recordObservation(at: 1_000_000_000)
        XCTAssertFalse(continuity.confirmsLoss(at: 1_249_000_000))
        XCTAssertTrue(continuity.confirmsLoss(at: 1_250_000_000))

        var actionableContinuity = VisualEvidenceContinuity()
        actionableContinuity.recordObservation(at: 2_000_000_000)
        XCTAssertFalse(actionableContinuity.confirmsLoss(at: 2_120_000_000))
        XCTAssertTrue(actionableContinuity.confirmsLoss(at: 2_250_000_000))
    }

    func testCredibleHumanRetainsSocialPriorityOverAnOrdinaryObject() {
        let model = PredictiveWorldModel()
        let previous = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.05, y: 0.30, width: 0.18, height: 0.30),
                confidence: 0.80,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                posteriorProbability: 0.80,
                sceneID: "scene-person",
                isActionEligible: true
            ),
            at: 10_000_000_000
        ).target
        let distantPerson = VisualObservation(
            rect: NormalizedRect(x: 0.72, y: 0.30, width: 0.18, height: 0.30),
            confidence: 0.72,
            source: .neuralDetector,
            kind: .human,
            label: "person",
            sceneID: "scene-other-person"
        )
        let nearbyObject = VisualObservation(
            rect: NormalizedRect(x: 0.42, y: 0.30, width: 0.20, height: 0.30),
            confidence: 0.96,
            source: .neuralDetector,
            kind: .object,
            label: "book",
            sceneID: "scene-book"
        )

        let distribution = ProbabilisticAttentionSelector.infer(
            candidates: [distantPerson, nearbyObject],
            previousTarget: previous
        )

        XCTAssertEqual(distribution.selected?.label, "person")
    }

    func testHabituationLetsNovelEvidenceOrNoTargetWin() {
        let familiar = VisualObservation(
            rect: NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3),
            confidence: 0.90,
            source: .neuralDetector,
            kind: .object,
            label: "book",
            stabilityMilliseconds: 9_000
        )
        let novel = VisualObservation(
            rect: NormalizedRect(x: 0.65, y: 0.3, width: 0.2, height: 0.3),
            confidence: 0.68,
            source: .neuralDetector,
            kind: .object,
            label: "chair"
        )
        XCTAssertEqual(
            ProbabilisticAttentionSelector.infer(candidates: [familiar, novel], previousTarget: nil).selected?.label,
            "chair"
        )
        XCTAssertNil(ProbabilisticAttentionSelector.infer(candidates: [familiar], previousTarget: nil).selected)
        let model = PredictiveWorldModel()
        let previous = model.ingestVisual(
            VisualObservation(
                rect: familiar.rect,
                confidence: 0.90,
                source: .neuralDetector,
                kind: .object,
                label: "book",
                posteriorProbability: 0.80,
                sceneID: "scene-familiar",
                isActionEligible: true
            ), at: 12_000_000_000
        ).target
        let retained = VisualObservation(
            rect: familiar.rect,
            confidence: 0.90,
            source: .neuralDetector,
            kind: .object,
            label: "book",
            sceneID: "scene-familiar",
            stabilityMilliseconds: 9_000
        )
        XCTAssertNil(ProbabilisticAttentionSelector.infer(candidates: [retained], previousTarget: previous).selected)
    }

    func testNativeHumanLeaseNeverCarriesIntoObjectAttention() {
        let model = PredictiveWorldModel()
        let start: UInt64 = 6_000_000_000
        let human = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3),
                confidence: 0.9,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                posteriorProbability: 0.8,
                isActionEligible: true
            ),
            at: start
        )
        var gate = NativeHumanTrackingGate()
        XCTAssertEqual(gate.update(human), .none)
        let stableHuman = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3),
                confidence: 0.9,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                posteriorProbability: 0.8,
                isActionEligible: true
            ),
            at: start + 160_000_000
        )
        XCTAssertEqual(gate.update(stableHuman), .start)
        XCTAssertTrue(gate.isActive)
        let weakHuman = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3),
                confidence: 0.55,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                posteriorProbability: 0.55,
                isActionEligible: true
            ),
            at: start + 360_000_000
        )
        XCTAssertEqual(gate.update(weakHuman), .heartbeat)
        XCTAssertEqual(gate.update(stableHuman, hasVisualEvidence: false), .stop)
        XCTAssertFalse(gate.isActive)
        XCTAssertEqual(gate.update(stableHuman), .none)

        let object = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.6, y: 0.3, width: 0.2, height: 0.2),
                confidence: 0.9,
                source: .neuralDetector,
                kind: .object,
                label: "cup",
                posteriorProbability: 0.8,
                isActionEligible: true
            ),
            at: start + 600_000_000
        )
        XCTAssertEqual(gate.update(object), .none)
        XCTAssertEqual(gate.stop(), .none)
    }

    func testVerifiedFaceLockReacquiresNativeTrackingFromOneFreshFrame() {
        let model = PredictiveWorldModel()
        let start: UInt64 = 6_500_000_000
        let face = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.38, y: 0.25, width: 0.24, height: 0.35),
                confidence: 0.72,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                posteriorProbability: 0.90,
                sceneID: "verified-face",
                isActionEligible: true
            ),
            at: start
        )
        var gate = NativeHumanTrackingGate()

        XCTAssertEqual(gate.update(face, immediateAcquisitionPermitted: true), .start)
        XCTAssertTrue(gate.isActive)
        XCTAssertEqual(gate.heartbeatIfActive(at: start + 199_000_000), .none)
        XCTAssertEqual(gate.heartbeatIfActive(at: start + 200_000_000), .heartbeat)
        XCTAssertEqual(gate.update(face, hasVisualEvidence: false, immediateAcquisitionPermitted: true), .stop)
    }

    func testRepeatedTemporalFaceEvidenceCanStartBoundedNativeAcquisition() {
        var gate = NativeHumanTrackingGate()
        let start: UInt64 = 6_700_000_000

        XCTAssertEqual(gate.acquireFromTemporalFaceEvidence(at: start), .start)
        XCTAssertTrue(gate.isActive)
        XCTAssertEqual(gate.heartbeatIfActive(at: start + 199_000_000), .none)
        XCTAssertEqual(gate.heartbeatIfActive(at: start + 200_000_000), .heartbeat)
        XCTAssertEqual(gate.invalidate(), .stop)
        XCTAssertFalse(gate.isActive)
    }

    func testPersonObservationCannotInterruptActiveNativeFaceTracking() {
        let timestamp: UInt64 = 6_800_000_000
        let person = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.28, y: 0.05, width: 0.44, height: 0.90),
                confidence: 0.90,
                source: .neuralDetector,
                kind: .human,
                label: "person",
                posteriorProbability: 0.90,
                isActionEligible: true
            ),
            at: timestamp
        )
        var controller = SubconsciousAttentionController()
        let retained = controller.advance(
            belief: person,
            evidence: .visualObservation,
            socialFixationPermitted: true,
            nativeSocialTrackingActive: true
        )

        XCTAssertEqual(retained.state, .socialRetention)
        XCTAssertFalse(retained.permitsExternalSocialReframing)
        XCTAssertTrue(retained.suppressesExploration)
    }

    func testSustainedSocialLossReleasesTrackingAndReacquisitionResetsIt() {
        let start: UInt64 = 6_850_000_000
        var continuity = VisualEvidenceContinuity(lossConfirmationMilliseconds: 1_200)
        continuity.recordObservation(at: start)

        XCTAssertFalse(continuity.confirmsLoss(at: start + 1_199_000_000))
        XCTAssertTrue(continuity.confirmsLoss(at: start + 1_200_000_000))

        continuity.recordObservation(at: start + 1_300_000_000)
        XCTAssertFalse(continuity.confirmsLoss(at: start + 1_400_000_000))
    }

    func testConfirmedFaceLossCannotKeepSocialAttentionWithoutFreshEvidence() {
        let start: UInt64 = 6_875_000_000
        var continuity = VisualEvidenceContinuity(lossConfirmationMilliseconds: 1_200)
        continuity.recordObservation(at: start)
        let faceBelief = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.40, y: 0.25, width: 0.20, height: 0.30),
                confidence: 0.92,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                posteriorProbability: 0.94,
                sceneID: "face-before-loss",
                isActionEligible: true
            ),
            at: start
        )
        var controller = SubconsciousAttentionController()
        XCTAssertEqual(
            controller.advance(
                belief: faceBelief,
                evidence: .visualObservation,
                socialFixationPermitted: true
            ).state,
            .socialFixation
        )

        let socialEvidenceFresh = !continuity.confirmsLoss(at: start + 1_200_000_000)
        XCTAssertFalse(socialEvidenceFresh)
        let released = controller.advance(
            belief: faceBelief,
            evidence: .visualLoss,
            socialFixationPermitted: socialEvidenceFresh
        )
        XCTAssertEqual(released.state, .exploration)
        XCTAssertFalse(released.suppressesExploration)
    }

    func testCompetingRawFaceCannotInterruptVerifiedFaceLock() {
        let start: UInt64 = 6_900_000_000
        var lock = FaceLockLease()
        lock.record(
            sceneID: "verified-face",
            rect: NormalizedRect(x: 0.42, y: 0.28, width: 0.16, height: 0.22),
            at: start
        )

        XCTAssertTrue(lock.suppressesCompetingFace(
            sceneID: "raw-lookalike",
            rect: NormalizedRect(x: 0.02, y: 0.04, width: 0.62, height: 0.90),
            at: start + 100_000_000
        ))
        XCTAssertFalse(lock.suppressesCompetingFace(
            sceneID: "verified-face",
            rect: NormalizedRect(x: 0.43, y: 0.28, width: 0.16, height: 0.22),
            at: start + 100_000_000
        ))
    }

    func testExplorationFaceInterceptionUsesRepeatedDetectorEvidence() {
        XCTAssertFalse(FaceLockLease.permitsProvisionalExplorationInterception(
            observationCount: 1,
            confidence: 0.99
        ))
        XCTAssertFalse(FaceLockLease.permitsProvisionalExplorationInterception(
            observationCount: 3,
            confidence: 0
        ))
        XCTAssertTrue(FaceLockLease.permitsProvisionalExplorationInterception(
            observationCount: 2,
            confidence: 0.55
        ))
    }

    func testExternalObjectNeverMovesL0() {
        let calibration = ExternalGimbalCalibration(
            panSign: 1,
            pitchSign: -1,
            maximumPanDegreesPerSecond: 8,
            maximumPitchDegreesPerSecond: 6
        )
        XCTAssertTrue(calibration.isValid)
        let tiny3Calibration = ExternalGimbalCalibration.fromPositivePulseDisplacements(
            panImageDelta: -0.04,
            pitchImageDelta: 0.03,
            deviceProfile: .tiny3Lite,
            panPoseDelta: -1,
            pitchPoseDelta: 1,
            homePose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1)
        )
        XCTAssertEqual(tiny3Calibration?.deviceProfile, .tiny3Lite)
        XCTAssertEqual(
            ExternalGimbalCalibration.fromPositivePulseDisplacements(panImageDelta: -0.04, pitchImageDelta: 0.03)?.panSign,
            1
        )
        XCTAssertNil(
            ExternalGimbalCalibration.fromPositivePulseDisplacements(panImageDelta: -0.01, pitchImageDelta: 0.03)
        )
        let model = PredictiveWorldModel()
        let object = model.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.7, y: 0.65, width: 0.15, height: 0.15),
                confidence: 0.9,
                source: .neuralDetector,
                kind: .object,
                label: "cup",
                posteriorProbability: 0.8,
                stabilityMilliseconds: 300,
                isActionEligible: true
            ),
            at: 7_000_000_000
        )
        var fixation = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: false)
        XCTAssertEqual(fixation.update(object), .none, "ordinary object evidence must not move L0")
        let explicitObject = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.7, y: 0.65, width: 0.15, height: 0.15),
                confidence: 0.9,
                source: .neuralDetector,
                kind: .object,
                label: "cup",
                attentionWeight: 0.9,
                posteriorProbability: 0.8,
                stabilityMilliseconds: 300,
                isActionEligible: true
            ),
            at: 7_000_000_000
        )
        XCTAssertEqual(fixation.update(explicitObject), .none, "top-down object evidence must not move L0")

        let unstableVertical = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.7, y: 0.65, width: 0.15, height: 0.15),
                confidence: 0.9,
                source: .neuralFaceDetector,
                label: "face",
                stabilityMilliseconds: 0,
                isActionEligible: true
            ),
            at: 7_000_000_000
        )
        var unstableVerticalGate = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: false)
        guard case let .velocity(unstablePitch, _) = unstableVerticalGate.update(unstableVertical) else {
            return XCTFail("expected tracking observation for a newly observed face")
        }
        XCTAssertNotEqual(unstablePitch, 0)

        let nearFace = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.48, y: 0.40, width: 0.12, height: 0.20),
                confidence: 0.9,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                stabilityMilliseconds: 200,
                isActionEligible: true
            ),
            at: 7_000_000_000
        )
        let farFace = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.78, y: 0.40, width: 0.12, height: 0.20),
                confidence: 0.9,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                stabilityMilliseconds: 200,
                isActionEligible: true
            ),
            at: 7_000_000_000
        )
        var nearFaceGate = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: false)
        var farFaceGate = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: false)
        XCTAssertEqual(nearFaceGate.update(nearFace), .none)
        guard case let .velocity(_, farFacePan) = farFaceGate.update(farFace) else {
            return XCTFail("far face did not emit a tracking velocity")
        }
        XCTAssertLessThanOrEqual(abs(farFacePan), 8)

        let farPerson = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.78, y: 0.40, width: 0.12, height: 0.20),
                confidence: 0.9,
                source: .neuralDetector,
                kind: .human,
                label: "person",
                stabilityMilliseconds: 300,
                isActionEligible: true
            ),
            at: 7_000_000_000
        )
        var farPersonGate = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: false)
        XCTAssertEqual(farPersonGate.update(farPerson), .none, "person-only evidence must not move L0")

        func faceBelief(centerX: Double, at monotonicNS: UInt64) -> BeliefSnapshot {
            PredictiveWorldModel().ingestVisual(
                VisualObservation(
                    rect: NormalizedRect(x: centerX - 0.06, y: 0.40, width: 0.12, height: 0.20),
                    confidence: 0.95,
                    source: .neuralFaceDetector,
                    kind: .human,
                    label: "face",
                    sceneID: "stable-face",
                    stabilityMilliseconds: 250,
                    isActionEligible: true
                ),
                at: monotonicNS
            )
        }
        func faceVerticalBelief(centerY: Double, stabilityMilliseconds: Double, at monotonicNS: UInt64) -> BeliefSnapshot {
            PredictiveWorldModel().ingestVisual(
                VisualObservation(
                    rect: NormalizedRect(x: 0.44, y: centerY - 0.10, width: 0.12, height: 0.20),
                    confidence: 0.95,
                    source: .neuralFaceDetector,
                    kind: .human,
                    label: "face",
                    sceneID: "rising-face",
                    stabilityMilliseconds: stabilityMilliseconds,
                    isActionEligible: true
                ),
                at: monotonicNS
            )
        }
        let dynamicCalibration = ExternalGimbalCalibration(
            panSign: 1,
            pitchSign: 1,
            maximumPanDegreesPerSecond: 180,
            maximumPitchDegreesPerSecond: 90
        )
        var dynamicFaceGate = ExternalGimbalAttentionGate(calibration: dynamicCalibration, autonomousScanEnabled: false)
        guard case let .velocity(_, initialFacePan) = dynamicFaceGate.update(faceBelief(centerX: 0.58, at: 7_000_000_000)) else {
            return XCTFail("off-centre face did not begin a decisive correction")
        }
        XCTAssertGreaterThanOrEqual(initialFacePan, 8)
        XCTAssertLessThanOrEqual(initialFacePan, 36)
        var adaptiveFaceGate = ExternalGimbalAttentionGate(calibration: dynamicCalibration, autonomousScanEnabled: false)
        guard case let .velocity(_, initialAdaptivePan) = adaptiveFaceGate.update(faceBelief(centerX: 0.58, at: 7_300_000_000)),
              case let .velocity(_, persistentAdaptivePan) = adaptiveFaceGate.update(faceBelief(centerX: 0.72, at: 7_380_000_000)) else {
            return XCTFail("adaptive face drive did not emit both live corrections")
        }
        XCTAssertGreaterThan(abs(persistentAdaptivePan), abs(initialAdaptivePan))
        var closingFaceGate = ExternalGimbalAttentionGate(calibration: dynamicCalibration, autonomousScanEnabled: false)
        guard case let .velocity(_, initialClosingPan) = closingFaceGate.update(faceBelief(centerX: 0.80, at: 7_390_000_000)),
              case let .velocity(_, followupClosingPan) = closingFaceGate.update(faceBelief(centerX: 0.70, at: 7_470_000_000)) else {
            return XCTFail("face PD servo did not emit the closing-error commands")
        }
        XCTAssertGreaterThan(initialClosingPan, followupClosingPan)
        XCTAssertGreaterThanOrEqual(followupClosingPan, 0)
        var poseReferencedFaceGate = ExternalGimbalAttentionGate(calibration: dynamicCalibration, autonomousScanEnabled: false)
        guard case let .velocity(initialPosePitch, initialPosePan) = poseReferencedFaceGate.update(
            faceBelief(centerX: 0.58, at: 7_480_000_000),
            faceBearing: GimbalRelativeBearing(azimuthDegrees: 12, elevationDegrees: -8),
            currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 7_480_000_000)
        ), case let .velocity(closingPosePitch, closingPosePan) = poseReferencedFaceGate.update(
            faceBelief(centerX: 0.58, at: 7_560_000_000),
            faceBearing: GimbalRelativeBearing(azimuthDegrees: 12, elevationDegrees: -8),
            currentPose: GimbalPose(pitchDegrees: -4, panDegrees: 6, monotonicNS: 7_560_000_000)
        ) else {
            return XCTFail("pose-referenced face servo did not emit physical-bearing commands")
        }
        XCTAssertLessThan(initialPosePitch, 0)
        XCTAssertGreaterThan(initialPosePan, 0)
        XCTAssertLessThan(abs(closingPosePitch), abs(initialPosePitch))
        XCTAssertLessThan(abs(closingPosePan), abs(initialPosePan))

        let measuredTiny3Calibration = ExternalGimbalCalibration(
            panSign: 1,
            pitchSign: -1,
            maximumPanDegreesPerSecond: 90,
            maximumPitchDegreesPerSecond: 45,
            deviceProfile: .tiny3Lite,
            posePanImageSign: 1,
            posePitchImageSign: -1,
            velocityPanPoseSign: -1,
            velocityPitchPoseSign: 1,
            homePanDegrees: 0,
            homePitchDegrees: 0
        )
        var measuredTiny3Gate = ExternalGimbalAttentionGate(
            calibration: measuredTiny3Calibration,
            autonomousScanEnabled: false
        )
        guard case let .velocity(tiny3Pitch, tiny3Pan) = measuredTiny3Gate.update(
            faceBelief(centerX: 0.58, at: 7_570_000_000),
            faceBearing: GimbalRelativeBearing(azimuthDegrees: 12, elevationDegrees: -8),
            currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 7_570_000_000)
        ) else {
            return XCTFail("measured-attitude face servo did not emit a correction")
        }
        XCTAssertLessThan(tiny3Pan, 0, "measured Tiny 3 pan direction must follow its velocity pulse")
        XCTAssertLessThan(tiny3Pitch, 0, "measured Tiny 3 pitch direction must follow its velocity pulse")
        var risingFaceGate = ExternalGimbalAttentionGate(calibration: dynamicCalibration, autonomousScanEnabled: false)
        guard case let .velocity(initialPitch, _) = risingFaceGate.update(
            faceVerticalBelief(centerY: 0.22, stabilityMilliseconds: 0, at: 7_420_000_000)
        ) else {
            return XCTFail("a newly observed elevated face did not begin pitch correction")
        }
        XCTAssertGreaterThanOrEqual(abs(initialPitch), 8)
        guard case let .velocity(predictedPitch, _) = risingFaceGate.update(
            faceVerticalBelief(centerY: 0.10, stabilityMilliseconds: 16, at: 7_500_000_000)
        ) else {
            return XCTFail("outward face motion lost its pitch correction")
        }
        XCTAssertGreaterThan(abs(predictedPitch), 8)
        XCTAssertEqual(dynamicFaceGate.update(faceBelief(centerX: 0.45, at: 7_080_000_000)), .hold)
        guard case let .velocity(_, persistentFacePan) = dynamicFaceGate.update(faceBelief(centerX: 0.30, at: 7_160_000_000)) else {
            return XCTFail("persistent face movement did not resume correction")
        }
        XCTAssertLessThan(persistentFacePan, 0)
        XCTAssertLessThan(abs(persistentFacePan), 25, "face reversal bypassed the command slew")
        var nativeHandoffGate = ExternalGimbalAttentionGate(calibration: dynamicCalibration, autonomousScanEnabled: false)
        _ = nativeHandoffGate.update(faceBelief(centerX: 0.70, at: 7_200_000_000))
        XCTAssertEqual(nativeHandoffGate.release(), .stop, "native handoff did not release external face ownership")

        let stalledVerticalModel = PredictiveWorldModel()
        let stalledVerticalObservation = VisualObservation(
            rect: NormalizedRect(x: 0.70, y: 0.12, width: 0.15, height: 0.15),
            confidence: 0.90,
            source: .neuralDetector,
            kind: .human,
            label: "person",
            posteriorProbability: 0.80,
            sceneID: "stalled-top-face",
            stabilityMilliseconds: 500,
            isActionEligible: true
        )
        var stalledVerticalGate = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: false)
        for update in 0..<3 {
            let belief = stalledVerticalModel.ingestVisual(
                stalledVerticalObservation,
                at: 7_200_000_000 + UInt64(update) * 100_000_000
            )
            guard case let .velocity(pitch, _) = stalledVerticalGate.update(
                belief,
                allowSocialReframing: true
            ) else {
                return XCTFail("stalled vertical target did not preserve pan observation")
            }
            XCTAssertNotEqual(pitch, 0)
        }
        let stalledVerticalBelief = stalledVerticalModel.ingestVisual(
            stalledVerticalObservation,
            at: 7_500_000_000
        )
        guard case let .velocity(stalledPitch, stalledPan) = stalledVerticalGate.update(
            stalledVerticalBelief,
            allowSocialReframing: true
        ) else {
            return XCTFail("stalled vertical target did not retain pan-only observation")
        }
        XCTAssertEqual(stalledPitch, 0)
        XCTAssertNotEqual(stalledPan, 0)

        let movingVerticalBelief = stalledVerticalModel.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.70, y: 0.02, width: 0.15, height: 0.15),
                confidence: 0.90,
                source: .neuralDetector,
                kind: .human,
                label: "person",
                posteriorProbability: 0.80,
                sceneID: "stalled-top-face",
                stabilityMilliseconds: 500,
                isActionEligible: true
            ),
            at: 7_600_000_000
        )
        guard case let .velocity(movingPitch, _) = stalledVerticalGate.update(
            movingVerticalBelief,
            allowSocialReframing: true
        ) else {
            return XCTFail("a vertically moving social target lost its tracking command")
        }
        XCTAssertNotEqual(movingPitch, 0)

        _ = model.ingestVisionMiss(at: 7_100_000_000)
        XCTAssertEqual(fixation.recordVisualLoss(at: 7_100_000_000), .none)

        var scan = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: true)
        XCTAssertEqual(scan.recordVisualLoss(at: 8_000_000_000), .none)
        XCTAssertEqual(scan.nextScanEligibleAtNS, 8_450_000_000)
        XCTAssertEqual(scan.beginScanIfEligible(at: 8_449_000_000), .none)
        guard case let .velocity(pitchDegreesPerSecond: scanPitch, panDegreesPerSecond: scanPan) = scan.beginScanIfEligible(at: 8_450_000_000) else {
            return XCTFail("expected bounded scan pulse")
        }
        XCTAssertEqual(scanPitch, 0)
        XCTAssertLessThanOrEqual(abs(scanPan), 120)
        XCTAssertEqual(scan.recordVisualLoss(at: 9_850_000_000), .stop)
        guard case .velocity = scan.beginScanIfEligible(at: 14_900_000_000) else {
            return XCTFail("expected continued search sweep during visual absence")
        }

        let scanFace = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.70, y: 0.40, width: 0.12, height: 0.20),
                confidence: 0.90,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                stabilityMilliseconds: 300,
                isActionEligible: true
            ),
            at: 15_000_000_000
        )
        _ = scan.update(scanFace)
        XCTAssertEqual(scan.recordVisualLoss(at: 15_000_000_000), .stop)
        guard case .velocity = scan.beginScanIfEligible(at: 16_500_000_000) else {
            return XCTFail("fresh visual evidence did not restart the search dwell")
        }
    }

    func testAttentionControllerSeparatesSceneAttentionFromSocialMotorAuthority() {
        let timestamp: UInt64 = 7_000_000_000
        let objectBelief = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.62, y: 0.30, width: 0.18, height: 0.22),
                confidence: 0.90,
                source: .neuralDetector,
                kind: .object,
                label: "cup",
                posteriorProbability: 0.80,
                isActionEligible: true
            ),
            at: timestamp
        )
        let faceBelief = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.42, y: 0.30, width: 0.16, height: 0.20),
                confidence: 0.95,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                posteriorProbability: 0.80,
                isActionEligible: true
            ),
            at: timestamp
        )

        var controller = SubconsciousAttentionController()
        let object = controller.advance(
            belief: objectBelief,
            evidence: .visualObservation,
            socialFixationPermitted: false
        )
        XCTAssertEqual(object.state, .sceneObservation)
        XCTAssertTrue(object.suppressesExploration)
        XCTAssertTrue(object.preservesActiveExploration)
        XCTAssertFalse(object.permitsNativeSocialTracking)

        let staticObject = VisualObservation(
            rect: objectBelief.target!.rect,
            confidence: 0.90,
            source: .neuralDetector,
            kind: .object,
            label: "cup",
            posteriorProbability: 0.50,
            sceneID: "static-cup",
            isActionEligible: true
        )
        var dwellController = SubconsciousAttentionController()
        let firstStaticObject = PredictiveWorldModel().ingestVisual(staticObject, at: timestamp)
        XCTAssertEqual(
            dwellController.advance(
                belief: firstStaticObject,
                evidence: .visualObservation,
                socialFixationPermitted: false
            ).state,
            .sceneObservation
        )
        let activeStaticObject = PredictiveWorldModel().ingestVisual(staticObject, at: timestamp + 450_000_000)
        XCTAssertEqual(
            dwellController.advance(
                belief: activeStaticObject,
                evidence: .visualObservation,
                socialFixationPermitted: false
            ).state,
            .sceneObservation
        )
        let elapsedStaticObject = PredictiveWorldModel().ingestVisual(staticObject, at: timestamp + 500_000_000)
        XCTAssertEqual(
            dwellController.advance(
                belief: elapsedStaticObject,
                evidence: .visualObservation,
                socialFixationPermitted: false
            ).state,
            .exploration
        )

        let face = controller.advance(
            belief: faceBelief,
            evidence: .visualObservation,
            socialFixationPermitted: true
        )
        XCTAssertEqual(face.state, .socialFixation)
        XCTAssertTrue(face.permitsNativeSocialTracking)

        let unverifiedFace = controller.advance(
            belief: faceBelief,
            evidence: .visualObservation,
            socialFixationPermitted: false
        )
        XCTAssertEqual(unverifiedFace.state, .socialRetention)
        XCTAssertTrue(unverifiedFace.preservesActiveExploration)
        XCTAssertFalse(unverifiedFace.permitsExternalSocialReframing)

        var rawFaceController = SubconsciousAttentionController()
        let initialRawFace = rawFaceController.advance(
            belief: faceBelief,
            evidence: .visualObservation,
            socialFixationPermitted: false
        )
        XCTAssertEqual(initialRawFace.state, .exploration)
        XCTAssertFalse(initialRawFace.suppressesExploration)

        let provisionalFace = controller.advance(
            belief: faceBelief,
            evidence: .visualObservation,
            socialFixationPermitted: true,
            nativeSocialTrackingPermitted: false
        )
        XCTAssertEqual(provisionalFace.state, .socialFixation)
        XCTAssertFalse(provisionalFace.permitsNativeSocialTracking)

        let personBelief = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.05, y: 0.20, width: 0.30, height: 0.55),
                confidence: 0.85,
                source: .neuralDetector,
                kind: .human,
                label: "person",
                posteriorProbability: 0.75,
                isActionEligible: true
            ),
            at: timestamp
        )
        let person = controller.advance(
            belief: personBelief,
            evidence: .visualObservation,
            socialFixationPermitted: false
        )
        XCTAssertEqual(person.state, .socialReframing)
        XCTAssertTrue(person.permitsExternalSocialReframing)
        XCTAssertFalse(person.permitsNativeSocialTracking)

        let gap = controller.advance(
            belief: objectBelief,
            evidence: .visualLoss,
            socialFixationPermitted: true
        )
        XCTAssertEqual(gap.state, .socialRetention)
        XCTAssertFalse(gap.permitsNativeSocialTracking)
        XCTAssertFalse(gap.suppressesExploration)

        let nativeTrackedGap = controller.advance(
            belief: objectBelief,
            evidence: .visualLoss,
            socialFixationPermitted: true,
            nativeSocialTrackingActive: true
        )
        XCTAssertTrue(nativeTrackedGap.suppressesExploration)

        let lockedBody = controller.advance(
            belief: personBelief,
            evidence: .visualObservation,
            socialFixationPermitted: true
        )
        XCTAssertEqual(lockedBody.state, .socialReframing)
        XCTAssertTrue(lockedBody.permitsExternalSocialReframing)
    }

    func testSceneFieldRetainsAllCandidatesAndRestrictsActuationAuthority() {
        let start: UInt64 = 9_000_000_000
        var field = SceneField()
        let scene = field.ingest([
            VisualObservation(
                rect: NormalizedRect(x: 0.08, y: 0.24, width: 0.18, height: 0.25),
                confidence: 0.75,
                source: .systemSaliency
            ),
            VisualObservation(
                rect: NormalizedRect(x: 0.64, y: 0.25, width: 0.20, height: 0.25),
                confidence: 0.72,
                source: .systemSaliency
            )
        ], at: start)
        XCTAssertEqual(scene.count, 2, "the scene field must retain more than attention's one selected target")
        XCTAssertTrue(scene.allSatisfy { $0.observation.kind == .unknown && !$0.isActionEligible })

        var genericField = SceneField()
        var genericCandidate: SceneCandidate?
        for frame in 0...2 {
            genericCandidate = genericField.ingest([
                VisualObservation(
                    rect: NormalizedRect(x: 0.64, y: 0.25, width: 0.20, height: 0.25),
                    confidence: 0.72,
                    source: .systemSaliency
                )
            ], at: start + UInt64(frame) * 100_000_000,
               cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + UInt64(frame) * 100_000_000)).first
        }
        guard let genericCandidate else { return XCTFail("missing generic visual candidate") }
        XCTAssertTrue(genericCandidate.isActionEligible, "a stable, ordinary unknown object should be observable")
        let genericModel = PredictiveWorldModel()
        let genericBelief = genericModel.ingestVisual(
            VisualObservation(
                rect: genericCandidate.observation.rect,
                confidence: genericCandidate.observation.confidence,
                source: genericCandidate.observation.source,
                kind: .unknown,
                posteriorProbability: 0.7,
                sceneID: genericCandidate.id,
                stabilityMilliseconds: genericCandidate.stabilityMilliseconds,
                isActionEligible: true
            ),
            at: start + 300_000_000
        )
        let genericCalibration = ExternalGimbalCalibration(
            panSign: 1,
            pitchSign: 1,
            maximumPanDegreesPerSecond: 8,
            maximumPitchDegreesPerSecond: 6
        )
        var genericGate = ExternalGimbalAttentionGate(calibration: genericCalibration, autonomousScanEnabled: false)
        XCTAssertEqual(genericGate.update(genericBelief), .none, "default non-human evidence must not move L0")
        let explicitGenericBelief = PredictiveWorldModel().ingestVisual(
            VisualObservation(
                rect: genericCandidate.observation.rect,
                confidence: genericCandidate.observation.confidence,
                source: genericCandidate.observation.source,
                kind: .unknown,
                attentionWeight: 0.9,
                posteriorProbability: 0.7,
                sceneID: genericCandidate.id,
                stabilityMilliseconds: genericCandidate.stabilityMilliseconds,
                isActionEligible: true
            ),
            at: start + 300_000_000
        )
        XCTAssertEqual(genericGate.update(explicitGenericBelief), .none, "top-down non-human evidence must not move L0")

        var weightedSceneField = SceneField()
        let weightedScene = weightedSceneField.ingest([
            VisualObservation(
                rect: NormalizedRect(x: 0.58, y: 0.30, width: 0.18, height: 0.20),
                confidence: 0.85,
                source: .neuralDetector,
                kind: .object,
                label: "book",
                attentionWeight: 0.9
            )
        ], at: start,
           cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start))
        XCTAssertEqual(weightedScene.first?.observation.attentionWeight ?? -1, 0.9, accuracy: 0.000_001)

        var wallField = SceneField()
        var wallCandidate: SceneCandidate?
        for frame in 0...7 {
            wallCandidate = wallField.ingest([
                VisualObservation(
                    rect: NormalizedRect(x: 0.35, y: 0.02, width: 0.06, height: 0.05),
                    confidence: 0.92,
                    source: .neuralDetector,
                    kind: .object,
                    label: "bottle",
                    posteriorProbability: 0.9
                )
            ], at: start + UInt64(frame) * 100_000_000).first
        }
        guard let wallCandidate else { return XCTFail("missing persistent wall hypothesis") }
        XCTAssertFalse(wallCandidate.isActionEligible)

        let model = PredictiveWorldModel()
        let wallBelief = model.ingestVisual(wallCandidate.attentionObservation(), at: start + 800_000_000)
        let calibration = ExternalGimbalCalibration(
            panSign: 1,
            pitchSign: 1,
            maximumPanDegreesPerSecond: 8,
            maximumPitchDegreesPerSecond: 6
        )
        var gate = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: false)
        XCTAssertEqual(gate.update(wallBelief), .none)

        var corroboratedField = SceneField()
        var corroboratedCandidate: SceneCandidate?
        for frame in 0...5 {
            corroboratedCandidate = corroboratedField.ingest([
                VisualObservation(
                    rect: NormalizedRect(x: 0.35, y: 0.30, width: 0.25, height: 0.25),
                    confidence: 0.86,
                    source: .neuralDetector,
                    kind: .object,
                    label: "book"
                ),
                VisualObservation(
                    rect: NormalizedRect(x: 0.35, y: 0.30, width: 0.25, height: 0.25),
                    confidence: 0.82,
                    source: .systemSaliency
                )
            ], at: start + UInt64(frame) * 100_000_000,
               cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + UInt64(frame) * 100_000_000)).first
        }
        guard let corroboratedCandidate else { return XCTFail("missing corroborated candidate") }
        XCTAssertTrue(corroboratedCandidate.isActionEligible)
        XCTAssertEqual(corroboratedCandidate.observation.source, .neuralDetector)
        XCTAssertEqual(corroboratedCandidate.attentionObservation().sceneID, corroboratedCandidate.id)
    }

    func testFullFrameSaliencyRemainsSceneEvidenceButCannotDriveAttention() {
        var field = SceneField()
        let candidate = field.ingest([
            VisualObservation(
                rect: NormalizedRect(x: 0.05, y: 0.03, width: 0.90, height: 0.88),
                confidence: 0.80,
                source: .systemSaliency
            )
        ], at: 11_000_000_000).first

        XCTAssertNotNil(candidate)
        XCTAssertFalse(candidate?.isActionEligible ?? true)
    }

    func testTrackingBoundaryShrinksTowardTheCurrentGimbalLimit() {
        let start: UInt64 = 11_500_000_000
        let centered = TrackingBoundary(
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
            horizontalFieldOfViewDegrees: 86
        )
        XCTAssertTrue(centered.contains(NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20)))
        XCTAssertFalse(centered.contains(NormalizedRect(x: 0.01, y: 0.35, width: 0.20, height: 0.20)))
        XCTAssertTrue(
            TrackingBoundary.allowsFaceLockAcquisition(NormalizedRect(x: 0.47, y: 0.67, width: 0.12, height: 0.20))
        )
        XCTAssertFalse(
            TrackingBoundary.allowsFaceLockAcquisition(NormalizedRect(x: 0.40, y: 0.00, width: 0.20, height: 0.08))
        )
        let lowerEdgeFaceRect = NormalizedRect(x: 0.40, y: 0.82, width: 0.20, height: 0.12)
        XCTAssertFalse(centered.contains(lowerEdgeFaceRect))
        XCTAssertTrue(centered.allowsFaceReentry(lowerEdgeFaceRect))
        var lowerEdgeFaceField = SceneField()
        let lowerEdgeFace = lowerEdgeFaceField.ingest(
            [VisualObservation(
                rect: lowerEdgeFaceRect,
                confidence: 0.95,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                isActionEligible: true,
                isFaceVerified: true
            )],
            at: start,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
            horizontalFieldOfViewDegrees: 86
        ).first
        XCTAssertTrue(lowerEdgeFace?.isActionEligible ?? false)
        let lowerEdgeFaceOffscreen = lowerEdgeFaceField.ingest(
            [],
            at: start + 300_000_000,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + 300_000_000),
            horizontalFieldOfViewDegrees: 86
        ).first
        XCTAssertFalse(lowerEdgeFaceOffscreen?.isActionEligible ?? true)
        XCTAssertNotNil(lowerEdgeFaceOffscreen?.bearing)
        var lowerEdgeObjectField = SceneField()
        let lowerEdgeObject = lowerEdgeObjectField.ingest(
            [VisualObservation(
                rect: lowerEdgeFaceRect,
                confidence: 0.95,
                source: .neuralDetector,
                kind: .object,
                label: "edge-object"
            )],
            at: start,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
            horizontalFieldOfViewDegrees: 86
        ).first
        XCTAssertFalse(lowerEdgeObject?.isActionEligible ?? true)
        let unavailablePose = TrackingBoundary(cameraPose: nil, horizontalFieldOfViewDegrees: 86)
        XCTAssertFalse(unavailablePose.isPoseAligned)
        XCTAssertFalse(unavailablePose.allowsMotorTarget(NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20)))

        var poseUnavailableField = SceneField()
        let poseUnavailableCandidate = poseUnavailableField.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
                confidence: 0.90,
                source: .neuralDetector,
                kind: .object,
                label: "unposed-object"
            )],
            at: start
        ).first
        XCTAssertFalse(poseUnavailableCandidate?.isActionEligible ?? true)
        var poseUnavailableHumanField = SceneField()
        let poseUnavailableHuman = poseUnavailableHumanField.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
                confidence: 0.90,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face"
            )],
            at: start
        ).first
        XCTAssertTrue(poseUnavailableHuman?.isActionEligible ?? false)
        let belief = PredictiveWorldModel().ingestVisual(poseUnavailableCandidate!.attentionObservation(), at: start)
        var gate = ExternalGimbalAttentionGate(
            calibration: ExternalGimbalCalibration(
                panSign: 1,
                pitchSign: 1,
                maximumPanDegreesPerSecond: 8,
                maximumPitchDegreesPerSecond: 6
            ),
            autonomousScanEnabled: false
        )
        XCTAssertEqual(gate.update(belief), .none)

        let leftLimit = TrackingBoundary(
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: -147, monotonicNS: start),
            horizontalFieldOfViewDegrees: 86
        )
        XCTAssertGreaterThan(leftLimit.minimumCenterX, 0.65)
        XCTAssertFalse(leftLimit.contains(NormalizedRect(x: 0.10, y: 0.35, width: 0.20, height: 0.20)))
        XCTAssertTrue(leftLimit.contains(NormalizedRect(x: 0.70, y: 0.35, width: 0.20, height: 0.20)))

        var field = SceneField()
        let candidate = field.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.10, y: 0.35, width: 0.20, height: 0.20),
                confidence: 0.90,
                source: .neuralDetector,
                kind: .object,
                label: "edge-object"
            )],
            at: start,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: -147, monotonicNS: start),
            horizontalFieldOfViewDegrees: 86
        ).first
        XCTAssertFalse(candidate?.isActionEligible ?? true)
    }

    func testSceneFieldReacquiresAVisibleHumanInGimbalRelativeSpace() {
        let start: UInt64 = 12_000_000_000
        var field = SceneField()
        let first = field.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
                confidence: 0.88,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                isActionEligible: true,
                isFaceVerified: true
            )],
            at: start,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 20, monotonicNS: start),
            horizontalFieldOfViewDegrees: 70,
            poseProjection: .obsbotTiny2Lite
        )
        guard let initial = first.first, let initialBearing = initial.bearing else {
            return XCTFail("missing initial spatial bearing")
        }
        XCTAssertEqual(initialBearing.azimuthDegrees, 20, accuracy: 0.5)

        let reacquired = field.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.0, y: 0.35, width: 0.20, height: 0.20),
                confidence: 0.90,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                isActionEligible: true,
                isFaceVerified: true
            )],
            at: start + 1_000_000_000,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 50, monotonicNS: start + 1_000_000_000),
            horizontalFieldOfViewDegrees: 70,
            poseProjection: .obsbotTiny2Lite
        )
        XCTAssertEqual(reacquired.count, 1)
        XCTAssertEqual(reacquired.first?.id, initial.id)
        XCTAssertEqual(reacquired.first?.bearing?.azimuthDegrees ?? 0, 20, accuracy: 4)

        let interveningFrame = field.ingest([], at: start + 1_075_000_000)
        XCTAssertEqual(interveningFrame.count, 1)
        XCTAssertFalse(interveningFrame[0].observedThisFrame)

        let offscreen = field.ingest([], at: start + 11_000_000_000)
        XCTAssertEqual(offscreen.count, 1)
        XCTAssertFalse(offscreen[0].observedThisFrame)
        XCTAssertGreaterThan(offscreen[0].lastSeenMilliseconds, 9_000)
        XCTAssertEqual(offscreen[0].spatialConfidence, reacquired[0].spatialConfidence, accuracy: 0.000_001)
        let persistent = field.ingest([], at: start + 61_000_000_000)
        XCTAssertEqual(persistent.count, 1)
        XCTAssertEqual(persistent.first?.id, initial.id)
        XCTAssertGreaterThanOrEqual(persistent.first?.lastSeenMilliseconds ?? 0, 60_000)
        let refreshed = field.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.0, y: 0.35, width: 0.20, height: 0.20),
                confidence: 0.92,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                isActionEligible: true
            )],
            at: start + 61_100_000_000,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 50, monotonicNS: start + 61_100_000_000),
            horizontalFieldOfViewDegrees: 70,
            poseProjection: .obsbotTiny2Lite
        )
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.id, initial.id)
        XCTAssertTrue(refreshed.first?.observedThisFrame ?? false)
        XCTAssertEqual(refreshed.first?.lastSeenMilliseconds, 0)

        var highElevationField = SceneField()
        _ = highElevationField.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
                confidence: 0.90,
                source: .neuralDetector,
                kind: .object,
                label: "lamp"
            )],
            at: start,
            cameraPose: GimbalPose(pitchDegrees: 60, panDegrees: 0, monotonicNS: start)
        )
        _ = highElevationField.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
                confidence: 0.90,
                source: .neuralDetector,
                kind: .object,
                label: "lamp"
            )],
            at: start + 100_000_000,
            cameraPose: GimbalPose(pitchDegrees: 60, panDegrees: 0, monotonicNS: start + 100_000_000)
        )
        XCTAssertGreaterThan(
            highElevationField.ingest([], at: start + 1_100_000_000).first?.bearing?.elevationDegrees ?? 0,
            36
        )

        var distinctField = SceneField()
        _ = distinctField.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
                confidence: 0.90,
                source: .neuralDetector,
                kind: .object,
                label: "book"
            )],
            at: start,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
            horizontalFieldOfViewDegrees: 70
        )
        let distinct = distinctField.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.40, y: 0.35, width: 0.20, height: 0.20),
                confidence: 0.90,
                source: .neuralDetector,
                kind: .object,
                label: "book"
            )],
            at: start + 1_000_000_000,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 40, monotonicNS: start + 1_000_000_000),
            horizontalFieldOfViewDegrees: 70
        )
        XCTAssertEqual(distinct.count, 2, "same label at a different bearing must remain a distinct spatial hypothesis")
    }

    func testSceneFieldKeepsAnAdjacentFaceMeasurementInOneTrack() {
        let start: UInt64 = 13_000_000_000
        var field = SceneField()
        let initial = field.ingest([
            VisualObservation(
                rect: NormalizedRect(x: 0.18, y: 0.32, width: 0.10, height: 0.12),
                confidence: 0.96,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face"
            )
        ], at: start).first
        let moved = field.ingest([
            VisualObservation(
                rect: NormalizedRect(x: 0.33, y: 0.32, width: 0.10, height: 0.12),
                confidence: 0.97,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face"
            )
        ], at: start + 80_000_000).first
        XCTAssertEqual(moved?.id, initial?.id)
    }

    func testSceneFieldExposesFreshBearingWithoutDestabilizingPersistentMapBearing() {
        let start: UInt64 = 32_000_000_000
        var field = SceneField()
        let initial = field.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.44, y: 0.40, width: 0.12, height: 0.20),
                confidence: 0.95,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                isActionEligible: true
            )],
            at: start,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
            horizontalFieldOfViewDegrees: 70
        )
        guard let initialID = initial.first?.id else {
            return XCTFail("initial face did not enter the scene field")
        }
        let moved = field.ingest(
            [VisualObservation(
                rect: NormalizedRect(x: 0.56, y: 0.40, width: 0.12, height: 0.20),
                confidence: 0.95,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                isActionEligible: true
            )],
            at: start + 80_000_000,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start + 80_000_000),
            horizontalFieldOfViewDegrees: 70
        )
        guard let candidate = moved.first(where: { $0.id == initialID }),
              let observedBearing = candidate.observedBearing,
              let persistentBearing = candidate.bearing else {
            return XCTFail("fresh and persistent bearings were not both available")
        }
        XCTAssertTrue(candidate.observedThisFrame)
        XCTAssertGreaterThan(
            abs(observedBearing.azimuthDegrees - persistentBearing.azimuthDegrees),
            1,
            "motor control must see the current bearing while the scene map remains filtered"
        )
    }

    func testFaceServoBrakesOnlyAgainstMeasuredGimbalOvershoot() {
        let calibration = ExternalGimbalCalibration(
            panSign: 1,
            pitchSign: 1,
            maximumPanDegreesPerSecond: 90,
            maximumPitchDegreesPerSecond: 45
        )
        func faceBelief(at monotonicNS: UInt64) -> BeliefSnapshot {
            PredictiveWorldModel().ingestVisual(
                VisualObservation(
                    rect: NormalizedRect(x: 0.52, y: 0.40, width: 0.12, height: 0.20),
                    confidence: 0.95,
                    source: .neuralFaceDetector,
                    kind: .human,
                    label: "face",
                    sceneID: "servo-face",
                    stabilityMilliseconds: 250,
                    isActionEligible: true
                ),
                at: monotonicNS
            )
        }
        var gate = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: false)
        guard case let .velocity(_, initialPan) = gate.update(
            faceBelief(at: 40_000_000_000),
            faceBearing: GimbalRelativeBearing(azimuthDegrees: 12, elevationDegrees: 0),
            currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 40_000_000_000),
            currentVelocity: GimbalVelocityFeedback(pitchDegreesPerSecond: 0, panDegreesPerSecond: 0)
        ), case let .velocity(_, brakingPan) = gate.update(
            faceBelief(at: 40_080_000_000),
            faceBearing: GimbalRelativeBearing(azimuthDegrees: 12, elevationDegrees: 0),
            currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 8, monotonicNS: 40_080_000_000),
            currentVelocity: GimbalVelocityFeedback(pitchDegreesPerSecond: 0, panDegreesPerSecond: 100)
        ), case let .velocity(_, reversingPan) = gate.update(
            faceBelief(at: 40_160_000_000),
            faceBearing: GimbalRelativeBearing(azimuthDegrees: 12, elevationDegrees: 0),
            currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 10, monotonicNS: 40_160_000_000),
            currentVelocity: GimbalVelocityFeedback(pitchDegreesPerSecond: 0, panDegreesPerSecond: 80)
        ) else {
            return XCTFail("pose-feedback face servo did not issue continuous commands")
        }
        XCTAssertGreaterThan(initialPan, 0)
        XCTAssertLessThan(brakingPan, initialPan, "measured closure must reduce drive before centre crossing")
        XCTAssertLessThan(reversingPan, 0, "only measured physical overshoot may request a braking reversal")

        var movingFaceGate = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: false)
        _ = movingFaceGate.update(
            faceBelief(at: 41_000_000_000),
            faceBearing: GimbalRelativeBearing(azimuthDegrees: 12, elevationDegrees: 0),
            currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 41_000_000_000)
        )
        guard case let .velocity(_, movingFacePan) = movingFaceGate.update(
            faceBelief(at: 41_080_000_000),
            faceBearing: GimbalRelativeBearing(azimuthDegrees: 20, elevationDegrees: 0),
            currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 41_080_000_000),
            currentVelocity: GimbalVelocityFeedback(pitchDegreesPerSecond: 0, panDegreesPerSecond: 0)
        ) else {
            return XCTFail("rapid subject motion did not produce a follow command")
        }
        XCTAssertGreaterThan(movingFacePan, 0, "subject motion alone must not reverse the camera away from the face")
    }

    func testGimbalPoseFreshnessRequiresACaptureAlignedSample() {
        let pose = GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000_000_000)
        XCTAssertTrue(pose.isFresh(for: 1_050_000_000, maximumAgeNS: 50_000_000))
        XCTAssertFalse(pose.isFresh(for: 1_050_000_001, maximumAgeNS: 50_000_000))
        XCTAssertFalse(pose.isFresh(for: 999_999_999, maximumAgeNS: 50_000_000))
    }

    func testPanoramaPoseUsesBracketedCaptureTimeInsteadOfThePreviousAttitude() {
        let estimate = CaptureAlignedPoseInterpolator.estimate(
            samples: [
                GimbalPose(pitchDegrees: -8, panDegrees: 10, monotonicNS: 1_000_000_000),
                GimbalPose(pitchDegrees: 4, panDegrees: 34, monotonicNS: 1_040_000_000),
            ],
            at: 1_010_000_000
        )
        XCTAssertEqual(estimate?.mode, .bracketed)
        XCTAssertEqual(estimate?.pose.panDegrees ?? 0, 16, accuracy: 0.000_001)
        XCTAssertEqual(estimate?.pose.pitchDegrees ?? 0, -5, accuracy: 0.000_001)
        XCTAssertEqual(estimate?.interpolationFraction ?? 0, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(estimate?.pose.monotonicNS, 1_010_000_000)
        XCTAssertEqual(
            estimate?.angularVelocityDegreesPerSecond ?? 0,
            hypot(24, 12) / 0.04,
            accuracy: 0.000_001
        )
    }

    func testPanoramaPoseRejectsUnbracketedAndWidelySpacedAttitudes() {
        XCTAssertNil(CaptureAlignedPoseInterpolator.estimate(
            samples: [GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000_000_000)],
            at: 1_010_000_000
        ))
        XCTAssertNil(CaptureAlignedPoseInterpolator.estimate(
            samples: [
                GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000_000_000),
                GimbalPose(pitchDegrees: 0, panDegrees: 40, monotonicNS: 1_100_000_000),
            ],
            at: 1_050_000_000
        ))
    }

    func testPanoramaExactPoseStillMeasuresLocalAngularVelocity() {
        let estimate = CaptureAlignedPoseInterpolator.estimate(
            samples: [
                GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000_000_000),
                GimbalPose(pitchDegrees: 0, panDegrees: 10, monotonicNS: 1_100_000_000),
                GimbalPose(pitchDegrees: 0, panDegrees: 20, monotonicNS: 1_200_000_000),
            ],
            at: 1_100_000_000
        )
        XCTAssertEqual(estimate?.mode, .exact)
        XCTAssertEqual(estimate?.pose.panDegrees ?? 0, 10, accuracy: 0.000_001)
        XCTAssertEqual(
            estimate?.angularVelocityDegreesPerSecond ?? 0,
            100,
            accuracy: 0.000_001
        )
    }

    func testPanoramaProjectionUsesCalibratedImageSignsAndDynamicMasks() {
        let pose = GimbalPose(pitchDegrees: 5, panDegrees: 20, monotonicNS: 1)
        let center = SphericalPanoramaProjection.sourceCoordinate(
            for: GimbalRelativeBearing(azimuthDegrees: -20, elevationDegrees: -5),
            cameraPose: pose,
            horizontalFieldOfViewDegrees: 86,
            poseProjection: .obsbotTiny2Lite
        )
        XCTAssertEqual(center?.normalizedX ?? 0, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(center?.normalizedY ?? 0, 0.5, accuracy: 0.000_001)
        let imageRight = SphericalPanoramaProjection.sourceCoordinate(
            for: GimbalRelativeBearing(azimuthDegrees: -10, elevationDegrees: -5),
            cameraPose: pose,
            horizontalFieldOfViewDegrees: 86,
            poseProjection: .obsbotTiny2Lite
        )
        XCTAssertGreaterThan(imageRight?.normalizedX ?? 0, 0.5)
        let imageTop = SphericalPanoramaProjection.sourceCoordinate(
            for: GimbalRelativeBearing(azimuthDegrees: -20, elevationDegrees: 5),
            cameraPose: pose,
            horizontalFieldOfViewDegrees: 86,
            poseProjection: .obsbotTiny2Lite
        )
        XCTAssertLessThan(imageTop?.normalizedY ?? 1, 0.5)
        let imageBottom = SphericalPanoramaProjection.sourceCoordinate(
            for: GimbalRelativeBearing(azimuthDegrees: -20, elevationDegrees: -15),
            cameraPose: pose,
            horizontalFieldOfViewDegrees: 86,
            poseProjection: .obsbotTiny2Lite
        )
        XCTAssertGreaterThan(imageBottom?.normalizedY ?? 0, 0.5)
        XCTAssertTrue(SphericalPanoramaProjection.isDynamicallyMasked(
            sourceCoordinate: imageRight!,
            visionRects: [NormalizedRect(x: 0.5, y: 0.35, width: 0.2, height: 0.3)]
        ))
        XCTAssertTrue(SphericalPanoramaProjection.isDynamicallyMasked(
            sourceCoordinate: imageTop!,
            visionRects: [NormalizedRect(x: 0.45, y: 0.65, width: 0.1, height: 0.25)]
        ))
        XCTAssertFalse(SphericalPanoramaProjection.isDynamicallyMasked(
            sourceCoordinate: imageTop!,
            visionRects: [NormalizedRect(x: 0.45, y: 0.05, width: 0.1, height: 0.15)]
        ))
        XCTAssertNil(SphericalPanoramaProjection.sourceCoordinate(
            for: GimbalRelativeBearing(azimuthDegrees: 100, elevationDegrees: -5),
            cameraPose: pose,
            horizontalFieldOfViewDegrees: 86,
            poseProjection: .obsbotTiny2Lite
        ))
    }

    func testPanoramaRasterUsesAStandardWorldSphericalOrientation() {
        let upperLeft = SphericalPanoramaProjection.outputBearing(
            column: 0,
            row: 0,
            width: 100,
            height: 50,
            minimumElevationDegrees: -45,
            maximumElevationDegrees: 45
        )
        let lowerRight = SphericalPanoramaProjection.outputBearing(
            column: 99,
            row: 49,
            width: 100,
            height: 50,
            minimumElevationDegrees: -45,
            maximumElevationDegrees: 45
        )
        XCTAssertLessThan(upperLeft.azimuthDegrees, lowerRight.azimuthDegrees)
        XCTAssertGreaterThan(upperLeft.elevationDegrees, lowerRight.elevationDegrees)
    }

    func testPanoramaProjectionCouplesYawAndPitchOnTheSphere() {
        let coordinate = SphericalPanoramaProjection.sourceCoordinate(
            for: GimbalRelativeBearing(azimuthDegrees: 30, elevationDegrees: 30),
            cameraPose: GimbalPose(pitchDegrees: 30, panDegrees: 0, monotonicNS: 1),
            horizontalFieldOfViewDegrees: 86,
            poseProjection: .identity
        )
        XCTAssertNotNil(coordinate)
        XCTAssertGreaterThan(abs((coordinate?.normalizedY ?? 0.5) - 0.5), 0.01)
    }

    func testPanoramaQualityProtectsAStablePixelFromAFastPass() {
        XCTAssertEqual(
            PanoramaObservationQuality.motionQuality(angularVelocityDegreesPerSecond: 0),
            1,
            accuracy: 0.000_001
        )
        let fastQuality = PanoramaObservationQuality.motionQuality(
            angularVelocityDegreesPerSecond: 60
        )
        XCTAssertLessThan(fastQuality, 0.15)
        XCTAssertTrue(PanoramaObservationQuality.admitsProjection(
            angularVelocityDegreesPerSecond: 2.0
        ))
        XCTAssertFalse(PanoramaObservationQuality.admitsProjection(
            angularVelocityDegreesPerSecond: 2.001
        ))
        XCTAssertTrue(PanoramaObservationQuality.admitsCalibration(
            angularVelocityDegreesPerSecond: 0.75
        ))
        XCTAssertFalse(PanoramaObservationQuality.admitsCalibration(
            angularVelocityDegreesPerSecond: 0.751
        ))
        XCTAssertNil(PanoramaObservationQuality.continuousStripHalfWidthNormalized(
            angularVelocityDegreesPerSecond: 2.0,
            horizontalFieldOfViewDegrees: 62
        ))
        let strip = PanoramaObservationQuality.continuousStripHalfWidthNormalized(
            angularVelocityDegreesPerSecond: 20,
            horizontalFieldOfViewDegrees: 62
        )
        XCTAssertEqual(strip ?? 0, 7.0 / 124.0, accuracy: 0.000_001)
        let delayedStrip = PanoramaObservationQuality.continuousStripHalfWidthNormalized(
            angularVelocityDegreesPerSecond: 30,
            horizontalFieldOfViewDegrees: 62,
            admissionIntervalSeconds: 0.70
        )
        XCTAssertEqual(delayedStrip ?? 0, 23.0 / 124.0, accuracy: 0.000_001)
        XCTAssertGreaterThan(delayedStrip ?? 0, strip ?? 0)
        XCTAssertGreaterThanOrEqual(
            PanoramaObservationQuality.motionQuality(angularVelocityDegreesPerSecond: 18) * 0.78,
            0.45
        )
        XCTAssertLessThan(
            PanoramaObservationQuality.motionQuality(angularVelocityDegreesPerSecond: 30) * 0.78,
            0.45
        )
        XCTAssertNil(PanoramaObservationQuality.continuousStripHalfWidthNormalized(
            angularVelocityDegreesPerSecond: 40.001,
            horizontalFieldOfViewDegrees: 62
        ))
        XCTAssertFalse(PanoramaObservationQuality.shouldReplace(
            existingQuality: 0.9,
            incomingQuality: fastQuality
        ))
        XCTAssertTrue(PanoramaObservationQuality.shouldReplace(
            existingQuality: 0,
            incomingQuality: fastQuality
        ))
        XCTAssertFalse(PanoramaObservationQuality.shouldReplace(
            existingQuality: 0.9,
            incomingQuality: 0.89
        ))
        XCTAssertTrue(PanoramaObservationQuality.shouldReplace(
            existingQuality: 0.9,
            incomingQuality: 0.94
        ))
    }

    func testPanoramaReachabilitySeparatesPhysicalCoverageFromFullSphere() {
        let projection = CameraProjectionModel.pinhole(horizontalFieldOfViewDegrees: 62.4)
        XCTAssertTrue(SphericalPanoramaProjection.isReachable(
            GimbalRelativeBearing(azimuthDegrees: 130, elevationDegrees: 40),
            cameraProjectionModel: projection,
            poseProjection: .obsbotTiny2Lite
        ))
        XCTAssertFalse(SphericalPanoramaProjection.isReachable(
            GimbalRelativeBearing(azimuthDegrees: 175, elevationDegrees: 0),
            cameraProjectionModel: projection,
            poseProjection: .obsbotTiny2Lite
        ))
        XCTAssertFalse(SphericalPanoramaProjection.isReachable(
            GimbalRelativeBearing(azimuthDegrees: 0, elevationDegrees: 44.5),
            cameraProjectionModel: projection,
            poseProjection: .obsbotTiny2Lite
        ))
    }

    func testExplorationTimeoutDoesNotCutOffALongReachableStrip() {
        XCTAssertGreaterThan(
            SmoothExplorationDynamics.waypointTimeoutSeconds(
                panErrorDegrees: 220,
                pitchErrorDegrees: 0,
                maximumPanDegreesPerSecond: 12,
                maximumPitchDegreesPerSecond: 8
            ),
            19
        )
    }

    func testPanoramaRegistrationRefinesOnlyLocalPoseResiduals() {
        let width = 1_280
        let translationForTenDegrees = tan(10 * .pi / 180)
            / (2 * tan(43 * .pi / 180)) * Double(width)
        let refined = PanoramaPoseRefinement.refine(
            previousPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1),
            currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 9, monotonicNS: 2),
            alignmentTranslationX: translationForTenDegrees,
            alignmentTranslationY: 0,
            imageWidth: width,
            imageHeight: 720,
            horizontalFieldOfViewDegrees: 86,
            confidence: 1,
            poseProjection: .identity
        )
        XCTAssertTrue(refined.accepted)
        XCTAssertGreaterThan(refined.correctedPose.panDegrees, 9)
        XCTAssertLessThanOrEqual(refined.correctedPose.panDegrees, 10)
        XCTAssertLessThanOrEqual(abs(refined.panCorrectionDegrees), 86 * 0.04)

        let rejected = PanoramaPoseRefinement.refine(
            previousPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1),
            currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 9, monotonicNS: 2),
            alignmentTranslationX: 1_200,
            alignmentTranslationY: 0,
            imageWidth: width,
            imageHeight: 720,
            horizontalFieldOfViewDegrees: 86,
            confidence: 1,
            poseProjection: .identity
        )
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.correctedPose.panDegrees, 9, accuracy: 0.000_001)

        let lowConfidence = PanoramaPoseRefinement.refine(
            previousPose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1),
            currentPose: GimbalPose(pitchDegrees: 0, panDegrees: 9, monotonicNS: 2),
            alignmentTranslationX: translationForTenDegrees,
            alignmentTranslationY: 0,
            imageWidth: width,
            imageHeight: 720,
            horizontalFieldOfViewDegrees: 86,
            confidence: 0.4,
            poseProjection: .identity
        )
        XCTAssertFalse(lowConfidence.accepted)
        XCTAssertEqual(lowConfidence.correctedPose.panDegrees, 9, accuracy: 0.000_001)
    }

    func testCompatibleLearnedEmbeddingRevisitsOneSphericalCell() {
        let base = Array(1...24).map(Float.init)
        guard let embedding = PanoramaPlaceEmbedding(
            encoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
            revision: 2,
            values: base
        ), let scaledEmbedding = PanoramaPlaceEmbedding(
            encoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
            revision: 2,
            values: base.map { $0 * 3 }
        ) else {
            return XCTFail("expected valid learned place embeddings")
        }
        XCTAssertEqual(
            embedding.similarity(to: scaledEmbedding) ?? 0,
            1,
            accuracy: 0.000_001
        )

        let start: UInt64 = 44_000_000_000
        let pose = GimbalPose(pitchDegrees: 1, panDegrees: 3, monotonicNS: start)
        var field = SpatialCoverageField()
        let first = field.observePlace(
            embedding: embedding,
            pose: pose,
            observationQuality: 1,
            at: start
        )
        let revisit = field.observePlace(
            embedding: scaledEmbedding,
            pose: pose,
            observationQuality: 1,
            at: start + 1_000_000_000
        )
        XCTAssertFalse(first?.isRevisit ?? true)
        XCTAssertTrue(revisit?.isRevisit ?? false)
        XCTAssertEqual(first?.bearing, revisit?.bearing)
        XCTAssertEqual(revisit?.observationCount, 2)
        XCTAssertGreaterThan(revisit?.familiarity ?? 0, 0.999)

        let cells = field.snapshot(at: start + 1_000_000_000)
        let recognized = cells.filter { $0.placeObservationCount > 0 }
        XCTAssertEqual(recognized.count, 1)
        XCTAssertEqual(recognized.first?.placeObservationCount, 2)
        let unknown = cells.first { $0.placeObservationCount == 0 }
        XCTAssertGreaterThan(
            unknown?.expectedInformationGain ?? 0,
            recognized.first?.expectedInformationGain ?? 1
        )

        let memory = field.placeMemorySnapshot(generatedAtUnixMilliseconds: 123)
        var restoredField = SpatialCoverageField()
        XCTAssertEqual(restoredField.restorePlaceMemory(
            memory,
            expectedEncoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
            expectedRevision: 2
        ), 1)
        XCTAssertEqual(
            restoredField.snapshot(at: start + 2_000_000_000)
                .filter { $0.placeObservationCount > 0 }
                .first?.placeObservationCount,
            2
        )
    }

    func testIncompatiblePlaceEncoderCannotBecomeARevisit() {
        let pose = GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1)
        let revisionTwo = PanoramaPlaceEmbedding(
            encoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
            revision: 2,
            values: Array(repeating: 1, count: 16)
        )!
        let revisionThree = PanoramaPlaceEmbedding(
            encoder: PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder,
            revision: 3,
            values: Array(repeating: 1, count: 16)
        )!
        var field = SpatialCoverageField()
        XCTAssertFalse(field.observePlace(
            embedding: revisionTwo,
            pose: pose,
            observationQuality: 1,
            at: 1
        )!.isRevisit)
        let incompatible = field.observePlace(
            embedding: revisionThree,
            pose: pose,
            observationQuality: 1,
            at: 2
        )
        XCTAssertFalse(incompatible?.isRevisit ?? true)
        XCTAssertEqual(incompatible?.observationCount, 1)
    }

    func testPanoramaBackgroundAdmissionBridgesHumanDetectorGaps() {
        let start: UInt64 = 40_000_000_000
        XCTAssertTrue(PanoramaEntityMaskPolicy.shouldMask(.human))
        XCTAssertFalse(PanoramaEntityMaskPolicy.shouldMask(.object))
        XCTAssertFalse(PanoramaEntityMaskPolicy.shouldMask(.unknown))
        var admission = PanoramaBackgroundAdmission(humanHoldNS: 750_000_000)
        XCTAssertFalse(admission.admits(hasObservedHuman: true, at: start))
        XCTAssertFalse(admission.admits(hasObservedHuman: false, at: start + 749_999_999))
        XCTAssertTrue(admission.admits(hasObservedHuman: false, at: start + 750_000_000))
    }

    func testPanoramaQualityDeficitRemainsAnExplorationTarget() {
        let start: UInt64 = 12_500_000_000
        var field = SpatialCoverageField()
        for pitch in [-24.0, 24.0] {
            for pan in [-110.0, 0.0, 110.0] {
                field.observe(
                    pose: GimbalPose(pitchDegrees: pitch, panDegrees: pan, monotonicNS: start),
                    horizontalFieldOfViewDegrees: 86,
                    at: start
                )
            }
        }
        field.observePanorama(
            pose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
            horizontalFieldOfViewDegrees: 86,
            frameQuality: 1,
            dynamicVisionRects: [],
            poseProjection: .identity,
            at: start
        )
        let cells = field.snapshot(at: start)
        let centre = cells.first { $0.bearing.azimuthDegrees == 0 && $0.bearing.elevationDegrees == 0 }
        XCTAssertEqual(centre?.panoramaQuality ?? 0, 1, accuracy: 0.000_001)
        let selected = field.nextDirection(
            from: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
            at: start + 1_000_000
        )
        XCTAssertNotNil(selected)
        XCTAssertLessThan(selected?.panoramaQuality ?? 1, 0.1)
    }

    func testCoverageUsesCalibratedPrincipalPointAndMotorAxisSigns() {
        let start: UInt64 = 12_750_000_000
        let model = CameraProjectionModel(
            focalXNormalized: 0.824,
            focalYNormalized: 1.408,
            principalXNormalized: 0.60,
            principalYNormalized: 0.50
        )
        var field = SpatialCoverageField()
        field.observe(
            pose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start),
            horizontalFieldOfViewDegrees: 86,
            poseProjection: .obsbotTiny2Lite,
            cameraProjectionModel: model,
            at: start
        )
        let cells = field.snapshot(at: start)
        let positiveMotorCell = cells.first {
            $0.bearing.azimuthDegrees == 36 && $0.bearing.elevationDegrees == 0
        }
        let negativeMotorCell = cells.first {
            $0.bearing.azimuthDegrees == -36 && $0.bearing.elevationDegrees == 0
        }
        XCTAssertEqual(positiveMotorCell?.observationCount, 1)
        XCTAssertEqual(negativeMotorCell?.observationCount, 0)
    }

    func testCoverageFieldPrefersAnUnseenDirection() {
        let start: UInt64 = 12_000_000_000
        let origin = GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start)
        var field = SpatialCoverageField()
        field.observe(pose: origin, horizontalFieldOfViewDegrees: 86, at: start)
        guard let first = field.nextDirection(from: origin, at: start + 100_000_000) else {
            return XCTFail("expected an unseen exploration direction")
        }
        XCTAssertGreaterThan(abs(first.bearing.azimuthDegrees), 43)
        XCTAssertLessThanOrEqual(abs(first.bearing.elevationDegrees), 39)
        guard let sampled = field.sampleNextDirection(from: origin, at: start + 100_000_000, temperature: 1.4, uniform: 0) else {
            return XCTFail("expected a sampled unseen direction")
        }
        XCTAssertEqual(abs(sampled.bearing.elevationDegrees), 39, accuracy: 0.000_001)
        let sampledProbability = sampled.probability
        field.recordUnproductiveVisit(to: sampled)
        XCTAssertLessThan(
            field.sampleNextDirection(from: origin, at: start + 100_000_000, temperature: 1.4, uniform: 0)?.probability ?? 1,
            sampledProbability
        )
        XCTAssertNil(
            field.sampleNextDirection(from: origin, at: start + 100_000_000, temperature: 1.4, uniform: 0.999_999)
        )
        let explored = GimbalPose(
            pitchDegrees: first.bearing.elevationDegrees,
            panDegrees: first.bearing.azimuthDegrees,
            monotonicNS: start + 200_000_000
        )
        field.observe(pose: explored, horizontalFieldOfViewDegrees: 86, at: start + 200_000_000)
        XCTAssertNotEqual(
            field.nextDirection(from: explored, at: start + 300_000_000)?.bearing,
            first.bearing
        )
    }

    func testCoverageFieldInhibitsReturnToTheJustExploredRegion() {
        let start: UInt64 = 13_000_000_000
        let origin = GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start)
        var field = SpatialCoverageField()
        let selected = SpatialCoverageDirection(
            bearing: GimbalRelativeBearing(azimuthDegrees: -144, elevationDegrees: -39),
            probability: 1
        )
        let nearbyBearing = GimbalRelativeBearing(azimuthDegrees: -144, elevationDegrees: -26)
        let probabilityBefore = field.explorationProbability(
            for: nearbyBearing,
            from: origin,
            at: start + 1_000_000_000,
            temperature: 1
        )
        field.recordUnproductiveVisit(to: selected, at: start)
        // The nearby cell receives inhibition of return in addition to its
        // ordinary information value; a distant, otherwise equivalent cell is
        // left available for the next posterior draw.
        let probabilityAfter = field.explorationProbability(
            for: nearbyBearing,
            from: origin,
            at: start + 1_000_000_000,
            temperature: 1
        )
        XCTAssertLessThan(probabilityAfter ?? 1, probabilityBefore ?? 0)
        let probabilityAfterDecay = field.explorationProbability(
            for: nearbyBearing,
            from: origin,
            at: start + 76_000_000_000,
            temperature: 1
        )
        XCTAssertGreaterThan(probabilityAfterDecay ?? 0, probabilityAfter ?? 1)
        XCTAssertNotNil(field.sampleNextDirection(
            from: origin,
            at: start + 1_000_000_000,
            temperature: 1,
            uniform: 0.5
        ))
    }

    func testPanStallRecoveryRecentersOnlyAfterBothDirectionsFail() {
        var recovery = PanStallRecovery()
        XCTAssertEqual(
            recovery.record(requestedPanDegreesPerSecond: 180, observedMotionDegrees: 0.1),
            .reverse
        )
        XCTAssertEqual(
            recovery.record(requestedPanDegreesPerSecond: -180, observedMotionDegrees: 0.1),
            .recenter
        )
        XCTAssertEqual(
            recovery.record(requestedPanDegreesPerSecond: 180, observedMotionDegrees: 2),
            .none
        )
    }

    func testExplorationVelocityBlendsAcrossWaypointReversal() {
        let start: UInt64 = 12_000_000_000
        var dynamics = SmoothExplorationDynamics()
        let first = dynamics.advance(towardPitch: 40, pan: 120, at: start)
        let second = dynamics.advance(towardPitch: 40, pan: 120, at: start + 50_000_000)
        let reversed = dynamics.advance(towardPitch: -40, pan: -120, at: start + 100_000_000)

        XCTAssertEqual(first.pitchDegreesPerSecond, 4, accuracy: 0.000_001)
        XCTAssertEqual(first.panDegreesPerSecond, 6, accuracy: 0.000_001)
        XCTAssertEqual(second.pitchDegreesPerSecond, 8, accuracy: 0.000_001)
        XCTAssertEqual(second.panDegreesPerSecond, 12, accuracy: 0.000_001)
        XCTAssertEqual(reversed.pitchDegreesPerSecond, 4, accuracy: 0.000_001)
        XCTAssertEqual(reversed.panDegreesPerSecond, 6, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(reversed.panDegreesPerSecond, 0)
        var fastGesture = SmoothExplorationDynamics()
        let gestureStart = fastGesture.advance(
            towardPitch: 40,
            pan: 0,
            at: start,
            maximumPitchAcceleration: 420,
            maximumPanAcceleration: 760
        )
        XCTAssertEqual(gestureStart.pitchDegreesPerSecond, 21, accuracy: 0.000_001)
        XCTAssertEqual(gestureStart.panDegreesPerSecond, 0, accuracy: 0.000_001)
        XCTAssertEqual(
            SmoothExplorationDynamics.stoppingVelocity(
                errorDegrees: 2,
                maximumDegreesPerSecond: 60,
                accelerationDegreesPerSecondSquared: 120
            ),
            0
        )
        XCTAssertLessThan(
            SmoothExplorationDynamics.stoppingVelocity(
                errorDegrees: 12,
                maximumDegreesPerSecond: 60,
                accelerationDegreesPerSecondSquared: 120
            ),
            60
        )
        XCTAssertEqual(
            SmoothExplorationDynamics.waypointTimeoutSeconds(
                panErrorDegrees: 180,
                pitchErrorDegrees: 0
            ),
            3 / 0.45 + 1.5,
            accuracy: 0.000_001
        )
        XCTAssertTrue(
            SmoothExplorationDynamics.shouldBlendToNextWaypoint(
                panErrorDegrees: 6,
                pitchErrorDegrees: 8
            )
        )
        XCTAssertFalse(
            SmoothExplorationDynamics.shouldBlendToNextWaypoint(
                panErrorDegrees: 8,
                pitchErrorDegrees: 8
            )
        )
        let origin = GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: start)
        let envelope = GimbalKinematicEnvelope.obsbotTiny2Lite
        XCTAssertTrue(envelope.containsTrackingCenter(
            GimbalRelativeBearing(azimuthDegrees: 110.8, elevationDegrees: 24.8)
        ))
        XCTAssertFalse(envelope.containsTrackingCenter(
            GimbalRelativeBearing(azimuthDegrees: 126.1, elevationDegrees: 0)
        ))
        XCTAssertFalse(envelope.containsTrackingCenter(
            GimbalRelativeBearing(azimuthDegrees: 0, elevationDegrees: -34.1)
        ))
        let boundaryGuide = GimbalVisibilityRoutePlanner.guide(
            to: GimbalRelativeBearing(azimuthDegrees: 108, elevationDegrees: 30),
            from: origin
        )
        XCTAssertNotNil(boundaryGuide)
        if let boundaryGuide {
            XCTAssertGreaterThan(boundaryGuide.azimuthDegrees, 60)
            XCTAssertLessThan(boundaryGuide.azimuthDegrees, 110)
            XCTAssertGreaterThan(boundaryGuide.elevationDegrees, 0)
            XCTAssertLessThan(boundaryGuide.elevationDegrees, 24)
        }
        let nearestVisible = GimbalVisibilityRoutePlanner.guide(
            to: GimbalRelativeBearing(azimuthDegrees: 72, elevationDegrees: 0),
            from: origin
        )
        let panoramaCentred = GimbalVisibilityRoutePlanner.guide(
            to: GimbalRelativeBearing(azimuthDegrees: 72, elevationDegrees: 0),
            from: origin,
            observationPreference: .centered
        )
        XCTAssertLessThan(nearestVisible?.azimuthDegrees ?? .infinity, 72)
        XCTAssertEqual(panoramaCentred?.azimuthDegrees ?? 0, 72, accuracy: 0.000_001)
        let edgeVisiblePlan = GimbalVisibilityRoutePlanner.plan(
            to: GimbalRelativeBearing(azimuthDegrees: 140, elevationDegrees: 38),
            from: origin
        )
        XCTAssertNotNil(edgeVisiblePlan)
        XCTAssertLessThanOrEqual(
            abs(edgeVisiblePlan?.observationPose.azimuthDegrees ?? .infinity),
            GimbalKinematicEnvelope.obsbotTiny2Lite.maximumAutonomousPanDegrees
        )
        XCTAssertLessThanOrEqual(
            abs(edgeVisiblePlan?.observationPose.elevationDegrees ?? .infinity),
            GimbalKinematicEnvelope.obsbotTiny2Lite.maximumAutonomousPitchDegrees
        )
        XCTAssertNil(
            GimbalVisibilityRoutePlanner.guide(
                to: GimbalRelativeBearing(azimuthDegrees: 170, elevationDegrees: 0),
                from: origin
            )
        )
        let seamSafeGuide = GimbalVisibilityRoutePlanner.guide(
            to: GimbalRelativeBearing(azimuthDegrees: -108, elevationDegrees: 0),
            from: GimbalPose(pitchDegrees: 0, panDegrees: 100, monotonicNS: start)
        )
        XCTAssertNotNil(seamSafeGuide)
        if let seamSafeGuide {
            XCTAssertLessThan(seamSafeGuide.azimuthDegrees, 0)
        }
        let atlasSnapshot = SpatialCoverageField().snapshot(at: start + 300_000_000)
        XCTAssertTrue(atlasSnapshot.contains { abs($0.bearing.azimuthDegrees) > 110 })
        XCTAssertTrue(atlasSnapshot.contains { abs($0.bearing.elevationDegrees) > 30 })
        XCTAssertTrue(atlasSnapshot.allSatisfy { cell in
            GimbalVisibilityRoutePlanner.plan(to: cell.bearing, from: origin) != nil
        })
        let calibration = ExternalGimbalCalibration(
            panSign: 1,
            pitchSign: -1,
            maximumPanDegreesPerSecond: 180,
            maximumPitchDegreesPerSecond: 90
        )
        XCTAssertEqual(
            calibration.panCommand(forPoseError: 40, projection: .obsbotTiny2Lite),
            -40
        )
        XCTAssertEqual(
            calibration.pitchCommand(forPoseError: 20, projection: .obsbotTiny2Lite),
            20
        )
    }

    func testFringeEvidenceCannotBecomeAnOffscreenMotorTarget() {
        let start: UInt64 = 12_000_000_000
        var field = SceneField()
        for frame in 0...2 {
            _ = field.ingest(
                [VisualObservation(
                    rect: NormalizedRect(x: 0.35, y: 0.02, width: 0.06, height: 0.05),
                    confidence: 0.92,
                    source: .neuralDetector,
                    kind: .object,
                    label: "bottle"
                )],
                at: start + UInt64(frame) * 100_000_000,
                cameraPose: GimbalPose(
                    pitchDegrees: 0,
                    panDegrees: 0,
                    monotonicNS: start + UInt64(frame) * 100_000_000
                )
            )
        }
        let offscreen = field.ingest([], at: start + 400_000_000)
        XCTAssertFalse(offscreen[0].observedThisFrame)
    }

    func testIdleExplorationStartsOnceWithoutCalibration() {
        let start: UInt64 = 12_000_000_000
        var exploration = IdleExplorationGate()
        exploration.recordNoCalibratedTarget(at: start)
        XCTAssertEqual(exploration.nextScanEligibleAtNS, start + 450_000_000)
        XCTAssertEqual(exploration.beginIfEligible(at: start + 449_000_000), .none)
        XCTAssertEqual(
            exploration.beginIfEligible(at: start + 450_000_000),
            .velocity(pitchDegreesPerSecond: 0, panDegreesPerSecond: 180)
        )
        XCTAssertEqual(
            exploration.beginIfEligible(at: start + 2_000_000_000),
            .velocity(pitchDegreesPerSecond: 0, panDegreesPerSecond: 180)
        )
    }

    func testL1AuxiliaryAdmissionIsEventBoundedAndPeriodicallyRefreshed() {
        func context(
            at monotonicNS: UInt64,
            label: String? = nil,
            surprise: Double = 0
        ) -> L1AuxiliaryFrameContext {
            L1AuxiliaryFrameContext(
                captureNS: monotonicNS,
                trigger: "test",
                surprise: surprise,
                informationGain: 0,
                presenceProbability: label == nil ? 0 : 0.8,
                voiceProbability: 0,
                targetKind: label == nil ? nil : .human,
                targetLabel: label,
                targetProbability: label == nil ? 0 : 0.8,
                targetStatus: label == nil ? .none : .tracked
            )
        }

        let start: UInt64 = 30_000_000_000
        var gate = L1AuxiliarySemanticAdmissionGate()
        XCTAssertTrue(gate.admit(context(at: start)))
        XCTAssertFalse(gate.admit(context(at: start + 999_000_000, label: "face")))
        XCTAssertTrue(gate.admit(context(at: start + 1_000_000_000, label: "face")))
        XCTAssertFalse(gate.admit(context(at: start + 5_999_000_000, label: "face")))
        XCTAssertTrue(gate.admit(context(at: start + 6_000_000_000, label: "face")))
        XCTAssertTrue(gate.admit(context(at: start + 7_000_000_000, label: "face", surprise: 0.7)))
    }

    func testAuxiliaryFrameContextKeepsTheSourceHypothesisIdentity() throws {
        let context = L1AuxiliaryFrameContext(
            captureNS: 42_000_000_000,
            trigger: "test",
            surprise: 0,
            informationGain: 0.2,
            presenceProbability: 0.94,
            voiceProbability: 0,
            targetKind: .human,
            targetID: "scene-face-17",
            targetLabel: "face",
            targetProbability: 0.94,
            targetStatus: .tracked
        )
        XCTAssertEqual(context.targetID, "scene-face-17")
        XCTAssertEqual(
            try JSONDecoder().decode(
                L1AuxiliaryFrameContext.self,
                from: JSONEncoder().encode(context)
            ).targetID,
            "scene-face-17"
        )
    }

    func testL1AuxiliarySemanticInterruptRequiresConsistentCredibleEvidenceAndDebounces() {
        func cue(
            at monotonicNS: UInt64,
            situation: L1AuxiliarySituation,
            reason: L1AuxiliaryWakeReason,
            score: Double = 0.9,
            confidence: Double = 0.9
        ) -> L1AuxiliarySemanticCue {
            L1AuxiliarySemanticCue(
                requestID: monotonicNS,
                captureNS: monotonicNS,
                completedNS: monotonicNS,
                source: "test",
                summary: "bounded visible evidence",
                novelty: 0.8,
                socialPresence: situation == .socialBid ? 0.9 : 0,
                attentionHint: situation == .socialBid ? .person : .none,
                situation: situation,
                wakeReason: reason,
                wakeScore: score,
                confidence: confidence,
                inferenceMS: 100
            )
        }

        let start: UInt64 = 40_000_000_000
        var gate = L1AuxiliarySemanticInterruptGate()
        XCTAssertNil(gate.recommend(cue(at: start, situation: .ambient, reason: .none)))
        XCTAssertNil(gate.recommend(cue(at: start, situation: .socialBid, reason: .presentedObject)))
        XCTAssertNotNil(gate.recommend(cue(at: start, situation: .socialBid, reason: .directSocialBid)))
        XCTAssertNil(gate.recommend(cue(
            at: start + 4_999_000_000,
            situation: .socialBid,
            reason: .directSocialBid
        )))
        XCTAssertNotNil(gate.recommend(cue(
            at: start + 5_000_000_000,
            situation: .socialBid,
            reason: .directSocialBid
        )))
    }

    func testL1AuxiliaryTemporalSituationWakeRequiresPersistentEvidenceAndLatchesOneEpisode() {
        func cue(
            at monotonicNS: UInt64,
            socialPresence: Double = 0.95,
            eyeContact: Double = 0.95,
            engagement: Double = 0.90,
            novelty: Double = 0.10,
            conversationValue: Double = 0,
            situation: L1AuxiliarySituation = .ambient,
            confidence: Double = 0.90
        ) -> L1AuxiliarySemanticCue {
            L1AuxiliarySemanticCue(
                requestID: monotonicNS,
                captureNS: monotonicNS,
                completedNS: monotonicNS,
                source: "test",
                summary: "bounded temporal evidence",
                novelty: novelty,
                socialPresence: socialPresence,
                attentionHint: socialPresence > 0 ? .person : .none,
                situation: situation,
                wakeReason: .none,
                wakeScore: 0.1,
                confidence: confidence,
                eyeContact: eyeContact,
                engagement: engagement,
                conversationValue: conversationValue,
                inferenceMS: 100
            )
        }

        let start: UInt64 = 50_000_000_000
        var gate = L1AuxiliaryTemporalSituationGate()
        XCTAssertNil(gate.recommend(cue(at: start)))
        XCTAssertNil(gate.recommend(cue(at: start + 5_000_000_000)))
        let interrupt = gate.recommend(cue(at: start + 10_000_000_000))
        XCTAssertEqual(interrupt?.reason, .temporalContext)
        XCTAssertGreaterThanOrEqual(interrupt?.score ?? 0, 0.62)
        XCTAssertTrue(interrupt?.evidence.contains("temporal_theme=social_availability") ?? false)

        XCTAssertNil(gate.recommend(cue(at: start + 15_000_000_000)))
        XCTAssertNil(gate.recommend(cue(at: start + 20_000_000_000)))

        // A quiet interval discharges the latch; a new sustained episode may
        // later make one fresh proposal.
        XCTAssertNil(gate.recommend(cue(
            at: start + 25_000_000_000,
            socialPresence: 0,
            eyeContact: 0,
            engagement: 0
        )))
        XCTAssertNil(gate.recommend(cue(
            at: start + 30_000_000_000,
            socialPresence: 0,
            eyeContact: 0,
            engagement: 0
        )))
        XCTAssertNil(gate.recommend(cue(at: start + 35_000_000_000)))
        XCTAssertNotNil(gate.recommend(cue(at: start + 40_000_000_000)))

        var alreadyHandled = L1AuxiliaryTemporalSituationGate()
        alreadyHandled.markHandled(cue(at: start))
        XCTAssertNil(alreadyHandled.recommend(cue(at: start + 5_000_000_000)))
        XCTAssertNil(alreadyHandled.recommend(cue(at: start + 10_000_000_000)))

        var gapReset = L1AuxiliaryTemporalSituationGate()
        XCTAssertNil(gapReset.recommend(cue(at: start)))
        XCTAssertNil(gapReset.recommend(cue(at: start + 20_000_000_000)))
        XCTAssertNil(gapReset.recommend(cue(at: start + 25_000_000_000)))
        XCTAssertNotNil(gapReset.recommend(cue(at: start + 30_000_000_000)))
    }

    func testL1AuxiliaryTemporalSituationWakeDoesNotCombineDifferentContexts() {
        func cue(
            at monotonicNS: UInt64,
            social: Bool,
            scene: Bool
        ) -> L1AuxiliarySemanticCue {
            L1AuxiliarySemanticCue(
                requestID: monotonicNS,
                captureNS: monotonicNS,
                completedNS: monotonicNS,
                source: "test",
                summary: "bounded temporal evidence",
                novelty: scene ? 0.95 : 0.1,
                socialPresence: social ? 0.95 : 0,
                attentionHint: social ? .person : (scene ? .object : .none),
                situation: scene ? .sceneTransition : .ambient,
                wakeReason: .none,
                wakeScore: 0.1,
                confidence: 0.90,
                eyeContact: social ? 0.95 : 0,
                engagement: social ? 0.90 : 0,
                conversationValue: scene ? 0.95 : 0,
                inferenceMS: 100
            )
        }

        let start: UInt64 = 60_000_000_000
        var gate = L1AuxiliaryTemporalSituationGate()
        XCTAssertNil(gate.recommend(cue(at: start, social: true, scene: false)))
        XCTAssertNil(gate.recommend(cue(at: start + 5_000_000_000, social: false, scene: true)))
        XCTAssertNil(gate.recommend(cue(at: start + 10_000_000_000, social: true, scene: false)))
        XCTAssertNil(gate.recommend(cue(at: start + 15_000_000_000, social: true, scene: false)))
    }
}
#endif
