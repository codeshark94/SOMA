import Foundation

/// A small FIFO for asynchronous event side effects. Producers submit in their
/// observed order without blocking; one worker awaits each operation before
/// advancing, preserving causality across otherwise independently scheduled
/// Swift tasks.
public final class SerialAsyncEventPipeline: @unchecked Sendable {
    public typealias Operation = @Sendable () async -> Void

    private let continuation: AsyncStream<Operation>.Continuation
    private var worker: Task<Void, Never>?

    public init() {
        let streamPair = AsyncStream<Operation>.makeStream()
        continuation = streamPair.continuation
        worker = Task {
            for await operation in streamPair.stream {
                guard !Task.isCancelled else { return }
                await operation()
            }
        }
    }

    deinit {
        continuation.finish()
        worker?.cancel()
    }

    public func enqueue(_ operation: @escaping Operation) {
        continuation.yield(operation)
    }
}

public struct SemanticMemoryRecallPolicy: Equatable, Sendable {
    public let semanticWeight: Double
    public let confidenceWeight: Double
    public let recencyWeight: Double
    public let recencyHalfLife: TimeInterval

    public init(
        semanticWeight: Double = 0.68,
        confidenceWeight: Double = 0.20,
        recencyWeight: Double = 0.12,
        recencyHalfLife: TimeInterval = 30 * 24 * 60 * 60
    ) {
        let semantic = max(0, semanticWeight)
        let confidence = max(0, confidenceWeight)
        let recency = max(0, recencyWeight)
        let total = semantic + confidence + recency
        if total > 0 {
            self.semanticWeight = semantic / total
            self.confidenceWeight = confidence / total
            self.recencyWeight = recency / total
        } else {
            self.semanticWeight = 1
            self.confidenceWeight = 0
            self.recencyWeight = 0
        }
        self.recencyHalfLife = max(recencyHalfLife, 1)
    }
}

public struct SemanticMemoryCandidate: Equatable, Sendable {
    public let projection: RemoteMemoryProjection
    public let embedding: [Float]

    public init(projection: RemoteMemoryProjection, embedding: [Float]) {
        self.projection = projection
        self.embedding = embedding
    }
}

public struct SemanticMemoryHit: Equatable, Sendable {
    public let projection: RemoteMemoryProjection
    public let similarity: Double
    public let score: Double

    public init(projection: RemoteMemoryProjection, similarity: Double, score: Double) {
        self.projection = projection
        self.similarity = similarity
        self.score = score
    }
}

/// Ranks already-authorized memory projections. Embedding transport and
/// privacy filtering remain outside this pure policy, making the ordering
/// deterministic and independently testable.
public enum SemanticMemoryRanker {
    public static func rank(
        queryEmbedding: [Float],
        candidates: [SemanticMemoryCandidate],
        at date: Date = Date(),
        limit: Int,
        policy: SemanticMemoryRecallPolicy = .init()
    ) -> [SemanticMemoryHit] {
        guard !queryEmbedding.isEmpty, limit > 0 else { return [] }
        let scored = candidates.compactMap { candidate -> SemanticMemoryHit? in
            guard let rawSimilarity = cosineSimilarity(queryEmbedding, candidate.embedding) else {
                return nil
            }
            let similarity = min(max((Double(rawSimilarity) + 1) / 2, 0), 1)
            let confidence = min(max(candidate.projection.confidence, 0), 1)
            let age = max(0, date.timeIntervalSince(candidate.projection.updatedAt))
            let recency = exp(-log(2) * age / policy.recencyHalfLife)
            return SemanticMemoryHit(
                projection: candidate.projection,
                similarity: Double(rawSimilarity),
                score: similarity * policy.semanticWeight
                    + confidence * policy.confidenceWeight
                    + recency * policy.recencyWeight
            )
        }
        .sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 1e-12 { return lhs.score > rhs.score }
            if lhs.projection.updatedAt != rhs.projection.updatedAt {
                return lhs.projection.updatedAt > rhs.projection.updatedAt
            }
            return lhs.projection.id.uuidString < rhs.projection.id.uuidString
        }
        var seenSummaries: Set<String> = []
        var selected: [SemanticMemoryHit] = []
        for hit in scored {
            let normalizedSummary = hit.projection.summary
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSummary.isEmpty,
                  seenSummaries.insert(normalizedSummary).inserted else { continue }
            selected.append(hit)
            if selected.count >= min(limit, 64) { break }
        }
        return selected
    }
}

/// Revision-aware embedding cache. Corrected memories never reuse the vector
/// for an older textual revision, and bounded LRU eviction prevents a long-
/// running installation from accumulating an unbounded semantic index.
public final class RevisionedMemoryEmbeddingCache: @unchecked Sendable {
    private struct Key: Hashable {
        let id: UUID
        let revision: UInt64
    }

    private let lock = NSLock()
    private var embeddings: [Key: [Float]] = [:]
    private var lastUsed: [Key: UInt64] = [:]
    private let capacity: Int

    public init(capacity: Int = 1_024) {
        self.capacity = min(max(capacity, 16), 16_384)
    }

    public func embedding(for id: UUID, revision: UInt64) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(id: id, revision: revision)
        guard let value = embeddings[key] else { return nil }
        lastUsed[key] = DispatchTime.now().uptimeNanoseconds
        return value
    }

    public func set(_ value: [Float], for id: UUID, revision: UInt64) {
        guard !value.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = Key(id: id, revision: revision)
        Array(embeddings.keys)
            .filter { $0.id == id && $0.revision != revision }
            .forEach {
                embeddings.removeValue(forKey: $0)
                lastUsed.removeValue(forKey: $0)
            }
        while embeddings[key] == nil, embeddings.count >= capacity,
              let oldest = lastUsed.min(by: { $0.value < $1.value })?.key {
            embeddings.removeValue(forKey: oldest)
            lastUsed.removeValue(forKey: oldest)
        }
        embeddings[key] = value
        lastUsed[key] = DispatchTime.now().uptimeNanoseconds
    }
}

public struct SpeculativeMemoryPrefetchPolicy: Equatable, Sendable {
    public let minimumQueryCharacters: Int
    public let minimumIncrementCharacters: Int
    public let maximumQueryCharacters: Int
    public let claimWaitMilliseconds: UInt64
    public let minimumCharacterNGramAgreement: Double

    public init(
        minimumQueryCharacters: Int = 6,
        minimumIncrementCharacters: Int = 8,
        maximumQueryCharacters: Int = 512,
        claimWaitMilliseconds: UInt64 = 45,
        minimumCharacterNGramAgreement: Double = 0.68
    ) {
        self.minimumQueryCharacters = min(max(minimumQueryCharacters, 1), 64)
        self.minimumIncrementCharacters = min(max(minimumIncrementCharacters, 1), 64)
        self.maximumQueryCharacters = min(max(maximumQueryCharacters, 64), 4_096)
        self.claimWaitMilliseconds = min(max(claimWaitMilliseconds, 1), 500)
        self.minimumCharacterNGramAgreement = min(max(minimumCharacterNGramAgreement, 0.5), 1)
    }
}

public struct SpeculativeMemoryRecall: Equatable, Sendable {
    public let threadID: String
    public let turnGeneration: UInt64
    public let personEntityID: UUID
    public let query: String
    public let projections: [RemoteMemoryProjection]

    public init(
        threadID: String,
        turnGeneration: UInt64,
        personEntityID: UUID,
        query: String,
        projections: [RemoteMemoryProjection]
    ) {
        self.threadID = threadID
        self.turnGeneration = turnGeneration
        self.personEntityID = personEntityID
        self.query = query
        self.projections = projections
    }
}

/// Starts person-scoped memory retrieval from an evolving transcript, then
/// claims the result only when the finalized utterance still agrees with the
/// partial text that produced it. It never writes memory or creates a model
/// turn, so a stale prefetch cannot become synthetic speech.
public actor SpeculativeMemoryPrefetcher {
    public typealias Retriever = @Sendable (UUID, String) async -> [RemoteMemoryProjection]

    private struct TurnKey: Hashable {
        let threadID: String
        let turnGeneration: UInt64
    }

    private struct Entry {
        let personEntityID: UUID
        let requestRevision: UInt64
        let query: String
        let task: Task<Void, Never>
        var projections: [RemoteMemoryProjection]?
    }

    private let policy: SpeculativeMemoryPrefetchPolicy
    private let retrieve: Retriever
    private var peopleByThread: [String: UUID] = [:]
    private var entries: [TurnKey: Entry] = [:]
    private var finalizingTurns: Set<TurnKey> = []
    private var lastFinalizedGenerationByThread: [String: UInt64] = [:]
    private var nextRequestRevision: UInt64 = 0

    public init(
        policy: SpeculativeMemoryPrefetchPolicy = .init(),
        retrieve: @escaping Retriever
    ) {
        self.policy = policy
        self.retrieve = retrieve
    }

    public func begin(threadID: String, personEntityID: UUID?) {
        let thread = normalizedThreadID(threadID)
        guard !thread.isEmpty else { return }
        cancelEntries(for: thread)
        finalizingTurns = finalizingTurns.filter { $0.threadID != thread }
        lastFinalizedGenerationByThread.removeValue(forKey: thread)
        if let personEntityID {
            peopleByThread[thread] = personEntityID
        } else {
            peopleByThread.removeValue(forKey: thread)
        }
    }

    public func ingestPartial(threadID: String, turnGeneration: UInt64, text: String) {
        let thread = normalizedThreadID(threadID)
        let query = normalizedQuery(text)
        let key = TurnKey(threadID: thread, turnGeneration: turnGeneration)
        guard let personEntityID = peopleByThread[thread],
              turnGeneration > 0,
              finalizingTurns.contains(key)
                || turnGeneration > (lastFinalizedGenerationByThread[thread] ?? 0),
              query.count >= policy.minimumQueryCharacters else { return }
        if let existing = entries[key] {
            guard existing.personEntityID == personEntityID else {
                existing.task.cancel()
                entries.removeValue(forKey: key)
                return start(key: key, personEntityID: personEntityID, query: query)
            }
            if existing.query == query { return }
            if query.hasPrefix(existing.query),
               query.count - existing.query.count < policy.minimumIncrementCharacters {
                return
            }
            existing.task.cancel()
        }
        start(key: key, personEntityID: personEntityID, query: query)
    }

    public func claim(
        threadID: String,
        turnGeneration: UInt64,
        finalText: String
    ) async -> SpeculativeMemoryRecall? {
        let thread = normalizedThreadID(threadID)
        let finalQuery = normalizedQuery(finalText)
        let key = TurnKey(threadID: thread, turnGeneration: turnGeneration)
        guard turnGeneration > 0,
              turnGeneration > (lastFinalizedGenerationByThread[thread] ?? 0),
              peopleByThread[thread] != nil else { return nil }
        finalizingTurns.insert(key)
        defer {
            finalizingTurns.remove(key)
            lastFinalizedGenerationByThread[thread] = max(
                lastFinalizedGenerationByThread[thread] ?? 0,
                turnGeneration
            )
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ policy.claimWaitMilliseconds * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let current = entries[key] {
                guard peopleByThread[thread] == current.personEntityID,
                      compatible(partial: current.query, final: finalQuery) else {
                    entries.removeValue(forKey: key)?.task.cancel()
                    return nil
                }
                if let projections = current.projections {
                    entries.removeValue(forKey: key)
                    return SpeculativeMemoryRecall(
                        threadID: thread,
                        turnGeneration: turnGeneration,
                        personEntityID: current.personEntityID,
                        query: current.query,
                        projections: projections
                    )
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        entries.removeValue(forKey: key)?.task.cancel()
        return nil
    }

    public func end(threadID: String) {
        let thread = normalizedThreadID(threadID)
        peopleByThread.removeValue(forKey: thread)
        cancelEntries(for: thread)
        finalizingTurns = finalizingTurns.filter { $0.threadID != thread }
        lastFinalizedGenerationByThread.removeValue(forKey: thread)
    }

    public func personEntityID(threadID: String) -> UUID? {
        peopleByThread[normalizedThreadID(threadID)]
    }

    private func start(key: TurnKey, personEntityID: UUID, query: String) {
        nextRequestRevision &+= 1
        let requestRevision = nextRequestRevision
        let retrieve = self.retrieve
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let projections = await retrieve(personEntityID, query)
            guard !Task.isCancelled else { return }
            await self?.finish(
                key: key,
                requestRevision: requestRevision,
                projections: projections
            )
        }
        entries[key] = Entry(
            personEntityID: personEntityID,
            requestRevision: requestRevision,
            query: query,
            task: task,
            projections: nil
        )
    }

    private func finish(
        key: TurnKey,
        requestRevision: UInt64,
        projections: [RemoteMemoryProjection]
    ) {
        guard var entry = entries[key], entry.requestRevision == requestRevision else { return }
        entry.projections = projections
        entries[key] = entry
    }

    private func cancelEntries(for threadID: String) {
        let keys = entries.keys.filter { $0.threadID == threadID }
        for key in keys {
            entries.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func compatible(partial: String, final: String) -> Bool {
        guard !partial.isEmpty, !final.isEmpty else { return false }
        let lhs = comparisonText(partial)
        let rhs = comparisonText(final)
        if rhs.hasPrefix(lhs) || lhs.hasPrefix(rhs) { return true }
        let lhsNGrams = characterNGrams(lhs)
        let rhsNGrams = characterNGrams(rhs)
        guard !lhsNGrams.isEmpty, !rhsNGrams.isEmpty else { return false }
        let agreement = Double(lhsNGrams.intersection(rhsNGrams).count)
            / Double(min(lhsNGrams.count, rhsNGrams.count))
        return agreement >= policy.minimumCharacterNGramAgreement
    }

    private func comparisonText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func characterNGrams(_ value: String) -> Set<String> {
        let characters = Array(value)
        guard characters.count >= 2 else { return [] }
        return Set((0 ..< characters.count - 1).map {
            String(characters[$0 ... $0 + 1])
        })
    }

    private func normalizedThreadID(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
    }

    private func normalizedQuery(_ value: String) -> String {
        String(
            value
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .prefix(policy.maximumQueryCharacters)
        )
    }
}
