#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class StreamingMemoryRecallTests: XCTestCase {
    func testSemanticRankerPrefersRelevantConfidentMemoryAndDeduplicatesSummary() {
        let now = Date(timeIntervalSince1970: 10_000)
        let relevant = projection(
            summary: "The participant is building a camera tracking system",
            confidence: 0.9,
            updatedAt: now
        )
        let duplicate = projection(
            summary: "THE PARTICIPANT IS BUILDING A CAMERA TRACKING SYSTEM",
            confidence: 0.7,
            updatedAt: now.addingTimeInterval(-60)
        )
        let unrelated = projection(
            summary: "The participant prefers tea",
            confidence: 1,
            updatedAt: now
        )

        let hits = SemanticMemoryRanker.rank(
            queryEmbedding: [1, 0],
            candidates: [
                .init(projection: relevant, embedding: [1, 0]),
                .init(projection: duplicate, embedding: [0.99, 0.01]),
                .init(projection: unrelated, embedding: [0, 1]),
            ],
            at: now,
            limit: 3
        )

        XCTAssertEqual(hits.first?.projection.id, relevant.id)
        XCTAssertEqual(hits.filter {
            $0.projection.summary.lowercased().contains("camera tracking")
        }.count, 1)
    }

    func testRevisionedEmbeddingCacheCannotServeCorrectedTextFromOldRevision() {
        let cache = RevisionedMemoryEmbeddingCache(capacity: 16)
        let id = UUID()
        cache.set([1, 0], for: id, revision: 1)
        XCTAssertEqual(cache.embedding(for: id, revision: 1), [1, 0])

        cache.set([0, 1], for: id, revision: 2)
        XCTAssertNil(cache.embedding(for: id, revision: 1))
        XCTAssertEqual(cache.embedding(for: id, revision: 2), [0, 1])
    }

    func testCompatibleFinalTranscriptClaimsPreparedMemoryWithoutCreatingAnotherLookup() async {
        let recorder = RetrievalRecorder()
        let personID = UUID()
        let expected = projection(summary: "Remembered project", confidence: 0.8)
        let prefetcher = SpeculativeMemoryPrefetcher(
            policy: .init(claimWaitMilliseconds: 100)
        ) { person, query in
            await recorder.record(person: person, query: query)
            return [expected]
        }

        await prefetcher.begin(threadID: "thread-a", personEntityID: personID)
        await prefetcher.ingestPartial(
            threadID: "thread-a",
            turnGeneration: 1,
            text: "camera project"
        )
        let recalled = await prefetcher.claim(
            threadID: "thread-a",
            turnGeneration: 1,
            finalText: "camera project status"
        )

        XCTAssertEqual(recalled?.personEntityID, personID)
        XCTAssertEqual(recalled?.turnGeneration, 1)
        XCTAssertEqual(recalled?.projections, [expected])
        let retrievalCount = await recorder.count
        XCTAssertEqual(retrievalCount, 1)
    }

    func testContradictingFinalTranscriptRejectsSpeculativeMemory() async {
        let expected = projection(summary: "Wrong topic", confidence: 0.8)
        let prefetcher = SpeculativeMemoryPrefetcher(
            policy: .init(claimWaitMilliseconds: 100)
        ) { _, _ in [expected] }

        await prefetcher.begin(threadID: "thread-b", personEntityID: UUID())
        await prefetcher.ingestPartial(
            threadID: "thread-b",
            turnGeneration: 1,
            text: "camera project"
        )
        let recalled = await prefetcher.claim(
            threadID: "thread-b",
            turnGeneration: 1,
            finalText: "weather tomorrow"
        )

        XCTAssertNil(recalled)
    }

    func testMinorASRRevisionCanClaimTheSameSemanticPrefetch() async {
        let expected = projection(summary: "Current camera project", confidence: 0.8)
        let prefetcher = SpeculativeMemoryPrefetcher(
            policy: .init(claimWaitMilliseconds: 100)
        ) { _, _ in [expected] }

        await prefetcher.begin(threadID: "thread-c", personEntityID: UUID())
        await prefetcher.ingestPartial(
            threadID: "thread-c",
            turnGeneration: 1,
            text: "카메라 프로젝트 보여"
        )
        let recalled = await prefetcher.claim(
            threadID: "thread-c",
            turnGeneration: 1,
            finalText: "카메라 프로젝트 좀 보여줘"
        )

        XCTAssertEqual(recalled?.projections, [expected])
    }

    func testFinalEventCanWaitForSameTurnPartialScheduledImmediatelyAfterIt() async {
        let expected = projection(summary: "Current project status", confidence: 0.9)
        let prefetcher = SpeculativeMemoryPrefetcher(
            policy: .init(claimWaitMilliseconds: 100)
        ) { _, _ in [expected] }

        await prefetcher.begin(threadID: "thread-d", personEntityID: UUID())
        let claim = Task {
            await prefetcher.claim(
                threadID: "thread-d",
                turnGeneration: 7,
                finalText: "project status"
            )
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        await prefetcher.ingestPartial(
            threadID: "thread-d",
            turnGeneration: 7,
            text: "project stat"
        )

        let recalled = await claim.value
        XCTAssertEqual(recalled?.turnGeneration, 7)
        XCTAssertEqual(recalled?.projections, [expected])
    }

    func testFinalizedTurnRejectsLatePartialFromTheSameGeneration() async {
        let recorder = RetrievalRecorder()
        let prefetcher = SpeculativeMemoryPrefetcher(
            policy: .init(claimWaitMilliseconds: 20)
        ) { person, query in
            await recorder.record(person: person, query: query)
            return []
        }

        await prefetcher.begin(threadID: "thread-e", personEntityID: UUID())
        _ = await prefetcher.claim(
            threadID: "thread-e",
            turnGeneration: 3,
            finalText: "finished utterance"
        )
        await prefetcher.ingestPartial(
            threadID: "thread-e",
            turnGeneration: 3,
            text: "late partial"
        )

        let retrievalCount = await recorder.count
        XCTAssertEqual(retrievalCount, 0)
    }

    private func projection(
        summary: String,
        confidence: Double,
        updatedAt: Date = Date(timeIntervalSince1970: 10_000)
    ) -> RemoteMemoryProjection {
        RemoteMemoryProjection(
            id: UUID(),
            revision: 1,
            tier: .mediumTerm,
            kind: .personFact,
            summary: summary,
            confidence: confidence,
            updatedAt: updatedAt
        )
    }
}

private actor RetrievalRecorder {
    private(set) var count = 0

    func record(person: UUID, query: String) {
        _ = person
        _ = query
        count += 1
    }
}
#endif
