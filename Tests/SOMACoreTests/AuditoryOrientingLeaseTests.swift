import Testing
@testable import SOMACore

struct AuditoryOrientingLeaseTests {
    private func onset(
        at monotonicNS: UInt64,
        confidence: Double,
        transient: Bool = false
    ) -> AuditoryOnsetEvidence {
        AuditoryOnsetEvidence(
            monotonicNS: monotonicNS,
            levelDB: -22,
            thresholdDB: -27,
            confidence: confidence,
            transient: transient
        )
    }

    @Test
    func ordinaryAcousticOnsetCannotAcquireMotorWithoutVoiceEvidence() {
        var admission = AuditoryOrientingAdmission()
        #expect(admission.observeOnset(onset(at: 1_000_000_000, confidence: 0.62)) == nil)
        #expect(admission.observeVoiceActivity(
            active: true,
            confidence: 0.374,
            at: 1_220_000_000
        ) == nil)
        #expect(admission.observeVoiceActivity(
            active: false,
            confidence: 0.05,
            at: 1_500_000_000
        ) == nil)
    }

    @Test
    func sustainedVoiceCorroboratesARecentAcousticOnset() {
        var admission = AuditoryOrientingAdmission()
        let evidence = onset(at: 1_000_000_000, confidence: 0.55)
        #expect(admission.observeOnset(evidence) == nil)
        #expect(admission.observeVoiceActivity(
            active: true,
            confidence: 0.42,
            at: 1_180_000_000
        ) == nil)
        #expect(admission.observeVoiceActivity(
            active: true,
            confidence: 0.44,
            at: 1_400_000_000
        ) == evidence)
    }

    @Test
    func staleAcousticOnsetCannotBorrowLaterSpeechEvidence() {
        var admission = AuditoryOrientingAdmission()
        #expect(admission.observeOnset(onset(at: 1_000_000_000, confidence: 0.60)) == nil)
        #expect(admission.observeVoiceActivity(
            active: true,
            confidence: 0.85,
            at: 1_900_000_000
        ) == nil)
    }

    @Test
    func sharpSalientTransientCanOrientWithoutSpeechClassification() {
        var admission = AuditoryOrientingAdmission()
        let evidence = onset(at: 1_000_000_000, confidence: 0.92, transient: true)
        #expect(admission.observeOnset(evidence) == evidence)
    }

    @Test
    func repeatedOnsetsCannotReplaceOrExtendAnActiveEpisode() {
        var lease = AuditoryOrientingLease(durationMilliseconds: 4_500)
        let first = lease.begin(requestID: "first", at: 1_000_000_000)

        #expect(first?.expiresAtNS == 5_500_000_000)
        #expect(lease.begin(requestID: "second", at: 2_300_000_000) == nil)
        #expect(lease.begin(requestID: "third", at: 5_400_000_000) == nil)
        #expect(lease.activeEpisode == first)
    }

    @Test
    func endingAnEpisodeAllowsASeparateFutureEpisode() {
        var lease = AuditoryOrientingLease(durationMilliseconds: 4_500)
        let first = lease.begin(requestID: "first", at: 1_000_000_000)

        #expect(lease.contains(requestID: "first"))
        #expect(lease.end() == first)
        #expect(!lease.isActive)

        let second = lease.begin(requestID: "second", at: 6_000_000_000)
        #expect(second?.requestID == "second")
        #expect(second?.expiresAtNS == 10_500_000_000)
    }
}
