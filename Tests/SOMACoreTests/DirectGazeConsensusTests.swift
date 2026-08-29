import Testing
@testable import SOMACore

struct DirectGazeConsensusTests {
    private let face = NormalizedRect(x: 0.3, y: 0.2, width: 0.2, height: 0.3)

    @Test
    func oneDirectCaptureCannotAuthorizeContact() {
        var consensus = DirectGazeConsensus()

        let state = consensus.stabilize([
            .init(rect: face, evidence: .direct, capturedNS: 1_000_000_000),
        ])

        #expect(state == [.unavailable])
    }

    @Test
    func repeatedUseOfTheSameCaptureDoesNotBuildConsensus() {
        var consensus = DirectGazeConsensus()
        let sample = DirectGazeConsensusSample(
            rect: face,
            evidence: .direct,
            capturedNS: 1_000_000_000
        )

        #expect(consensus.stabilize([sample]) == [.unavailable])
        #expect(consensus.stabilize([sample]) == [.unavailable])
    }

    @Test
    func twoIndependentDirectCapturesAuthorizeContact() {
        var consensus = DirectGazeConsensus()

        #expect(consensus.stabilize([
            .init(rect: face, evidence: .direct, capturedNS: 1_000_000_000),
        ]) == [.unavailable])
        #expect(consensus.stabilize([
            .init(rect: face, evidence: .direct, capturedNS: 1_080_000_000),
        ]) == [.direct])
    }

    @Test
    func avertedCaptureBreaksTheDirectRun() {
        var consensus = DirectGazeConsensus()

        _ = consensus.stabilize([
            .init(rect: face, evidence: .direct, capturedNS: 1_000_000_000),
        ])
        #expect(consensus.stabilize([
            .init(rect: face, evidence: .averted, capturedNS: 1_080_000_000),
        ]) == [.averted])
        #expect(consensus.stabilize([
            .init(rect: face, evidence: .direct, capturedNS: 1_160_000_000),
        ]) == [.unavailable])
    }
}
