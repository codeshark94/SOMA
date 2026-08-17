import Foundation

/// Client for Ollama's text-embedding endpoint (`/api/embed`). Used to give
/// episodic memory semantic recall: a query is embedded and ranked against
/// episode narratives by cosine similarity, instead of the substring matching
/// the memory store's plain `query` uses.
public struct OllamaEmbeddingClient: Sendable {
    public let host: String
    public let model: String

    public init(
        host: String? = nil,
        model: String = "embeddinggemma:300m"
    ) {
        let raw = host ?? ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "http://127.0.0.1:11434"
        self.host = raw.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        self.model = model
    }

    /// Embeds a single text. Returns `nil` on any transport or decode failure
    /// so callers can degrade gracefully to recency-only recall.
    public func embed(_ text: String) async -> [Float]? {
        let batch = await embedBatch([text])
        return batch?.first
    }

    /// Embeds a batch of texts in one request. Returns `nil` on failure.
    public func embedBatch(_ texts: [String]) async -> [[Float]]? {
        let trimmed = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.isEmpty, trimmed.contains(where: { !$0.isEmpty }) else { return nil }
        guard let url = URL(string: "\(host)/api/embed") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": trimmed,
        ])
        request.timeoutInterval = 20
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawEmbeddings = outer["embeddings"] as? [[NSNumber]] else { return nil }
            return rawEmbeddings.map { $0.map(\.floatValue) }
        } catch {
            return nil
        }
    }
}

/// Cosine similarity between two equal-length vectors. Returns `nil` when
/// either vector is empty or the magnitudes are zero.
public func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
    var dot: Float = 0
    var lhsMag: Float = 0
    var rhsMag: Float = 0
    for i in 0..<lhs.count {
        dot += lhs[i] * rhs[i]
        lhsMag += lhs[i] * lhs[i]
        rhsMag += rhs[i] * rhs[i]
    }
    let magnitude = (lhsMag.squareRoot()) * (rhsMag.squareRoot())
    guard magnitude > 0 else { return nil }
    return dot / magnitude
}

/// A scored episodic recall result.
public struct EpisodicRecall: Sendable, Equatable {
    public let recordID: UUID
    public let narrative: String
    public let salience: Double
    public let similarity: Float
    public let updatedAt: Date

    public init(
        recordID: UUID,
        narrative: String,
        salience: Double,
        similarity: Float,
        updatedAt: Date
    ) {
        self.recordID = recordID
        self.narrative = narrative
        self.salience = salience
        self.similarity = similarity
        self.updatedAt = updatedAt
    }
}

/// In-memory cache of episode embeddings keyed by record ID, so repeated
/// recalls don't re-embed unchanged narratives. Bounded to avoid unbounded
/// growth; evicts least-recently-used entries beyond the cap.
public final class EpisodicEmbeddingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var embeddings: [UUID: [Float]] = [:]
    private var lastUsed: [UUID: UInt64] = [:]
    private let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = capacity
    }

    public func embedding(for id: UUID) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = embeddings[id] else { return nil }
        lastUsed[id] = DispatchTime.now().uptimeNanoseconds
        return value
    }

    public func set(_ value: [Float], for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if embeddings[id] == nil, embeddings.count >= capacity {
            // Evict the least-recently-used entry.
            if let oldest = lastUsed.min(by: { $0.value < $1.value })?.key {
                embeddings.removeValue(forKey: oldest)
                lastUsed.removeValue(forKey: oldest)
            }
        }
        embeddings[id] = value
        lastUsed[id] = DispatchTime.now().uptimeNanoseconds
    }
}
