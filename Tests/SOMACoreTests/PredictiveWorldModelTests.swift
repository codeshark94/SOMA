#if canImport(XCTest)
import XCTest
@testable import SOMACore

final class PredictiveWorldModelTests: XCTestCase {
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

    func testExplorationFaceInterceptionIsBoundedToRepeatedHighConfidenceEvidence() {
        XCTAssertFalse(FaceLockLease.permitsProvisionalExplorationInterception(
            observationCount: 1,
            confidence: 0.99
        ))
        XCTAssertFalse(FaceLockLease.permitsProvisionalExplorationInterception(
            observationCount: 3,
            confidence: 0.89
        ))
        XCTAssertTrue(FaceLockLease.permitsProvisionalExplorationInterception(
            observationCount: 2,
            confidence: 0.90
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
            source: .neuralFaceDetector,
            kind: .human,
            label: "face",
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
            guard case let .velocity(pitch, _) = stalledVerticalGate.update(belief) else {
                return XCTFail("stalled vertical target did not preserve pan observation")
            }
            XCTAssertNotEqual(pitch, 0)
        }
        let stalledVerticalBelief = stalledVerticalModel.ingestVisual(
            stalledVerticalObservation,
            at: 7_500_000_000
        )
        guard case let .velocity(stalledPitch, stalledPan) = stalledVerticalGate.update(stalledVerticalBelief) else {
            return XCTFail("stalled vertical target did not retain pan-only observation")
        }
        XCTAssertEqual(stalledPitch, 0)
        XCTAssertNotEqual(stalledPan, 0)

        let movingVerticalBelief = stalledVerticalModel.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.70, y: 0.02, width: 0.15, height: 0.15),
                confidence: 0.90,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                posteriorProbability: 0.80,
                sceneID: "stalled-top-face",
                stabilityMilliseconds: 500,
                isActionEligible: true
            ),
            at: 7_600_000_000
        )
        guard case let .velocity(movingPitch, _) = stalledVerticalGate.update(movingVerticalBelief) else {
            return XCTFail("a vertically moving face lost its tracking command")
        }
        XCTAssertNotEqual(movingPitch, 0)

        _ = model.ingestVisionMiss(at: 7_100_000_000)
        XCTAssertEqual(fixation.recordVisualLoss(at: 7_100_000_000), .none)

        var scan = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: true)
        XCTAssertEqual(scan.recordVisualLoss(at: 8_000_000_000), .none)
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
        XCTAssertEqual(weightedScene.first?.observation.attentionWeight, 0.9, accuracy: 0.000_001)

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
                isActionEligible: true
            )],
            at: start,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 20, monotonicNS: start),
            horizontalFieldOfViewDegrees: 70
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
                isActionEligible: true
            )],
            at: start + 1_000_000_000,
            cameraPose: GimbalPose(pitchDegrees: 0, panDegrees: 50, monotonicNS: start + 1_000_000_000),
            horizontalFieldOfViewDegrees: 70
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
            horizontalFieldOfViewDegrees: 70
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

    func testGimbalPoseFreshnessRequiresACaptureAlignedSample() {
        let pose = GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: 1_000_000_000)
        XCTAssertTrue(pose.isFresh(for: 1_050_000_000, maximumAgeNS: 50_000_000))
        XCTAssertFalse(pose.isFresh(for: 1_050_000_001, maximumAgeNS: 50_000_000))
        XCTAssertFalse(pose.isFresh(for: 999_999_999, maximumAgeNS: 50_000_000))
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
        XCTAssertLessThanOrEqual(abs(first.bearing.elevationDegrees), 30)
        guard let sampled = field.sampleNextDirection(from: origin, at: start + 100_000_000, temperature: 1.4, uniform: 0) else {
            return XCTFail("expected a sampled unseen direction")
        }
        XCTAssertEqual(abs(sampled.bearing.elevationDegrees), 30, accuracy: 0.000_001)
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
            4.5,
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

    func testL05AdmissionIsEventBoundedAndPeriodicallyRefreshed() {
        func context(
            at monotonicNS: UInt64,
            label: String? = nil,
            surprise: Double = 0
        ) -> L05FrameContext {
            L05FrameContext(
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
        var gate = L05SemanticAdmissionGate()
        XCTAssertTrue(gate.admit(context(at: start)))
        XCTAssertFalse(gate.admit(context(at: start + 999_000_000, label: "face")))
        XCTAssertTrue(gate.admit(context(at: start + 1_000_000_000, label: "face")))
        XCTAssertFalse(gate.admit(context(at: start + 5_999_000_000, label: "face")))
        XCTAssertTrue(gate.admit(context(at: start + 6_000_000_000, label: "face")))
        XCTAssertTrue(gate.admit(context(at: start + 7_000_000_000, label: "face", surprise: 0.7)))
    }
}
#endif
