#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class CognitiveEmbodimentTests: XCTestCase {
    func testEveryCognitiveLayerCanIssueTheSameLeasedTrackingGoal() throws {
        for layer in CognitiveControlLayer.allCases {
            let request = makeRequest(
                layer: layer,
                operation: .trackTarget(
                    TrackTargetGoal(
                        targetReference: "target:cup",
                        reacquireIfOccluded: true,
                        motionStyle: .attentive
                    )
                )
            )
            XCTAssertNoThrow(try request.validate())
        }
    }

    func testCognitiveAuthorityHasOnlyL1AndL2() {
        XCTAssertEqual(CognitiveControlLayer.allCases, [.l1, .l2])
    }

    func testTargetLabelsAndAttentionPriorsRoundTripAsStableJSON() throws {
        let registration = makeRequest(
            layer: .l1,
            operation: .registerTarget(
                SemanticTargetRegistration(
                    targetReference: "target:red-cup",
                    sceneID: "scene-42",
                    label: "red cup",
                    aliases: ["cup", "mug"],
                    visualQuery: "the red cup beside the keyboard",
                    expectedKind: .object,
                    initialSelectionLogPrior: 2.5
                )
            )
        )
        try registration.validate()
        let data = try JSONEncoder().encode(registration)
        let decoded = try JSONDecoder().decode(CognitiveEmbodimentRequest.self, from: data)
        XCTAssertEqual(decoded, registration)

        let policy = AttentionPolicyGoal(
            targets: [
                TargetAttentionDirective(
                    targetReference: "target:red-cup",
                    selectionLogPrior: 2,
                    trackingCommitment: 0.9
                ),
                TargetAttentionDirective(
                    targetReference: "target:door",
                    selectionLogPrior: -1,
                    trackingCommitment: 0.2
                ),
            ],
            selectionTemperature: 0.7,
            noveltyStrength: 0.8,
            habituationStrength: 0.6
        )
        XCTAssertEqual(policy.normalizedTargetPriors.values.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertGreaterThan(
            policy.normalizedTargetPriors["target:red-cup"] ?? 0,
            policy.normalizedTargetPriors["target:door"] ?? 1
        )
    }

    func testExplorationPolicyControlsRegionsDirectionsAndMotionCharacter() throws {
        let policy = ExplorationPolicyGoal(
            mode: .memoryGap,
            regions: [
                SphericalSearchRegion(
                    center: GimbalRelativeBearing(azimuthDegrees: -45, elevationDegrees: 5),
                    azimuthRadiusDegrees: 35,
                    elevationRadiusDegrees: 20,
                    preference: 0.9
                )
            ],
            preferredDirections: [
                DirectionalPreference(
                    bearing: GimbalRelativeBearing(azimuthDegrees: -60, elevationDegrees: 0),
                    concentration: 4,
                    weight: 3
                ),
                DirectionalPreference(
                    bearing: GimbalRelativeBearing(azimuthDegrees: 40, elevationDegrees: 10),
                    concentration: 2,
                    weight: 1
                ),
            ],
            coverageStrength: 0.4,
            noveltyStrength: 0.7,
            memoryGapStrength: 1,
            motionContinuity: 0.95,
            tempo: 0.65,
            dwellMilliseconds: 500
        )
        let request = makeRequest(layer: .l1, operation: .explore(policy))
        XCTAssertNoThrow(try request.validate())
        XCTAssertEqual(policy.normalizedDirectionWeights, [0.75, 0.25])
    }

    func testInvalidOrUnboundedLeaseIsRejected() {
        let request = CognitiveEmbodimentRequest(
            requestID: "invalid",
            layer: .l2,
            reason: "track requested object",
            evidenceIDs: [],
            lease: EmbodimentLease(
                ownerID: "l2:session",
                priority: 100,
                issuedAtNS: 1,
                durationMilliseconds: 600_001,
                cancellationToken: "cancel:invalid"
            ),
            operation: .trackTarget(TrackTargetGoal(targetReference: "target:object"))
        )
        XCTAssertThrowsError(try request.validate())
    }

    func testShadowArbiterRequiresRegistrationAndPreemptsOnlyByPriority() {
        let now: UInt64 = 5_000_000_000
        let arbiter = ShadowEmbodimentArbiter()
        let unknown = shadowRequest(
            id: "track-unknown",
            layer: .l1,
            owner: "l1:e4b",
            priority: 40,
            now: now,
            operation: .trackTarget(TrackTargetGoal(targetReference: "target:person"))
        )
        XCTAssertEqual(arbiter.submit(unknown, at: now).reason, "tracking_target_unknown")

        let registration = shadowRequest(
            id: "register-person",
            layer: .l1,
            owner: "l1:e4b",
            priority: 40,
            now: now,
            operation: .registerTarget(
                SemanticTargetRegistration(
                    targetReference: "target:person",
                    sceneID: "scene:person",
                    label: "person",
                    expectedKind: .human
                )
            )
        )
        XCTAssertEqual(arbiter.submit(registration, at: now).status, .accepted)

        let tracking = shadowRequest(
            id: "track-person",
            layer: .l1,
            owner: "l1:e4b",
            priority: 40,
            now: now,
            operation: .trackTarget(TrackTargetGoal(targetReference: "target:person"))
        )
        XCTAssertEqual(arbiter.submit(tracking, at: now).status, .accepted)

        let lowerPriority = shadowRequest(
            id: "explore-lower",
            layer: .l1,
            owner: "l1:situation",
            priority: 40,
            now: now,
            operation: .explore(ExplorationPolicyGoal(mode: .noveltySeeking))
        )
        XCTAssertEqual(arbiter.submit(lowerPriority, at: now).status, .rejected)

        let higherPriority = shadowRequest(
            id: "orient-higher",
            layer: .l2,
            owner: "l2:dialogue",
            priority: 90,
            now: now,
            operation: .orient(OrientGoal(bearing: .init(azimuthDegrees: 20, elevationDegrees: 5)))
        )
        let preempted = arbiter.submit(higherPriority, at: now)
        XCTAssertEqual(preempted.status, .accepted)
        XCTAssertEqual(preempted.preemptedRequestID, "track-person")
        XCTAssertEqual(preempted.snapshot.activeRequestID, "orient-higher")
        XCTAssertFalse(preempted.snapshot.physicalActuationEnabled)
    }

    func testShadowArbiterExpiresOwnedStateAndReleaseIsOwnerScoped() {
        let now: UInt64 = 9_000_000_000
        let arbiter = ShadowEmbodimentArbiter()
        let registration = shadowRequest(
            id: "register",
            layer: .l1,
            owner: "l1:context",
            priority: 50,
            now: now,
            durationMilliseconds: 100,
            operation: .registerTarget(
                SemanticTargetRegistration(
                    targetReference: "target:door",
                    sceneID: "scene:door",
                    label: "door"
                )
            )
        )
        XCTAssertEqual(arbiter.submit(registration, at: now).status, .accepted)
        XCTAssertEqual(arbiter.snapshot(at: now + 99_000_000).registeredTargets.count, 1)
        XCTAssertTrue(arbiter.snapshot(at: now + 100_000_000).registeredTargets.isEmpty)

        let release = shadowRequest(
            id: "release",
            layer: .l1,
            owner: "l1:context",
            priority: 50,
            now: now + 200_000_000,
            operation: .release
        )
        XCTAssertEqual(arbiter.submit(release, at: now + 200_000_000).status, .released)
    }

    func testShadowUnixSocketRoundTripIsOwnerOnlyAndNonActuating() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/soma-ipc-\(suffix)", isDirectory: true)
        let socketURL = directory.appendingPathComponent("shadow.sock")
        let server = EmbodimentShadowSocketServer(socketURL: socketURL)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let snapshotReply = try EmbodimentShadowSocketClient.send(
            EmbodimentIPCCommand(kind: .snapshot),
            socketURL: socketURL
        )
        XCTAssertTrue(snapshotReply.ok)
        XCTAssertEqual(snapshotReply.snapshot?.mode, "shadow")
        XCTAssertEqual(snapshotReply.snapshot?.physicalActuationEnabled, false)

        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let now = DispatchTime.now().uptimeNanoseconds
        let registration = shadowRequest(
            id: "socket-register",
            layer: .l1,
            owner: "l1:e4b-socket",
            priority: 45,
            now: now,
            operation: .registerTarget(
                SemanticTargetRegistration(
                    targetReference: "target:socket-person",
                    sceneID: "scene:socket-person",
                    label: "person",
                    expectedKind: .human
                )
            )
        )
        let reply = try EmbodimentShadowSocketClient.send(
            EmbodimentIPCCommand(kind: .submit, request: registration),
            socketURL: socketURL
        )
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.decision?.status, .accepted)
        XCTAssertEqual(reply.snapshot?.registeredTargets.first?.targetReference, "target:socket-person")
        XCTAssertEqual(reply.snapshot?.physicalActuationEnabled, false)
    }

    func testPersonContextUsesTheOwnerOnlySocketInsteadOfASecondMemoryStore() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/soma-person-context-ipc-\(suffix)", isDirectory: true)
        let socketURL = directory.appendingPathComponent("shadow.sock")
        let personID = UUID()
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            personContextProvider: { request in
                guard request.operation == .setPreferredLanguage,
                      request.confirmedByUser,
                      request.personEntityID == personID,
                      request.languageTag == "zh-Hans" else {
                    return .failure(EmbodimentIPCError.malformedMessage)
                }
                return .success(PersonContextSnapshot(
                    personEntityID: personID,
                    preferredLanguageTag: "zh-Hans",
                    proactiveContactPreference: .unknown,
                    rapport: nil,
                    facts: ["preferred_language": "zh-Hans"]
                ))
            }
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let reply = try EmbodimentShadowSocketClient.send(
            .init(kind: .personContext, personContext: PersonContextIPCRequest(
                operation: .setPreferredLanguage,
                personEntityID: personID,
                languageTag: "zh-Hans",
                confirmedByUser: true
            )),
            socketURL: socketURL
        )
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.personContext?.preferredLanguageTag, "zh-Hans")
        XCTAssertNil(reply.snapshot)
    }

    func testSemanticTargetBindingPreservesExplicitSceneIdentityOffscreen() {
        var binder = SemanticTargetBindingEngine()
        let registration = SemanticTargetRegistration(
            targetReference: "target:known-person",
            sceneID: "scene-person-7",
            label: "known person",
            expectedKind: .human
        )
        let visible = sceneEntity(
            id: "scene-person-7",
            kind: .human,
            label: "person",
            observed: true
        )
        let bound = binder.resolve(registrations: [registration], entities: [visible])
        XCTAssertEqual(bound.first?.status, .bound)
        XCTAssertEqual(bound.first?.sceneID, "scene-person-7")
        XCTAssertEqual(bound.first?.posteriorProbability, 1)

        let offscreen = sceneEntity(
            id: "scene-person-7",
            kind: .human,
            label: "person",
            observed: false,
            lastSeenMilliseconds: 45_000
        )
        let retained = binder.resolve(registrations: [registration], entities: [offscreen])
        XCTAssertEqual(retained.first?.status, .retained)
        XCTAssertEqual(retained.first?.sceneID, "scene-person-7")
        XCTAssertEqual(retained.first?.reason, "explicit_scene_retained")
    }

    func testDescriptorBindingSurfacesAmbiguityInsteadOfInventingIdentity() {
        var binder = SemanticTargetBindingEngine()
        let registration = SemanticTargetRegistration(
            targetReference: "target:visitor",
            label: "visitor",
            aliases: ["person"],
            visualQuery: "the visitor in front of the camera",
            expectedKind: .human,
            initialSelectionLogPrior: 2
        )
        let bindings = binder.resolve(
            registrations: [registration],
            entities: [
                sceneEntity(id: "scene-person-a", kind: .human, label: "person", observed: true),
                sceneEntity(id: "scene-person-b", kind: .human, label: "person", observed: true),
            ]
        )
        XCTAssertEqual(bindings.first?.status, .ambiguous)
        XCTAssertNil(bindings.first?.sceneID)
        XCTAssertGreaterThan(bindings.first?.normalizedEntropy ?? 0, 0.5)
    }

    func testDescriptorAliasesAreExplicitAndLanguageAgnostic() {
        var binder = SemanticTargetBindingEngine()
        let registration = SemanticTargetRegistration(
            targetReference: "target:guest",
            label: "손님",
            aliases: ["PERSON", "visiteur"],
            visualQuery: "the current guest",
            expectedKind: .human,
            initialSelectionLogPrior: 3
        )
        let binding = binder.resolve(
            registrations: [registration],
            entities: [sceneEntity(id: "scene-guest", kind: .human, label: "person", observed: true)]
        ).first
        XCTAssertEqual(binding?.status, .bound)
        XCTAssertEqual(binding?.sceneID, "scene-guest")
    }

    func testArbiterPublishesOnlySemanticBindingTransitions() {
        let now: UInt64 = 20_000_000_000
        let arbiter = ShadowEmbodimentArbiter()
        let registration = shadowRequest(
            id: "binding-register",
            layer: .l1,
            owner: "l1:binding",
            priority: 60,
            now: now,
            operation: .registerTarget(
                SemanticTargetRegistration(
                    targetReference: "target:cup",
                    sceneID: "scene-cup",
                    label: "cup",
                    expectedKind: .object
                )
            )
        )
        XCTAssertEqual(arbiter.submit(registration, at: now).status, .accepted)
        let entity = sceneEntity(id: "scene-cup", kind: .object, label: "cup", observed: true)
        let first = arbiter.updateScene([entity], at: now + 1)
        XCTAssertEqual(first.map(\.status), [.bound])
        XCTAssertTrue(arbiter.updateScene([entity], at: now + 2).isEmpty)
        let snapshot = arbiter.snapshot(at: now + 3)
        XCTAssertEqual(snapshot.sceneEntityCount, 1)
        XCTAssertEqual(snapshot.targetBindings.first?.sceneID, "scene-cup")
        XCTAssertFalse(snapshot.physicalActuationEnabled)
    }

    func testArbiterPublishesSharedSphericalAtlasAndRememberedBearings() {
        let now: UInt64 = 25_000_000_000
        let atlas = SphericalSceneAtlasStore()
        let panorama = PanoramaMapStatusStore()
        let arbiter = ShadowEmbodimentArbiter(spatialAtlas: atlas, panoramaStatus: panorama)
        panorama.update(PanoramaMapStatus(
            state: "ready",
            imagePath: "/tmp/panorama.jpg",
            metadataPath: "/tmp/panorama.json",
            width: 1024,
            height: 256,
            minimumElevationDegrees: -45,
            maximumElevationDegrees: 45,
            revision: 2,
            acceptedFrames: 8,
            poseInterpolationMisses: 1,
            dynamicallyMaskedPixels: 32,
            coverageFraction: 0.4,
            lastUpdatedNS: now
        ))
        atlas.observe(
            pose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: now),
            horizontalFieldOfViewDegrees: 86,
            at: now
        )
        _ = arbiter.updateScene([
            sceneEntity(
                id: "scene:offscreen-person",
                kind: .human,
                label: "person",
                observed: false,
                lastSeenMilliseconds: 120_000
            )
        ], at: now + 1)

        let snapshot = arbiter.snapshot(at: now + 2)
        XCTAssertEqual(snapshot.schemaVersion, 4)
        XCTAssertEqual(snapshot.spatialAtlas.schemaVersion, 4)
        XCTAssertEqual(snapshot.spatialAtlas.restoredPlaceCount, 0)
        XCTAssertEqual(snapshot.spatialAtlas.persistedPlaceCount, 0)
        XCTAssertGreaterThan(snapshot.spatialAtlas.observedCellCount, 0)
        XCTAssertTrue(snapshot.spatialAtlas.cells.contains { abs($0.bearing.azimuthDegrees) > 110 })
        XCTAssertTrue(snapshot.spatialAtlas.cells.allSatisfy {
            (0...1).contains($0.expectedInformationGain)
        })
        XCTAssertEqual(snapshot.spatialAtlas.entities.first?.sceneID, "scene:offscreen-person")
        XCTAssertEqual(
            snapshot.spatialAtlas.kinematicEnvelope,
            GimbalKinematicEnvelope.obsbotTiny2Lite
        )
        XCTAssertEqual(snapshot.panorama?.revision, 2)
        XCTAssertEqual(snapshot.panorama?.schemaVersion, 7)
        XCTAssertEqual(snapshot.panorama?.coverageFraction ?? 0, 0.4, accuracy: 0.000_001)
    }

    func testPhysicalMotorCoordinatorPreemptsAndExpiresWithoutBypassingL0() {
        let now: UInt64 = 30_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let first = shadowRequest(
            id: "orient-first",
            layer: .l1,
            owner: "l1:situation",
            priority: 40,
            now: now,
            durationMilliseconds: 200,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: 25, elevationDegrees: 4),
                motionStyle: .smooth
            ))
        )
        let firstDecision = arbiter.submit(first, at: now)
        XCTAssertTrue(firstDecision.snapshot.physicalActuationEnabled)
        XCTAssertEqual(firstDecision.snapshot.mode, "active")
        guard case let .orient(requestID, bearing, _, _, expiresAtNS, _) = coordinator.apply(
            request: first,
            decision: firstDecision,
            at: now
        ) else {
            return XCTFail("accepted orientation must become an L0 semantic motor intent")
        }
        XCTAssertEqual(requestID, first.requestID)
        XCTAssertEqual(bearing.azimuthDegrees, 25)
        XCTAssertEqual(expiresAtNS, now + 200_000_000)

        let second = shadowRequest(
            id: "orient-second",
            layer: .l2,
            owner: "l2:dialogue",
            priority: 90,
            now: now + 1,
            durationMilliseconds: 100,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: -15, elevationDegrees: 0),
                motionStyle: .attentive
            ))
        )
        let secondDecision = arbiter.submit(second, at: now + 1)
        XCTAssertEqual(secondDecision.preemptedRequestID, first.requestID)
        guard case let .orient(requestID, bearing, _, _, _, _) = coordinator.apply(
            request: second,
            decision: secondDecision,
            at: now + 1
        ) else {
            return XCTFail("higher-priority goal must replace the current semantic intent")
        }
        XCTAssertEqual(requestID, second.requestID)
        XCTAssertEqual(bearing.azimuthDegrees, -15)
        XCTAssertNil(coordinator.expire(at: now + 100_000_000))
        XCTAssertEqual(
            coordinator.expire(at: now + 100_000_001),
            .release(requestID: second.requestID, reason: "lease_expired")
        )
    }

    func testPhysicalTrackingSuspendsUntilOneRegisteredSceneBindingIsGrounded() {
        let now: UInt64 = 40_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let registration = shadowRequest(
            id: "register-cup",
            layer: .l1,
            owner: "l1:context",
            priority: 50,
            now: now,
            operation: .registerTarget(SemanticTargetRegistration(
                targetReference: "target:cup",
                sceneID: "scene:cup",
                label: "cup",
                expectedKind: .object
            ))
        )
        XCTAssertEqual(arbiter.submit(registration, at: now).status, .accepted)
        let track = shadowRequest(
            id: "track-cup",
            layer: .l1,
            owner: "l1:context",
            priority: 50,
            now: now + 1,
            operation: .trackTarget(TrackTargetGoal(targetReference: "target:cup"))
        )
        let ungroundedDecision = arbiter.submit(track, at: now + 1)
        XCTAssertEqual(
            coordinator.apply(request: track, decision: ungroundedDecision, at: now + 1),
            .suspend(
                requestID: track.requestID,
                reason: "target_binding_unavailable",
                expiresAtNS: track.lease.expiresAtNS
            )
        )

        _ = arbiter.updateScene([
            EmbodimentSceneEntity(
                sceneID: "scene:cup",
                kind: .object,
                label: "cup",
                confidence: 0.91,
                observedThisFrame: true,
                actionEligible: false,
                bearing: .init(azimuthDegrees: 35, elevationDegrees: -3),
                spatialConfidence: 0.92,
                lastSeenMilliseconds: 0
            )
        ], at: now + 2)
        guard case let .track(_, reference, sceneID, bearing, observed, _, _) = coordinator.update(
            snapshot: arbiter.snapshot(at: now + 3),
            at: now + 3
        ) else {
            return XCTFail("an explicit high-level target may move only after one scene binding is grounded")
        }
        XCTAssertEqual(reference, "target:cup")
        XCTAssertEqual(sceneID, "scene:cup")
        XCTAssertEqual(bearing.azimuthDegrees, 35)
        XCTAssertTrue(observed)
    }

    func testPhysicalReleaseIsOwnerScoped() {
        let now: UInt64 = 50_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orient = shadowRequest(
            id: "owner-orient",
            layer: .l1,
            owner: "l1:owner",
            priority: 50,
            now: now,
            operation: .orient(OrientGoal(bearing: .init(azimuthDegrees: 10, elevationDegrees: 0)))
        )
        _ = coordinator.apply(request: orient, decision: arbiter.submit(orient, at: now), at: now)

        let foreignRelease = shadowRequest(
            id: "foreign-release",
            layer: .l2,
            owner: "l2:other",
            priority: 90,
            now: now + 1,
            operation: .release
        )
        XCTAssertNil(coordinator.apply(
            request: foreignRelease,
            decision: arbiter.submit(foreignRelease, at: now + 1),
            at: now + 1
        ))
        XCTAssertEqual(coordinator.activeRequestID, orient.requestID)

        let ownerRelease = shadowRequest(
            id: "owner-release",
            layer: .l1,
            owner: "l1:owner",
            priority: 50,
            now: now + 2,
            operation: .release
        )
        XCTAssertEqual(
            coordinator.apply(
                request: ownerRelease,
                decision: arbiter.submit(ownerRelease, at: now + 2),
                at: now + 2
            ),
            .release(requestID: orient.requestID, reason: "owner_released")
        )
    }

    func testCaptureViewIsAOneShotMotorGoalThatPreservesOwnerMemory() {
        let now: UInt64 = 60_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let registration = shadowRequest(
            id: "capture-register",
            layer: .l1,
            owner: "l1:context",
            priority: 60,
            now: now,
            durationMilliseconds: 20_000,
            operation: .registerTarget(SemanticTargetRegistration(
                targetReference: "target:desk",
                sceneID: "scene:desk",
                label: "desk"
            ))
        )
        XCTAssertEqual(arbiter.submit(registration, at: now).status, .accepted)
        let capture = shadowRequest(
            id: "capture-bearing",
            layer: .l1,
            owner: "l1:context",
            priority: 60,
            now: now + 1,
            durationMilliseconds: 5_000,
            operation: .captureView(CaptureViewGoal(
                bearing: .init(azimuthDegrees: -32, elevationDegrees: 7),
                fieldOfViewDegrees: 40
            ))
        )
        let decision = arbiter.submit(capture, at: now + 1)
        guard case let .capture(requestID, reference, sceneID, bearing, fov, expiresAtNS) = coordinator.apply(
            request: capture,
            decision: decision,
            at: now + 1
        ) else {
            return XCTFail("capture must retain its own alignment and frame-acquisition intent")
        }
        XCTAssertEqual(requestID, capture.requestID)
        XCTAssertNil(reference)
        XCTAssertNil(sceneID)
        XCTAssertEqual(bearing.azimuthDegrees, -32)
        XCTAssertEqual(fov, 40)
        XCTAssertEqual(expiresAtNS, capture.lease.expiresAtNS)

        XCTAssertTrue(arbiter.completeMotorGoal(requestID: capture.requestID, at: now + 2))
        XCTAssertNil(arbiter.snapshot(at: now + 3).activeRequestID)
        XCTAssertEqual(arbiter.snapshot(at: now + 3).registeredTargets.count, 1)
        XCTAssertEqual(
            coordinator.complete(requestID: capture.requestID),
            .release(requestID: capture.requestID, reason: "capture_completed")
        )
    }

    func testCaptureResultIPCReturnsOnlyTheRequestedTTLResource() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/soma-capture-ipc-\(suffix)", isDirectory: true)
        let socketURL = directory.appendingPathComponent("capture.sock")
        let ready = EmbodimentViewResource(
            requestID: "capture-1",
            state: .ready,
            imagePath: "/private/tmp/capture-1.jpg",
            mimeType: "image/jpeg",
            width: 640,
            height: 360,
            capturedAtNS: 100,
            resourceExpiresAtNS: 60_000_000_100,
            bearing: .init(azimuthDegrees: 12, elevationDegrees: 3),
            cameraBearing: .init(azimuthDegrees: 11.8, elevationDegrees: 3.1),
            fieldOfViewDegrees: 50
        )
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            captureResultProvider: { requestID, _ in
                requestID == ready.requestID ? ready : nil
            }
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let reply = try EmbodimentShadowSocketClient.send(
            .init(kind: .captureResult, requestID: ready.requestID),
            socketURL: socketURL
        )
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.viewResource, ready)

        let unknown = try EmbodimentShadowSocketClient.send(
            .init(kind: .captureResult, requestID: "capture-other"),
            socketURL: socketURL
        )
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.error, "capture_result_unknown")
    }

    func testCaptureAlignmentUsesHysteresisAcrossBrakingOvershoot() {
        let start: UInt64 = 70_000_000_000
        XCTAssertEqual(
            CaptureAlignmentHysteresis.evaluate(
                errorDegrees: 2.1,
                stableSinceNS: nil,
                at: start
            ).phase,
            .drive
        )
        let entered = CaptureAlignmentHysteresis.evaluate(
            errorDegrees: 1.9,
            stableSinceNS: nil,
            at: start + 1
        )
        XCTAssertEqual(entered.phase, .beginSettling)
        XCTAssertEqual(
            CaptureAlignmentHysteresis.evaluate(
                errorDegrees: 3.8,
                stableSinceNS: entered.stableSinceNS,
                at: start + 179_000_001
            ).phase,
            .awaitSettling
        )
        XCTAssertEqual(
            CaptureAlignmentHysteresis.evaluate(
                errorDegrees: 4.4,
                stableSinceNS: entered.stableSinceNS,
                at: start + 180_000_001
            ).phase,
            .capture
        )
        XCTAssertEqual(
            CaptureAlignmentHysteresis.evaluate(
                errorDegrees: 4.6,
                stableSinceNS: entered.stableSinceNS,
                at: start + 180_000_001
            ),
            CaptureAlignmentDecision(phase: .drive, stableSinceNS: nil)
        )
    }

    private func makeRequest(
        layer: CognitiveControlLayer,
        operation: CognitiveEmbodimentOperation
    ) -> CognitiveEmbodimentRequest {
        CognitiveEmbodimentRequest(
            requestID: "request:\(layer.rawValue)",
            layer: layer,
            reason: "semantic attention goal",
            evidenceIDs: ["evidence:1"],
            lease: EmbodimentLease(
                ownerID: "owner:\(layer.rawValue)",
                priority: 50,
                issuedAtNS: 1_000_000_000,
                durationMilliseconds: 5_000,
                cancellationToken: "cancel:\(layer.rawValue)"
            ),
            operation: operation
        )
    }

    private func shadowRequest(
        id: String,
        layer: CognitiveControlLayer,
        owner: String,
        priority: UInt8,
        now: UInt64,
        durationMilliseconds: UInt64 = 5_000,
        operation: CognitiveEmbodimentOperation
    ) -> CognitiveEmbodimentRequest {
        CognitiveEmbodimentRequest(
            requestID: id,
            layer: layer,
            reason: "shadow test",
            evidenceIDs: ["test:evidence"],
            lease: EmbodimentLease(
                ownerID: owner,
                priority: priority,
                issuedAtNS: now,
                durationMilliseconds: durationMilliseconds,
                cancellationToken: "cancel:\(id)"
            ),
            operation: operation
        )
    }

    private func sceneEntity(
        id: String,
        kind: AttentionTargetKind,
        label: String?,
        observed: Bool,
        lastSeenMilliseconds: Double = 0
    ) -> EmbodimentSceneEntity {
        EmbodimentSceneEntity(
            sceneID: id,
            kind: kind,
            label: label,
            confidence: 0.9,
            observedThisFrame: observed,
            actionEligible: kind == .human,
            bearing: GimbalRelativeBearing(azimuthDegrees: 10, elevationDegrees: 2),
            spatialConfidence: 0.9,
            lastSeenMilliseconds: lastSeenMilliseconds
        )
    }
}
#endif
