import Testing
@testable import SOMACore

struct AcousticExplorationArousalTests {
    private func onset(confidence: Double = 0.9) -> AuditoryOnsetEvidence {
        AuditoryOnsetEvidence(
            monotonicNS: 1_000_000_000,
            levelDB: -12,
            thresholdDB: -25,
            confidence: confidence,
            transient: true
        )
    }

    @Test
    func loudOnsetAcceleratesOnlyAnExistingExploration() {
        var arousal = AcousticExplorationArousal()
        #expect(arousal.observe(onset(), explorationActive: false, at: 1_000_000_000) == nil)
        #expect(arousal.profile(at: 1_000_000_000) == .neutral)

        let profile = arousal.observe(onset(), explorationActive: true, at: 1_000_000_000)
        #expect(profile != nil)
        #expect(profile!.speedMultiplier > 3)
        #expect(profile!.accelerationMultiplier > 2)
        #expect(profile!.samplingTemperatureMultiplier > 1)
        #expect(profile!.waypointLookAheadBoostDegrees > 0)
    }

    @Test
    func ordinaryRoomLevelChangeCannotCreateArousal() {
        var arousal = AcousticExplorationArousal()
        #expect(arousal.observe(
            onset(confidence: 0.72),
            explorationActive: true,
            at: 1_000_000_000
        ) == nil)
        #expect(arousal.profile(at: 1_100_000_000) == .neutral)
    }

    @Test
    func acousticArousalDecaysBackIntoOrdinaryExploration() {
        var arousal = AcousticExplorationArousal()
        let initial = arousal.observe(onset(), explorationActive: true, at: 1_000_000_000)!
        let later = arousal.profile(at: 4_000_000_000)
        let settled = arousal.profile(at: 8_000_000_000)

        #expect(later.intensity < initial.intensity)
        #expect(later.speedMultiplier < initial.speedMultiplier)
        #expect(settled == .neutral)
    }

    @Test
    func unlocalizedSoundResamplesAzimuthWithoutInventingElevation() {
        let sampled = SpatialCoverageDirection(
            bearing: .init(azimuthDegrees: 72, elevationDegrees: -28),
            probability: 0.42,
            panoramaQuality: 0.31,
            placeFamiliarity: 0.58,
            expectedInformationGain: 0.76
        )
        let pose = GimbalPose(
            pitchDegrees: 11.5,
            panDegrees: -34,
            monotonicNS: 2_000_000_000
        )

        let bearing = AcousticExplorationResamplePolicy.horizontalBearing(
            sampled: sampled,
            currentPose: pose
        )

        #expect(bearing.azimuthDegrees == 72)
        #expect(bearing.elevationDegrees == 11.5)
    }
}
