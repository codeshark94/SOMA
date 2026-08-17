@preconcurrency import AVFoundation
import AudioToolbox
import CoreML
import CoreMedia
import CoreVideo
import CoreImage
import Foundation
import SOMACore
import SOMAVADModel
@preconcurrency import Vision

// MARK: - SOMA .env layer configuration helpers
/// Reads a boolean from a `SOMA_*` / `OLLAMA_*` environment variable that the
/// Control Center manages through `~/Library/Application Support/SOMA/.env`.
func somaEnvBool(_ key: String, default defaultValue: Bool) -> Bool {
    guard let raw = ProcessInfo.processInfo.environment[key] else { return defaultValue }
    switch raw.lowercased() {
    case "true", "1", "yes", "on": return true
    case "false", "0", "no", "off": return false
    default: return defaultValue
    }
}

func somaEnvDouble(_ key: String, default defaultValue: Double) -> Double {
    guard let raw = ProcessInfo.processInfo.environment[key],
          let value = Double(raw), value > 0 else { return defaultValue }
    return value
}

func somaEnvString(_ key: String, default defaultValue: String) -> String {
    guard let raw = ProcessInfo.processInfo.environment[key],
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return defaultValue }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The base host of the local Ollama server (from `.env` `OLLAMA_HOST`).
func somaOllamaHost() -> String {
    let raw = ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "http://127.0.0.1:11434"
    return raw.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
}

/// Runs registered graceful-stop closures when the process receives SIGTERM or
/// SIGINT (e.g. `launchctl bootout` from the menu bar "Stop SOMA"). Without this
/// the runtime is killed abruptly and the camera's built-in AI tracking is left
/// enabled, so it keeps following people after SOMA has been stopped.
private final class GracefulShutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [() -> Void] = []
    private let source: DispatchSourceSignal

    init(signals: [Int32]) {
        for sig in signals { signal(sig, SIG_IGN) }
        let src = DispatchSource.makeSignalSource(
            signal: signals[0],
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        self.source = src
        src.setEventHandler { [weak self] in self?.fire() }
        src.resume()
    }

    func onTerminate(_ action: @escaping () -> Void) {
        lock.lock()
        actions.append(action)
        lock.unlock()
    }

    private func fire() {
        lock.lock()
        let current = actions
        lock.unlock()
        current.forEach { $0() }
        // Give the shutdown command (AI-tracking off + park) time to flush
        // before the process exits.
        usleep(700_000)
        Foundation.exit(EXIT_SUCCESS)
    }
}

/// Mutable holder for the anonymous-registration review gate. The FaceIdentity
/// runtime consults `approve()` before surfacing a new anonymous identity; the
/// reviewer is installed once L1 setup is ready and otherwise defaults to allow.
final class AnonymousReviewBox: @unchecked Sendable {
    var reviewer: @Sendable () -> Bool = { true }
    func approve() -> Bool { reviewer() }
}

/// Accumulates L1's model-driven curiosity (information needs / topic goals)
/// about the interaction target and broader context, periodically collects
/// current web material on those topics via Ollama's hosted web_search, and
/// exposes the collected context so L1 can craft richer conversational openers.
final class L1CuriosityCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "soma.l1.curiosity")
    private let onHealth: @Sendable (String, String) -> Void
    private var topics: [String: Double] = [:]
    private var collected: [String: [CuriosityItem]] = [:]
    private var timer: DispatchSourceTimer?

    struct CuriosityItem {
        let title: String
        let url: String
        let snippet: String
    }

    init(onHealth: @escaping @Sendable (String, String) -> Void) {
        self.onHealth = onHealth
    }

    /// Accumulate curiosity topics from an L1 frame's information needs.
    /// Weighted by expected information gain, capped to the most valuable 24.
    func registerTopics(from needs: [L1InformationNeed]) {
        lock.lock()
        for need in needs {
            let topic = need.informationGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty else { continue }
            topics[topic, default: 0] = max(topics[topic] ?? 0, need.expectedInformationGain)
        }
        if topics.count > 24 {
            let sorted = topics.sorted { $0.value > $1.value }.prefix(24).map { ($0.key, $0.value) }
            topics = Dictionary(uniqueKeysWithValues: sorted)
        }
        lock.unlock()
        onHealth("curiosity_topics", "count=\(topics.count)")
    }

    /// Kick off collection: an initial pass shortly after start, then repeat
    /// on the configured cadence. Honors SOMA_L1_CURIOSITY_ENABLED and
    /// SOMA_L1_CURIOSITY_INTERVAL_HOURS from the managed .env.
    func start() {
        guard somaEnvBool("SOMA_L1_CURIOSITY_ENABLED", default: true) else {
            onHealth("curiosity_collect", "state=disabled; reason=SOMA_L1_CURIOSITY_ENABLED")
            return
        }
        let intervalSeconds = Int(somaEnvDouble("SOMA_L1_CURIOSITY_INTERVAL_HOURS", default: 24) * 3600)
        queue.asyncAfter(deadline: .now() + .seconds(60)) { [weak self] in
            self?.collectAll()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(intervalSeconds), repeating: .seconds(intervalSeconds))
        t.setEventHandler { [weak self] in
            self?.collectAll()
        }
        t.resume()
        timer = t
    }

    private func collectAll() {
        lock.lock()
        let snapshot = Array(topics.keys)
        lock.unlock()
        guard !snapshot.isEmpty else {
            onHealth("curiosity_collect", "state=idle; topics=0")
            return
        }
        var collectedThisRun = 0
        var failed = 0
        for topic in snapshot {
            let raw = performL1WebSearch(query: topic, maxResults: 4)
            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["ok"] as? Bool == true,
                  let results = obj["results"] as? [[String: Any]] else {
                failed += 1
                continue
            }
            let items = results.compactMap { r -> CuriosityItem? in
                guard let title = r["title"] as? String else { return nil }
                return CuriosityItem(
                    title: title,
                    url: r["url"] as? String ?? "",
                    snippet: r["snippet"] as? String ?? ""
                )
            }
            lock.lock()
            collected[topic] = items
            lock.unlock()
            collectedThisRun += items.count
        }
        onHealth("curiosity_collect", "state=done; topics=\(snapshot.count); results=\(collectedThisRun); failed=\(failed)")
    }

    /// A compact summary of collected material, used to inform L1 openers.
    /// Returns an empty string when nothing has been collected yet.
    func contextSummary(limit: Int = 4) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !collected.isEmpty else { return "" }
        var lines: [String] = []
        let ordered = collected.keys.sorted { collected[$0]?.count ?? 0 > collected[$1]?.count ?? 0 }
        for topic in ordered.prefix(limit) {
            let items = collected[topic] ?? []
            guard !items.isEmpty else { continue }
            let head = items.prefix(2).map { "\($0.title): \($0.snippet)" }.joined(separator: " | ")
            lines.append("[\(topic)] \(head)")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }
}

/// Synchronous L1 review of the current frame: asks the local Gemma model
/// whether the primary face is a real human worth tracking as an anonymous
/// identity. Runs only when a brand-new anonymous identity is about to be
/// created, so the blocking wait is rare and acceptable.
func l1PersonContextSummary(_ provider: L1MemoryContextProvider, for entityID: UUID) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    Task { [provider] in
        let ctx = await provider.context(for: entityID)
        var facts: [String] = ctx.projections.map { $0.summary }
        if let rapport = ctx.rapport {
            facts.append("familiarity=\(rapport.familiarity)")
        }
        if !ctx.informationNeeds.isEmpty {
            facts.append("open_information_needs=\(ctx.informationNeeds.count)")
        }
        let joined = facts.prefix(12).joined(separator: " | ")
            .replacingOccurrences(of: "\"", with: "'")
        box.set(.success(#"{"ok":true,"projections":\#(facts.count),"summary":"\#(joined)"}"#))
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(summary)? = box.get() {
        return summary
    }
    return #"{"ok":false,"error":"no_context"}"#
}

func l1StorePersonFact(_ provider: L1MemoryContextProvider, for entityID: UUID, fact: String) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<Bool>()
    Task { [provider] in
        let stored = await provider.storePersonFact(fact, for: entityID)
        box.set(.success(stored))
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(stored)? = box.get() {
        return stored ? #"{"ok":true,"stored":true}"# : #"{"ok":false,"error":"store_unavailable"}"#
    }
    return #"{"ok":false,"error":"store_unavailable"}"#
}

func l1RecallEpisodes(_ provider: L1MemoryContextProvider, query: String, entityID: UUID?) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    Task { [provider] in
        let recalled = await provider.recallEpisodes(query: query, entityID: entityID)
        let joined = recalled.joined(separator: " | ").replacingOccurrences(of: "\"", with: "'")
        box.set(.success(#"{"ok":true,"count":\#(recalled.count),"episodes":"\#(joined)"}"#))
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(summary)? = box.get() {
        return summary
    }
    return #"{"ok":false,"error":"recall_failed"}"#
}

private struct L1WebSearchResult: Decodable {
    let results: [ResultItem]?
    struct ResultItem: Decodable {
        let title: String?
        let url: String?
        let content: String?
    }
}

private struct L1WebFetchResult: Decodable {
    let title: String?
    let content: String?
}

/// Minimal Ollama /api/chat response decoder for the parallel object
/// identification call (image-based).
private struct L1ObjectIdentificationResponse: Decodable {
    let message: Message?
    struct Message: Decodable {
        let content: String?
    }
}

/// Calls Ollama's hosted web_search API. Requires OLLAMA_API_KEY.
func performL1WebSearch(query: String, maxResults: Int = 5) -> String {
    guard let key = ProcessInfo.processInfo.environment["OLLAMA_API_KEY"], !key.isEmpty else {
        return #"{"ok":false,"error":"OLLAMA_API_KEY not set; hosted web_search requires an Ollama API key"}"#
    }
    guard let url = URL(string: "https://ollama.com/api/web_search") else {
        return #"{"ok":false,"error":"bad_url"}"#
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let body = ["query": query, "max_results": maxResults] as [String: Any]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 20
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        guard error == nil,
              let data,
              let decoded = try? JSONDecoder().decode(L1WebSearchResult.self, from: data),
              let results = decoded.results, !results.isEmpty else {
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no_data"
            box.set(.success(#"{"ok":false,"error":"search_failed","detail":"\#(String(raw.prefix(160)).replacingOccurrences(of: "\"", with: "'"))"}"#))
            return
        }
        let items = results.prefix(maxResults).map { item -> [String: String] in
            [
                "title": item.title ?? "",
                "url": item.url ?? "",
                "snippet": (item.content ?? "").prefix(400).replacingOccurrences(of: "\"", with: "'")
            ]
        }
        let payload = ["ok": true, "query": query, "results": items] as [String: Any]
        let encoded = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
        box.set(.success(encoded))
    }.resume()
    semaphore.wait()
    if case let .success(value)? = box.get() { return value }
    return #"{"ok":false}"#
}

/// Calls Ollama's hosted web_fetch API. Requires OLLAMA_API_KEY.
func performL1WebFetch(url: String) -> String {
    guard let key = ProcessInfo.processInfo.environment["OLLAMA_API_KEY"], !key.isEmpty else {
        return #"{"ok":false,"error":"OLLAMA_API_KEY not set; hosted web_fetch requires an Ollama API key"}"#
    }
    guard let endpoint = URL(string: "https://ollama.com/api/web_fetch") else {
        return #"{"ok":false,"error":"bad_url"}"#
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["url": url])
    request.timeoutInterval = 20
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        guard error == nil, let data,
              let decoded = try? JSONDecoder().decode(L1WebFetchResult.self, from: data),
              let content = decoded.content, !content.isEmpty else {
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no_data"
            box.set(.success(#"{"ok":false,"error":"fetch_failed","detail":"\#(String(raw.prefix(160)).replacingOccurrences(of: "\"", with: "'"))"}"#))
            return
        }
        let payload: [String: Any] = [
            "ok": true,
            "title": decoded.title ?? "",
            "content": String(content.prefix(2000)).replacingOccurrences(of: "\"", with: "'")
        ]
        let encoded = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
        box.set(.success(encoded))
    }.resume()
    semaphore.wait()
    if case let .success(value)? = box.get() { return value }
    return #"{"ok":false}"#
}

/// Sends the given JPEG to the local L1 Gemma model (via Ollama /api/chat,
/// which accepts image input) and asks it to identify the object shown. Runs
/// as an independent inference, parallel to the conscious-stream cycle, and is
/// not part of the L1 situation workload. Returns a JSON string describing the
/// object.
func performL1ObjectIdentification(jpeg: Data) -> String {
    guard !jpeg.isEmpty else {
        return #"{"ok":false,"error":"empty_image"}"#
    }
    let model = ProcessInfo.processInfo.environment["SOMA_L1_MODEL"] ?? "gemma4:31b-cloud"
    guard let url = URL(string: "\(somaOllamaHost())/api/chat") else {
        return #"{"ok":false,"error":"bad_endpoint"}"#
    }
    let system = (
        "You are SOMA L1's object recognition helper. You are shown one camera frame. "
        + "Identify the single most prominent object in the frame (for example a specific "
        + "figurine, a bicycle, a book, a collectible). Be concrete and specific about what it "
        + "is, using general knowledge. Do not identify a person, do not infer private traits, "
        + "do not issue commands. "
        + "Reply with exactly one JSON object with keys: name (short noun), category, "
        + "description (2-3 sentences)."
    )
    let user = "Identify the most prominent object in this image and return the JSON."
    let messages: [[String: Any]] = [
        ["role": "system", "content": system],
        ["role": "user", "content": user, "images": [jpeg.base64EncodedString()]]
    ]
    let payload: [String: Any] = [
        "model": model,
        "messages": messages,
        "stream": false,
        "options": ["temperature": 0, "num_predict": 384]
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
        return #"{"ok":false,"error":"encode_failed"}"#
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    request.timeoutInterval = 40
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    URLSession.shared.dataTask(with: request) { data, _, error in
        defer { semaphore.signal() }
        guard error == nil, let data,
              let decoded = try? JSONDecoder().decode(L1ObjectIdentificationResponse.self, from: data),
              let content = decoded.message?.content else {
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no_data"
            box.set(.success(#"{"ok":false,"error":"ollama_failed","detail":"\#(String(raw.prefix(160)).replacingOccurrences(of: "\"", with: "'"))"}"#))
            return
        }
        // Best-effort: the model was asked for JSON; try to normalize the text.
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("{"), let data = clean.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let enc = (try? JSONSerialization.data(withJSONObject: obj))
                .flatMap { String(data: $0, encoding: .utf8) }
            box.set(.success(enc ?? #"{"ok":false}"#))
            return
        }
        // Fall back to a text description wrapped as JSON.
        let payloadOut = ["ok": true, "raw": String(clean.prefix(600)).replacingOccurrences(of: "\"", with: "'")]
        let enc = (try? JSONSerialization.data(withJSONObject: payloadOut))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
        box.set(.success(enc))
    }.resume()
    semaphore.wait()
    if case let .success(value)? = box.get() { return value }
    return #"{"ok":false}"#
}

func performL1AnonymousReview(
    frameURL: URL,
    onHealth: @escaping (String, String) -> Void
) -> Bool {
    guard FileManager.default.isReadableFile(atPath: frameURL.path),
          let imageData = try? Data(contentsOf: frameURL),
          imageData.count > 0,
          imageData.count <= 2 * 1_024 * 1_024 else {
        // No frame to review: fall back to allowing the identity.
        return true
    }
    let prompt = """
    Look at this current camera frame. Is the primary face a real human person who should be \
    tracked as an anonymous identity — not a photograph, screen, reflection, or non-human object? \
    If it is clearly a real person, set register_anonymous_identity to true. If it is noise, \
    ambiguous, or not clearly a real living person, set it to false. \
    Reply with strict JSON only: {"register_anonymous_identity":true} or {"register_anonymous_identity":false}.
    """
    let body: [String: Any] = [
        "model": "gemma4:31b-cloud",
        "prompt": prompt,
        "images": [imageData.base64EncodedString()],
        "stream": false,
        "format": "json",
        "options": ["temperature": 0.2, "num_predict": 32]
    ]
    guard let url = URL(string: "\(somaOllamaHost())/api/generate") else { return true }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 20
    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return true }
    request.httpBody = payload

    let semaphore = DispatchSemaphore(value: 0)
    var decision = true
    var healthMessage = "unavailable"
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        guard error == nil,
              let data,
              let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = outer["response"] as? String,
              let contentData = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let register = parsed["register_anonymous_identity"] as? Bool else {
            healthMessage = error?.localizedDescription ?? "malformed_response"
            return
        }
        decision = register
        healthMessage = register ? "approved" : "declined"
    }.resume()
    semaphore.wait()
    onHealth("reviewed", "decision=\(healthMessage)")
    return decision
}

private enum RuntimeError: LocalizedError {
    case invalidArgument(String)
    case unavailable(String)
    case unauthorized(String)
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message),
                .unavailable(let message),
                .unauthorized(let message),
                .configuration(let message):
            return message
        }
    }
}

private struct Options {
    let duration: TimeInterval
    let videoID: String
    let audioID: String
    let outputURL: URL
    let traceRotationPolicy: JSONLRotationPolicy?
    let importantOutputURL: URL?
    let importantRotationPolicy: JSONLRotationPolicy?
    let guidedScenario: Bool
    let tdoaCalibrationURL: URL?
    let tdoaCalibrationOutputURL: URL?
    let allowCameraMotion: Bool
    let nativeGimbalHelperURL: URL?
    let gimbalOutputURL: URL?
    let gimbalTraceRotationPolicy: JSONLRotationPolicy?
    let allowNativeHumanTracking: Bool
    let allowExternalGimbalControl: Bool
    let allowAutonomousScan: Bool
    let externalGimbalCalibrationURL: URL?
    let externalGimbalCalibrationOutputURL: URL?
    let diagnosticSnapshotURL: URL?
    let faceLockDiagnosticDirectoryURL: URL?
    let l1AuxiliaryVLMPythonURL: URL?
    let l1AuxiliaryVLMWorkerURL: URL?
    let l1AuxiliaryVLMModel: String?
    let embodimentShadowSocketURL: URL?
    let allowEmbodimentMotorControl: Bool
    let embodimentViewDirectoryURL: URL?
    let panoramaOutputURL: URL?
    let panoramaPlaceMemoryURL: URL?
    let cameraGeometryCalibrationURL: URL?
    let cameraGeometryCaptureDirectoryURL: URL?
    let panoramaStripScan: Bool
    let localSpeechLocaleIdentifier: String?
    let l2CodexBridgeURL: URL?
    let l2LiveVoice: Bool
    let controlSettingsURL: URL

    static func parse(_ arguments: [String]) throws -> Options {
        var duration: TimeInterval = 60
        var videoID: String?
        var audioID: String?
        var outputURL = defaultOutputURL()
        var traceMaximumMegabytes: Int?
        var traceRetainedFiles: Int?
        var importantOutputURL: URL?
        var importantMaximumMegabytes: Int?
        var importantRetainedFiles: Int?
        var guidedScenario = false
        var tdoaCalibrationURL: URL?
        var tdoaCalibrationOutputURL: URL?
        var allowCameraMotion = false
        var nativeGimbalHelperURL: URL?
        var gimbalOutputURL: URL?
        var gimbalTraceMaximumMegabytes: Int?
        var gimbalTraceRetainedFiles: Int?
        var allowNativeHumanTracking = false
        var allowExternalGimbalControl = false
        var allowAutonomousScan = false
        var externalGimbalCalibrationURL: URL?
        var externalGimbalCalibrationOutputURL: URL?
        var diagnosticSnapshotURL: URL?
        var faceLockDiagnosticDirectoryURL: URL?
        var l1AuxiliaryVLMPythonURL: URL?
        var l1AuxiliaryVLMWorkerURL: URL?
        var l1AuxiliaryVLMModel: String?
        var embodimentShadowSocketURL: URL?
        var allowEmbodimentMotorControl = false
        var embodimentViewDirectoryURL: URL?
        var panoramaOutputURL: URL?
        var panoramaPlaceMemoryURL: URL?
        var cameraGeometryCalibrationURL: URL?
        var cameraGeometryCaptureDirectoryURL: URL?
        var panoramaStripScan = false
        var localSpeechLocaleIdentifier: String?
        var l2CodexBridgeURL: URL?
        var l2LiveVoice = false
        var controlSettingsURL = SOMAControlSettingsStore.defaultURL()
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--duration":
                index += 1
                guard index < arguments.count,
                      let parsed = TimeInterval(arguments[index]),
                      parsed >= 0 else {
                    throw RuntimeError.invalidArgument("--duration must be 0 (continuous) or a positive number of seconds")
                }
                duration = parsed
            case "--video-id":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--video-id requires the OBSBOT video unique ID")
                }
                videoID = arguments[index]
            case "--audio-id":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--audio-id requires the OBSBOT microphone unique ID")
                }
                audioID = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--output requires a trace path")
                }
                outputURL = URL(fileURLWithPath: arguments[index])
            case "--trace-max-megabytes":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--trace-max-megabytes requires a positive integer")
                }
                traceMaximumMegabytes = value
            case "--trace-retained-files":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--trace-retained-files requires a positive integer")
                }
                traceRetainedFiles = value
            case "--important-output":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--important-output requires a JSONL basename")
                }
                importantOutputURL = URL(fileURLWithPath: arguments[index])
            case "--important-max-megabytes":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--important-max-megabytes requires a positive integer")
                }
                importantMaximumMegabytes = value
            case "--important-retained-files":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--important-retained-files requires a positive integer")
                }
                importantRetainedFiles = value
            case "--guided-scenario":
                guidedScenario = true
            case "--tdoa-calibration":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--tdoa-calibration requires a calibration JSON path")
                }
                tdoaCalibrationURL = URL(fileURLWithPath: arguments[index])
            case "--tdoa-calibrate":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--tdoa-calibrate requires an output JSON path")
                }
                tdoaCalibrationOutputURL = URL(fileURLWithPath: arguments[index])
            case "--allow-camera-motion":
                allowCameraMotion = true
            case "--native-gimbal-helper":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--native-gimbal-helper requires an executable path")
                }
                nativeGimbalHelperURL = URL(fileURLWithPath: arguments[index])
            case "--gimbal-output":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--gimbal-output requires a JSONL trace path")
                }
                gimbalOutputURL = URL(fileURLWithPath: arguments[index])
            case "--gimbal-trace-max-megabytes":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--gimbal-trace-max-megabytes requires a positive integer")
                }
                gimbalTraceMaximumMegabytes = value
            case "--gimbal-trace-retained-files":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--gimbal-trace-retained-files requires a positive integer")
                }
                gimbalTraceRetainedFiles = value
            case "--allow-external-gimbal-control":
                allowExternalGimbalControl = true
            case "--allow-native-human-tracking":
                allowNativeHumanTracking = true
            case "--allow-autonomous-scan":
                allowAutonomousScan = true
            case "--external-gimbal-calibration":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--external-gimbal-calibration requires a calibration JSON path")
                }
                externalGimbalCalibrationURL = URL(fileURLWithPath: arguments[index])
            case "--calibrate-external-gimbal":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--calibrate-external-gimbal requires an output JSON path")
                }
                externalGimbalCalibrationOutputURL = URL(fileURLWithPath: arguments[index])
            case "--diagnostic-snapshot":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--diagnostic-snapshot requires a JPEG output path")
                }
                diagnosticSnapshotURL = URL(fileURLWithPath: arguments[index])
            case "--face-lock-diagnostics":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--face-lock-diagnostics requires a new directory path")
                }
                faceLockDiagnosticDirectoryURL = URL(fileURLWithPath: arguments[index])
            case "--l1-auxiliary-vlm-python":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--l1-auxiliary-vlm-python requires an executable path")
                }
                l1AuxiliaryVLMPythonURL = URL(fileURLWithPath: arguments[index])
            case "--l1-auxiliary-vlm-worker":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--l1-auxiliary-vlm-worker requires a Python worker path")
                }
                l1AuxiliaryVLMWorkerURL = URL(fileURLWithPath: arguments[index])
            case "--l1-auxiliary-vlm-model":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--l1-auxiliary-vlm-model requires a local model directory")
                }
                l1AuxiliaryVLMModel = arguments[index]
            case "--embodiment-shadow-socket":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw RuntimeError.invalidArgument("--embodiment-shadow-socket requires an absolute Unix socket path")
                }
                embodimentShadowSocketURL = URL(fileURLWithPath: arguments[index])
            case "--allow-embodiment-motor-control":
                allowEmbodimentMotorControl = true
            case "--embodiment-view-directory":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw RuntimeError.invalidArgument("--embodiment-view-directory requires an absolute directory path")
                }
                embodimentViewDirectoryURL = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--panorama-output":
                index += 1
                guard index < arguments.count,
                      arguments[index].hasPrefix("/"),
                      ["jpg", "jpeg"].contains(URL(fileURLWithPath: arguments[index]).pathExtension.lowercased()) else {
                    throw RuntimeError.invalidArgument("--panorama-output requires an absolute JPEG path")
                }
                panoramaOutputURL = URL(fileURLWithPath: arguments[index])
            case "--panorama-place-memory":
                index += 1
                guard index < arguments.count,
                      arguments[index].hasPrefix("/"),
                      URL(fileURLWithPath: arguments[index]).pathExtension.lowercased() == "json" else {
                    throw RuntimeError.invalidArgument("--panorama-place-memory requires an absolute JSON path")
                }
                panoramaPlaceMemoryURL = URL(fileURLWithPath: arguments[index])
            case "--camera-geometry-calibration":
                index += 1
                guard index < arguments.count,
                      arguments[index].hasPrefix("/"),
                      URL(fileURLWithPath: arguments[index]).pathExtension.lowercased() == "json" else {
                    throw RuntimeError.invalidArgument("--camera-geometry-calibration requires an absolute JSON path")
                }
                cameraGeometryCalibrationURL = URL(fileURLWithPath: arguments[index])
            case "--capture-camera-geometry":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw RuntimeError.invalidArgument("--capture-camera-geometry requires an absolute new directory path")
                }
                cameraGeometryCaptureDirectoryURL = URL(fileURLWithPath: arguments[index])
            case "--panorama-strip-scan":
                panoramaStripScan = true
            case "--local-speech-recognition":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--local-speech-recognition requires a locale such as ko-KR or en-US")
                }
                localSpeechLocaleIdentifier = arguments[index]
            case "--l2-codex-bridge":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw RuntimeError.invalidArgument("--l2-codex-bridge requires an absolute executable path")
                }
                l2CodexBridgeURL = URL(fileURLWithPath: arguments[index])
            case "--l2-live-voice":
                l2LiveVoice = true
            case "--soma-settings":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw RuntimeError.invalidArgument("--soma-settings requires an absolute JSON path")
                }
                controlSettingsURL = URL(fileURLWithPath: arguments[index])
            case "--help", "-h":
                printUsage()
                Foundation.exit(EXIT_SUCCESS)
            default:
                throw RuntimeError.invalidArgument("Unknown argument: \(arguments[index])")
            }
            index += 1
        }

        guard let videoID, let audioID else {
            throw RuntimeError.invalidArgument("--video-id and --audio-id are required. Use `swift run soma-probe --list-formats` first.")
        }
        let traceRotationPolicy = try rotationPolicy(
            maximumMegabytes: traceMaximumMegabytes,
            retainedFiles: traceRetainedFiles,
            optionPrefix: "trace"
        )
        let importantRotationPolicy = try rotationPolicy(
            maximumMegabytes: importantMaximumMegabytes,
            retainedFiles: importantRetainedFiles,
            optionPrefix: "important"
        )
        if (importantOutputURL == nil) != (importantRotationPolicy == nil) {
            throw RuntimeError.invalidArgument("--important-output, --important-max-megabytes, and --important-retained-files must be supplied together")
        }
        if importantOutputURL == outputURL {
            throw RuntimeError.invalidArgument("--important-output must differ from --output")
        }
        let gimbalTraceRotationPolicy = try rotationPolicy(
            maximumMegabytes: gimbalTraceMaximumMegabytes,
            retainedFiles: gimbalTraceRetainedFiles,
            optionPrefix: "gimbal-trace"
        )
        if gimbalTraceRotationPolicy != nil, gimbalOutputURL == nil {
            throw RuntimeError.invalidArgument("Gimbal trace rotation requires --gimbal-output")
        }
        if guidedScenario, duration != GuidedScenarioPhase.duration {
            throw RuntimeError.invalidArgument("--guided-scenario requires --duration 50")
        }
        if tdoaCalibrationOutputURL != nil, duration != TDOACalibrationPhase.duration {
            throw RuntimeError.invalidArgument("--tdoa-calibrate requires --duration 45")
        }
        if guidedScenario, tdoaCalibrationOutputURL != nil {
            throw RuntimeError.invalidArgument("--guided-scenario and --tdoa-calibrate cannot run together")
        }
        if tdoaCalibrationURL != nil, tdoaCalibrationOutputURL != nil {
            throw RuntimeError.invalidArgument("Choose either --tdoa-calibration or --tdoa-calibrate")
        }
        let wantsExternalControl = allowExternalGimbalControl || allowAutonomousScan
            || allowEmbodimentMotorControl || panoramaStripScan
            || externalGimbalCalibrationURL != nil || externalGimbalCalibrationOutputURL != nil
        let wantsActuation = allowCameraMotion || nativeGimbalHelperURL != nil || gimbalOutputURL != nil || wantsExternalControl || allowNativeHumanTracking
        if wantsActuation {
            guard allowCameraMotion, let nativeGimbalHelperURL, let gimbalOutputURL else {
                throw RuntimeError.invalidArgument("Camera motion requires --allow-camera-motion, --native-gimbal-helper, and --gimbal-output together")
            }
            guard duration.rounded() == duration,
                  duration == 0 || (duration >= 1 && duration <= 30) else {
                throw RuntimeError.invalidArgument("Camera-motion runs require an integer --duration of 0 (continuous) or 1...30 seconds")
            }
            guard !guidedScenario, tdoaCalibrationOutputURL == nil else {
                throw RuntimeError.invalidArgument("Camera motion cannot be combined with guided scenarios or TDOA calibration")
            }
            guard FileManager.default.isExecutableFile(atPath: nativeGimbalHelperURL.path) else {
                throw RuntimeError.invalidArgument("Native gimbal helper is not executable: \(nativeGimbalHelperURL.path)")
            }
            guard !FileManager.default.fileExists(atPath: gimbalOutputURL.path) else {
                throw RuntimeError.invalidArgument("Gimbal trace already exists: \(gimbalOutputURL.path)")
            }
        }
        if wantsExternalControl, externalGimbalCalibrationOutputURL == nil {
            guard allowExternalGimbalControl, let externalGimbalCalibrationURL else {
                throw RuntimeError.invalidArgument("External control requires --allow-external-gimbal-control and --external-gimbal-calibration together")
            }
            guard FileManager.default.fileExists(atPath: externalGimbalCalibrationURL.path) else {
                throw RuntimeError.invalidArgument("External gimbal calibration is unavailable: \(externalGimbalCalibrationURL.path)")
            }
        }
        if allowAutonomousScan, !allowExternalGimbalControl {
            throw RuntimeError.invalidArgument("--allow-autonomous-scan requires --allow-external-gimbal-control")
        }
        if allowEmbodimentMotorControl {
            guard embodimentShadowSocketURL != nil,
                  embodimentViewDirectoryURL != nil,
                  allowExternalGimbalControl else {
                throw RuntimeError.invalidArgument("--allow-embodiment-motor-control requires --embodiment-shadow-socket, --embodiment-view-directory, and --allow-external-gimbal-control")
            }
        } else if embodimentViewDirectoryURL != nil {
            throw RuntimeError.invalidArgument("--embodiment-view-directory requires --allow-embodiment-motor-control")
        }
        if panoramaStripScan {
            guard panoramaOutputURL != nil,
                  allowAutonomousScan,
                  duration == 0 || duration == 30,
                  cameraGeometryCaptureDirectoryURL == nil else {
                throw RuntimeError.invalidArgument("--panorama-strip-scan requires --panorama-output, --allow-autonomous-scan, duration 0 or 30 seconds, and no geometry capture")
            }
        }
        if let calibrationOutputURL = externalGimbalCalibrationOutputURL {
            guard !allowExternalGimbalControl, !allowAutonomousScan, !allowNativeHumanTracking, externalGimbalCalibrationURL == nil else {
                throw RuntimeError.invalidArgument("External calibration cannot be combined with external control, scan, native tracking, or an input calibration")
            }
            guard duration >= 12 else {
                throw RuntimeError.invalidArgument("--calibrate-external-gimbal requires --duration of at least 12 seconds")
            }
            guard !FileManager.default.fileExists(atPath: calibrationOutputURL.path) else {
                throw RuntimeError.invalidArgument("External calibration output already exists: \(calibrationOutputURL.path)")
            }
        }
        if let diagnosticSnapshotURL {
            guard duration > 0, !FileManager.default.fileExists(atPath: diagnosticSnapshotURL.path) else {
                throw RuntimeError.invalidArgument("--diagnostic-snapshot requires a positive --duration and a new output path")
            }
        }
        if let faceLockDiagnosticDirectoryURL {
            guard !FileManager.default.fileExists(atPath: faceLockDiagnosticDirectoryURL.path) else {
                throw RuntimeError.invalidArgument("--face-lock-diagnostics requires a new directory path")
            }
        }
        if panoramaPlaceMemoryURL != nil, panoramaOutputURL == nil {
            throw RuntimeError.invalidArgument("--panorama-place-memory requires --panorama-output")
        }
        if let cameraGeometryCalibrationURL,
           !FileManager.default.fileExists(atPath: cameraGeometryCalibrationURL.path) {
            throw RuntimeError.invalidArgument("Camera geometry calibration is unavailable: \(cameraGeometryCalibrationURL.path)")
        }
        if let cameraGeometryCaptureDirectoryURL {
            guard panoramaOutputURL != nil,
                  duration == 0 || duration >= 30,
                  !FileManager.default.fileExists(atPath: cameraGeometryCaptureDirectoryURL.path) else {
                throw RuntimeError.invalidArgument("--capture-camera-geometry requires --panorama-output, duration 0 or at least 30 seconds, and a new directory")
            }
        }
        if let localSpeechLocaleIdentifier {
            guard !localSpeechLocaleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  localSpeechLocaleIdentifier.count <= 32 else {
                throw RuntimeError.invalidArgument("--local-speech-recognition requires a valid bounded locale identifier")
            }
        }
        if let l2CodexBridgeURL {
            guard localSpeechLocaleIdentifier != nil else {
                throw RuntimeError.invalidArgument("--l2-codex-bridge requires --local-speech-recognition")
            }
            guard FileManager.default.isExecutableFile(atPath: l2CodexBridgeURL.path) else {
                throw RuntimeError.invalidArgument("L2 Codex bridge is not executable: \(l2CodexBridgeURL.path)")
            }
        }
        if l2LiveVoice, l2CodexBridgeURL != nil {
            throw RuntimeError.invalidArgument("Choose either --l2-live-voice or --l2-codex-bridge")
        }
        let l1AuxiliaryValuesPresent = [
            l1AuxiliaryVLMPythonURL != nil,
            l1AuxiliaryVLMWorkerURL != nil,
            l1AuxiliaryVLMModel != nil,
        ]
        if l1AuxiliaryValuesPresent.contains(true) {
            guard l1AuxiliaryValuesPresent.allSatisfy({ $0 }),
                  let l1AuxiliaryVLMPythonURL,
                  let l1AuxiliaryVLMWorkerURL,
                  let l1AuxiliaryVLMModel else {
                throw RuntimeError.invalidArgument("L1 auxiliary VLM requires its Python, worker, and model arguments together")
            }
            guard FileManager.default.isExecutableFile(atPath: l1AuxiliaryVLMPythonURL.path) else {
                throw RuntimeError.invalidArgument("L1 auxiliary VLM Python is not executable: \(l1AuxiliaryVLMPythonURL.path)")
            }
            guard FileManager.default.fileExists(atPath: l1AuxiliaryVLMWorkerURL.path) else {
                throw RuntimeError.invalidArgument("L1 auxiliary VLM worker is unavailable: \(l1AuxiliaryVLMWorkerURL.path)")
            }
            guard !l1AuxiliaryVLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuntimeError.invalidArgument("--l1-auxiliary-vlm-model cannot be empty")
            }
            guard FileManager.default.fileExists(atPath: l1AuxiliaryVLMModel) else {
                throw RuntimeError.invalidArgument("L1 auxiliary VLM model is unavailable locally: \(l1AuxiliaryVLMModel)")
            }
        }
        return Options(
            duration: duration,
            videoID: videoID,
            audioID: audioID,
            outputURL: outputURL,
            traceRotationPolicy: traceRotationPolicy,
            importantOutputURL: importantOutputURL,
            importantRotationPolicy: importantRotationPolicy,
            guidedScenario: guidedScenario,
            tdoaCalibrationURL: tdoaCalibrationURL,
            tdoaCalibrationOutputURL: tdoaCalibrationOutputURL,
            allowCameraMotion: allowCameraMotion,
            nativeGimbalHelperURL: nativeGimbalHelperURL,
            gimbalOutputURL: gimbalOutputURL,
            gimbalTraceRotationPolicy: gimbalTraceRotationPolicy,
            allowNativeHumanTracking: allowNativeHumanTracking,
            allowExternalGimbalControl: allowExternalGimbalControl,
            allowAutonomousScan: allowAutonomousScan,
            externalGimbalCalibrationURL: externalGimbalCalibrationURL,
            externalGimbalCalibrationOutputURL: externalGimbalCalibrationOutputURL,
            diagnosticSnapshotURL: diagnosticSnapshotURL,
            faceLockDiagnosticDirectoryURL: faceLockDiagnosticDirectoryURL,
            l1AuxiliaryVLMPythonURL: l1AuxiliaryVLMPythonURL,
            l1AuxiliaryVLMWorkerURL: l1AuxiliaryVLMWorkerURL,
            l1AuxiliaryVLMModel: l1AuxiliaryVLMModel,
            embodimentShadowSocketURL: embodimentShadowSocketURL,
            allowEmbodimentMotorControl: allowEmbodimentMotorControl,
            embodimentViewDirectoryURL: embodimentViewDirectoryURL,
            panoramaOutputURL: panoramaOutputURL,
            panoramaPlaceMemoryURL: panoramaPlaceMemoryURL,
            cameraGeometryCalibrationURL: cameraGeometryCalibrationURL,
            cameraGeometryCaptureDirectoryURL: cameraGeometryCaptureDirectoryURL,
            panoramaStripScan: panoramaStripScan,
            localSpeechLocaleIdentifier: localSpeechLocaleIdentifier,
            l2CodexBridgeURL: l2CodexBridgeURL,
            l2LiveVoice: l2LiveVoice,
            controlSettingsURL: controlSettingsURL
        )
    }

    private static func defaultOutputURL() -> URL {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/subconscious/subconscious-\(stamp).jsonl")
    }

    private static func rotationPolicy(
        maximumMegabytes: Int?,
        retainedFiles: Int?,
        optionPrefix: String
    ) throws -> JSONLRotationPolicy? {
        guard maximumMegabytes != nil || retainedFiles != nil else { return nil }
        guard let maximumMegabytes,
              let retainedFiles,
              maximumMegabytes > 0,
              retainedFiles > 0,
              maximumMegabytes <= Int.max / 1_048_576 else {
            throw RuntimeError.invalidArgument("--\(optionPrefix)-max-megabytes and --\(optionPrefix)-retained-files must be supplied together as positive integers")
        }
        return JSONLRotationPolicy(
            maximumBytes: maximumMegabytes * 1_048_576,
            retainedFiles: retainedFiles
        )
    }
}

private struct GuidedScenarioPhase {
    static let duration: TimeInterval = 50

    let startsAfterSeconds: TimeInterval
    let state: String
    let instruction: String

    static let phases = [
        GuidedScenarioPhase(startsAfterSeconds: 0, state: "prepare_out_of_frame", instruction: "0-5s: move fully outside the frame and become silent"),
        GuidedScenarioPhase(startsAfterSeconds: 5, state: "quiet_out_of_frame", instruction: "5-15s: remain outside the frame and silent"),
        GuidedScenarioPhase(startsAfterSeconds: 15, state: "enter_and_move", instruction: "15-25s: enter the frame and move normally"),
        GuidedScenarioPhase(startsAfterSeconds: 25, state: "speak_to_camera", instruction: "25-35s: face the camera and speak normally"),
        GuidedScenarioPhase(startsAfterSeconds: 35, state: "exit_and_silence", instruction: "35-45s: leave the frame and remain silent"),
        GuidedScenarioPhase(startsAfterSeconds: 45, state: "settle", instruction: "45-50s: remain out of frame and silent")
    ]
}

private struct TDOACalibrationPhase {
    static let duration: TimeInterval = 45

    let startsAfterSeconds: TimeInterval
    let position: TDOACalibrationPosition
    let instruction: String

    static let phases = [
        TDOACalibrationPhase(startsAfterSeconds: 0, position: .left, instruction: "0-15s: stand left of camera, face it, and speak naturally"),
        TDOACalibrationPhase(startsAfterSeconds: 15, position: .center, instruction: "15-30s: stand centered on camera, face it, and speak naturally"),
        TDOACalibrationPhase(startsAfterSeconds: 30, position: .right, instruction: "30-45s: stand right of camera, face it, and speak naturally")
    ]
}

private struct DeviceIdentity: Codable, Sendable {
    let name: String
    let uniqueID: String
    let modelID: String?
}

private struct VideoConfiguration {
    let requested: String
    let applied: Bool
    let detail: String
}

private struct RuntimeEvent: Encodable, Sendable {
    let event: String
    let monotonicNS: UInt64
    let source: String
    let state: String
    let message: String?
}

private struct BeliefEvent: Encodable, Sendable {
    let event = "subconscious.belief"
    let monotonicNS: UInt64
    let reason: String
    let belief: BeliefSnapshot
}

private struct VoiceEvent: Encodable, Sendable {
    let event = "voice.activity"
    let monotonicNS: UInt64
    let source: String
    let active: Bool
    let confidence: Double
    let levelDB: Double
}

private struct SpeechInteractionTraceEvent: Encodable, Sendable {
    let event = "speech.interaction"
    let monotonicNS: UInt64
    let state: String
    let speechStartedAtNS: UInt64?
    let speechEndedAtNS: UInt64?
    let preRollMilliseconds: UInt64?
    let audioChunkCount: Int?
    let transcriptCharacters: Int?
    let localeIdentifier: String?
    let confidence: Double?
    let latencyMilliseconds: Double?
    let handedToL2: Bool?
    let turnID: String?
    let responseCharacters: Int?
    let reason: String?

    init(_ value: LocalSpeechInteractionState, at monotonicNS: UInt64) {
        self.monotonicNS = monotonicNS
        switch value {
        case let .turnStarted(startedNS, preRollMS, chunkCount, authorization):
            state = "turn_started"
            speechStartedAtNS = startedNS
            speechEndedAtNS = nil
            preRollMilliseconds = preRollMS
            audioChunkCount = chunkCount
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = nil
            turnID = nil
            responseCharacters = nil
            reason = authorization
        case let .turnCancelled(value):
            state = "turn_cancelled"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = nil
            turnID = nil
            responseCharacters = nil
            reason = value
        case let .recognitionCompleted(startedNS, endedNS, characters, locale, score, latencyMS, handedOff):
            state = "recognition_completed"
            speechStartedAtNS = startedNS
            speechEndedAtNS = endedNS
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = characters
            localeIdentifier = locale
            confidence = score
            latencyMilliseconds = latencyMS
            handedToL2 = handedOff
            turnID = nil
            responseCharacters = nil
            reason = nil
        case let .recognitionFailed(value):
            state = "recognition_failed"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = nil
            turnID = nil
            responseCharacters = nil
            reason = value
        case let .l2Completed(value, characters, latencyMS):
            state = "l2_completed"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = latencyMS
            handedToL2 = true
            turnID = value
            responseCharacters = characters
            reason = nil
        case let .l2Failed(value, failure):
            state = "l2_failed"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = false
            turnID = value
            responseCharacters = nil
            reason = failure
        case let .speechStarted(value, characters, locale):
            state = "speech_started"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = locale
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = true
            turnID = value
            responseCharacters = characters
            reason = nil
        case let .speechCompleted(value, durationMS):
            state = "speech_completed"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = durationMS
            handedToL2 = true
            turnID = value
            responseCharacters = nil
            reason = nil
        case let .speechCancelled(value, cancellation):
            state = "speech_cancelled"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = true
            turnID = value
            responseCharacters = nil
            reason = cancellation
        }
    }
}

private final class ConversationContactRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: ConversationContactGate

    init(eyeContactFreshnessMilliseconds: UInt64 = 450) {
        gate = ConversationContactGate(configuration: .init(
            eyeContactFreshnessMilliseconds: eyeContactFreshnessMilliseconds
        ))
    }

    func observe(_ candidates: [SceneCandidate], at monotonicNS: UInt64) {
        let hasEyeContact = candidates.contains { candidate in
            candidate.observedThisFrame
                && candidate.observation.kind == .human
                && candidate.observation.label == "face"
                && candidate.isActionEligible
                && candidate.faceVerificationEligible
                && candidate.eyeContactEligible
        }
        guard hasEyeContact else { return }
        lock.lock()
        gate.observeEyeContact(at: monotonicNS)
        lock.unlock()
    }

    func issueSocialPulse(at monotonicNS: UInt64) {
        lock.lock()
        gate.issueSocialPulse(at: monotonicNS)
        lock.unlock()
    }

    func authorizeSpeechOnset(at monotonicNS: UInt64) -> ConversationOpeningAuthorization? {
        lock.lock()
        defer { lock.unlock() }
        return gate.authorizeSpeechOnset(at: monotonicNS)
    }

    func markConversationOpened(at monotonicNS: UInt64) {
        lock.lock()
        gate.markConversationOpened(at: monotonicNS)
        lock.unlock()
    }

    func recordConversationActivity(at monotonicNS: UInt64) {
        lock.lock()
        gate.recordConversationActivity(at: monotonicNS)
        lock.unlock()
    }

    func closeConversation() {
        lock.lock()
        gate.closeConversation()
        lock.unlock()
    }
}

private struct AudioDirectionEvent: Encodable, Sendable {
    let event = "audio.direction"
    let monotonicNS: UInt64
    let direction: AudioDirection
    let confidence: Double
    let lagSamples: Int
    let fractionalLagSamples: Double
    let delayMilliseconds: Double
    let correlation: Double
}

private struct VisionEvent: Encodable, Sendable {
    let event = "vision.observation"
    let monotonicNS: UInt64
    let source: VisualObservationSource
    let confidence: Double
    let kind: AttentionTargetKind
    let label: String?
    let attentionWeight: Double
    let attentionProbability: Double
    let attentionEntropy: Double
    let captureToBeliefMS: Double
}

private struct FaceIdentityEvent: Encodable, Sendable {
    let schemaVersion = 1
    let event = "identity.observation"
    let monotonicNS: UInt64
    let state: String
    let subject: String
    let confidence: Double
    let inferenceMS: Double
}

/// Face recognition remains a local, probabilistic signal. This tracker only
/// applies an administrator label after the encrypted profile matcher has
/// emitted its repeated-confirmation result, and it expires quickly when the
/// matching face is no longer observed.
private struct InteractionParticipant: Sendable {
    let entityID: UUID
    let authority: SOMAInteractionAuthority
}

private struct IdentityPresenceRuntimeEvent: Encodable, Sendable {
    let schemaVersion = 1
    let event = "identity.presence"
    let monotonicNS: UInt64
    let state: String
    let subject: String
    let previousSubject: String?
    let kind: String
    let confirmations: Int?
    let reason: String
}

/// Holds the most recent primary-face identity decision so a periodic trace
/// heartbeat can re-emit it. The menu bar only reads the tail of the trace, so
/// a sparse identity.observation (emitted only on state transitions) scrolls
/// out of its read window within seconds. Re-emitting the current state keeps a
/// fresh copy available while the face is still present; it is cleared on
/// departure so a stale identity is never replayed after the person leaves.
private final class LatestIdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: String?
    private var subject: String?
    private var label: String?
    private var confidence: Double = 0
    private var observedNS: UInt64 = 0

    func update(state: String, subject: String, label: String, confidence: Double, observedNS: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.state = state
        self.subject = subject
        self.label = label
        self.confidence = confidence
        self.observedNS = observedNS
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        state = nil
        subject = nil
        label = nil
        confidence = 0
        observedNS = 0
    }

    func snapshot() -> (state: String, subject: String, label: String?, confidence: Double, observedNS: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let state, let subject else { return nil }
        return (state, subject, label, confidence, observedNS)
    }
}

/// Writes the current primary-face identity to a small always-current JSON file
/// that the menu bar reads directly (instead of scanning a huge trace tail).
private func writeIdentityState(
    state: String,
    subject: String,
    confidence: Double,
    to url: URL
) {
    let json = "{\"state\":\(JSONString(state)),\"subject\":\(JSONString(subject)),\"confidence\":\(confidence)}\n"
    try? json.write(to: url, atomically: true, encoding: .utf8)
}

private func clearIdentityState(at url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Minimal JSON string literal escaping for the identity file payload. (A bare
/// Swift String is not a valid top-level NSJSONSerialization type, so the
/// escaping must be done by hand.)
private func JSONString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x22: out += "\\\""       // "
        case 0x5C: out += "\\\\"       // backslash
        case 0x08: out += "\\b"
        case 0x0C: out += "\\f"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0x00...0x1F:
            out += String(format: "\\u%04x", scalar.value)
        default:
            out.append(Character(scalar))
        }
    }
    out += "\""
    return out
}

private struct IdentityPresenceUpdate: Sendable {
    let transition: IdentityPresenceTransition
    let participant: InteractionParticipant?
    let l1Decision: FaceIdentityRuntimeDecision?
}

/// Converts face-recognition samples into one socially meaningful presence
/// stream. Its state is local only: opaque IDs select person memory, never a
/// display name or a biometric projection.
private final class IdentityPresenceCoordinator: @unchecked Sendable {
    private let administrator: SOMAAdministratorIdentity?
    private let openWithUnknownIdentity: Bool
    private let lock = NSLock()
    private var tracker = IdentityPresenceTracker()
    private var latestParticipant: InteractionParticipant?

    init(administrator: SOMAAdministratorIdentity?, openWithUnknownIdentity: Bool = false) {
        self.administrator = administrator
        self.openWithUnknownIdentity = openWithUnknownIdentity
    }

    func observe(
        _ decision: FaceIdentityRuntimeDecision,
        at monotonicNS: UInt64
    ) -> [IdentityPresenceUpdate] {
        let identity: IdentityPresenceIdentity
        switch decision {
        case let .known(entityID, _, _):
            identity = IdentityPresenceIdentity(entityID: entityID, kind: .enrolled)
        case let .anonymous(entityID, _, _, _):
            identity = IdentityPresenceIdentity(entityID: entityID, kind: .pseudonymous)
        case let .unknownCandidate(handle, _):
            // When proactive openings with unknown identities are enabled, an
            // unrecognized face is treated as a pseudonymous participant so L1
            // may open with it. The entityID is derived from the anonymous
            // handle, so a later promotion to a registered anonymous identity
            // keeps the same participant identity.
            guard openWithUnknownIdentity else { return [] }
            identity = IdentityPresenceIdentity(
                entityID: FaceIdentityRuntime.pseudonymousEntityID(for: handle),
                kind: .pseudonymous
            )
        case .knownCandidate:
            return []
        }
        lock.lock()
        let updates = materialize(
            tracker.observe(identity, at: monotonicNS),
            decision: decision
        )
        lock.unlock()
        return updates
    }

    func observeVerifiedFace(_ present: Bool, at monotonicNS: UInt64) -> [IdentityPresenceUpdate] {
        lock.lock()
        defer { lock.unlock() }
        if present {
            tracker.recordVerifiedFace(at: monotonicNS)
        }
        return materialize(tracker.advance(at: monotonicNS), decision: nil)
    }

    func interactionReference() -> String? {
        guard let participant = currentParticipant() else { return nil }
        switch participant.authority {
        case .administrator:
            return "verified_local_administrator; person context is available only through the supplied local MCP reference"
        case .participant:
            return "locally recognized conversation participant; do not infer or speak a name beyond explicitly stored person context"
        }
    }

    func recognizedPersonEntityID() -> UUID? {
        currentParticipant()?.entityID
    }

    func authority(for personEntityID: UUID) -> SOMAInteractionAuthority {
        personEntityID == administrator?.entityID ? .administrator : .participant
    }

    func hasCurrentParticipant(_ personEntityID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestParticipant?.entityID == personEntityID
    }

    func currentParticipant() -> InteractionParticipant? {
        lock.lock()
        defer { lock.unlock() }
        return latestParticipant
    }

    private func materialize(
        _ transitions: [IdentityPresenceTransition],
        decision: FaceIdentityRuntimeDecision?
    ) -> [IdentityPresenceUpdate] {
        transitions.map { transition in
            switch transition {
            case let .arrived(identity):
                let participant = participant(for: identity)
                latestParticipant = participant
                return IdentityPresenceUpdate(
                    transition: transition,
                    participant: participant,
                    l1Decision: decision
                )
            case let .replaced(_, current):
                let participant = participant(for: current)
                latestParticipant = participant
                return IdentityPresenceUpdate(
                    transition: transition,
                    participant: participant,
                    l1Decision: decision
                )
            case let .departed(identity):
                if latestParticipant?.entityID == identity.entityID {
                    latestParticipant = nil
                }
                return IdentityPresenceUpdate(
                    transition: transition,
                    participant: nil,
                    l1Decision: nil
                )
            case .replacementCandidate:
                return IdentityPresenceUpdate(
                    transition: transition,
                    participant: nil,
                    l1Decision: nil
                )
            }
        }
    }

    private func participant(for identity: IdentityPresenceIdentity) -> InteractionParticipant {
        InteractionParticipant(
            entityID: identity.entityID,
            authority: identity.entityID == administrator?.entityID ? .administrator : .participant
        )
    }
}

/// Maintains a short, multi-person recognition window separately from the
/// single social participant stream. A speaker/interaction handoff remains a
/// deliberate one-person decision, while administrator MCP queries can still
/// report everyone independently recognized in the current view.
private final class PresentIdentityRoster: @unchecked Sendable {
    private struct Entry: Sendable {
        let identity: IdentityPresenceIdentity
        let confidence: Double
        let lastSeenNS: UInt64
        let anonymousHandle: AnonymousFaceHandle?
    }

    private let lock = NSLock()
    private let retentionNS: UInt64 = 3_000_000_000
    private var entries: [UUID: Entry] = [:]

    func record(_ decision: FaceIdentityRuntimeDecision, at monotonicNS: UInt64) {
        let identity: IdentityPresenceIdentity
        let anonymousHandle: AnonymousFaceHandle?
        switch decision {
        case let .known(entityID, _, _):
            identity = .init(entityID: entityID, kind: .enrolled)
            anonymousHandle = nil
        case let .anonymous(entityID, handle, _, _):
            identity = .init(entityID: entityID, kind: .pseudonymous)
            anonymousHandle = handle
        case .unknownCandidate, .knownCandidate:
            return
        }
        lock.lock()
        prune(at: monotonicNS)
        entries[identity.entityID] = Entry(
            identity: identity,
            confidence: decision.confidence,
            lastSeenNS: monotonicNS,
            anonymousHandle: anonymousHandle
        )
        lock.unlock()
    }

    func promoteableAnonymousHandle(
        for personEntityID: UUID,
        at monotonicNS: UInt64
    ) -> AnonymousFaceHandle? {
        lock.lock()
        defer { lock.unlock() }
        prune(at: monotonicNS)
        return entries[personEntityID]?.anonymousHandle
    }

    func entries(at monotonicNS: UInt64) -> [(identity: IdentityPresenceIdentity, confidence: Double, ageMS: UInt64)] {
        lock.lock()
        defer { lock.unlock() }
        prune(at: monotonicNS)
        return entries.values
            .map { entry in
                (
                    identity: entry.identity,
                    confidence: entry.confidence,
                    ageMS: monotonicNS >= entry.lastSeenNS
                        ? (monotonicNS - entry.lastSeenNS) / 1_000_000
                        : 0
                )
            }
            .sorted {
                if $0.ageMS != $1.ageMS { return $0.ageMS < $1.ageMS }
                return $0.identity.entityID.uuidString < $1.identity.entityID.uuidString
            }
    }

    private func prune(at monotonicNS: UInt64) {
        entries = entries.filter { _, entry in
            monotonicNS >= entry.lastSeenNS && monotonicNS - entry.lastSeenNS < retentionNS
        }
    }
}

/// Composes the natural-language L1 thought for the diagnostic thought log:
/// the situation summary, the social-decision rationale, the working
/// hypothesis, and any spoken-opening text the model chose.
private func l1ThoughtStreamMessage(
    for frame: L1SituationFrame,
    action: String
) -> String {
    var parts: [String] = ["action=\(action)"]
    if !frame.summary.isEmpty {
        parts.append(frame.summary)
    }
    if let hypothesis = frame.thoughtState?.workingHypothesis, !hypothesis.isEmpty {
        parts.append("hypothesis: \(hypothesis)")
    }
    if let rationale = frame.socialDecision?.rationale, !rationale.isEmpty {
        parts.append("rationale: \(rationale)")
    }
    switch frame.socialDecision?.openingContent {
    case .greeting:
        parts.append("opening: greeting")
    case let .question(_, text):
        parts.append("opening: \(text)")
    case nil:
        break
    }
    return parts.joined(separator: " · ")
}

private func identityDiagnosticLabel(
    for decision: FaceIdentityRuntimeDecision,
    administrator: SOMAAdministratorIdentity?
) -> String {
    switch decision {
    case let .known(entityID, similarity, _):
        if entityID == administrator?.entityID {
            let name = administrator?.preferredAddress ?? administrator?.displayName ?? "Administrator"
            return "\(name) · known \(String(format: "%.2f", similarity))"
        }
        return "known \(entityID.uuidString.prefix(8)) \(String(format: "%.2f", similarity))"
    case let .knownCandidate(entityID, similarity):
        return "candidate \(entityID.uuidString.prefix(8)) \(String(format: "%.2f", similarity))"
    case let .anonymous(entityID, _, similarity, _):
        return "anonymous \(entityID.uuidString.prefix(8)) \(String(format: "%.2f", similarity))"
    case .unknownCandidate:
        return "unknown"
    }
}

private func identityPresenceRuntimeEvent(
    for transition: IdentityPresenceTransition,
    at monotonicNS: UInt64
) -> IdentityPresenceRuntimeEvent {
    func subject(_ identity: IdentityPresenceIdentity) -> String {
        identity.entityID.uuidString.lowercased()
    }
    switch transition {
    case let .arrived(identity):
        return IdentityPresenceRuntimeEvent(
            monotonicNS: monotonicNS,
            state: "arrived",
            subject: subject(identity),
            previousSubject: nil,
            kind: identity.kind.rawValue,
            confirmations: nil,
            reason: "recognized_identity"
        )
    case let .replacementCandidate(previous, candidate, confirmations):
        return IdentityPresenceRuntimeEvent(
            monotonicNS: monotonicNS,
            state: "replacement_candidate",
            subject: subject(candidate),
            previousSubject: subject(previous),
            kind: candidate.kind.rawValue,
            confirmations: confirmations,
            reason: "distinct_recognized_identity"
        )
    case let .replaced(previous, current):
        return IdentityPresenceRuntimeEvent(
            monotonicNS: monotonicNS,
            state: "replaced",
            subject: subject(current),
            previousSubject: subject(previous),
            kind: current.kind.rawValue,
            confirmations: nil,
            reason: "repeated_distinct_identity"
        )
    case let .departed(identity):
        return IdentityPresenceRuntimeEvent(
            monotonicNS: monotonicNS,
            state: "departed",
            subject: subject(identity),
            previousSubject: nil,
            kind: identity.kind.rawValue,
            confirmations: nil,
            reason: "verified_face_absent"
        )
    }
}

/// Forwards E2B's proportional reaction from the auxiliary VLM cue path to the
/// AttentionGimbalBridge, which is created later in setup. The cue closure runs
/// before the bridge exists, so the sink is attached once the bridge is up.
private final class L1AuxiliaryReactionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (L1AuxiliaryReaction, UInt64) -> Void)?

    func record(_ reaction: L1AuxiliaryReaction, at monotonicNS: UInt64) {
        lock.lock()
        let active = sink
        lock.unlock()
        active?(reaction, monotonicNS)
    }

    func attach(_ sink: @escaping @Sendable (L1AuxiliaryReaction, UInt64) -> Void) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }
}

/// Forwards E2B's scalar wake proposal to the primary L1 stream, which is
/// created later in setup. The interrupt closure runs before the L1 stream
/// exists, so the proposal is buffered here and forwarded once the stream is up.
private final class L1AuxiliaryWakeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (L1AuxiliarySemanticInterrupt) -> Void)?

    func record(_ interrupt: L1AuxiliarySemanticInterrupt) {
        lock.lock()
        let active = sink
        lock.unlock()
        active?(interrupt)
    }

    func attach(_ sink: @escaping @Sendable (L1AuxiliarySemanticInterrupt) -> Void) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }
}

private struct L1AuxiliarySemanticTraceEvent: Encodable, Sendable {
    let event = "l1.auxiliary.semantic"
    let requestID: UInt64
    let monotonicNS: UInt64
    let captureNS: UInt64
    let source: String
    let summary: String
    let novelty: Double
    let socialPresence: Double
    let attentionHint: L1AuxiliaryAttentionHint
    let situation: L1AuxiliarySituation
    let wakeReason: L1AuxiliaryWakeReason
    let wakeScore: Double
    let confidence: Double
    let eyeContact: Double
    let engagement: Double
    let bodyLanguage: L1AuxiliaryBodyLanguage
    let gesture: L1AuxiliaryGesture
    let approach: L1AuxiliaryApproach
    let reaction: L1AuxiliaryReaction
    let inferenceMS: Double
    let captureToCueMS: Double

    init(_ cue: L1AuxiliarySemanticCue) {
        requestID = cue.requestID
        monotonicNS = cue.completedNS
        captureNS = cue.captureNS
        source = cue.source
        summary = cue.summary
        novelty = cue.novelty
        socialPresence = cue.socialPresence
        attentionHint = cue.attentionHint
        situation = cue.situation
        wakeReason = cue.wakeReason
        wakeScore = cue.wakeScore
        confidence = cue.confidence
        eyeContact = cue.eyeContact
        engagement = cue.engagement
        bodyLanguage = cue.bodyLanguage
        gesture = cue.gesture
        approach = cue.approach
        reaction = cue.reaction
        inferenceMS = cue.inferenceMS
        captureToCueMS = milliseconds(from: cue.captureNS, to: cue.completedNS)
    }
}

private struct L1AuxiliarySemanticInterruptTraceEvent: Encodable, Sendable {
    let event = "l1.auxiliary.wake_proposal"
    let requestID: UInt64
    let monotonicNS: UInt64
    let captureNS: UInt64
    let situation: L1AuxiliarySituation
    let reason: L1AuxiliaryWakeReason
    let score: Double
    let confidence: Double
    let evidence: String

    init(_ interrupt: L1AuxiliarySemanticInterrupt) {
        requestID = interrupt.requestID
        monotonicNS = interrupt.completedNS
        captureNS = interrupt.captureNS
        situation = interrupt.situation
        reason = interrupt.reason
        score = interrupt.score
        confidence = interrupt.confidence
        evidence = interrupt.evidence
    }
}

private struct EmbodimentShadowTraceEvent: Encodable, Sendable {
    let event = "embodiment.decision"
    let monotonicNS: UInt64
    let requestID: String
    let layer: CognitiveControlLayer
    let operation: CognitiveEmbodimentOperationKind
    let status: EmbodimentShadowStatus
    let reason: String
    let preemptedRequestID: String?
    let activeOwnerID: String?
    let activeOperation: CognitiveEmbodimentOperationKind?
    let activeTargetReference: String?
    let activePriority: UInt8?
    let registeredTargetCount: Int
    let attentionPolicyOwnerCount: Int
    let physicalActuationEnabled: Bool

    init(_ decision: EmbodimentShadowDecision) {
        monotonicNS = decision.snapshot.monotonicNS
        requestID = decision.requestID
        layer = decision.layer
        operation = decision.operation
        status = decision.status
        reason = decision.reason
        preemptedRequestID = decision.preemptedRequestID
        activeOwnerID = decision.snapshot.activeOwnerID
        activeOperation = decision.snapshot.activeOperation
        activeTargetReference = decision.snapshot.activeTargetReference
        activePriority = decision.snapshot.activePriority
        registeredTargetCount = decision.snapshot.registeredTargets.count
        attentionPolicyOwnerCount = decision.snapshot.attentionPolicyOwners.count
        physicalActuationEnabled = decision.snapshot.physicalActuationEnabled
    }
}

private struct EmbodimentMotorTraceEvent: Encodable, Sendable {
    let event = "embodiment.motor"
    let monotonicNS: UInt64
    let requestID: String?
    let action: String
    let reason: String?
    let targetReference: String?
    let sceneID: String?
    let targetAzimuthDegrees: Double?
    let targetElevationDegrees: Double?
    let fieldOfViewDegrees: Double?
    let observedThisFrame: Bool?
    let expiresAtNS: UInt64?

    init(_ intent: EmbodimentMotorIntent, monotonicNS: UInt64) {
        self.monotonicNS = monotonicNS
        switch intent {
        case let .orient(requestID, bearing, _, _, expiresAtNS, reason):
            self.requestID = requestID
            action = "orient"
            self.reason = reason
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = bearing.azimuthDegrees
            targetElevationDegrees = bearing.elevationDegrees
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            self.expiresAtNS = expiresAtNS
        case let .track(requestID, targetReference, sceneID, bearing, observed, _, expiresAtNS):
            self.requestID = requestID
            action = "track"
            reason = nil
            self.targetReference = targetReference
            self.sceneID = sceneID
            targetAzimuthDegrees = bearing.azimuthDegrees
            targetElevationDegrees = bearing.elevationDegrees
            fieldOfViewDegrees = nil
            observedThisFrame = observed
            self.expiresAtNS = expiresAtNS
        case let .capture(requestID, targetReference, sceneID, bearing, fieldOfView, expiresAtNS):
            self.requestID = requestID
            action = "capture"
            reason = "capture_view_alignment"
            self.targetReference = targetReference
            self.sceneID = sceneID
            targetAzimuthDegrees = bearing.azimuthDegrees
            targetElevationDegrees = bearing.elevationDegrees
            fieldOfViewDegrees = fieldOfView
            observedThisFrame = nil
            self.expiresAtNS = expiresAtNS
        case let .explore(requestID, policy, expiresAtNS):
            self.requestID = requestID
            action = "explore"
            reason = policy.mode.rawValue
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            self.expiresAtNS = expiresAtNS
        case let .express(requestID, expression, expiresAtNS):
            self.requestID = requestID
            action = "express"
            reason = expression.rawValue
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            self.expiresAtNS = expiresAtNS
        case let .suspend(requestID, reason, expiresAtNS):
            self.requestID = requestID
            action = "suspend"
            self.reason = reason
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            self.expiresAtNS = expiresAtNS
        case let .release(requestID, reason):
            self.requestID = requestID
            action = "release"
            self.reason = reason
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            expiresAtNS = nil
        }
    }
}

private struct SemanticBindingTraceEvent: Encodable, Sendable {
    let event = "semantic.binding"
    let monotonicNS: UInt64
    let sourceSceneNS: UInt64
    let targetReference: String
    let sceneID: String?
    let status: SemanticTargetBindingStatus
    let posteriorProbability: Double
    let normalizedEntropy: Double
    let reason: String
    let observedThisFrame: Bool
    let motorCommandIssued = false

    init(_ binding: SemanticTargetBinding, sourceSceneNS: UInt64, monotonicNS: UInt64) {
        self.monotonicNS = monotonicNS
        self.sourceSceneNS = sourceSceneNS
        targetReference = binding.targetReference
        sceneID = binding.sceneID
        status = binding.status
        posteriorProbability = binding.posteriorProbability
        normalizedEntropy = binding.normalizedEntropy
        reason = binding.reason
        observedThisFrame = binding.observedThisFrame
    }
}

/// Scalar-only audit record for every active scene candidate. No pixels or
/// embeddings are persisted; labels remain hypotheses rather than identities.
private struct SceneEvent: Encodable, Sendable {
    let event = "scene.candidate"
    let monotonicNS: UInt64
    let sceneID: String
    let source: VisualObservationSource
    let kind: AttentionTargetKind
    let label: String?
    let confidence: Double
    let centerX: Double
    let centerY: Double
    let width: Double
    let height: Double
    let observedThisFrame: Bool
    let observationCount: Int
    let stabilityMilliseconds: Double
    let sourceCount: Int
    let actionEligible: Bool
    let faceActivityEligible: Bool
    let faceVerified: Bool
    let trackingMinimumCenterX: Double
    let trackingMaximumCenterX: Double
    let trackingMinimumCenterY: Double
    let trackingMaximumCenterY: Double
    let azimuthDegrees: Double?
    let elevationDegrees: Double?
    let spatialConfidence: Double
    let lastSeenMilliseconds: Double
}

private struct CameraIntentEvent: Encodable, Sendable {
    let event = "camera.intent"
    let monotonicNS: UInt64
    let owner: CameraControlOwner
    let state: String
    let route: AttentionActuatorRoute
    let commandID: String
    let targetKind: AttentionTargetKind?
    let targetLabel: String?
    let targetProbability: Double
}

/// The state captured whenever the bridge asks the native helper to stop.
/// This is diagnostic-only: it never participates in target selection or
/// motor control. The accompanying recorder links it to the latest bounded
/// face-lock JPEG so a stationary failure can be reconstructed afterwards.
private struct GimbalStopDiagnostic: Sendable {
    let monotonicNS: UInt64
    let reason: String
    let faceLockActive: Bool
    let faceLockMotorPermitted: Bool
    let lastObservedFaceMilliseconds: Double?
    let targetID: String?
    let targetKind: AttentionTargetKind?
    let targetLabel: String?
    let targetConfidence: Double?
    let targetCenterX: Double?
    let targetCenterY: Double?
    let targetActionEligible: Bool?
    let posePitchDegrees: Double?
    let posePanDegrees: Double?
}

private struct MetricsEvent: Encodable, Sendable {
    let event = "subconscious.metrics"
    let monotonicNS: UInt64
    let videoCallbacks: Int
    let audioCallbacks: Int
    let visionUpdates: Int
    let visionMisses: Int
    let visionFramesSkipped: Int
    let videoFramesSuperseded: Int
    let audioVADFramesSuperseded: Int
    let neuralEngineInferences: Int
    let neuralFaceInferences: Int
    let neuralVADInferences: Int
    let maximumVideoCallbackMS: Double
    let maximumAudioCallbackMS: Double
    let averageVideoCallbackMS: Double
    let averageAudioCallbackMS: Double
    let maximumVideoFrameIntervalMS: Double
    let maximumAudioCallbackIntervalMS: Double
    let maximumVisionMS: Double
    let maximumCaptureToBeliefMS: Double
    let averageNeuralEngineMS: Double
    let maximumNeuralEngineMS: Double
    let averageNeuralVADMS: Double
    let maximumNeuralVADMS: Double
    let maximumVADWindowEndToEvidenceMS: Double
}

private enum LongTermDisposition: Sendable {
    case never
    case always
    case onChange(key: String, fingerprint: String)
    case periodic(key: String, minimumIntervalNS: UInt64)
}

private protocol TraceEvent: Encodable, Sendable {
    var monotonicNS: UInt64 { get }
    var longTermDisposition: LongTermDisposition { get }
}

private extension TraceEvent {
    var longTermDisposition: LongTermDisposition { .never }
}

extension RuntimeEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition {
        if event.hasPrefix("scenario.") { return .always }
        if source == "attention_gimbal_bridge", state.hasPrefix("coverage_") { return .never }
        let failureStates = ["error", "fail", "fault", "reject", "timeout", "unavailable", "disconnect", "interrupt"]
        let isFailure = failureStates.contains { state.localizedCaseInsensitiveContains($0) }
        let fingerprint = isFailure ? "\(state)|\(message ?? "")" : state
        return .onChange(key: "runtime:\(event):\(source)", fingerprint: fingerprint)
    }
}

extension BeliefEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition {
        let target = belief.target
        let fingerprint = [
            belief.targetStatus.rawValue,
            belief.attentionCue.route.rawValue,
            target?.kind.rawValue ?? "none",
            target?.label ?? "none",
        ].joined(separator: "|")
        return .onChange(key: "belief", fingerprint: fingerprint)
    }
}

extension VoiceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}

extension SpeechInteractionTraceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}

extension AudioDirectionEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition {
        .onChange(key: "audio.direction", fingerprint: direction.rawValue)
    }
}
extension VisionEvent: TraceEvent {}
extension FaceIdentityEvent: TraceEvent {}
extension IdentityPresenceRuntimeEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}
extension L1AuxiliarySemanticTraceEvent: TraceEvent {}
extension L1AuxiliarySemanticInterruptTraceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}
extension EmbodimentShadowTraceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}
extension EmbodimentMotorTraceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}
extension SemanticBindingTraceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}
extension SceneEvent: TraceEvent {}
extension CameraIntentEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition {
        let mode: String
        if state.hasPrefix("coverage_") || state.hasPrefix("autonomous_scan_") {
            mode = "exploration"
        } else if state == "face_servo_velocity_requested"
                    || state == "social_reframe_requested"
                    || state == "native_tracking_requested" {
            mode = "social_tracking"
        } else {
            mode = state
        }
        let fingerprint = [
            owner.rawValue,
            mode,
            route.rawValue,
            targetKind?.rawValue ?? "none",
            targetLabel ?? "none",
        ].joined(separator: "|")
        return .onChange(key: "camera.intent", fingerprint: fingerprint)
    }
}

extension MetricsEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition {
        .periodic(key: "metrics", minimumIntervalNS: 3_600_000_000_000)
    }
}

private final class JSONLWriter: @unchecked Sendable {
    private struct PendingEvent {
        let monotonicNS: UInt64
        let data: Data
        let longTermDisposition: LongTermDisposition
    }

    private let queue = DispatchQueue(label: "soma.subconscious.trace")
    private let detailedStore: RotatingJSONLStore
    private let importantStore: RotatingJSONLStore?
    private let encoder: JSONEncoder
    private let reorderWindowNS: UInt64 = 20_000_000
    private var pending: [PendingEvent] = []
    private var greatestQueuedNS: UInt64 = 0
    private var lastWrittenNS: UInt64 = 0
    private var lateEventsDropped = 0
    private var lastImportantFingerprint: [String: String] = [:]
    private var lastImportantNS: [String: UInt64] = [:]

    init(
        url: URL,
        rotationPolicy: JSONLRotationPolicy? = nil,
        importantURL: URL? = nil,
        importantRotationPolicy: JSONLRotationPolicy? = nil
    ) throws {
        do {
            detailedStore = try RotatingJSONLStore(baseURL: url, policy: rotationPolicy)
            if let importantURL, let importantRotationPolicy {
                importantStore = try RotatingJSONLStore(
                    baseURL: importantURL,
                    policy: importantRotationPolicy
                )
            } else {
                importantStore = nil
            }
        } catch {
            throw RuntimeError.configuration("Cannot create trace output: \(error.localizedDescription)")
        }
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    func write<T: TraceEvent>(_ event: T) {
        queue.async { [weak self] in
            guard let self, var data = try? self.encoder.encode(event) else { return }
            data.append(0x0A)
            self.enqueue(PendingEvent(
                monotonicNS: event.monotonicNS,
                data: data,
                longTermDisposition: event.longTermDisposition
            ))
        }
    }

    func close() {
        queue.sync {
            flush(through: UInt64.max)
            try? detailedStore.close()
            try? importantStore?.close()
        }
    }

    func drain() -> Int {
        queue.sync {
            flush(through: UInt64.max)
            return lateEventsDropped
        }
    }

    private func enqueue(_ event: PendingEvent) {
        greatestQueuedNS = max(greatestQueuedNS, event.monotonicNS)
        pending.append(event)
        let cutoff = greatestQueuedNS > reorderWindowNS ? greatestQueuedNS - reorderWindowNS : 0
        flush(through: cutoff)
    }

    private func flush(through cutoff: UInt64) {
        pending.sort { $0.monotonicNS < $1.monotonicNS }
        var future: [PendingEvent] = []
        for event in pending {
            guard event.monotonicNS <= cutoff else {
                future.append(event)
                continue
            }
            guard event.monotonicNS >= lastWrittenNS else {
                lateEventsDropped += 1
                continue
            }
            try? detailedStore.write(event.data)
            if shouldWriteLongTerm(event.longTermDisposition, at: event.monotonicNS) {
                try? importantStore?.write(event.data)
            }
            lastWrittenNS = event.monotonicNS
        }
        pending = future
    }

    private func shouldWriteLongTerm(_ disposition: LongTermDisposition, at monotonicNS: UInt64) -> Bool {
        guard importantStore != nil else { return false }
        switch disposition {
        case .never:
            return false
        case .always:
            return true
        case .onChange(let key, let fingerprint):
            guard lastImportantFingerprint[key] != fingerprint else { return false }
            lastImportantFingerprint[key] = fingerprint
            lastImportantNS[key] = monotonicNS
            return true
        case .periodic(let key, let minimumIntervalNS):
            if let previousNS = lastImportantNS[key],
               monotonicNS >= previousNS,
               monotonicNS - previousNS < minimumIntervalNS {
                return false
            }
            lastImportantNS[key] = monotonicNS
            return true
        }
    }
}

private final class LatencyCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var videoCallbacks = 0
    private var audioCallbacks = 0
    private var visionUpdates = 0
    private var visionMisses = 0
    private var visionFramesSkipped = 0
    private var supersededFrames = 0
    private var supersededAudioVADFrames = 0
    private var neuralEngineInferences = 0
    private var neuralFaceInferences = 0
    private var neuralVADInferences = 0
    private var previousVideoNS: UInt64?
    private var previousAudioNS: UInt64?
    private var maximumVideoCallbackMS = 0.0
    private var maximumAudioCallbackMS = 0.0
    private var totalVideoCallbackMS = 0.0
    private var totalAudioCallbackMS = 0.0
    private var maximumVideoFrameIntervalMS = 0.0
    private var maximumAudioCallbackIntervalMS = 0.0
    private var maximumVisionMS = 0.0
    private var maximumCaptureToBeliefMS = 0.0
    private var totalNeuralEngineMS = 0.0
    private var maximumNeuralEngineMS = 0.0
    private var totalNeuralVADMS = 0.0
    private var maximumNeuralVADMS = 0.0
    private var maximumVADWindowEndToEvidenceMS = 0.0

    func videoCallback(at now: UInt64, processingMS: Double) {
        lock.lock()
        defer { lock.unlock() }
        videoCallbacks += 1
        if let previousVideoNS { maximumVideoFrameIntervalMS = max(maximumVideoFrameIntervalMS, milliseconds(from: previousVideoNS, to: now)) }
        previousVideoNS = now
        maximumVideoCallbackMS = max(maximumVideoCallbackMS, processingMS)
        totalVideoCallbackMS += processingMS
    }

    func audioCallback(at now: UInt64, processingMS: Double) {
        lock.lock()
        defer { lock.unlock() }
        audioCallbacks += 1
        if let previousAudioNS { maximumAudioCallbackIntervalMS = max(maximumAudioCallbackIntervalMS, milliseconds(from: previousAudioNS, to: now)) }
        previousAudioNS = now
        maximumAudioCallbackMS = max(maximumAudioCallbackMS, processingMS)
        totalAudioCallbackMS += processingMS
    }

    func visionUpdate(inferenceMS: Double, captureToBeliefMS: Double) {
        lock.lock()
        visionUpdates += 1
        maximumVisionMS = max(maximumVisionMS, inferenceMS)
        maximumCaptureToBeliefMS = max(maximumCaptureToBeliefMS, captureToBeliefMS)
        lock.unlock()
    }

    func visionMiss(inferenceMS: Double, captureToBeliefMS: Double) {
        lock.lock()
        visionMisses += 1
        maximumVisionMS = max(maximumVisionMS, inferenceMS)
        maximumCaptureToBeliefMS = max(maximumCaptureToBeliefMS, captureToBeliefMS)
        lock.unlock()
    }

    func visionFrameSkipped() {
        lock.lock()
        visionFramesSkipped += 1
        lock.unlock()
    }

    func neuralEngineInference(inferenceMS: Double) {
        lock.lock()
        neuralEngineInferences += 1
        totalNeuralEngineMS += inferenceMS
        maximumNeuralEngineMS = max(maximumNeuralEngineMS, inferenceMS)
        lock.unlock()
    }

    func neuralFaceInference() {
        lock.lock()
        neuralFaceInferences += 1
        lock.unlock()
    }

    func neuralVADInference(inferenceMS: Double, windowEndToEvidenceMS: Double) {
        lock.lock()
        neuralVADInferences += 1
        totalNeuralVADMS += inferenceMS
        maximumNeuralVADMS = max(maximumNeuralVADMS, inferenceMS)
        maximumVADWindowEndToEvidenceMS = max(maximumVADWindowEndToEvidenceMS, windowEndToEvidenceMS)
        lock.unlock()
    }

    func supersedeFrame() {
        lock.lock()
        supersededFrames += 1
        lock.unlock()
    }

    func supersedeAudioVADFrame() {
        lock.lock()
        supersededAudioVADFrames += 1
        lock.unlock()
    }

    func snapshot(at now: UInt64) -> MetricsEvent {
        lock.lock()
        defer { lock.unlock() }
        return MetricsEvent(
            monotonicNS: now,
            videoCallbacks: videoCallbacks,
            audioCallbacks: audioCallbacks,
            visionUpdates: visionUpdates,
            visionMisses: visionMisses,
            visionFramesSkipped: visionFramesSkipped,
            videoFramesSuperseded: supersededFrames,
            audioVADFramesSuperseded: supersededAudioVADFrames,
            neuralEngineInferences: neuralEngineInferences,
            neuralFaceInferences: neuralFaceInferences,
            neuralVADInferences: neuralVADInferences,
            maximumVideoCallbackMS: maximumVideoCallbackMS,
            maximumAudioCallbackMS: maximumAudioCallbackMS,
            averageVideoCallbackMS: videoCallbacks == 0 ? 0 : totalVideoCallbackMS / Double(videoCallbacks),
            averageAudioCallbackMS: audioCallbacks == 0 ? 0 : totalAudioCallbackMS / Double(audioCallbacks),
            maximumVideoFrameIntervalMS: maximumVideoFrameIntervalMS,
            maximumAudioCallbackIntervalMS: maximumAudioCallbackIntervalMS,
            maximumVisionMS: maximumVisionMS,
            maximumCaptureToBeliefMS: maximumCaptureToBeliefMS,
            averageNeuralEngineMS: neuralEngineInferences == 0 ? 0 : totalNeuralEngineMS / Double(neuralEngineInferences),
            maximumNeuralEngineMS: maximumNeuralEngineMS,
            averageNeuralVADMS: neuralVADInferences == 0 ? 0 : totalNeuralVADMS / Double(neuralVADInferences),
            maximumNeuralVADMS: maximumNeuralVADMS,
            maximumVADWindowEndToEvidenceMS: maximumVADWindowEndToEvidenceMS
        )
    }
}

private final class VideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let captureNS: UInt64
    let exposureNS: UInt64

    init(pixelBuffer: CVPixelBuffer, captureNS: UInt64, exposureNS: UInt64) {
        self.pixelBuffer = pixelBuffer
        self.captureNS = captureNS
        self.exposureNS = exposureNS
    }
}

private final class LatestFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: VideoFrame?
    private var signalPending = false

    func publish(_ frame: VideoFrame) -> (shouldWake: Bool, superseded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let superseded = latest != nil
        latest = frame
        if signalPending { return (false, superseded) }
        signalPending = true
        return (true, superseded)
    }

    func take() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        signalPending = false
        defer { latest = nil }
        return latest
    }
}

private final class BeliefPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: JSONLWriter
    private let onPublished: ((BeliefSnapshot, String) -> Void)?
    private var lastPublishNS: UInt64 = 0
    private var lastPolicy: ActiveSensingPolicy?
    private var lastTargetStatus: TargetStatus?
    private var lastAttentionCue: AttentionCue?

    init(writer: JSONLWriter, onPublished: ((BeliefSnapshot, String) -> Void)? = nil) {
        self.writer = writer
        self.onPublished = onPublished
    }

    func publish(_ belief: BeliefSnapshot, reason: String, force: Bool = false) {
        lock.lock()
        guard belief.monotonicNS >= lastPublishNS else {
            lock.unlock()
            return
        }
        let changed = belief.policy != lastPolicy
            || belief.targetStatus != lastTargetStatus
            || belief.attentionCue != lastAttentionCue
        let due = belief.monotonicNS - lastPublishNS >= 100_000_000
        guard force || changed || due else {
            lock.unlock()
            return
        }
        lastPublishNS = belief.monotonicNS
        lastPolicy = belief.policy
        lastTargetStatus = belief.targetStatus
        lastAttentionCue = belief.attentionCue
        lock.unlock()
        writer.write(BeliefEvent(monotonicNS: belief.monotonicNS, reason: reason, belief: belief))
        onPublished?(belief, reason)
    }
}

private final class GimbalPoseStore: @unchecked Sendable {
    private let lock = NSLock()
    private let geometryCalibration: CameraGeometryCalibration?
    private var recent: [GimbalPose] = []
    private var horizontalFieldOfViewDegrees = OBSBOTTiny2LiteOptics.wideHorizontalDegrees
    private var fieldOfViewMode = 86
    private var cameraProjectionModel = CameraProjectionModel.pinhole(
        horizontalFieldOfViewDegrees: OBSBOTTiny2LiteOptics.wideHorizontalDegrees
    )
    private var motionUntilNS: UInt64 = 0

    init(geometryCalibration: CameraGeometryCalibration? = nil) {
        self.geometryCalibration = geometryCalibration
        if let geometryCalibration, geometryCalibration.fovMode == 86 {
            cameraProjectionModel = geometryCalibration.projection
            horizontalFieldOfViewDegrees = geometryCalibration.projection.horizontalFieldOfViewDegrees
        }
    }

    func update(pitchDegrees: Double, panDegrees: Double, at monotonicNS: UInt64) {
        guard pitchDegrees.isFinite, panDegrees.isFinite else { return }
        lock.lock()
        recent.append(GimbalPose(pitchDegrees: pitchDegrees, panDegrees: panDegrees, monotonicNS: monotonicNS))
        // Live control reads only the newest samples, while the camera's host-
        // aligned PTS may arrive hundreds of milliseconds after exposure. Keep
        // more than the one-second PTS admission window so panorama alignment
        // can still find both measured sides of that exposure without relaxing
        // the 50/80 ms interpolation bounds.
        if recent.count > 128 { recent.removeFirst(recent.count - 128) }
        lock.unlock()
    }

    func updateFieldOfViewMode(_ degrees: Double) -> Double? {
        guard let horizontal = OBSBOTTiny2LiteOptics.horizontalDegrees(
            forFOVMode: degrees
        ) else { return nil }
        lock.lock()
        fieldOfViewMode = Int(degrees)
        if let geometryCalibration,
           geometryCalibration.fovMode == Int(degrees) {
            cameraProjectionModel = geometryCalibration.projection
            horizontalFieldOfViewDegrees = geometryCalibration.projection.horizontalFieldOfViewDegrees
        } else {
            cameraProjectionModel = .pinhole(horizontalFieldOfViewDegrees: horizontal)
            horizontalFieldOfViewDegrees = horizontal
        }
        let appliedHorizontal = horizontalFieldOfViewDegrees
        lock.unlock()
        return appliedHorizontal
    }

    /// Attitude packets describe where the gimbal was, but external velocity
    /// commands tell us that it is still moving between packets. Activity
    /// detection must never interpret that image motion as a person's motion.
    func noteMotion(at monotonicNS: UInt64, durationNS: UInt64) {
        lock.lock()
        motionUntilNS = max(motionUntilNS, monotonicNS &+ durationNS)
        lock.unlock()
    }

    func projection(at captureNS: UInt64) -> (
        pose: GimbalPose?,
        horizontalFieldOfViewDegrees: Double,
        fieldOfViewMode: Int,
        cameraProjectionModel: CameraProjectionModel,
        cameraSettled: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        let pose = recent.last(where: { $0.monotonicNS <= captureNS && $0.isFresh(for: captureNS, maximumAgeNS: 50_000_000) })
        let commandMotionActive = captureNS <= motionUntilNS
        guard let pose,
              let prior = recent.last(where: {
                  $0.monotonicNS < pose.monotonicNS
                    && pose.monotonicNS - $0.monotonicNS <= 100_000_000
              }),
              pose.monotonicNS > prior.monotonicNS else {
            return (pose, horizontalFieldOfViewDegrees, fieldOfViewMode, cameraProjectionModel, false)
        }
        let elapsedSeconds = Double(pose.monotonicNS - prior.monotonicNS) / 1_000_000_000
        let panRate = abs(pose.panDegrees - prior.panDegrees) / elapsedSeconds
        let pitchRate = abs(pose.pitchDegrees - prior.pitchDegrees) / elapsedSeconds
        return (
            pose,
            horizontalFieldOfViewDegrees,
            fieldOfViewMode,
            cameraProjectionModel,
            !commandMotionActive && panRate <= 4 && pitchRate <= 4
        )
    }

    /// Panorama-only delayed lookup. The real-time detector continues to use
    /// `projection(at:)`; this path waits for a measured attitude after the
    /// exposure and interpolates rather than increasing L0 reaction latency.
    func captureAlignedPose(at captureNS: UInt64) -> CaptureAlignedPoseResolution {
        lock.lock()
        defer { lock.unlock() }
        // The native helper asks for attitude at 20 ms cadence, but the SDK can
        // return no sample during an AI-tracking transaction and create a gap
        // near its 100 ms polling ceiling. Panorama may wait and interpolate a
        // measured bracket; live tracking retains the strict 50 ms path above.
        return CaptureAlignedPoseInterpolator.resolve(
            samples: recent,
            at: captureNS,
            maximumSampleDistanceNS: 120_000_000,
            maximumBracketSpanNS: 200_000_000
        )
    }

    func latest(at monotonicNS: UInt64, maximumAgeNS: UInt64 = 75_000_000) -> GimbalPose? {
        lock.lock()
        defer { lock.unlock() }
        return recent.last(where: { $0.monotonicNS <= monotonicNS && $0.isFresh(for: monotonicNS, maximumAgeNS: maximumAgeNS) })
    }

    /// Motor commands must use the latest physical pose, not a pose ordered
    /// before the frame timestamp. The helper can report a few milliseconds
    /// after Vision finishes a frame; rejecting that newer sample creates a
    /// stop/start cadence even though attitude feedback is continuous.
    func current(maximumAgeNS: UInt64 = 150_000_000) -> GimbalPose? {
        let now = monotonicNanoseconds()
        lock.lock()
        defer { lock.unlock() }
        guard let pose = recent.last,
              now >= pose.monotonicNS,
              now - pose.monotonicNS <= maximumAgeNS else {
            return nil
        }
        return pose
    }

    /// The most recent pose regardless of age. Used by bounded expressions so a
    /// stale attitude sample (e.g. during an SDK AI-tracking transaction) does
    /// not stall a bow/nod that should complete on a fixed timer.
    func lastKnown() -> GimbalPose? {
        lock.lock()
        defer { lock.unlock() }
        return recent.last
    }

}

/// Keeps semantic binding off the Vision queue. At most one scene update is
/// evaluated and one newer update is retained; intermediate snapshots are
/// superseded rather than accumulated behind live perception.
private final class EmbodimentSceneBridge: @unchecked Sendable {
    private struct Pending: Sendable {
        let candidates: [SceneCandidate]
        let sourceSceneNS: UInt64
    }

    private let queue = DispatchQueue(label: "soma.embodiment.scene-binding", qos: .utility)
    private let lock = NSLock()
    private let arbiter: ShadowEmbodimentArbiter
    private let writer: JSONLWriter
    private let onSnapshot: @Sendable (EmbodimentShadowSnapshot) -> Void
    private var pending: Pending?
    private var draining = false
    private var accepting = true

    init(
        arbiter: ShadowEmbodimentArbiter,
        writer: JSONLWriter,
        onSnapshot: @escaping @Sendable (EmbodimentShadowSnapshot) -> Void = { _ in }
    ) {
        self.arbiter = arbiter
        self.writer = writer
        self.onSnapshot = onSnapshot
    }

    func submit(_ candidates: [SceneCandidate], at sourceSceneNS: UInt64) {
        lock.lock()
        guard accepting else {
            lock.unlock()
            return
        }
        pending = Pending(candidates: candidates, sourceSceneNS: sourceSceneNS)
        guard !draining else {
            lock.unlock()
            return
        }
        draining = true
        lock.unlock()
        queue.async { [weak self] in self?.drain() }
    }

    func stop() {
        lock.lock()
        accepting = false
        pending = nil
        lock.unlock()
        queue.sync {}
    }

    private func drain() {
        while let work = take() {
            let entities = work.candidates.map(EmbodimentSceneEntity.init)
            let completedNS = monotonicNanoseconds()
            for binding in arbiter.updateScene(entities, at: completedNS) {
                writer.write(SemanticBindingTraceEvent(
                    binding,
                    sourceSceneNS: work.sourceSceneNS,
                    monotonicNS: completedNS
                ))
            }
            onSnapshot(arbiter.snapshot(at: completedNS))
        }
    }

    private func take() -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, let pending else {
            draining = false
            return nil
        }
        self.pending = nil
        return pending
    }
}

/// Serializes accepted cognitive leases and scene-grounding refreshes before
/// handing semantic motor intents to the existing L0 gimbal owner queue.
private final class CognitiveEmbodimentMotorAdapter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soma.embodiment.motor-adapter")
    private let bridge: AttentionGimbalBridge
    private let writer: JSONLWriter
    private var coordinator = EmbodimentMotorCoordinator()
    private var expiryGeneration = 0
    private var accepting = true

    init(bridge: AttentionGimbalBridge, writer: JSONLWriter) {
        self.bridge = bridge
        self.writer = writer
    }

    func submit(_ request: CognitiveEmbodimentRequest, decision: EmbodimentShadowDecision) {
        queue.async { [weak self] in
            guard let self, accepting else { return }
            let now = monotonicNanoseconds()
            if let intent = coordinator.apply(request: request, decision: decision, at: now) {
                publish(intent, at: now)
            }
            scheduleExpiryIfNeeded()
        }
    }

    func update(_ snapshot: EmbodimentShadowSnapshot) {
        queue.async { [weak self] in
            guard let self, accepting else { return }
            let now = monotonicNanoseconds()
            if let intent = coordinator.update(snapshot: snapshot, at: now) {
                publish(intent, at: now)
            }
            scheduleExpiryIfNeeded()
        }
    }

    func stop() {
        queue.sync {
            guard accepting else { return }
            accepting = false
            expiryGeneration += 1
            if let intent = coordinator.stop() {
                publish(intent, at: monotonicNanoseconds())
            }
        }
    }

    func completeCapture(requestID: String, succeeded: Bool) {
        queue.async { [weak self] in
            guard let self, accepting else { return }
            expiryGeneration += 1
            if let intent = coordinator.complete(
                requestID: requestID,
                reason: succeeded ? "capture_completed" : "capture_failed"
            ) {
                publish(intent, at: monotonicNanoseconds())
            }
        }
    }

    private func scheduleExpiryIfNeeded() {
        expiryGeneration += 1
        let generation = expiryGeneration
        guard let requestID = coordinator.activeRequestID,
              let expiresAtNS = coordinator.activeExpiresAtNS else { return }
        let now = monotonicNanoseconds()
        guard expiresAtNS > now else {
            if let intent = coordinator.expire(at: now) { publish(intent, at: now) }
            return
        }
        let delayNS = min(expiresAtNS - now, UInt64(Int.max))
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delayNS))) { [weak self] in
            self?.expire(requestID: requestID, generation: generation)
        }
    }

    private func expire(requestID: String, generation: Int) {
        guard accepting,
              generation == expiryGeneration,
              coordinator.activeRequestID == requestID else { return }
        let now = monotonicNanoseconds()
        if let intent = coordinator.expire(at: now) {
            publish(intent, at: now)
        }
    }

    private func publish(_ intent: EmbodimentMotorIntent, at monotonicNS: UInt64) {
        bridge.ingestEmbodimentIntent(intent)
        writer.write(EmbodimentMotorTraceEvent(intent, monotonicNS: monotonicNS))
    }
}

private enum LiveVoicePresentationState: String, Sendable {
    case inactive
    case ready
    case hearingUser = "hearing_user"
    case preparingResponse = "preparing_response"
    case responding
}

/// Motor command authority, L0 < L1 < L2. A higher layer may preempt a lower
/// layer's reflexive face lock or in-flight gesture.
private enum ScanPriority {
    case l0
    case l1
    case l2
}

private final class AttentionGimbalBridge: @unchecked Sendable {
    private enum State {
        case running
        case stopped
    }

    private struct CalibrationSample: Sendable {
        let sceneID: String
        let kind: AttentionTargetKind
        let label: String?
        let centerX: Double
        let centerY: Double
    }

    private enum CalibrationStage {
        case awaitingTarget
        case panPulse(baseline: CalibrationSample, startedNS: UInt64)
        case panSettling(baseline: CalibrationSample, stoppedNS: UInt64)
        case pitchPulse(panImageDelta: Double, baseline: CalibrationSample, startedNS: UInt64)
        case pitchSettling(panImageDelta: Double, baseline: CalibrationSample, stoppedNS: UInt64)
        case completed
        case failed
    }

    private enum CognitiveMotionMode {
        case waypoint(
            bearing: GimbalRelativeBearing,
            toleranceDegrees: Double,
            motionStyle: EmbodimentMotionStyle,
            state: String
        )
        case capture(
            requestID: String,
            bearing: GimbalRelativeBearing,
            fieldOfViewDegrees: Double,
            stableSinceNS: UInt64?,
            lastPositionCommandNS: UInt64?
        )
        case exploration(policy: ExplorationPolicyGoal)
        case expression(
            kind: SocialGimbalExpression,
            basePose: GimbalPose?,
            waypointIndex: Int,
            waypointStartedNS: UInt64?
        )
        case suspended(reason: String)
    }

    private let queue = DispatchQueue(label: "soma.subconscious.gimbal-bridge")
    private let writer: JSONLWriter
    private let process: Process
    private let input: FileHandle
    private let readyInput: FileHandle
    private let exited = DispatchSemaphore(value: 0)
    private let nativeHumanTrackingEnabled: Bool
    private let ledSettings: SOMALEDSettings
    private let calibrationOutputURL: URL?
    private let poseStore: GimbalPoseStore
    private let spatialAtlas: SphericalSceneAtlasStore
    private let faceLockDiagnosticRecorder: FaceLockDiagnosticRecorder?
    private let embodimentViewCaptureStore: EmbodimentViewCaptureStore?
    private let externalCalibration: ExternalGimbalCalibration?
    private let onOutgoingSocialPulse: @Sendable (UInt64) -> Void
    private var state: State = .running
    private var gate = NativeHumanTrackingGate()
    private var nativeCommandID: String?
    private var nativeTrackingActive = false
    private var nativeTrackingStartPending = false
    private var nativeHeartbeatGeneration = 0
    private var externalGate: ExternalGimbalAttentionGate?
    private var idleExplorationGate: IdleExplorationGate?
    private var externalCommandID: String?
    private var helperReady = false
    private var commandSequence = 0
    private var calibrationStage: CalibrationStage = .awaitingTarget
    private var calibrationMode: Bool
    private var externalStopGeneration = 0
    private var scanGeneration = 0
    private var scanRunning = false
    /// Motor authority is L0 < L1 < L2: the higher the layer, the more it may
    /// preempt the reflexive L0 face lock. A coverage scan records which layer
    /// started it so a lower layer never tears a higher layer's scan away.
    private var scanPriority: ScanPriority = .l0
    private var nextScanDirection = 1.0
    private var explorationWaypoint: SpatialCoverageDirection?
    private var explorationWaypointStartedNS: UInt64?
    private var explorationWaypointDeadlineNS: UInt64?
    private var explorationWaypointStartingPose: GimbalPose?
    private var explorationWaypointIndex = 0
    private let cameraGeometryCalibrationMode: Bool
    private let panoramaStripScanMode: Bool
    private var cameraGeometryRouteIndex = 0
    private var panoramaStripRouteIndex = 0
    private var cameraGeometryCommandedRouteIndex: Int?
    private var cameraGeometryWaypointStableSinceNS: UInt64?
    private var panoramaWaypointStableSinceNS: UInt64?
    private var cameraGeometryNextPositionCommandNS: UInt64 = 0
    private var explorationBoundaryTurning = false
    private var smoothExploration = SmoothExplorationDynamics()
    private var visualEvidenceGeneration = 0
    private var scanScheduledForEvidenceGeneration: Int?
    private var helperDiagnosticBuffer = ""
    private var poseAvailabilityReported = false
    private var fieldOfViewAvailabilityReported = false
    // The calibration expresses an expected axis sign. During exploration the
    // SDK attitude is the authority: one non-moving pan pulse reverses the
    // next pulse; both directions failing requires a physical re-home.
    private var explorationPanPolarity = 1.0
    private var panStallRecovery = PanStallRecovery()
    private var explorationRecentering = false
    private var explorationFailureCount = 0
    private var explorationRandomState: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var attentionController = SubconsciousAttentionController()
    private var lastAttentionDecisionSignature: String?
    /// Snapshot of the current L0 attention state for the periodic L1
    /// behavior-awareness pass (which the social gate otherwise never sees).
    private var behaviorAttentionState = "idle"
    private var behaviorTargetLabel: String?
    private var behaviorTargetConfidence = 0.0
    private var behaviorIsFaceTarget = false
    private var behaviorChangedAtNS: UInt64 = 0
    private var recentAttentionStates: [String] = []
    /// Supplies the currently recognized identity label (e.g. the administrator's
    /// name) so the behavior-awareness pass knows who it is looking at.
    var recognizedIdentityProvider: (() -> String?)?
    /// Supplies the currently perceived person's opaque entity ID so the
    /// acknowledgment queue can match a pending greeting to the person SOMA is
    /// actually looking at.
    var recognizedPersonEntityIDProvider: (() -> UUID?)?
    /// Acknowledgment queue: person entity IDs awaiting a greeting bow, keyed by
    /// enqueue time. A person is enqueued on arrival and the bow fires only once
    /// SOMA is perceiving them, so a greeting is never thrown at an empty view.
    private var pendingAcknowledgmentEntityIDs: [String: UInt64] = [:]
    /// People whose greeting has already been delivered. Cleared on departure so
    /// a re-arriving person is greeted again; within one presence it is judged
    /// from context that the greeting was received and never re-fired.
    private var deliveredAcknowledgmentEntityIDs: Set<String> = Set()
    private var actionableVisualContinuity = VisualEvidenceContinuity()
    private var socialTrackingContinuity = VisualEvidenceContinuity(lossConfirmationMilliseconds: 1_200)
    /// While native AI owns the live visual loop the device itself is tracking
    /// the person, and the app's ANE face detector can drop out for a second or
    /// more while the gimbal moves. This longer window trusts device-confirmed
    /// native tracking across those dropouts, releasing only after a sustained
    /// absence that a genuine departure would produce.
    private var nativeTrustContinuity = VisualEvidenceContinuity(lossConfirmationMilliseconds: 5_000)
    private var faceLock = FaceLockLease()
    /// Bounded recovery window for a verified face lock that has lost its face.
    /// The lock may hold through a short detector gap, but it must not pin the
    /// gimbal indefinitely when the person has actually left. After this window
    /// the lock is released and L0 resumes scanning.
    private var socialRetentionDeadlineNS: UInt64?
    private let socialRetentionWindowNS: UInt64 = 5_000_000_000
    /// Consecutive E2B reactions (orient/observe) observed while L0 is face-locked.
    /// When this reaches the threshold, E2B forcibly releases what it judges to be
    /// a wrong fixation and resumes scanning.
    private var consecutiveAuxiliaryReleaseSignal = 0
    private let auxiliaryOrientReleaseCount = 2
    private let auxiliaryObserveReleaseCount = 3
    private var activeSpatialFaceReacquisition: (id: String, deadlineNS: UInt64)?
    private var attemptedSpatialFaceReacquisitionIDs: Set<String> = []
    private var confirmedVisualLossNS: UInt64?
    private var lastSpatialFaceReacquisitionCommandNS: UInt64 = 0
    private var lastObservedFaceNS: UInt64?
    private var lastMotorTarget: AttentionTarget?
    private var freshFaceBearings: [String: (bearing: GimbalRelativeBearing, monotonicNS: UInt64)] = [:]
    // Camera delivery and face-model warm-up begin after the helper reports
    // ready. Do not let no-target exploration pull the optical axis away from
    // the user before that first live face pass has had time to arrive.
    private var explorationEligibleAfterNS: UInt64 = 0
    private var activeCognitiveMotorRequestID: String?
    private var activeCognitiveMotorExpiresAtNS: UInt64?
    private var cognitiveMotionMode: CognitiveMotionMode?
    private var cognitiveMotionGeneration = 0
    private var cognitiveMotionLoopRunning = false
    private var cognitiveMotionHolding = false
    private var cognitiveDynamics = SmoothExplorationDynamics()
    private var cognitiveExplorationWaypoint: SpatialCoverageDirection?
    private var cognitiveExplorationWaypointStartedNS: UInt64?
    private var socialPulseIssuedForRequestID: String?
    private var indicatorInputs = SubconsciousIndicatorInputs()
    private var localSpeechListening = false
    private var localSpeechWorking = false
    private var localSpeechSpeaking = false
    private var liveVoicePresentation: LiveVoicePresentationState = .inactive
    private var liveVoiceUserSpeaking = false
    private var liveVoiceResponsePending = false
    private var activeIndicatorState: SubconsciousIndicatorState?
    private var activeIndicatorRendering: SOMALEDDeviceRendering?
    private var indicatorIlluminated = false
    private var indicatorCalibrationPreset: SOMALEDFirmwarePreset?
    private var indicatorCalibrationStateID: Int?
    private var indicatorReassertionGeneration = 0
    /// The visual invitation stays legible through brief gaze-estimator
    /// dropouts. Voice admission deliberately remains governed by its own,
    /// shorter fresh-eye-contact window.
    private var eyeContactIndicatorLease = EyeContactIndicatorLease(holdMilliseconds: 2_000)
    private let indicatorReassertionIntervalMilliseconds = 1_000

    init(
        helperURL: URL,
        outputURL: URL,
        traceRotationPolicy: JSONLRotationPolicy?,
        duration: TimeInterval,
        externalCalibration: ExternalGimbalCalibration?,
        autonomousScanEnabled: Bool,
        idleExplorationEnabled: Bool,
        nativeHumanTrackingEnabled: Bool,
        ledSettings: SOMALEDSettings,
        calibrationOutputURL: URL?,
        cameraGeometryCalibrationMode: Bool,
        panoramaStripScanMode: Bool,
        poseStore: GimbalPoseStore,
        spatialAtlas: SphericalSceneAtlasStore,
        faceLockDiagnosticRecorder: FaceLockDiagnosticRecorder?,
        embodimentViewCaptureStore: EmbodimentViewCaptureStore?,
        onOutgoingSocialPulse: @escaping @Sendable (UInt64) -> Void,
        writer: JSONLWriter
    ) throws {
        self.writer = writer
        self.nativeHumanTrackingEnabled = nativeHumanTrackingEnabled
        self.ledSettings = ledSettings
        self.calibrationOutputURL = calibrationOutputURL
        self.cameraGeometryCalibrationMode = cameraGeometryCalibrationMode
        self.panoramaStripScanMode = panoramaStripScanMode
        self.poseStore = poseStore
        self.spatialAtlas = spatialAtlas
        self.faceLockDiagnosticRecorder = faceLockDiagnosticRecorder
        self.embodimentViewCaptureStore = embodimentViewCaptureStore
        self.onOutgoingSocialPulse = onOutgoingSocialPulse
        self.externalCalibration = externalCalibration
        calibrationMode = calibrationOutputURL != nil
        externalGate = externalCalibration.map {
            ExternalGimbalAttentionGate(calibration: $0, autonomousScanEnabled: autonomousScanEnabled)
        }
        idleExplorationGate = externalCalibration == nil && idleExplorationEnabled
            ? IdleExplorationGate()
            : nil
        process = Process()
        let inputPipe = Pipe()
        let readyPipe = Pipe()
        input = inputPipe.fileHandleForWriting
        readyInput = readyPipe.fileHandleForReading
        process.executableURL = helperURL
        var processArguments = [
            "--serve",
            "--allow-camera-motion",
            "--duration", String(Int(duration)),
            "--output", outputURL.path,
        ]
        if let traceRotationPolicy {
            processArguments += [
                "--trace-max-megabytes", String(traceRotationPolicy.maximumBytes / 1_048_576),
                "--trace-retained-files", String(traceRotationPolicy.retainedFiles),
            ]
        }
        process.arguments = processArguments
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = readyPipe
        process.terminationHandler = { [writer, exited = self.exited] completed in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "attention_gimbal_bridge",
                state: completed.terminationStatus == 0 ? "stopped" : "fault",
                message: "termination_status=\(completed.terminationStatus)"
            ))
            exited.signal()
        }
        try process.run()
        readyInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.ingestHelperDiagnostics(data)
        }
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "attention_gimbal_bridge",
            state: "started",
            message: "local_scalar_pipe_only"
        ))
    }

    private func ingestHelperDiagnostics(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.helperDiagnosticBuffer.append(chunk)
            while let newline = self.helperDiagnosticBuffer.firstIndex(of: "\n") {
                let line = String(self.helperDiagnosticBuffer[..<newline])
                self.helperDiagnosticBuffer.removeSubrange(...newline)
                self.consumeHelperDiagnostic(line)
            }
        }
    }

    private func consumeHelperDiagnostic(_ line: String) {
        if line == "SOMA_NATIVE_BRIDGE_READY" {
            guard !helperReady else { return }
            helperReady = true
            explorationEligibleAfterNS = monotonicNanoseconds() + 3_000_000_000
            let indicatorEnableCommandID = nextCommandID(prefix: "indicator-enable")
            send("indicator_enabled \(indicatorEnableCommandID) \(ledSettings.responseMode == .off ? 0 : 1)")
            let indicatorBrightnessCommandID = nextCommandID(prefix: "indicator-brightness")
            send("indicator_brightness \(indicatorBrightnessCommandID) \(ledSettings.brightness)")
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "attention_gimbal_bridge",
                state: "ready",
                message: "native_endpoint_discovered"
            ))
            if cameraGeometryCalibrationMode || panoramaStripScanMode {
                startSmoothExploration(initialPan: 0)
            }
            refreshIndicator(
                at: monotonicNanoseconds(),
                forceHardwareReassertion: true
            )
            startIndicatorReassertionLoop()
            return
        }
        if line.hasPrefix("SOMA_NATIVE_TRACKING ") {
            let values = line.split(separator: " ").dropFirst().reduce(into: [String: Substring]()) { result, part in
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return }
                result[String(pair[0])] = pair[1]
            }
            guard let state = values["state"] else { return }
            if state == "active" {
                nativeTrackingActive = true
                nativeTrackingStartPending = false
                startNativeHeartbeatLoop()
                // Native human tracking can replace the visible hardware
                // indication while it activates. Reassert the selected SOMA
                // signal after the device has confirmed that transition.
                refreshIndicator(
                    at: monotonicNanoseconds(),
                    forceHardwareReassertion: true
                )
            } else if state == "inactive" {
                stopNativeHeartbeatLoop()
                nativeTrackingActive = false
                nativeTrackingStartPending = false
                nativeCommandID = nil
                _ = gate.stop()
            }
            return
        }
        if line.hasPrefix("SOMA_GIMBAL_FOV degrees="),
           let degrees = Double(line.dropFirst("SOMA_GIMBAL_FOV degrees=".count)),
           let horizontal = poseStore.updateFieldOfViewMode(degrees) {
            guard !fieldOfViewAvailabilityReported else { return }
            fieldOfViewAvailabilityReported = true
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "gimbal_pose",
                state: "fov_available",
                message: String(
                    format: "reported_fov_mode=%.0f; horizontal_degrees=%.3f; optical_profile=tiny_2_lite; aspect_ratio=16:9",
                    degrees,
                    horizontal
                )
            ))
            return
        }
        guard line.hasPrefix("SOMA_GIMBAL_ATTITUDE ") else { return }
        let values = line.split(separator: " ").dropFirst().reduce(into: [String: Substring]()) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return }
            result[String(pair[0])] = pair[1]
        }
        guard let pitchText = values["pitch"], let pitch = Double(pitchText),
              let panText = values["pan"], let pan = Double(panText),
              let sampleText = values["monotonic_ns"], let sampleNS = UInt64(sampleText) else { return }
        let receivedNS = monotonicNanoseconds()
        // The SDK helper and DispatchTime can use monotonic clocks with
        // different sleep epochs. The local scalar pipe's receive timestamp
        // is therefore the shared clock for capture alignment; helper reports
        // arrive every 20 ms, below the 50 ms image-pose freshness window.
        guard sampleNS > 0 else { return }
        poseStore.update(pitchDegrees: pitch, panDegrees: pan, at: receivedNS)
        guard !poseAvailabilityReported else { return }
        poseAvailabilityReported = true
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: receivedNS,
            source: "gimbal_pose",
            state: "available",
            message: "sdk_attitude_feedback"
        ))
    }

    func ingest(_ belief: BeliefSnapshot, reason: String) {
        queue.async { [weak self] in self?.apply(belief, reason: reason) }
    }

    func ingestSceneCandidates(_ candidates: [SceneCandidate], at monotonicNS: UInt64) {
        queue.async { [weak self] in
            self?.spatialAtlas.updateScene(candidates.map(EmbodimentSceneEntity.init))
            self?.applySceneCandidates(candidates, at: monotonicNS)
        }
    }

    func ingestSpeechInteractionState(_ speechState: LocalSpeechInteractionState) {
        queue.async { [weak self] in
            guard let self else { return }
            switch speechState {
            case .turnStarted:
                localSpeechListening = true
                localSpeechWorking = false
                localSpeechSpeaking = false
            case let .recognitionCompleted(_, _, _, _, _, _, handedToL2):
                localSpeechListening = false
                localSpeechWorking = handedToL2
            case .speechStarted:
                localSpeechListening = false
                localSpeechWorking = false
                localSpeechSpeaking = true
            case .speechCompleted, .speechCancelled:
                localSpeechSpeaking = false
            case .l2Completed:
                localSpeechListening = false
                localSpeechWorking = false
            case .l2Failed, .recognitionFailed, .turnCancelled:
                localSpeechListening = false
                localSpeechWorking = false
                localSpeechSpeaking = false
            }
            refreshCommunicationIndicatorInputs()
            refreshIndicator(at: monotonicNanoseconds())
        }
    }

    func ingestLiveVoicePresentation(_ presentation: LiveVoicePresentationState) {
        queue.async { [weak self] in
            guard let self else { return }
            guard presentation != .preparingResponse || liveVoiceResponsePending else { return }
            liveVoicePresentation = presentation
            if presentation == .inactive {
                liveVoiceUserSpeaking = false
                liveVoiceResponsePending = false
            } else if presentation == .responding || presentation == .ready {
                liveVoiceResponsePending = false
            }
            refreshCommunicationIndicatorInputs()
            refreshIndicator(at: monotonicNanoseconds())
        }
    }

    func ingestLiveVoiceTurnAccepted() {
        queue.async { [weak self] in
            guard let self, liveVoicePresentation != .inactive else { return }
            liveVoiceResponsePending = true
        }
    }

    func ingestLiveVoiceUserActivity(active: Bool) {
        queue.async { [weak self] in
            guard let self, liveVoicePresentation != .inactive else { return }
            liveVoiceUserSpeaking = active
            refreshCommunicationIndicatorInputs()
            refreshIndicator(at: monotonicNanoseconds())
        }
    }

    private func refreshCommunicationIndicatorInputs() {
        let conversationActive = liveVoicePresentation == .hearingUser
            || liveVoicePresentation == .responding
            || liveVoiceUserSpeaking
            || localSpeechListening
            || localSpeechSpeaking
        let preparingReply = liveVoicePresentation == .preparingResponse || localSpeechWorking
        indicatorInputs.interactionState = preparingReply
            ? .preparingReply
            : (conversationActive ? .conversation : .idle)
    }

    func ingestCoverage(
        pose: GimbalPose,
        horizontalFieldOfViewDegrees: Double,
        poseProjection: GimbalPoseProjection,
        cameraProjectionModel: CameraProjectionModel,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            self?.spatialAtlas.observe(
                pose: pose,
                horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                poseProjection: poseProjection,
                cameraProjectionModel: cameraProjectionModel,
                at: monotonicNS
            )
        }
    }

    func ingestEmbodimentIntent(_ intent: EmbodimentMotorIntent) {
        queue.async { [weak self] in self?.applyEmbodimentIntent(intent) }
    }

    /// Enqueue a greeting for a person who has just been recognized/arrived.
    /// The bow is not fired here: it waits until SOMA is actually perceiving
    /// that person, so a greeting is never aimed at an empty view.
    func enqueueAcknowledgment(for entityID: UUID, at monotonicNS: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = entityID.uuidString
            guard !self.deliveredAcknowledgmentEntityIDs.contains(key) else { return }
            self.pendingAcknowledgmentEntityIDs[key] = monotonicNS
        }
    }

    /// Re-arm a person on departure so a re-arriving person is greeted again.
    func clearAcknowledgment(for entityID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = entityID.uuidString
            self.pendingAcknowledgmentEntityIDs.removeValue(forKey: key)
            self.deliveredAcknowledgmentEntityIDs.remove(key)
        }
    }

    /// L1 behavior `acknowledge_person` entry point. Instead of firing a
    /// greeting on a fixed cooldown, it drains the acknowledgment queue: if the
    /// person SOMA is currently perceiving has a pending greeting, fire a quick
    /// bow and mark it delivered so it is never re-fired within one presence.
    func acknowledgePersonIfEligible(at monotonicNS: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let perceived = self.recognizedPersonEntityIDProvider?() else { return }
            let key = perceived.uuidString
            guard self.pendingAcknowledgmentEntityIDs.removeValue(forKey: key) != nil else { return }
            self.deliveredAcknowledgmentEntityIDs.insert(key)
            // Use the current time for the lease, not the L1 directive's
            // (possibly stale) timestamp, so the bow has its full window to
            // complete instead of expiring immediately. The two-waypoint bow
            // needs ~0.5s of motion, so give it a comfortable 1.5s lease so it
            // reports cognitive_expression_completed rather than timing out.
            let now = monotonicNanoseconds()
            self.applyEmbodimentIntent(.express(
                requestID: "l1-ack-\(now)",
                expression: .acknowledge,
                expiresAtNS: now + 1_500_000_000
            ))
        }
    }

    func stop() {
        queue.sync {
            if case .stopped = state { return }
            if calibrationOutputURL != nil {
                switch calibrationStage {
                case .completed, .failed:
                    break
                default:
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: monotonicNanoseconds(),
                        source: "external_gimbal_calibration",
                        state: "incomplete",
                        message: "no_calibration_written"
                    ))
                }
            }
            let commandID = nextCommandID(prefix: "shutdown")
            send("shutdown \(commandID)")
            writer.write(CameraIntentEvent(
                monotonicNS: monotonicNanoseconds(),
                owner: .manual,
                state: "shutdown_requested",
                route: .none,
                commandID: commandID,
                targetKind: nil,
                targetLabel: nil,
                targetProbability: 0
            ))
            try? input.close()
            readyInput.readabilityHandler = nil
            stopNativeHeartbeatLoop()
            cancelExternalStop()
            cancelScan()
            state = .stopped
        }
        guard process.isRunning else { return }
        if exited.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 3)
        }
    }

    private func apply(_ belief: BeliefSnapshot, reason: String) {
        guard process.isRunning else {
            state = .stopped
            return
        }
        guard helperReady else { return }
        guard !cameraGeometryCalibrationMode, !panoramaStripScanMode else { return }
        guard !explorationRecentering else { return }
        if calibrationMode {
            if reason != "vision_miss", VisualObservationSource(rawValue: reason) == nil {
                // Calibration may move only in response to a completed visual
                // observation; predictions and audio cannot prove displacement.
                return
            }
            applyCalibration(belief, reason: reason)
            return
        }
        guard activeCognitiveMotorRequestID == nil else {
            // Perception continues while a higher layer owns the motor lease,
            // but autonomous L0 evidence cannot race that leased goal.
            return
        }
        let now = belief.monotonicNS
        if reason == "vision_miss" {
            // A completed detector miss can race another detector's fresh
            // face result. The worker already applies this continuity rule,
            // but keep it at the motor boundary as well: an isolated empty
            // result must not interrupt an active face correction.
            guard actionableVisualContinuity.confirmsLoss(at: now) else { return }
            let nativeOwnsSocialTracking = nativeTrackingActive || nativeTrackingStartPending
            // A device-confirmed native AI lock owns its own live visual loop
            // (the OBSBOT tracks the person independently of this app's ANE
            // detector). While the device-confirmed native lock is held, an
            // app-detector gap is a perception dropout, not a physical
            // departure, and must not tear the native lock down: the longer
            // native-trust window releases it only on a sustained absence. A
            // pending, not-yet-device-confirmed start still yields to the
            // shorter social gap so a false start cannot hold the gimbal
            // forever.
            let retainNativeThroughDetectorGap = faceLock.permitsMotor(at: now)
                && nativeOwnsSocialTracking
                && (nativeTrackingActive
                    ? !nativeTrustContinuity.confirmsLoss(at: now)
                    : !socialTrackingContinuity.confirmsLoss(at: now))
            let decision = attentionController.advance(
                belief: belief,
                evidence: .visualLoss,
                socialFixationPermitted: faceLock.permitsMotor(at: now),
                nativeSocialTrackingActive: retainNativeThroughDetectorGap
            )
            recordAttentionDecision(decision, target: belief.target, at: now)
            if decision.suppressesExploration {
                // Only a verified face lock is allowed a short detector gap.
                // A raw model candidate must never freeze exploration when it
                // disappears, otherwise a static false positive can hold the
                // gimbal in place without ever commanding a useful fixation.
                if externalCommandID != nil {
                    cancelExternalStop()
                    sendExternalStop(state: "face_lock_detector_gap", at: now)
                }
                // Bounded recovery: a verified face lock may hold through a
                // short detector gap, but must not pin the gimbal indefinitely
                // when the person has actually left. After the window, release
                // the lock and resume scanning.
                if socialRetentionDeadlineNS == nil {
                    socialRetentionDeadlineNS = now + socialRetentionWindowNS
                } else if now >= socialRetentionDeadlineNS! {
                    socialRetentionDeadlineNS = nil
                    faceLock.invalidate()
                    lastMotorTarget = nil
                    applyVisualLoss(belief, at: now)
                }
                return
            }
            applyVisualLoss(belief, at: now)
            return
        }
        guard VisualObservationSource(rawValue: reason) != nil else {
            // Predictions, audio, and periodic snapshots carry no new pixels;
            // they must never extend a physical motion pulse.
            _ = attentionController.advance(
                belief: belief,
                evidence: .nonVisualUpdate,
                socialFixationPermitted: faceLock.permitsMotor(at: now)
            )
            return
        }
        let decision = attentionController.advance(
            belief: belief,
            evidence: .visualObservation,
            socialFixationPermitted: faceLock.permitsInitialMotor(at: now),
            nativeSocialTrackingPermitted: faceLock.permitsInitialMotor(at: now),
            nativeSocialTrackingActive: nativeTrackingActive || nativeTrackingStartPending
        )
        recordAttentionDecision(decision, target: belief.target, at: now)
        switch decision.state {
        case .sceneObservation:
            // Objects and saliency remain genuine attention hypotheses. They
            // can delay a new blind search, but have no L0 motor authority to
            // cut a coverage trajectory that is already observing the scene.
            recordCurrentVisualAttention(at: now)
            if scanRunning, decision.preservesActiveExploration { return }
            quiesceForNonMotorAttention(at: now, target: belief.target, reason: reason)
            return
        case .socialRetention:
            // A current body box or detector-ID gap preserves social context
            // without pretending it is a fresh face measurement for a motor.
            // A provisional one-frame person candidate must not insert a
            // multi-second stop into an already active coverage trajectory.
            recordCurrentVisualAttention(at: now)
            if scanRunning, decision.preservesActiveExploration { return }
            cancelScan()
            if externalCommandID != nil {
                cancelExternalStop()
                sendExternalStop(state: "social_attention_no_fresh_face", at: now)
            }
            // A verified face lock may hold through a short detector gap, but it
            // must not pin the gimbal indefinitely when the person has actually
            // left. After a bounded recovery window, release the lock and
            // resume scanning so the robot does not sit still forever.
            if socialRetentionDeadlineNS == nil {
                socialRetentionDeadlineNS = now + socialRetentionWindowNS
            } else if now >= socialRetentionDeadlineNS! {
                socialRetentionDeadlineNS = nil
                faceLock.invalidate()
                lastMotorTarget = nil
                applyVisualLoss(belief, at: now)
            }
            return
        case .socialReframing:
            recordCurrentVisualAttention(at: now)
            guard let target = belief.target else { return }
            applySocialReframing(belief, target: target, at: now, reason: reason)
            return
        case .exploration, .idle:
            // A static non-human scene candidate receives a bounded,
            // probability-weighted observation dwell. When that dwell ends,
            // the scene remains in memory but deliberately yields to the
            // spherical explorer without waiting for it to vanish from pixels.
            let explorationAfterObservationDwell = decision.sceneID != nil
            guard explorationAfterObservationDwell || actionableVisualContinuity.confirmsLoss(at: now) else { return }
            applyVisualLoss(belief, at: now)
            return
        case .socialFixation:
            socialRetentionDeadlineNS = nil
            break
        }
        guard let target = belief.target else { return }
        if target.isFaceMotorTarget,
           faceLock.suppressesCompetingFace(
               sceneID: target.id,
               rect: target.rect,
               at: now
           ) {
            // A competing raw face candidate is not a visual-loss event for
            // the confirmed face. The direct SceneField face path keeps the
            // native helper alive from the held face itself.
            return
        }
        if target.isFaceMotorTarget,
           (!faceLock.holds(sceneID: target.id, rect: target.rect, at: now)
                || !faceLock.permitsInitialMotor(at: now)) {
            // A raw face gets only the short, non-renewable correction that
            // brings a clipped face into the independent verifier's view.
            guard actionableVisualContinuity.confirmsLoss(at: now) else { return }
            applyVisualLoss(belief, at: now)
            return
        }
        if let target = belief.target,
           faceLock.suppressesNonHumanAttention(
               kind: target.kind,
               attentionWeight: target.attentionWeight,
               at: now
           ) {
            // Selection normally suppresses this before a belief is emitted.
            // Keep the same L0 rule at the motor boundary so a future source
            // cannot make a default object interrupt an active face lock.
            return
        }
        // Keep only scalar context for a target that actually crossed the
        // motor boundary. A rejected lower-frame face-like candidate must not
        // be reported later as though it justified a physical stop.
        lastMotorTarget = target
        actionableVisualContinuity.recordObservation(at: now)
        confirmedVisualLossNS = nil
        if var idleExplorationGate {
            idleExplorationGate.recordNoCalibratedTarget(at: now)
            self.idleExplorationGate = idleExplorationGate
            scheduleScanAfterContinuousVisualLoss()
        } else {
            visualEvidenceGeneration += 1
        }
        let verifiedCurrentFaceLock: Bool
        if let target = belief.target {
            verifiedCurrentFaceLock = faceLock.permitsMotor(at: now)
                && faceLock.holds(sceneID: target.id, rect: target.rect, at: now)
        } else {
            verifiedCurrentFaceLock = false
        }
        let immediateNativeAcquisition = verifiedCurrentFaceLock
        let nativeAction: NativeHumanTrackingAction
        if nativeHumanTrackingEnabled && faceLock.permitsMotor(at: now) {
            // Retain a device-confirmed native lock through a short detector
            // blip: the current frame briefly lost its face target (nil, a
            // body/saliency candidate taking precedence, or a fast head move)
            // while the verified face lock still holds. Only a sustained
            // absence confirmed by the 5 s native-trust continuity should tear
            // the native lock down — the same principle as the vision_miss
            // retention above.
            if gate.isActive, !verifiedCurrentFaceLock, !nativeTrustContinuity.confirmsLoss(at: now) {
                nativeAction = gate.heartbeatIfActive(at: now)
            } else {
                nativeAction = gate.update(
                    belief,
                    immediateAcquisitionPermitted: immediateNativeAcquisition
                )
            }
        } else {
            nativeAction = gate.invalidate()
        }
        let externalAction: ExternalGimbalAttentionAction
        if var externalGate {
            // Keep the visual servo alive while a fresh face earns the native
            // lease. Once the device confirms native tracking, it becomes the
            // sole motor owner; a face must never create a 160 ms dead zone.
            let nativeHandoffPending = nativeHumanTrackingEnabled
                && (nativeTrackingStartPending || nativeAction == .start)
            let nativeOwnsHuman = nativeTrackingActive || nativeHandoffPending
            let faceBearing: GimbalRelativeBearing?
            if let target = belief.target,
               let stored = freshFaceBearings[target.id],
               now >= stored.monotonicNS,
               now - stored.monotonicNS <= 160_000_000 {
                faceBearing = stored.bearing
            } else {
                faceBearing = nil
            }
            let currentPose = poseStore.current()
            // External velocity is a physical closed loop. A face rectangle
            // without its capture-time bearing or a current SDK attitude is
            // awareness, not enough state to steer the gimbal: image-space
            // fallback here was the source of full-speed starts before the
            // pose loop could establish its absolute target.
            let hasFaceServoReference = belief.target?.isFaceMotorTarget != true
                || (faceBearing != nil && currentPose != nil)
            let observationAction = hasFaceServoReference
                ? externalGate.update(
                    belief,
                    faceBearing: faceBearing,
                    currentPose: currentPose,
                    poseProjection: .obsbotTiny2Lite
                )
                : (externalCommandID == nil ? .none : .stop)
            externalAction = nativeOwnsHuman
                ? (externalCommandID != nil || scanRunning ? .stop : .none)
                : observationAction
            self.externalGate = externalGate
        } else {
            externalAction = .none
        }
        if belief.target?.kind == .human {
            apply(externalAction, at: now, target: belief.target, reason: reason)
            apply(nativeAction, at: now, target: belief.target, reason: reason)
        } else {
            apply(nativeAction, at: now, target: belief.target, reason: reason)
            apply(externalAction, at: now, target: belief.target, reason: reason)
        }
    }

    private func recordAttentionDecision(
        _ decision: SubconsciousAttentionDecision,
        target: AttentionTarget?,
        at monotonicNS: UInt64
    ) {
        let signature = "\(decision.state.rawValue)|\(decision.permitsNativeSocialTracking)|\(decision.permitsExternalSocialReframing)"
        if signature != lastAttentionDecisionSignature {
            lastAttentionDecisionSignature = signature
            behaviorAttentionState = decision.state.rawValue
            behaviorTargetLabel = target?.label
            behaviorTargetConfidence = target?.confidence ?? 0
            behaviorIsFaceTarget = target?.isFaceMotorTarget ?? false
            behaviorChangedAtNS = monotonicNS
            recentAttentionStates.append(decision.state.rawValue)
            if recentAttentionStates.count > 16 {
                recentAttentionStates.removeFirst(recentAttentionStates.count - 16)
            }
        }
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "l0_attention_controller",
            state: decision.state.rawValue,
            message: String(
                format: "scene_id=%@; posterior_probability=%.3f; native_social_tracking=%@",
                decision.sceneID ?? "none",
                decision.posteriorProbability,
                decision.permitsNativeSocialTracking ? "eligible" : (decision.permitsExternalSocialReframing ? "social_reframe" : "not_eligible")
            )
        ))
    }

    func makeBehaviorContext(at nowNS: UInt64) -> L1BehaviorContext {
        let fixationSeconds = behaviorChangedAtNS == 0 ? 0 : Double(nowNS - behaviorChangedAtNS) / 1_000_000_000
        return L1BehaviorContext(
            attentionState: behaviorAttentionState,
            targetLabel: behaviorTargetLabel,
            targetConfidence: behaviorTargetConfidence,
            isFaceTarget: behaviorIsFaceTarget,
            fixationSeconds: fixationSeconds,
            scanActive: scanRunning,
            idleSeconds: fixationSeconds,
            recentStates: recentAttentionStates,
            recognizedIdentity: recognizedIdentityProvider?()
        )
    }

    private func recordCurrentVisualAttention(at monotonicNS: UInt64) {
        actionableVisualContinuity.recordObservation(at: monotonicNS)
        confirmedVisualLossNS = nil
        visualEvidenceGeneration += 1
        scanScheduledForEvidenceGeneration = nil
    }

    private func quiesceForNonMotorAttention(
        at monotonicNS: UInt64,
        target: AttentionTarget?,
        reason: String
    ) {
        cancelScan()
        let nativeAction = gate.invalidate()
        apply(nativeAction, at: monotonicNS, target: target, reason: reason)
        guard externalCommandID != nil else { return }
        cancelExternalStop()
        sendExternalStop(state: "scene_attention_no_motor", at: monotonicNS)
    }

    private func applySocialReframing(
        _ belief: BeliefSnapshot,
        target: AttentionTarget,
        at monotonicNS: UInt64,
        reason: String
    ) {
        guard target.kind == .human, target.label != "face" else {
            quiesceForNonMotorAttention(at: monotonicNS, target: target, reason: reason)
            return
        }
        cancelScan()
        let nativeAction = gate.invalidate()
        if var externalGate {
            let action = externalGate.update(
                belief,
                currentPose: poseStore.current(),
                poseProjection: .obsbotTiny2Lite,
                allowSocialReframing: true
            )
            self.externalGate = externalGate
            apply(nativeAction, at: monotonicNS, target: target, reason: reason)
            apply(action, at: monotonicNS, target: target, reason: reason)
        } else {
            apply(nativeAction, at: monotonicNS, target: target, reason: reason)
        }
    }

    private func applyVisualLoss(_ belief: BeliefSnapshot, at now: UInt64) {
        // Scene processing can observe a face one queue turn before the
        // selector publishes its matching belief. A miss in that interval is
        // not permission to restart exploration and look away from the face.
        guard !hasRecentObservedFace(at: now) else { return }
        if indicatorInputs.visualState != .none {
            indicatorInputs.visualState = .none
            eyeContactIndicatorLease.clear()
            refreshIndicator(at: now)
        }
        // Keep the first confirmed-loss time. Replacing it on every empty
        // detector frame makes every recovery grace period recede forever.
        if confirmedVisualLossNS == nil {
            confirmedVisualLossNS = now
        }
        let nativeAction = nativeHumanTrackingEnabled
            ? gate.update(belief, hasVisualEvidence: false)
            : gate.invalidate()
        let externalAction: ExternalGimbalAttentionAction
        if var externalGate {
            externalAction = scanRunning ? .none : externalGate.recordVisualLoss(at: now)
            self.externalGate = externalGate
            // A just-lost face gets time to re-enter the current view before
            // coverage can pull the camera elsewhere. This keeps a detector
            // gap from turning a social fixation into a broad search sweep.
            scheduleScanAfterContinuousVisualLoss()
        } else if var idleExplorationGate {
            idleExplorationGate.recordNoCalibratedTarget(at: now)
            self.idleExplorationGate = idleExplorationGate
            scheduleScanAfterContinuousVisualLoss()
            externalAction = .none
        } else {
            externalAction = .none
        }
        if belief.target?.kind == .human {
            apply(externalAction, at: now, target: nil, reason: "vision_miss")
            apply(nativeAction, at: now, target: nil, reason: "vision_miss")
        } else {
            apply(nativeAction, at: now, target: nil, reason: "vision_miss")
            apply(externalAction, at: now, target: nil, reason: "vision_miss")
        }
    }

    private func scheduleScanAfterContinuousVisualLoss(minimumDelayMilliseconds: Int? = nil) {
        guard !explorationRecentering else { return }
        let evidenceGeneration = visualEvidenceGeneration
        guard scanScheduledForEvidenceGeneration != evidenceGeneration else { return }
        scanScheduledForEvidenceGeneration = evidenceGeneration
        // The external gate measures absence from the first confirmed loss.
        // Give it its full dwell before asking for coverage, otherwise a
        // premature .none would consume this generation's only scan slot.
        let baseDelayMilliseconds: Int
        if let minimumDelayMilliseconds {
            baseDelayMilliseconds = minimumDelayMilliseconds
        } else if faceLock.isActive(at: monotonicNanoseconds()),
           faceLock.permitsMotor(at: monotonicNanoseconds()) {
            // Keep the social identity latched while its remembered bearing
            // gets the first bounded recovery attempt. Broad coverage starts
            // only if that local attempt fails to put the face back in view.
            baseDelayMilliseconds = 1_500
        } else if externalGate == nil && idleExplorationGate != nil {
            baseDelayMilliseconds = 450
        } else {
            baseDelayMilliseconds = 450
        }
        let now = monotonicNanoseconds()
        let startupDelayMilliseconds: Int
        if explorationEligibleAfterNS > now {
            startupDelayMilliseconds = Int((explorationEligibleAfterNS - now + 999_999) / 1_000_000)
        } else {
            startupDelayMilliseconds = 0
        }
        let delayMilliseconds = max(baseDelayMilliseconds, startupDelayMilliseconds)
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) { [weak self] in
            guard let self,
                  self.visualEvidenceGeneration == evidenceGeneration,
                  self.scanScheduledForEvidenceGeneration == evidenceGeneration,
                  case .running = self.state,
                  self.helperReady else {
                return
            }
            let now = monotonicNanoseconds()
            // A callback may have been queued before helper readiness set the
            // start-up grace. Enforce the same boundary at execution time;
            // otherwise that stale callback can begin a sweep before the
            // first live face pass reaches the bridge.
            guard now >= self.explorationEligibleAfterNS else {
                self.scanScheduledForEvidenceGeneration = nil
                self.scheduleScanAfterContinuousVisualLoss()
                return
            }
            guard !self.hasRecentObservedFace(at: now) else { return }
            let action: ExternalGimbalAttentionAction
            if var externalGate = self.externalGate {
                action = externalGate.beginScanIfEligible(at: now)
                self.externalGate = externalGate
            } else if var idleExplorationGate = self.idleExplorationGate {
                action = idleExplorationGate.beginIfEligible(at: now)
                self.idleExplorationGate = idleExplorationGate
            } else {
                return
            }
            self.apply(action, at: now, target: nil, reason: "visual_absence_timeout")
        }
    }

    private func apply(
        _ action: NativeHumanTrackingAction,
        at now: UInt64,
        target: AttentionTarget?,
        reason: String
    ) {
        switch action {
        case .none:
            return
        case .start:
            guard let target else { return }
            guard !nativeTrackingStartPending, !nativeTrackingActive else { return }
            let commandID = nextCommandID(prefix: "native-human")
            nativeTrackingStartPending = true
            send("native_start \(commandID)")
            nativeCommandID = commandID
            writer.write(CameraIntentEvent(
                monotonicNS: now,
                owner: .nativeAI,
                state: "native_tracking_requested",
                route: .nativeHumanTracking,
                commandID: commandID,
                targetKind: target.kind,
                targetLabel: target.label,
                targetProbability: target.posteriorProbability
            ))
        case .heartbeat:
            guard nativeTrackingActive, let commandID = nativeCommandID else { return }
            send("heartbeat \(commandID)")
        case .stop:
            stopNativeHeartbeatLoop()
            let commandID = nextCommandID(prefix: "manual-stop")
            send("manual_stop \(commandID)")
            nativeCommandID = nil
            nativeTrackingActive = false
            nativeTrackingStartPending = false
            writer.write(CameraIntentEvent(
                monotonicNS: now,
                owner: .nativeAI,
                state: reason == "vision_miss" ? "vision_lost" : "target_not_human_or_not_credible",
                route: .none,
                commandID: commandID,
                targetKind: nil,
                targetLabel: nil,
                targetProbability: 0
            ))
        }
    }

    /// The helper's 750 ms ownership watchdog protects against a dead bridge,
    /// not a momentary detector gap. Once native tracking is acknowledged,
    /// keep that watchdog alive from the control queue until this bridge
    /// explicitly releases the native lease.
    private func startNativeHeartbeatLoop() {
        nativeHeartbeatGeneration += 1
        scheduleNativeHeartbeat(generation: nativeHeartbeatGeneration)
    }

    private func scheduleNativeHeartbeat(generation: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self,
                  generation == self.nativeHeartbeatGeneration,
                  case .running = self.state,
                  self.process.isRunning,
                  self.helperReady,
                  self.nativeTrackingActive else {
                return
            }
            let now = monotonicNanoseconds()
            self.apply(
                self.gate.heartbeatIfActive(at: now),
                at: now,
                target: nil,
                reason: "native_tracking_lease"
            )
            self.scheduleNativeHeartbeat(generation: generation)
        }
    }

    private func stopNativeHeartbeatLoop() {
        nativeHeartbeatGeneration += 1
    }

    private func apply(
        _ action: ExternalGimbalAttentionAction,
        at now: UInt64,
        target: AttentionTarget?,
        reason: String
    ) {
        switch action {
        case .none:
            return
        case let .velocity(pitch, pan):
            if target == nil {
                startSmoothExploration(initialPan: pan)
            } else {
                guard let target else { return }
                cancelScan()
                if target.isFaceMotorTarget {
                    sendExternalVelocity(
                        pitch: pitch,
                        pan: pan,
                        state: "face_servo_velocity_requested",
                        target: target,
                        at: now,
                        hardStopAfterNS: 350_000_000
                    )
                    return
                }
                sendExternalVelocity(
                    pitch: pitch,
                    pan: pan,
                    state: target.kind == .human ? "social_reframe_requested" : "visual_fixation_requested",
                    target: target,
                    at: now,
                    hardStopAfterNS: 350_000_000
                )
            }
        case .hold:
            guard let target, target.isFaceMotorTarget else { return }
            cancelScan()
            sendExternalVelocity(
                pitch: 0,
                pan: 0,
                state: "face_hold_requested",
                target: target,
                at: now,
                hardStopAfterNS: 350_000_000
            )
        case .stop:
            cancelScan()
            cancelExternalStop()
            sendExternalStop(state: reason == "vision_miss" ? "vision_lost" : "external_attention_released", at: now)
        }
    }

    private func applyCalibration(_ belief: BeliefSnapshot, reason: String) {
        let now = belief.monotonicNS
        if reason == "vision_miss" {
            switch calibrationStage {
            case .awaitingTarget:
                // Calibration needs a stationary image reference. It waits for
                // a suitable scene candidate rather than moving the camera to
                // manufacture one.
                break
            case .panPulse, .panSettling, .pitchPulse, .pitchSettling:
                // Gimbal movement can blank one or two detector frames. The
                // timer already ends the pulse; wait for a same-track sample
                // during settling instead of mistaking this for target loss.
                break
            case .completed, .failed:
                break
            }
            return
        }
        switch calibrationStage {
        case .awaitingTarget:
            // The calibration anchor is selected directly from SceneField.
            // The attention posterior may legitimately switch to an edge
            // candidate between frames, but that is a poor target for a
            // displacement pulse.
            return
        case .panPulse:
            return
        case .panSettling:
            guard let sample = calibrationSample(from: belief) else { return }
            advanceCalibration(with: sample, target: belief.target, at: now)
        case .pitchPulse:
            return
        case .pitchSettling:
            guard let sample = calibrationSample(from: belief) else { return }
            advanceCalibration(with: sample, target: belief.target, at: now)
        case .completed, .failed:
            return
        }
    }

    private func applySceneCandidates(_ candidates: [SceneCandidate], at monotonicNS: UInt64) {
        guard !cameraGeometryCalibrationMode, !panoramaStripScanMode else { return }
        if calibrationMode {
            applyCalibrationCandidates(candidates, at: monotonicNS)
            return
        }
        // Social signalling follows fresh human perception, not the later
        // face-lock/motor decision. A person at the frame edge or awaiting
        // landmark corroboration is still someone SOMA has noticed.
        if candidates.contains(where: {
            $0.observedThisFrame && $0.observation.kind == .human
        }) {
            let priorVisualState = indicatorInputs.visualState
            indicatorInputs.observeHumanVisualPresence()
            // A person is in view but the ready-to-speak blink must still
            // fall back to human_detected once the eye-contact lease expires,
            // even on frames that yield no fresh face observation (face briefly
            // undetected or the person has stopped looking). Without this, the
            // blink can stay asserted while the user looks away.
            let hasFreshEyeContactThisFrame = candidates.contains {
                $0.observedThisFrame
                    && $0.observation.kind == .human
                    && $0.observation.label == "face"
                    && $0.eyeContactEligible
            }
            if indicatorInputs.visualState == .eyeContact,
               !hasFreshEyeContactThisFrame,
               !eyeContactIndicatorLease.isActive(at: monotonicNS) {
                indicatorInputs.visualState = .humanDetected
            }
            if indicatorInputs.visualState != priorVisualState {
                refreshIndicator(at: monotonicNS)
            }
        }
        guard process.isRunning,
              helperReady,
              !explorationRecentering else {
            return
        }
        freshFaceBearings.removeAll(keepingCapacity: true)
        for candidate in candidates where candidate.observedThisFrame
            && candidate.observation.kind == .human
            && candidate.observation.label == "face" {
            if let bearing = candidate.bearing {
                freshFaceBearings[candidate.id] = (bearing, monotonicNS)
            }
        }
        guard activeCognitiveMotorRequestID == nil else { return }
        let observedFaces = candidates.filter { candidate in
            candidate.observedThisFrame
                && candidate.observation.kind == .human
                && candidate.observation.label == "face"
                && candidate.isActionEligible
        }
        // A complete landmark set can acquire a static, real face immediately.
        // An ANE-only candidate normally needs world-relative activity. During
        // an active exploration pulse that activity cannot be measured, so a
        // repeated high-confidence face may only open the provisional external
        // re-centering path; native authority still requires verification.
        // A landmark-verified face is a real person (the verifier rules out
        // static face-shaped distractors), so it may interrupt the coverage
        // scan even while it is near an edge. Requiring a foveal frame here let
        // the scan sweep past the user and keep running, destabilizing the
        // person's identity because the gimbal never stopped to face them.
        let verifiedFace = observedFaces
            .filter { $0.faceVerificationEligible }
            .max { $0.observation.confidence < $1.observation.confidence }
        let heldFace = observedFaces.first(where: {
            faceLock.permitsMotor(at: monotonicNS)
                && faceLock.holds(sceneID: $0.id, rect: $0.observation.rect, at: monotonicNS)
        })
        let observedFace: SceneCandidate?
        if let heldFace,
           !(faceLock.isProvisional(at: monotonicNS)
                && verifiedFace?.id != heldFace.id) {
            observedFace = heldFace
        } else if let verifiedFace {
            // A landmark-confirmed face must immediately replace a provisional
            // ANE-only lookalike. Raw candidates still acquire first when
            // they are alone, but they cannot make a person wait out a false
            // lock once independent face evidence arrives.
            observedFace = verifiedFace
        } else if !faceLock.permitsMotor(at: monotonicNS) {
            // A moving raw face may acquire the initial provisional lease,
            // but it may never replace an already confirmed social reference.
            // The earlier ordering let an unrelated active false positive
            // steal a live face lock and turn the gimbal away from the user.
            observedFace = observedFaces
                .filter {
                    let provisionalExplorationInterception = scanRunning
                        && FaceLockLease.permitsProvisionalExplorationInterception(
                            observationCount: $0.observationCount,
                            confidence: $0.observation.confidence
                        )
                    return ($0.faceActivityEligible || provisionalExplorationInterception)
                        && isFaceAcquisitionFramed($0.observation.rect)
                }
                .max { $0.observation.confidence < $1.observation.confidence }
        } else if faceLock.permitsMotor(at: monotonicNS) {
            // Keep the current verified social reference through a detector
            // ID gap. A new raw rectangle waits for independent verification
            // rather than becoming an arbitrary handoff target.
            observedFace = nil
        } else {
            observedFace = nil
        }
        if let observedFace {
            // A current face gets one short re-centering attempt even before
            // independent verification, so an edge-clipped real face is not
            // discarded before the verifier can see it. Verification is still
            // required to extend the lease or enable native AI tracking.
            let accepted = faceLock.observe(
                sceneID: observedFace.id,
                rect: observedFace.observation.rect,
                verified: observedFace.faceVerificationEligible,
                at: monotonicNS
            )
            if accepted, faceLock.permitsInitialMotor(at: monotonicNS) {
                let preemptedExploration = scanRunning || activeSpatialFaceReacquisition != nil
                lastObservedFaceNS = monotonicNS
                if faceLock.permitsMotor(at: monotonicNS) {
                    // The ready-to-speak invitation must be earned by the
                    // camera actually following the person (device-confirmed
                    // native tracking). A locked face with eye contact but no
                    // live tracking is "person visible", not "ready to talk":
                    // the two states rise and fall together so the blinking
                    // blue indicator never claims a tracking SOMA is not doing.
                    if nativeTrackingActive, observedFace.eyeContactEligible {
                        eyeContactIndicatorLease.observe(
                            sceneID: observedFace.id,
                            at: monotonicNS
                        )
                        indicatorInputs.visualState = .eyeContact
                    } else if nativeTrackingActive,
                              eyeContactIndicatorLease.isActive(at: monotonicNS) {
                        // Bridge a brief gaze dropout (and a SceneField track-ID
                        // reassignment of the same face) while the camera is
                        // still following the person. We intentionally use the
                        // non-refreshing isActive() hold here rather than
                        // maintain(sceneID:), which refreshes the lease on every
                        // same-face observation and would keep the blink asserted
                        // indefinitely once eye contact drops. This expires ~3s
                        // after the last real eye contact, so looking away
                        // releases the blink instead of holding it.
                        indicatorInputs.visualState = .eyeContact
                    } else {
                        indicatorInputs.visualState = .humanDetected
                    }
                    refreshIndicator(at: monotonicNS)
                    socialTrackingContinuity.recordObservation(at: monotonicNS)
                    nativeTrustContinuity.recordObservation(at: monotonicNS)
                }
                // Invalidate any absence callback that was queued before this
                // frame. It must not revive a search pulse after preemption.
                visualEvidenceGeneration += 1
                scanScheduledForEvidenceGeneration = nil
                activeSpatialFaceReacquisition = nil
                attemptedSpatialFaceReacquisitionIDs.removeAll()
                explorationFailureCount = max(0, explorationFailureCount - 1)
                cancelScan()
                if preemptedExploration, externalCommandID != nil {
                    cancelExternalStop()
                    sendExternalStop(state: "face_observation_preempted_exploration", at: monotonicNS)
                }
                apply(
                    gate.heartbeatIfActive(at: monotonicNS),
                    at: monotonicNS,
                    target: nil,
                    reason: observedFace.observation.source.rawValue
                )
                return
            }
        }

        // Native-only installations still need a local face lock. Only the
        // optional external spatial re-acquisition path depends on a learned
        // screen-to-gimbal calibration.
        guard externalCalibration != nil,
              faceLock.permitsMotor(at: monotonicNS),
              let lockedFaceID = faceLock.sceneID else { return }
        guard let rememberedFace = candidates
            .filter({ candidate in
                !candidate.observedThisFrame
                    && candidate.observation.kind == .human
                    && candidate.observation.label == "face"
                    && candidate.id == lockedFaceID
                    && candidate.observationCount >= 2
                    && candidate.spatialConfidence >= 0.70
                    && candidate.bearing != nil
            })
            .min(by: { $0.lastSeenMilliseconds < $1.lastSeenMilliseconds }) else {
            return
        }
        guard let confirmedVisualLossNS,
              monotonicNS >= confirmedVisualLossNS + 200_000_000 else { return }
        applySpatialFaceReacquisition(rememberedFace, at: monotonicNS)
    }

    /// Apply E2B's proportional reaction as a simple L0 control signal. Called
    /// from the auxiliary VLM cue path (not the face pipeline) so E2B can add
    /// human detection without disturbing face-lock evidence.
    func applyAuxiliaryReaction(_ reaction: L1AuxiliaryReaction, at monotonicNS: UInt64) {
        let prior = indicatorInputs.resolvedState
        indicatorInputs.applyAuxiliaryReaction(reaction)
        if indicatorInputs.resolvedState != prior {
            refreshIndicator(at: monotonicNS)
        }
        applyAuxiliaryL0Release(reaction, at: monotonicNS)
    }

    /// Direct L0 un-stick: if L0 is currently face-locked but E2B consistently
    /// reports a reaction that points attention elsewhere (orient = non-person
    /// scene change; observe = sustained ambient change), release the lock and
    /// resume scanning. This lets E2B break a fixation the face detector itself
    /// will not clear. Requires several consecutive cues so a single transient
    /// judgment does not tear down a legitimate lock.
    private func applyAuxiliaryL0Release(_ reaction: L1AuxiliaryReaction, at monotonicNS: UInt64) {
        guard faceLock.sceneID != nil else {
            consecutiveAuxiliaryReleaseSignal = 0
            return
        }
        let threshold: Int
        switch reaction {
        case .orient: threshold = auxiliaryOrientReleaseCount
        case .observe: threshold = auxiliaryObserveReleaseCount
        default:
            consecutiveAuxiliaryReleaseSignal = 0
            return
        }
        consecutiveAuxiliaryReleaseSignal += 1
        guard consecutiveAuxiliaryReleaseSignal >= threshold else { return }
        consecutiveAuxiliaryReleaseSignal = 0
        releaseWrongFixation(reason: "auxiliary_\(reaction.rawValue)", at: monotonicNS)
    }

    private func releaseWrongFixation(reason: String, at monotonicNS: UInt64) {
        faceLock.invalidate()
        lastMotorTarget = nil
        sendExternalStop(state: reason, at: monotonicNS)
        resumeCoverageScan()
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "l0_auxiliary_release",
            state: reason,
            message: "E2B released a fixation E2B judged to be wrong; resumed coverage scan"
        ))
    }

    private func isFaceAcquisitionFramed(_ rect: SOMACore.NormalizedRect) -> Bool {
        // A new lock needs a foveal face measurement. This is deliberately
        // stricter than the ongoing servo envelope: after a real face has
        // acquired the lease, it may walk toward an edge without being
        // abandoned. The lower field is where the live cable/desk false
        // positives occur, so it cannot originate a social motor lock.
        TrackingBoundary.allowsFaceLockAcquisition(rect)
    }

    private func applySpatialFaceReacquisition(_ candidate: SceneCandidate, at monotonicNS: UInt64) {
        guard !hasRecentObservedFace(at: monotonicNS) else { return }
        if let activeSpatialFaceReacquisition {
            guard activeSpatialFaceReacquisition.id == candidate.id else { return }
            guard monotonicNS < activeSpatialFaceReacquisition.deadlineNS else {
                attemptedSpatialFaceReacquisitionIDs.insert(candidate.id)
                self.activeSpatialFaceReacquisition = nil
                return
            }
        } else {
            guard !attemptedSpatialFaceReacquisitionIDs.contains(candidate.id) else { return }
            activeSpatialFaceReacquisition = (candidate.id, monotonicNS + 1_000_000_000)
        }
        guard let calibration = externalCalibration,
              let bearing = candidate.bearing,
              let pose = poseStore.latest(at: monotonicNS),
              let motionGuide = GimbalVisibilityRoutePlanner.guide(
                to: bearing,
                from: pose,
                horizontalViewMarginDegrees: 18,
                verticalViewMarginDegrees: 12
              ) else {
            attemptedSpatialFaceReacquisitionIDs.insert(candidate.id)
            activeSpatialFaceReacquisition = nil
            return
        }
        let panError = spatialFaceReacquisitionSpeed(
            errorDegrees: motionGuide.azimuthDegrees - pose.panDegrees,
            maximumDegreesPerSecond: 72,
            fullScaleDegrees: 24
        )
        let pitchError = spatialFaceReacquisitionSpeed(
            errorDegrees: motionGuide.elevationDegrees - pose.pitchDegrees,
            maximumDegreesPerSecond: 30,
            fullScaleDegrees: 12
        )
        let pan = calibration.panCommand(
            forPoseError: panError,
            projection: .obsbotTiny2Lite
        )
        let pitch = calibration.pitchCommand(
            forPoseError: pitchError,
            projection: .obsbotTiny2Lite
        )
        guard pan != 0 || pitch != 0 else {
            attemptedSpatialFaceReacquisitionIDs.insert(candidate.id)
            activeSpatialFaceReacquisition = nil
            return
        }
        guard lastSpatialFaceReacquisitionCommandNS == 0
                || monotonicNS >= lastSpatialFaceReacquisitionCommandNS + 100_000_000 else {
            return
        }
        cancelScan()
        lastSpatialFaceReacquisitionCommandNS = monotonicNS
        sendExternalVelocity(
            pitch: pitch,
            pan: pan,
            state: "spatial_face_reacquisition_requested",
            target: nil,
            at: monotonicNS,
            hardStopAfterNS: 250_000_000
        )
    }

    private func spatialFaceReacquisitionSpeed(
        errorDegrees: Double,
        maximumDegreesPerSecond: Double,
        fullScaleDegrees: Double
    ) -> Double {
        let magnitude = abs(errorDegrees)
        guard magnitude > 1.5 else { return 0 }
        let normalized = min(1, (magnitude - 1.5) / max(fullScaleDegrees - 1.5, 0.1))
        let minimum = min(8, maximumDegreesPerSecond)
        let speed = minimum + (maximumDegreesPerSecond - minimum) * pow(normalized, 1.2)
        return errorDegrees < 0 ? -speed : speed
    }

    private func applyCalibrationCandidates(_ candidates: [SceneCandidate], at monotonicNS: UInt64) {
        guard calibrationMode, process.isRunning, helperReady else { return }
        if case .awaitingTarget = calibrationStage {
            guard let sample = calibrationAnchor(from: candidates) else { return }
            beginCalibration(with: sample, at: monotonicNS)
            return
        }
        let baseline: CalibrationSample
        switch calibrationStage {
        case let .panSettling(sample, stoppedNS) where monotonicNS >= stoppedNS + 400_000_000:
            baseline = sample
        case let .pitchSettling(_, sample, stoppedNS) where monotonicNS >= stoppedNS + 400_000_000:
            baseline = sample
        default:
            return
        }
        guard let sample = candidates.lazy
            .filter(\.observedThisFrame)
            .compactMap(calibrationSample(from:))
            .first(where: { matches($0, baseline) }) else {
            return
        }
        advanceCalibration(with: sample, target: nil, at: monotonicNS)
    }

    private func spatialSpeed(
        errorDegrees: Double,
        maximumDegreesPerSecond: Double,
        fullScaleDegrees: Double
    ) -> Double {
        let magnitude = abs(errorDegrees)
        guard magnitude > 1 else { return 0 }
        let normalized = min(1, (magnitude - 1) / max(fullScaleDegrees - 1, 0.1))
        let minimum = min(18, maximumDegreesPerSecond)
        let speed = minimum + (maximumDegreesPerSecond - minimum) * pow(normalized, 1.35)
        return errorDegrees < 0 ? -speed : speed
    }

    private func angularDifference(_ targetDegrees: Double, _ currentDegrees: Double) -> Double {
        var difference = (targetDegrees - currentDegrees).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference <= -180 { difference += 360 }
        return difference
    }

    private func calibrationAnchor(from candidates: [SceneCandidate]) -> CalibrationSample? {
        let anchor = candidates
            .filter { candidate in
                let observation = candidate.observation
                return candidate.observedThisFrame
                    && candidate.stabilityMilliseconds >= 500
                    && observation.label != nil
                    && observation.rect.centerX >= 0.25
                    && observation.rect.centerX <= 0.70
                    && observation.rect.centerY >= 0.20
                    && observation.rect.centerY <= 0.80
            }
            .max { lhs, rhs in
                lhs.observation.confidence < rhs.observation.confidence
            }
        return anchor.flatMap(calibrationSample(from:))
    }

    private func beginCalibration(with sample: CalibrationSample, at monotonicNS: UInt64) {
        cancelScan()
        calibrationStage = .panPulse(baseline: sample, startedNS: monotonicNS)
        sendCalibrationVelocity(
            pitch: 0,
            pan: 18,
            state: "calibration_pan_pulse",
            target: nil,
            at: monotonicNS,
            afterStop: { [weak self] stoppedNS in
                self?.calibrationStage = .panSettling(baseline: sample, stoppedNS: stoppedNS)
            }
        )
    }

    private func advanceCalibration(
        with sample: CalibrationSample,
        target: AttentionTarget?,
        at monotonicNS: UInt64
    ) {
        switch calibrationStage {
        case let .panSettling(baseline, stoppedNS):
            guard monotonicNS >= stoppedNS + 400_000_000, matches(sample, baseline) else { return }
            let panImageDelta = sample.centerX - baseline.centerX
            guard abs(panImageDelta) >= 0.015 else {
                failCalibration("pan_response_below_detector_jitter", at: monotonicNS)
                return
            }
            calibrationStage = .pitchPulse(panImageDelta: panImageDelta, baseline: sample, startedNS: monotonicNS)
            sendCalibrationVelocity(
                pitch: 25,
                pan: 0,
                state: "calibration_pitch_pulse",
                target: target,
                at: monotonicNS,
                afterStop: { [weak self] stoppedNS in
                    self?.calibrationStage = .pitchSettling(panImageDelta: panImageDelta, baseline: sample, stoppedNS: stoppedNS)
                }
            )
        case let .pitchSettling(panImageDelta, baseline, stoppedNS):
            guard monotonicNS >= stoppedNS + 400_000_000, matches(sample, baseline) else { return }
            let pitchImageDelta = sample.centerY - baseline.centerY
            guard let calibration = ExternalGimbalCalibration.fromPositivePulseDisplacements(
                panImageDelta: panImageDelta,
                pitchImageDelta: pitchImageDelta
            ) else {
                failCalibration("pitch_response_below_detector_jitter", at: monotonicNS)
                return
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(calibration).write(to: calibrationOutputURL!, options: .atomic)
                calibrationStage = .completed
                calibrationMode = false
                externalGate = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: true)
                idleExplorationGate = nil
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNS,
                    source: "external_gimbal_calibration",
                    state: "completed",
                    message: String(format: "pan_image_delta=%.4f; pitch_image_delta=%.4f", panImageDelta, pitchImageDelta)
                ))
            } catch {
                failCalibration("write_failed", at: monotonicNS)
            }
        default:
            return
        }
    }

    private func calibrationSample(from belief: BeliefSnapshot) -> CalibrationSample? {
        guard let target = belief.target, target.isActionEligible else { return nil }
        return CalibrationSample(
            sceneID: target.id,
            kind: target.kind,
            label: target.label,
            centerX: target.rect.centerX,
            centerY: target.rect.centerY
        )
    }

    private func calibrationSample(from candidate: SceneCandidate) -> CalibrationSample? {
        guard candidate.isActionEligible else { return nil }
        let observation = candidate.observation
        return CalibrationSample(
            sceneID: candidate.id,
            kind: observation.kind,
            label: observation.label,
            centerX: observation.rect.centerX,
            centerY: observation.rect.centerY
        )
    }

    private func matches(_ candidate: CalibrationSample, _ baseline: CalibrationSample) -> Bool {
        if candidate.sceneID == baseline.sceneID {
            return true
        }

        // A short calibration pulse can move an otherwise stable detector box
        // far enough that SceneField assigns a new local ID. Keep the
        // correspondence only for an identified, same-kind target that remains
        // near the prior image position; anonymous saliency never crosses an
        // ID boundary during calibration.
        guard let label = baseline.label,
              candidate.kind == baseline.kind,
              candidate.label == label else {
            return false
        }
        return abs(candidate.centerX - baseline.centerX) <= 0.25
            && abs(candidate.centerY - baseline.centerY) <= 0.25
    }

    private func applyEmbodimentIntent(_ intent: EmbodimentMotorIntent) {
        let now = monotonicNanoseconds()
        switch intent {
        case let .orient(requestID, bearing, tolerance, style, expiresAtNS, reason):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            cognitiveMotionMode = .waypoint(
                bearing: bearing,
                toleranceDegrees: tolerance,
                motionStyle: style,
                state: "cognitive_\(reason)"
            )
            cognitiveMotionHolding = false
            startCognitiveMotionLoop()
        case let .track(requestID, reference, sceneID, bearing, observed, style, expiresAtNS):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            cognitiveMotionMode = .waypoint(
                bearing: bearing,
                toleranceDegrees: observed ? 2.0 : 4.0,
                motionStyle: style,
                state: "cognitive_track_\(String(reference.prefix(32)))_\(String(sceneID.prefix(32)))"
            )
            cognitiveMotionHolding = false
            startCognitiveMotionLoop()
        case let .capture(requestID, reference, sceneID, bearing, fieldOfView, expiresAtNS):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            embodimentViewCaptureStore?.prepare(
                requestID: requestID,
                targetReference: reference,
                sceneID: sceneID,
                bearing: bearing,
                fieldOfViewDegrees: fieldOfView,
                leaseExpiresAtNS: expiresAtNS,
                at: now
            )
            cognitiveMotionMode = .capture(
                requestID: requestID,
                bearing: bearing,
                fieldOfViewDegrees: fieldOfView,
                stableSinceNS: nil,
                lastPositionCommandNS: nil
            )
            cognitiveMotionHolding = false
            startCognitiveMotionLoop()
        case let .explore(requestID, policy, expiresAtNS):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            cognitiveMotionMode = .exploration(policy: policy)
            cognitiveExplorationWaypoint = nil
            cognitiveExplorationWaypointStartedNS = nil
            cognitiveMotionHolding = false
            startCognitiveMotionLoop()
        case let .express(requestID, expression, expiresAtNS):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            cognitiveMotionMode = .expression(
                kind: expression,
                basePose: nil,
                waypointIndex: 0,
                waypointStartedNS: nil
            )
            cognitiveMotionHolding = false
            startCognitiveMotionLoop()
        case let .suspend(requestID, reason, expiresAtNS):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            if reason.hasPrefix("capture_") {
                embodimentViewCaptureStore?.fail(
                    requestID: requestID,
                    reason: reason,
                    leaseExpiresAtNS: expiresAtNS,
                    at: now
                )
            }
            cognitiveMotionMode = .suspended(reason: reason)
            stopCognitiveMotion(state: "cognitive_\(reason)", at: now, retainLease: true)
        case let .release(requestID, reason):
            guard requestID == nil || activeCognitiveMotorRequestID == requestID else { return }
            releaseCognitiveMotor(state: "cognitive_\(reason)", at: now)
        }
    }

    private func claimCognitiveMotor(requestID: String, expiresAtNS: UInt64, at monotonicNS: UInt64) {
        let changesOwner = activeCognitiveMotorRequestID != requestID
        let previousRequestID = activeCognitiveMotorRequestID
        activeCognitiveMotorRequestID = requestID
        activeCognitiveMotorExpiresAtNS = expiresAtNS
        visualEvidenceGeneration += 1
        scanScheduledForEvidenceGeneration = nil
        activeSpatialFaceReacquisition = nil
        cancelScan()
        if changesOwner {
            if let previousRequestID {
                embodimentViewCaptureStore?.cancel(
                    requestID: previousRequestID,
                    reason: "capture_preempted",
                    at: monotonicNS
                )
            }
            cognitiveMotionGeneration += 1
            cognitiveMotionLoopRunning = false
            cognitiveDynamics.reset()
            cognitiveExplorationWaypoint = nil
            cognitiveExplorationWaypointStartedNS = nil
            let nativeAction = gate.invalidate()
            apply(nativeAction, at: monotonicNS, target: nil, reason: "cognitive_motor_preemption")
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "embodiment_motor",
                state: "lease_acquired",
                message: "request_id=\(String(requestID.prefix(96)))"
            ))
        }
    }

    private func startCognitiveMotionLoop() {
        guard !cognitiveMotionLoopRunning else { return }
        cognitiveMotionLoopRunning = true
        cognitiveMotionGeneration += 1
        scheduleCognitiveMotionTick(generation: cognitiveMotionGeneration)
    }

    private func scheduleCognitiveMotionTick(generation: Int, afterMilliseconds: Int = 0) {
        queue.asyncAfter(deadline: .now() + .milliseconds(afterMilliseconds)) { [weak self] in
            self?.runCognitiveMotionTick(generation: generation)
        }
    }

    private func runCognitiveMotionTick(generation: Int) {
        guard generation == cognitiveMotionGeneration,
              cognitiveMotionLoopRunning,
              let requestID = activeCognitiveMotorRequestID,
              let expiresAtNS = activeCognitiveMotorExpiresAtNS else { return }
        let now = monotonicNanoseconds()
        guard now < expiresAtNS else {
            releaseCognitiveMotor(state: "cognitive_lease_expired", at: now)
            return
        }
        guard process.isRunning, helperReady, let calibration = externalCalibration else {
            if !cognitiveMotionHolding {
                cognitiveMotionHolding = true
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "embodiment_motor",
                    state: "actuator_unavailable",
                    message: "request_id=\(String(requestID.prefix(96)))"
                ))
            }
            scheduleCognitiveMotionTick(generation: generation, afterMilliseconds: 100)
            return
        }
        // Bounded expressions (bow/nod/greeting) complete on a fixed timer, so
        // they may use the last known pose even if the attitude sample is stale
        // (e.g. during an SDK AI-tracking transaction). Other modes need a fresh
        // pose to avoid driving on outdated geometry.
        let pose: GimbalPose?
        if case .expression = cognitiveMotionMode {
            pose = poseStore.lastKnown()
        } else {
            pose = poseStore.current(maximumAgeNS: 250_000_000)
        }
        guard let pose else {
            if !cognitiveMotionHolding {
                stopCognitiveMotion(state: "cognitive_pose_wait", at: now, retainLease: true)
                cognitiveMotionLoopRunning = true
            }
            scheduleCognitiveMotionTick(
                generation: cognitiveMotionGeneration,
                afterMilliseconds: 50
            )
            return
        }

        switch cognitiveMotionMode {
        case let .waypoint(bearing, tolerance, style, state):
            driveCognitiveWaypoint(
                bearing,
                toleranceDegrees: tolerance,
                motionStyle: style,
                state: state,
                calibration: calibration,
                pose: pose,
                at: now
            )
        case let .capture(requestID, bearing, fieldOfView, stableSinceNS, lastPositionCommandNS):
            driveCognitiveCapture(
                requestID: requestID,
                bearing: bearing,
                fieldOfViewDegrees: fieldOfView,
                stableSinceNS: stableSinceNS,
                lastPositionCommandNS: lastPositionCommandNS,
                pose: pose,
                at: now
            )
        case let .exploration(policy):
            driveCognitiveExploration(
                policy: policy,
                calibration: calibration,
                pose: pose,
                at: now
            )
        case let .expression(kind, basePose, waypointIndex, waypointStartedNS):
            driveCognitiveExpression(
                kind: kind,
                basePose: basePose,
                waypointIndex: waypointIndex,
                waypointStartedNS: waypointStartedNS,
                calibration: calibration,
                pose: pose,
                at: now
            )
        case let .suspended(reason):
            if !cognitiveMotionHolding {
                stopCognitiveMotion(state: "cognitive_\(reason)", at: now, retainLease: true)
            }
        case .none:
            break
        }
        if cognitiveMotionLoopRunning {
            scheduleCognitiveMotionTick(
                generation: cognitiveMotionGeneration,
                afterMilliseconds: 50
            )
        }
    }

    private func driveCognitiveWaypoint(
        _ target: GimbalRelativeBearing,
        toleranceDegrees: Double,
        motionStyle: EmbodimentMotionStyle,
        accelerationMultiplier: Double = 1,
        state: String,
        calibration: ExternalGimbalCalibration,
        pose: GimbalPose,
        at monotonicNS: UInt64
    ) {
        guard let guide = GimbalVisibilityRoutePlanner.guide(
            to: target,
            from: pose,
            observationPreference: .centered
        ) else {
            stopCognitiveMotion(state: "cognitive_route_unreachable", at: monotonicNS, retainLease: true)
            return
        }
        let panError = guide.azimuthDegrees - pose.panDegrees
        let pitchError = guide.elevationDegrees - pose.pitchDegrees
        guard hypot(panError, pitchError) > toleranceDegrees else {
            if !cognitiveMotionHolding {
                stopCognitiveMotion(state: "\(state)_holding", at: monotonicNS, retainLease: true)
            }
            return
        }
        cognitiveMotionHolding = false
        let profile = cognitiveMotionProfile(for: motionStyle)
        let desiredPan = SmoothExplorationDynamics.stoppingVelocity(
            errorDegrees: panError,
            maximumDegreesPerSecond: min(profile.panSpeed, calibration.maximumPanDegreesPerSecond),
            accelerationDegreesPerSecondSquared: profile.panAcceleration,
            deadbandDegrees: toleranceDegrees
        )
        let desiredPitch = SmoothExplorationDynamics.stoppingVelocity(
            errorDegrees: pitchError,
            maximumDegreesPerSecond: min(profile.pitchSpeed, calibration.maximumPitchDegreesPerSecond),
            accelerationDegreesPerSecondSquared: profile.pitchAcceleration,
            deadbandDegrees: toleranceDegrees
        )
        let velocity = cognitiveDynamics.advance(
            towardPitch: calibration.pitchCommand(
                forPoseError: desiredPitch,
                projection: .obsbotTiny2Lite
            ),
            pan: calibration.panCommand(
                forPoseError: desiredPan,
                projection: .obsbotTiny2Lite
            ),
            at: monotonicNS,
            maximumPitchAcceleration: profile.pitchAcceleration * accelerationMultiplier,
            maximumPanAcceleration: profile.panAcceleration * accelerationMultiplier
        )
        sendExternalVelocity(
            pitch: velocity.pitchDegreesPerSecond,
            pan: velocity.panDegreesPerSecond,
            state: state,
            target: nil,
            at: monotonicNS,
            hardStopAfterNS: 250_000_000
        )
    }

    private func driveCognitiveCapture(
        requestID: String,
        bearing: GimbalRelativeBearing,
        fieldOfViewDegrees: Double,
        stableSinceNS: UInt64?,
        lastPositionCommandNS: UInt64?,
        pose: GimbalPose,
        at monotonicNS: UInt64
    ) {
        guard let guide = GimbalVisibilityRoutePlanner.guide(
            to: bearing,
            from: pose,
            observationPreference: .centered
        ) else {
            embodimentViewCaptureStore?.cancel(
                requestID: requestID,
                reason: "capture_route_unreachable",
                at: monotonicNS
            )
            stopCognitiveMotion(
                state: "cognitive_capture_route_unreachable",
                at: monotonicNS,
                retainLease: true
            )
            return
        }
        let error = hypot(
            guide.azimuthDegrees - pose.panDegrees,
            guide.elevationDegrees - pose.pitchDegrees
        )
        let alignment = CaptureAlignmentHysteresis.evaluate(
            errorDegrees: error,
            stableSinceNS: stableSinceNS,
            at: monotonicNS
        )
        switch alignment.phase {
        case .capture:
            stopCognitiveMotion(
                state: "cognitive_capture_aligned",
                at: monotonicNS,
                retainLease: true
            )
            embodimentViewCaptureStore?.markAligned(
                requestID: requestID,
                cameraPose: pose,
                at: monotonicNS
            )
        case .drive:
            let shouldRefreshPosition = lastPositionCommandNS.map {
                monotonicNS >= $0 + 250_000_000
            } ?? true
            if shouldRefreshPosition {
                sendExternalPosition(
                    pitch: guide.elevationDegrees,
                    pan: guide.azimuthDegrees,
                    state: "cognitive_capture_position",
                    target: nil,
                    at: monotonicNS,
                    hardStopAfterNS: nil
                )
            }
            cognitiveMotionMode = .capture(
                requestID: requestID,
                bearing: bearing,
                fieldOfViewDegrees: fieldOfViewDegrees,
                stableSinceNS: nil,
                lastPositionCommandNS: shouldRefreshPosition
                    ? monotonicNS
                    : lastPositionCommandNS
            )
        case .beginSettling:
            stopCognitiveMotion(
                state: "cognitive_capture_settling",
                at: monotonicNS,
                retainLease: true
            )
            cognitiveMotionMode = .capture(
                requestID: requestID,
                bearing: bearing,
                fieldOfViewDegrees: fieldOfViewDegrees,
                stableSinceNS: alignment.stableSinceNS,
                lastPositionCommandNS: lastPositionCommandNS
            )
            cognitiveMotionLoopRunning = true
        case .awaitSettling:
            break
        }
    }

    private func driveCognitiveExploration(
        policy: ExplorationPolicyGoal,
        calibration: ExternalGimbalCalibration,
        pose: GimbalPose,
        at monotonicNS: UInt64
    ) {
        if let waypoint = cognitiveExplorationWaypoint,
           let startedNS = cognitiveExplorationWaypointStartedNS {
            let distance = hypot(
                waypoint.bearing.azimuthDegrees - pose.panDegrees,
                waypoint.bearing.elevationDegrees - pose.pitchDegrees
            )
            let blendRadius = 3 + 9 * policy.motionContinuity
            let dwellElapsed = monotonicNS >= startedNS + policy.dwellMilliseconds * 1_000_000
            if distance <= blendRadius && (policy.motionContinuity >= 0.60 || dwellElapsed) {
                spatialAtlas.recordUnproductiveVisit(to: waypoint, at: monotonicNS)
                cognitiveExplorationWaypoint = nil
                cognitiveExplorationWaypointStartedNS = nil
            }
        }
        if cognitiveExplorationWaypoint == nil {
            let atlas = spatialAtlas.snapshot(at: monotonicNS)
            guard let sampled = CognitiveExplorationPlanner.sample(
                cells: atlas.cells,
                policy: policy,
                from: pose,
                kinematicEnvelope: atlas.kinematicEnvelope,
                uniform: nextExplorationUniform()
            ),
            let guide = GimbalVisibilityRoutePlanner.guide(
                to: sampled.bearing,
                from: pose,
                kinematicEnvelope: atlas.kinematicEnvelope,
                observationPreference: .centered
            ) else {
                stopCognitiveMotion(state: "cognitive_exploration_no_route", at: monotonicNS, retainLease: true)
                cognitiveMotionLoopRunning = true
                return
            }
            cognitiveExplorationWaypoint = SpatialCoverageDirection(
                bearing: guide,
                probability: sampled.probability,
                panoramaQuality: sampled.panoramaQuality,
                placeFamiliarity: sampled.placeFamiliarity,
                expectedInformationGain: sampled.expectedInformationGain
            )
            cognitiveExplorationWaypointStartedNS = monotonicNS
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "embodiment_motor",
                state: "cognitive_exploration_direction_sampled",
                message: String(
                    format: "mode=%@; probability=%.4f; azimuth_degrees=%.2f; elevation_degrees=%.2f",
                    policy.mode.rawValue,
                    sampled.probability,
                    sampled.bearing.azimuthDegrees,
                    sampled.bearing.elevationDegrees
                )
            ))
        }
        guard let waypoint = cognitiveExplorationWaypoint else { return }
        let tempoScale = 0.45 + 0.55 * policy.tempo
        let style: EmbodimentMotionStyle = policy.motionContinuity >= 0.65 ? .smooth : .curious
        let profile = cognitiveMotionProfile(for: style)
        let adjustedProfile = (
            panSpeed: profile.panSpeed * tempoScale,
            pitchSpeed: profile.pitchSpeed * tempoScale,
            panAcceleration: profile.panAcceleration,
            pitchAcceleration: profile.pitchAcceleration
        )
        driveCognitiveWaypoint(
            waypoint.bearing,
            toleranceDegrees: max(1.5, 5 * (1 - policy.motionContinuity)),
            motionStyle: style,
            state: "cognitive_exploration_\(policy.mode.rawValue)",
            calibration: ExternalGimbalCalibration(
                panSign: calibration.panSign,
                pitchSign: calibration.pitchSign,
                maximumPanDegreesPerSecond: min(calibration.maximumPanDegreesPerSecond, adjustedProfile.panSpeed),
                maximumPitchDegreesPerSecond: min(calibration.maximumPitchDegreesPerSecond, adjustedProfile.pitchSpeed)
            ),
            pose: pose,
            at: monotonicNS
        )
        // Exploration owns the lease for its full duration. A requested dwell
        // pauses physical output but keeps this low-rate planner alive so the
        // next waypoint can blend in without a new MCP request.
        cognitiveMotionLoopRunning = true
    }

    private func driveCognitiveExpression(
        kind: SocialGimbalExpression,
        basePose: GimbalPose?,
        waypointIndex: Int,
        waypointStartedNS: UInt64?,
        calibration: ExternalGimbalCalibration,
        pose: GimbalPose,
        at monotonicNS: UInt64
    ) {
        let base = basePose ?? pose
        let offsets = cognitiveExpressionOffsets(kind, currentPan: base.panDegrees)
        guard waypointIndex < offsets.count else {
            // An expression is a bounded overlay. Holding its lease after the
            // return waypoint would suppress face fixation until timeout.
            releaseCognitiveMotor(state: "cognitive_expression_completed", at: monotonicNS)
            return
        }
        let offset = offsets[waypointIndex]
        let target = GimbalRelativeBearing(
            azimuthDegrees: base.panDegrees + offset.pan,
            elevationDegrees: base.pitchDegrees + offset.pitch
        )
        if kind == .greeting,
           let requestID = activeCognitiveMotorRequestID,
           socialPulseIssuedForRequestID != requestID {
            socialPulseIssuedForRequestID = requestID
            onOutgoingSocialPulse(monotonicNS)
        }
        let distance = hypot(target.azimuthDegrees - pose.panDegrees, target.elevationDegrees - pose.pitchDegrees)
        let startedNS = waypointStartedNS ?? monotonicNS
        let minimumWaypointNS: UInt64 = kind == .greeting ? 70_000_000 : 120_000_000
        let arrivalToleranceDegrees = kind == .greeting ? 0.75 : 1.8
        // Advance on arrival OR on a time fallback. Some gimbal SDKs do not
        // reflect commanded movement in the attitude feedback, so the pose
        // distance never converges; without this fallback the expression would
        // hold until the lease expires and never report completion.
        let waypointTimeoutNS: UInt64 = kind == .greeting ? 250_000_000 : 400_000_000
        if distance <= arrivalToleranceDegrees {
            // Waypoint reached. Advance once the minimum dwell time has elapsed;
            // otherwise hold (keep the loop running) WITHOUT re-driving the
            // waypoint. Re-driving would hit the "_holding" branch in
            // driveCognitiveWaypoint, which stops the motion loop and stalls the
            // expression before it can advance to the next waypoint.
            let dwellElapsed = monotonicNS >= startedNS + minimumWaypointNS
            cognitiveMotionMode = .expression(
                kind: kind,
                basePose: base,
                waypointIndex: dwellElapsed ? waypointIndex + 1 : waypointIndex,
                waypointStartedNS: dwellElapsed ? monotonicNS : startedNS
            )
            return
        }
        if monotonicNS >= startedNS + waypointTimeoutNS {
            // Time fallback: advance even if the pose never converged.
            cognitiveMotionMode = .expression(
                kind: kind,
                basePose: base,
                waypointIndex: waypointIndex + 1,
                waypointStartedNS: monotonicNS
            )
            return
        }
        cognitiveMotionMode = .expression(
            kind: kind,
            basePose: base,
            waypointIndex: waypointIndex,
            waypointStartedNS: startedNS
        )
        driveCognitiveWaypoint(
            target,
            toleranceDegrees: kind == .greeting ? 0.75 : 1.2,
            motionStyle: kind == .greeting ? .playful : .attentive,
            accelerationMultiplier: kind == .greeting ? 4 : 1,
            state: "cognitive_expression_\(kind.rawValue)",
            calibration: calibration,
            pose: pose,
            at: monotonicNS
        )
    }

    private func cognitiveExpressionOffsets(
        _ expression: SocialGimbalExpression,
        currentPan: Double
    ) -> [(pitch: Double, pan: Double)] {
        let inward = currentPan > 0 ? -1.0 : 1.0
        switch expression {
        case .acknowledge:
            // Positive pitch = down (pitchCommand == error with pitchSign -1 and
            // pitchImageSign -1). A bow must lower the head, so use +5.
            return [(pitch: 5, pan: 0), (pitch: 0, pan: 0)]
        case .nod:
            // Down, up, return.
            return [(pitch: 7, pan: 0), (pitch: -3, pan: 0), (pitch: 0, pan: 0)]
        case .attentiveReframe:
            return [(pitch: 2, pan: 7 * inward), (pitch: 0, pan: 0)]
        case .thinkingGlance:
            return [(pitch: 4, pan: 10 * inward), (pitch: 0, pan: 0)]
        case .greeting:
            // Explicit greetings are a brief bow and return, never a
            // side-to-side sweep that can dislodge the social target.
            return [(pitch: 4, pan: 0), (pitch: 0, pan: 0)]
        }
    }

    private func cognitiveMotionProfile(
        for style: EmbodimentMotionStyle
    ) -> (panSpeed: Double, pitchSpeed: Double, panAcceleration: Double, pitchAcceleration: Double) {
        switch style {
        case .precise: (36, 18, 90, 60)
        case .smooth: (58, 28, 120, 80)
        case .attentive: (78, 34, 180, 100)
        case .curious: (48, 25, 110, 75)
        case .playful: (68, 32, 190, 105)
        case .cautious: (28, 15, 70, 45)
        }
    }

    private func stopCognitiveMotion(state: String, at monotonicNS: UInt64, retainLease: Bool) {
        cognitiveMotionGeneration += 1
        cognitiveMotionLoopRunning = false
        cognitiveDynamics.reset()
        cognitiveMotionHolding = true
        cognitiveExplorationWaypoint = nil
        cognitiveExplorationWaypointStartedNS = nil
        cancelExternalStop()
        if externalCommandID != nil {
            sendExternalStop(state: state, at: monotonicNS)
        }
        if !retainLease {
            activeCognitiveMotorRequestID = nil
            activeCognitiveMotorExpiresAtNS = nil
            cognitiveMotionMode = nil
        }
    }

    private func releaseCognitiveMotor(state: String, at monotonicNS: UInt64) {
        guard activeCognitiveMotorRequestID != nil else { return }
        let releasedRequestID = activeCognitiveMotorRequestID
        if let releasedRequestID {
            embodimentViewCaptureStore?.cancel(
                requestID: releasedRequestID,
                reason: state,
                at: monotonicNS
            )
        }
        stopCognitiveMotion(state: state, at: monotonicNS, retainLease: false)
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "embodiment_motor",
            state: "lease_released",
            message: "request_id=\(String((releasedRequestID ?? "none").prefix(96))); reason=\(String(state.prefix(96)))"
        ))
        scanScheduledForEvidenceGeneration = nil
        scheduleScanAfterContinuousVisualLoss()
    }

    private func sendCalibrationVelocity(
        pitch: Double,
        pan: Double,
        state: String,
        target: AttentionTarget?,
        at monotonicNS: UInt64,
        afterStop: @escaping @Sendable (UInt64) -> Void
    ) {
        sendExternalVelocity(
            pitch: pitch,
            pan: pan,
            state: state,
            target: target,
            at: monotonicNS,
            hardStopAfterNS: 180_000_000,
            hardStopState: state == "calibration_pan_pulse" ? "calibration_pan_stop" : "calibration_pitch_stop",
            helperPulseDurationMS: 180,
            afterStop: afterStop
        )
    }

    private func sendExternalVelocity(
        pitch: Double,
        pan: Double,
        state: String,
        target: AttentionTarget?,
        at monotonicNS: UInt64,
        hardStopAfterNS: UInt64,
        hardStopState: String = "external_hard_stop",
        helperPulseDurationMS: Int? = nil,
        afterStop: (@Sendable (UInt64) -> Void)? = nil
    ) {
        // A face command is never allowed to keep pushing while its own
        // previous commands have carried the optical axis into a posture that
        // cannot be justified by the current image. Release the latch, stop,
        // and request the helper's home position before considering another
        // candidate.
        if target?.isFaceMotorTarget == true,
           requestFaceServoRecenterIfBeyondEnvelope(at: monotonicNS) {
            return
        }
        cancelExternalStop()
        if pitch != 0 || pan != 0 {
            poseStore.noteMotion(
                at: monotonicNS,
                durationNS: max(hardStopAfterNS, 180_000_000) + 250_000_000
            )
        }
        let commandID = externalCommandID ?? nextCommandID(prefix: "external")
        externalCommandID = commandID
        if let helperPulseDurationMS {
            send(String(format: "external_pulse %@ %.4f %.4f %d", commandID, pitch, pan, helperPulseDurationMS))
        } else {
            send(String(format: "external_velocity %@ %.4f %.4f", commandID, pitch, pan))
        }
        writer.write(CameraIntentEvent(
            monotonicNS: monotonicNS,
            owner: .external,
            state: state,
            route: .externalVisualControl,
            commandID: commandID,
            targetKind: target?.kind,
            targetLabel: target?.label,
            targetProbability: target?.posteriorProbability ?? 0
        ))
        scheduleExternalStop(afterNS: hardStopAfterNS, state: hardStopState, afterStop: afterStop)
    }

    private func requestFaceServoRecenterIfBeyondEnvelope(at monotonicNS: UInt64) -> Bool {
        guard !explorationRecentering,
              let pose = poseStore.current(maximumAgeNS: 500_000_000),
              (abs(pose.pitchDegrees) >= 42 || abs(pose.panDegrees) >= 115) else {
            return false
        }
        faceLock.invalidate()
        lastMotorTarget = nil
        sendExternalStop(state: "face_servo_limit_recenter", at: monotonicNS)
        requestExplorationRecenter(at: monotonicNS, observedPanMotion: 0)
        return true
    }

    private func sendExternalPosition(
        pitch: Double,
        pan: Double,
        state: String,
        target: AttentionTarget?,
        at monotonicNS: UInt64,
        hardStopAfterNS: UInt64?
    ) {
        cancelExternalStop()
        poseStore.noteMotion(at: monotonicNS, durationNS: 750_000_000)
        let commandID = externalCommandID ?? nextCommandID(prefix: "external")
        externalCommandID = commandID
        send(String(format: "external_position %@ %.4f %.4f", commandID, pitch, pan))
        writer.write(CameraIntentEvent(
            monotonicNS: monotonicNS,
            owner: .external,
            state: state,
            route: .externalVisualControl,
            commandID: commandID,
            targetKind: target?.kind,
            targetLabel: target?.label,
            targetProbability: target?.posteriorProbability ?? 0
        ))
        if let hardStopAfterNS {
            scheduleExternalStop(afterNS: hardStopAfterNS, state: "external_hard_stop")
        }
    }

    private func sendExternalStop(state: String, at monotonicNS: UInt64) {
        poseStore.noteMotion(at: monotonicNS, durationNS: 250_000_000)
        let faceAgeMilliseconds: Double?
        if let lastObservedFaceNS, monotonicNS >= lastObservedFaceNS {
            faceAgeMilliseconds = Double(monotonicNS - lastObservedFaceNS) / 1_000_000
        } else {
            faceAgeMilliseconds = nil
        }
        let target = lastMotorTarget
        let pose = poseStore.current(maximumAgeNS: 500_000_000)
        faceLockDiagnosticRecorder?.recordStop(GimbalStopDiagnostic(
            monotonicNS: monotonicNS,
            reason: state,
            faceLockActive: faceLock.isActive(at: monotonicNS),
            faceLockMotorPermitted: faceLock.permitsMotor(at: monotonicNS),
            lastObservedFaceMilliseconds: faceAgeMilliseconds,
            targetID: target?.id,
            targetKind: target?.kind,
            targetLabel: target?.label,
            targetConfidence: target?.confidence,
            targetCenterX: target?.rect.centerX,
            targetCenterY: target?.rect.centerY,
            targetActionEligible: target?.isActionEligible,
            posePitchDegrees: pose?.pitchDegrees,
            posePanDegrees: pose?.panDegrees
        ))
        let commandID = nextCommandID(prefix: "external-stop")
        send("external_stop \(commandID)")
        externalCommandID = nil
        writer.write(CameraIntentEvent(
            monotonicNS: monotonicNS,
            owner: .external,
            state: state,
            route: .none,
            commandID: commandID,
            targetKind: nil,
            targetLabel: nil,
            targetProbability: 0
        ))
    }

    private func scheduleExternalStop(
        afterNS: UInt64,
        state: String,
        afterStop: (@Sendable (UInt64) -> Void)? = nil
    ) {
        externalStopGeneration += 1
        let generation = externalStopGeneration
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(afterNS))) { [weak self] in
            guard let self,
                  self.externalStopGeneration == generation,
                  case .running = self.state else { return }
            let stoppedNS = monotonicNanoseconds()
            self.sendExternalStop(state: state, at: stoppedNS)
            afterStop?(stoppedNS)
        }
    }

    private func cancelExternalStop() {
        externalStopGeneration += 1
    }

    private func startSmoothExploration(initialPan: Double, priority: ScanPriority = .l0) {
        // A remembered face has its own bounded return path. Starting a
        // coverage trajectory alongside it races two targets through the same
        // command slot and is perceived as looking away from the person.
        let now = monotonicNanoseconds()
        let exclusiveScan = cameraGeometryCalibrationMode || panoramaStripScanMode
        switch priority {
        case .l0:
            // Reflexive L0 scan is the lowest authority: it yields to a
            // recently observed face, an active L0 face lock, and an in-flight
            // L1 cognitive expression (bow/nod/greeting).
            guard (exclusiveScan || !hasRecentObservedFace(at: now)),
                  (exclusiveScan || activeSpatialFaceReacquisition == nil),
                  (exclusiveScan || !faceLock.permitsMotor(at: now)),
                  (exclusiveScan || !cognitiveMotionLoopRunning),
                  !scanRunning,
                  !explorationRecentering else { return }
        case .l1:
            // L1 (conscious stream) outranks L0: it may tear away the reflexive
            // face lock to scan, but yields to an active L2 scan.
            guard !(scanRunning && scanPriority == .l2),
                  !explorationRecentering else { return }
            faceLock.invalidate()
        case .l2:
            // L2 (conversation) is the highest authority: it may tear away the
            // L0 face lock and preempt an in-flight L1 cognitive expression.
            guard !explorationRecentering else { return }
            faceLock.invalidate()
            stopCognitiveMotion(state: "l2_preempted", at: now, retainLease: false)
        }
        scanPriority = priority
        scanRunning = true
        scanGeneration += 1
        explorationWaypoint = nil
        explorationWaypointStartedNS = nil
        explorationWaypointDeadlineNS = nil
        explorationWaypointStartingPose = nil
        explorationWaypointIndex = 0
        cameraGeometryCommandedRouteIndex = nil
        cameraGeometryWaypointStableSinceNS = nil
        panoramaWaypointStableSinceNS = nil
        cameraGeometryNextPositionCommandNS = 0
        explorationBoundaryTurning = false
        smoothExploration.reset()
        scheduleScanControlTick(initialPan: initialPan, generation: scanGeneration)
    }

    /// L1/L2 behavior directive entry point: resume the coverage scan. The
    /// `priority` argument encodes the motor authority of the issuing layer
    /// (L1 conscious stream or L2 conversation), so a higher layer may tear
    /// away the reflexive L0 face lock.
    func resumeCoverageScan(priority: ScanPriority = .l0) {
        startSmoothExploration(initialPan: 0, priority: priority)
    }

    private func cancelScan() {
        scanGeneration += 1
        scanRunning = false
        explorationWaypoint = nil
        explorationWaypointStartedNS = nil
        explorationWaypointDeadlineNS = nil
        explorationWaypointStartingPose = nil
        cameraGeometryCommandedRouteIndex = nil
        cameraGeometryWaypointStableSinceNS = nil
        panoramaWaypointStableSinceNS = nil
        cameraGeometryNextPositionCommandNS = 0
        explorationBoundaryTurning = false
        smoothExploration.reset()
    }

    private func hasRecentObservedFace(at monotonicNS: UInt64) -> Bool {
        guard let lastObservedFaceNS else { return false }
        guard monotonicNS >= lastObservedFaceNS else { return true }
        return monotonicNS - lastObservedFaceNS <= 600_000_000
    }

    private func scheduleScanControlTick(
        initialPan: Double,
        generation: Int,
        afterMilliseconds: Int = 0
    ) {
        queue.asyncAfter(deadline: .now() + .milliseconds(afterMilliseconds)) { [weak self] in
            self?.runScanControlTick(initialPan: initialPan, generation: generation)
        }
    }

    private func runScanControlTick(initialPan: Double, generation: Int) {
        guard scanRunning, generation == scanGeneration else { return }
        let now = monotonicNanoseconds()
        // A reflexive L0 scan yields to a recently observed face, an active L0
        // face lock, and a spatial reacquisition. A higher-authority L1/L2 scan
        // keeps scanning: it already tore the face lock away on initiation.
        let l0Yields = !hasRecentObservedFace(at: now)
            && activeSpatialFaceReacquisition == nil
            && !faceLock.permitsMotor(at: now)
        guard cameraGeometryCalibrationMode || panoramaStripScanMode
            || (scanPriority == .l0 ? l0Yields : true) else {
            cancelScan()
            return
        }
        let desired: (pitch: Double, pan: Double, state: String)
        if let calibration = externalCalibration {
            guard let pose = poseStore.latest(at: now, maximumAgeNS: 250_000_000) else {
                // A transient attitude gap must not silently switch a
                // calibrated spherical route into the blind fallback scan or
                // reset its waypoint clock. Decelerate on the existing curve
                // and resume the same route when a fresh pose arrives.
                let velocity = smoothExploration.advance(
                    towardPitch: 0,
                    pan: 0,
                    at: now
                )
                sendSmoothExplorationVelocity(
                    velocity,
                    state: "coverage_pose_wait_curve",
                    at: now
                )
                scheduleScanControlTick(
                    initialPan: initialPan,
                    generation: generation,
                    afterMilliseconds: 50
                )
                return
            }
            if cameraGeometryCalibrationMode {
                runCameraGeometryCalibrationTick(
                    pose: pose,
                    at: now,
                    generation: generation
                )
                return
            }
            // Turn inward early enough to brake before the joint limit. This
            // remains a velocity curve; absolute re-centering is reserved for
            // a measured two-direction stall instead of normal exploration.
            beginBoundaryTurnIfNeeded(at: now, pose: pose)
            finishExplorationWaypointIfNeeded(at: now, pose: pose)
            guard scanRunning, generation == scanGeneration, !explorationRecentering else { return }
            if explorationWaypoint == nil {
                var plannedDirection: (cell: SpatialCoverageDirection, guide: GimbalRelativeBearing, uniform: Double)?
                if panoramaStripScanMode {
                    let bearing = Self.panoramaStripScanBearings[
                        panoramaStripRouteIndex % Self.panoramaStripScanBearings.count
                    ]
                    plannedDirection = (
                        SpatialCoverageDirection(
                            bearing: bearing,
                            probability: 1,
                            panoramaQuality: 0,
                            placeFamiliarity: 0,
                            expectedInformationGain: 1
                        ),
                        bearing,
                        0
                    )
                    panoramaStripRouteIndex += 1
                } else {
                    for _ in 0..<8 {
                        let coverageUniform = nextExplorationUniform()
                        guard let sampledDirection = spatialAtlas.sampleNextDirection(
                            from: pose,
                            at: now,
                            temperature: explorationTemperature,
                            uniform: coverageUniform
                        ) else { break }
                        if let motionGuide = GimbalVisibilityRoutePlanner.guide(
                            to: sampledDirection.bearing,
                            from: pose,
                            observationPreference: .centered
                        ) {
                            plannedDirection = (sampledDirection, motionGuide, coverageUniform)
                            break
                        }
                        spatialAtlas.recordUnproductiveVisit(to: sampledDirection, at: now)
                        writer.write(RuntimeEvent(
                            event: "source.health",
                            monotonicNS: now,
                            source: "attention_gimbal_bridge",
                            state: "coverage_direction_unreachable",
                            message: String(
                                format: "cell_azimuth_degrees=%.2f; cell_elevation_degrees=%.2f",
                                sampledDirection.bearing.azimuthDegrees,
                                sampledDirection.bearing.elevationDegrees
                            )
                        ))
                    }
                }
                guard let plannedDirection else {
                    explorationWaypointDeadlineNS = nil
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: now,
                        source: "attention_gimbal_bridge",
                        state: "coverage_no_exploration_sampled",
                        message: String(format: "temperature=%.2f", explorationTemperature)
                    ))
                    let velocity = smoothExploration.advance(towardPitch: 0, pan: 0, at: now)
                    sendSmoothExplorationVelocity(
                        velocity,
                        state: "coverage_exploration_decelerating",
                        at: now
                    )
                    scheduleScanControlTick(initialPan: initialPan, generation: generation, afterMilliseconds: 150)
                    return
                }
                explorationWaypoint = SpatialCoverageDirection(
                    bearing: plannedDirection.guide,
                    probability: plannedDirection.cell.probability,
                    panoramaQuality: plannedDirection.cell.panoramaQuality,
                    placeFamiliarity: plannedDirection.cell.placeFamiliarity,
                    expectedInformationGain: plannedDirection.cell.expectedInformationGain
                )
                explorationWaypointStartedNS = now
                explorationWaypointDeadlineNS = now + UInt64(
                    SmoothExplorationDynamics.waypointTimeoutSeconds(
                        panErrorDegrees: plannedDirection.guide.azimuthDegrees - pose.panDegrees,
                        pitchErrorDegrees: plannedDirection.guide.elevationDegrees - pose.pitchDegrees,
                        maximumPanDegreesPerSecond: min(
                            maximumActiveExplorationPanDegreesPerSecond,
                            calibration.maximumPanDegreesPerSecond
                        ),
                        maximumPitchDegreesPerSecond: min(
                            maximumActiveExplorationPitchDegreesPerSecond,
                            calibration.maximumPitchDegreesPerSecond
                        )
                    ) * 1_000_000_000
                )
                explorationWaypointStartingPose = pose
                panoramaWaypointStableSinceNS = nil
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "attention_gimbal_bridge",
                    state: "coverage_direction_sampled",
                    message: String(
                        format: "temperature=%.2f; uniform=%.6f; probability=%.3f; panorama_quality=%.3f; place_familiarity=%.3f; expected_information_gain=%.3f; cell_azimuth_degrees=%.2f; cell_elevation_degrees=%.2f; guide_azimuth_degrees=%.2f; guide_elevation_degrees=%.2f",
                        explorationTemperature,
                        plannedDirection.uniform,
                        plannedDirection.cell.probability,
                        plannedDirection.cell.panoramaQuality,
                        plannedDirection.cell.placeFamiliarity,
                        plannedDirection.cell.expectedInformationGain,
                        plannedDirection.cell.bearing.azimuthDegrees,
                        plannedDirection.cell.bearing.elevationDegrees,
                        plannedDirection.guide.azimuthDegrees,
                        plannedDirection.guide.elevationDegrees
                    )
                ))
                // Penalize the selected spatial cell, not its inset motor
                // guide. Fresh camera frames record the FOV actually covered.
                spatialAtlas.recordUnproductiveVisit(to: plannedDirection.cell, at: now)
            }
            guard let direction = explorationWaypoint else { return }
            // Coverage cells are spherical directions, not yaw-only labels.
            // The acceleration limiter blends either a sampled waypoint or a
            // boundary-return guide into the current velocity.
            let pitchError = SmoothExplorationDynamics.stoppingVelocity(
                    errorDegrees: direction.bearing.elevationDegrees - pose.pitchDegrees,
                    maximumDegreesPerSecond: min(
                        maximumActiveExplorationPitchDegreesPerSecond,
                        calibration.maximumPitchDegreesPerSecond
                    ),
                    accelerationDegreesPerSecondSquared: 80
                )
            let panError = SmoothExplorationDynamics.stoppingVelocity(
                    // The spherical map wraps at 180 degrees, but the
                    // physical Tiny pan joint does not. Take the reachable
                    // path through home instead of driving into the nearer
                    // mathematical wrap boundary.
                    errorDegrees: direction.bearing.azimuthDegrees - pose.panDegrees,
                    maximumDegreesPerSecond: min(
                        maximumActiveExplorationPanDegreesPerSecond,
                        calibration.maximumPanDegreesPerSecond
                    ),
                    accelerationDegreesPerSecondSquared: 120
                )
            desired = (
                calibration.pitchCommand(
                    forPoseError: pitchError,
                    projection: .obsbotTiny2Lite
                ),
                calibration.panCommand(
                    forPoseError: panError,
                    projection: .obsbotTiny2Lite
                ) * explorationPanPolarity,
                explorationBoundaryTurning
                    ? "coverage_boundary_turn_curve"
                    : "coverage_exploration_curve_\(explorationWaypointIndex + 1)"
            )
        } else {
            if explorationWaypointStartedNS == nil {
                explorationWaypointStartedNS = now
            } else if let startedNS = explorationWaypointStartedNS,
                      now >= startedNS + 1_500_000_000 {
                nextScanDirection *= -1
                explorationWaypointStartedNS = now
                explorationWaypointIndex = (explorationWaypointIndex + 1) % 6
            }
            desired = (
                0,
                min(abs(initialPan), 60) * nextScanDirection * explorationPanPolarity,
                "autonomous_scan_curve_\(explorationWaypointIndex + 1)"
            )
        }
        let velocity = smoothExploration.advance(
            towardPitch: desired.pitch,
            pan: desired.pan,
            at: now
        )
        sendSmoothExplorationVelocity(velocity, state: desired.state, at: now)
        scheduleScanControlTick(initialPan: initialPan, generation: generation, afterMilliseconds: 50)
    }

    private static let cameraGeometryCalibrationBearings: [GimbalRelativeBearing] = [
        .init(azimuthDegrees: -60, elevationDegrees: -15),
        .init(azimuthDegrees: -40, elevationDegrees: -15),
        .init(azimuthDegrees: -20, elevationDegrees: -15),
        .init(azimuthDegrees: 0, elevationDegrees: -15),
        .init(azimuthDegrees: 20, elevationDegrees: -15),
        .init(azimuthDegrees: 40, elevationDegrees: -15),
        .init(azimuthDegrees: 60, elevationDegrees: -15),
        .init(azimuthDegrees: 60, elevationDegrees: 0),
        .init(azimuthDegrees: 40, elevationDegrees: 0),
        .init(azimuthDegrees: 20, elevationDegrees: 0),
        .init(azimuthDegrees: 0, elevationDegrees: 0),
        .init(azimuthDegrees: -20, elevationDegrees: 0),
        .init(azimuthDegrees: -40, elevationDegrees: 0),
        .init(azimuthDegrees: -60, elevationDegrees: 0),
        .init(azimuthDegrees: -60, elevationDegrees: 15),
        .init(azimuthDegrees: -40, elevationDegrees: 15),
        .init(azimuthDegrees: -20, elevationDegrees: 15),
        .init(azimuthDegrees: 0, elevationDegrees: 15),
        .init(azimuthDegrees: 20, elevationDegrees: 15),
        .init(azimuthDegrees: 40, elevationDegrees: 15),
        .init(azimuthDegrees: 60, elevationDegrees: 15),
    ]

    private static let panoramaStripScanBearings: [GimbalRelativeBearing] = [
        .init(azimuthDegrees: -110, elevationDegrees: -24),
        .init(azimuthDegrees: 110, elevationDegrees: -24),
        .init(azimuthDegrees: 110, elevationDegrees: -8),
        .init(azimuthDegrees: -110, elevationDegrees: -8),
        .init(azimuthDegrees: -110, elevationDegrees: 8),
        .init(azimuthDegrees: 110, elevationDegrees: 8),
        .init(azimuthDegrees: 110, elevationDegrees: 24),
        .init(azimuthDegrees: -110, elevationDegrees: 24),
    ]

    private static let maximumExplorationPanDegreesPerSecond = 30.0
    private static let maximumExplorationPitchDegreesPerSecond = 18.0
    private static let maximumPanoramaStripPanDegreesPerSecond = 12.0
    private static let maximumPanoramaStripPitchDegreesPerSecond = 8.0

    private var maximumActiveExplorationPanDegreesPerSecond: Double {
        panoramaStripScanMode
            ? Self.maximumPanoramaStripPanDegreesPerSecond
            : Self.maximumExplorationPanDegreesPerSecond
    }

    private var maximumActiveExplorationPitchDegreesPerSecond: Double {
        panoramaStripScanMode
            ? Self.maximumPanoramaStripPitchDegreesPerSecond
            : Self.maximumExplorationPitchDegreesPerSecond
    }

    private func runCameraGeometryCalibrationTick(
        pose: GimbalPose,
        at monotonicNS: UInt64,
        generation: Int
    ) {
        let route = Self.cameraGeometryCalibrationBearings
        let routeIndex = cameraGeometryRouteIndex % route.count
        let target = route[routeIndex]
        let panError = abs(target.azimuthDegrees - pose.panDegrees)
        let pitchError = abs(target.elevationDegrees - pose.pitchDegrees)
        let reached = panError <= 0.60 && pitchError <= 0.60

        if cameraGeometryCommandedRouteIndex != routeIndex
            || monotonicNS >= cameraGeometryNextPositionCommandNS {
            sendExternalPosition(
                pitch: target.elevationDegrees,
                pan: target.azimuthDegrees,
                state: "camera_geometry_absolute_waypoint_\(routeIndex + 1)",
                target: nil,
                at: monotonicNS,
                hardStopAfterNS: nil
            )
            cameraGeometryCommandedRouteIndex = routeIndex
            cameraGeometryNextPositionCommandNS = monotonicNS + 400_000_000
        }

        if reached {
            if let stableSince = cameraGeometryWaypointStableSinceNS,
               monotonicNS >= stableSince + 900_000_000 {
                cameraGeometryRouteIndex = (routeIndex + 1) % route.count
                cameraGeometryCommandedRouteIndex = nil
                cameraGeometryWaypointStableSinceNS = nil
                cameraGeometryNextPositionCommandNS = 0
            } else if cameraGeometryWaypointStableSinceNS == nil {
                cameraGeometryWaypointStableSinceNS = monotonicNS
            }
        } else {
            cameraGeometryWaypointStableSinceNS = nil
        }

        scheduleScanControlTick(
            initialPan: 0,
            generation: generation,
            afterMilliseconds: 50
        )
    }

    private func beginBoundaryTurnIfNeeded(at monotonicNS: UInt64, pose: GimbalPose) {
        let envelope = GimbalKinematicEnvelope.obsbotTiny2Lite
        let measuredCenter = GimbalRelativeBearing(
            azimuthDegrees: pose.panDegrees,
            elevationDegrees: pose.pitchDegrees
        )
        guard !explorationBoundaryTurning,
              !envelope.containsTrackingCenter(measuredCenter) else { return }
        // Autonomous waypoints may legitimately sit on their own boundary.
        // Recovery begins only outside the wider tracking envelope, otherwise
        // normal servo overshoot would replace a valid strip with an inward
        // recovery target and fragment the resulting spatial coverage.
        let recoveryPan = max(0, envelope.maximumAutonomousPanDegrees - 20)
        let recoveryPitch = max(0, envelope.maximumAutonomousPitchDegrees - 9)
        let targetPan = abs(pose.panDegrees) > envelope.maximumAutonomousPanDegrees
            ? (pose.panDegrees < 0 ? -recoveryPan : recoveryPan)
            : min(max(pose.panDegrees, -recoveryPan), recoveryPan)
        let targetPitch = abs(pose.pitchDegrees) > envelope.maximumAutonomousPitchDegrees
            ? (pose.pitchDegrees < 0 ? -recoveryPitch : recoveryPitch)
            : min(max(pose.pitchDegrees, -recoveryPitch), recoveryPitch)
        explorationBoundaryTurning = true
        explorationWaypoint = SpatialCoverageDirection(
            bearing: GimbalRelativeBearing(
                azimuthDegrees: targetPan,
                elevationDegrees: targetPitch
            ),
            probability: 1
        )
        explorationWaypointStartedNS = monotonicNS
        explorationWaypointDeadlineNS = monotonicNS + UInt64(
            SmoothExplorationDynamics.waypointTimeoutSeconds(
                panErrorDegrees: targetPan - pose.panDegrees,
                pitchErrorDegrees: targetPitch - pose.pitchDegrees,
                maximumPanDegreesPerSecond: min(
                    maximumActiveExplorationPanDegreesPerSecond,
                    externalCalibration?.maximumPanDegreesPerSecond
                        ?? maximumActiveExplorationPanDegreesPerSecond
                ),
                maximumPitchDegreesPerSecond: min(
                    maximumActiveExplorationPitchDegreesPerSecond,
                    externalCalibration?.maximumPitchDegreesPerSecond
                        ?? maximumActiveExplorationPitchDegreesPerSecond
                )
            ) * 1_000_000_000
        )
        explorationWaypointStartingPose = pose
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "attention_gimbal_bridge",
            state: "coverage_out_of_envelope_recovery_started",
            message: String(
                format: "pose_pan_degrees=%.2f; pose_pitch_degrees=%.2f; target_pan_degrees=%.2f; target_pitch_degrees=%.2f",
                pose.panDegrees,
                pose.pitchDegrees,
                targetPan,
                targetPitch
            )
        ))
    }

    private func finishExplorationWaypointIfNeeded(at monotonicNS: UInt64, pose: GimbalPose) {
        guard let direction = explorationWaypoint,
              let startedNS = explorationWaypointStartedNS else { return }
        let panError = abs(direction.bearing.azimuthDegrees - pose.panDegrees)
        let pitchError = abs(direction.bearing.elevationDegrees - pose.pitchDegrees)
        // High-information views approach the optical centre; familiar,
        // already-clear views blend earlier into the next reachable route.
        // This keeps epistemic exploration continuous without stopping at a
        // waypoint merely because it was selected by the atlas posterior.
        let lookAheadRadiusDegrees = 2 + 8 * (1 - direction.expectedInformationGain)
        let reached = SmoothExplorationDynamics.shouldBlendToNextWaypoint(
            panErrorDegrees: panError,
            pitchErrorDegrees: pitchError,
            lookAheadRadiusDegrees: lookAheadRadiusDegrees
        )
        let timedOut = explorationWaypointDeadlineNS.map { monotonicNS >= $0 }
            ?? (monotonicNS >= startedNS + 3_500_000_000)
        if panoramaStripScanMode, !explorationBoundaryTurning, reached, !timedOut {
            if let stableSince = panoramaWaypointStableSinceNS {
                guard monotonicNS >= stableSince + 450_000_000 else { return }
            } else {
                panoramaWaypointStableSinceNS = monotonicNS
                return
            }
        } else if !reached {
            panoramaWaypointStableSinceNS = nil
        }
        guard reached || timedOut else { return }
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "attention_gimbal_bridge",
            state: "coverage_waypoint_completed",
            message: String(
                format: "result=%@; target_pan_degrees=%.2f; target_pitch_degrees=%.2f; pose_pan_degrees=%.2f; pose_pitch_degrees=%.2f; elapsed_ms=%.1f",
                reached ? "reached" : "timed_out",
                direction.bearing.azimuthDegrees,
                direction.bearing.elevationDegrees,
                pose.panDegrees,
                pose.pitchDegrees,
                Double(monotonicNS - startedNS) / 1_000_000
            )
        ))
        if reached {
            explorationFailureCount = max(0, explorationFailureCount - 1)
        } else {
            explorationFailureCount += 1
            if let startingPose = explorationWaypointStartingPose,
               adaptExplorationPanPolarity(
                    from: startingPose,
                    requestedPan: direction.bearing.azimuthDegrees - startingPose.panDegrees
               ) {
                return
            }
        }
        explorationWaypoint = nil
        explorationWaypointStartedNS = nil
        explorationWaypointDeadlineNS = nil
        explorationWaypointStartingPose = nil
        panoramaWaypointStableSinceNS = nil
        explorationBoundaryTurning = false
        explorationWaypointIndex = (explorationWaypointIndex + 1) % 6
    }

    private func sendSmoothExplorationVelocity(
        _ velocity: SmoothExplorationVelocity,
        state: String,
        at monotonicNS: UInt64
    ) {
        sendExternalVelocity(
            pitch: velocity.pitchDegreesPerSecond,
            pan: velocity.panDegreesPerSecond,
            state: state,
            target: nil,
            at: monotonicNS,
            hardStopAfterNS: 650_000_000
        )
    }

    private func adaptExplorationPanPolarity(from startingPose: GimbalPose, requestedPan: Double) -> Bool {
        guard abs(requestedPan) >= 12,
              let endingPose = poseStore.latest(
                at: monotonicNanoseconds(),
                maximumAgeNS: 500_000_000
              ) else {
            return false
        }
        let panMotion = abs(angularDifference(endingPose.panDegrees, startingPose.panDegrees))
        switch panStallRecovery.record(
            requestedPanDegreesPerSecond: requestedPan,
            observedMotionDegrees: panMotion
        ) {
        case .none:
            return false
        case .reverse:
            explorationPanPolarity *= -1
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "attention_gimbal_bridge",
                state: "coverage_pan_reversed",
                message: String(format: "requested_pan_degrees_per_second=%.2f; observed_pan_motion_degrees=%.2f", requestedPan, panMotion)
            ))
            return false
        case .recenter:
            requestExplorationRecenter(at: monotonicNanoseconds(), observedPanMotion: panMotion)
            return true
        }
    }

    private func requestExplorationRecenter(at monotonicNS: UInt64, observedPanMotion: Double) {
        guard !explorationRecentering else { return }
        explorationRecentering = true
        cancelExternalStop()
        cancelScan()
        scanScheduledForEvidenceGeneration = nil
        let commandID = nextCommandID(prefix: "coverage-recenter")
        send("recenter \(commandID)")
        writer.write(CameraIntentEvent(
            monotonicNS: monotonicNS,
            owner: .manual,
            state: "coverage_recenter_requested",
            route: .none,
            commandID: commandID,
            targetKind: nil,
            targetLabel: nil,
            targetProbability: 0
        ))
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "attention_gimbal_bridge",
            state: "coverage_pan_stall_recenter",
            message: String(format: "observed_pan_motion_degrees=%.2f", observedPanMotion)
        ))
        awaitExplorationRecenter(untilNS: monotonicNS + 5_000_000_000)
    }

    private func awaitExplorationRecenter(untilNS: UInt64) {
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self, self.explorationRecentering, case .running = self.state else { return }
            let now = monotonicNanoseconds()
            if let pose = self.poseStore.latest(at: now, maximumAgeNS: 500_000_000),
               abs(pose.pitchDegrees) <= 4,
               abs(pose.panDegrees) <= 4 {
                self.explorationRecentering = false
                self.explorationPanPolarity = 1
                self.writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "attention_gimbal_bridge",
                    state: "coverage_recentered",
                    message: "sdk_attitude_near_home"
                ))
                self.scheduleScanAfterContinuousVisualLoss()
                return
            }
            guard now < untilNS else {
                self.send("manual_stop \(self.nextCommandID(prefix: "coverage-recenter-timeout"))")
                // A failed home confirmation must not permanently suppress the
                // L0 search loop. Stop the incomplete position command, then
                // re-arm normal no-target exploration from the measured pose.
                self.explorationRecentering = false
                self.explorationPanPolarity = 1
                self.scanScheduledForEvidenceGeneration = nil
                self.writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "attention_gimbal_bridge",
                    state: "coverage_recenter_timeout",
                    message: "manual_stop_requested; exploration_rearmed"
                ))
                self.queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                    self?.scheduleScanAfterContinuousVisualLoss()
                }
                return
            }
            self.awaitExplorationRecenter(untilNS: untilNS)
        }
    }

    private var explorationTemperature: Double {
        // Keep stochasticity without flattening the novelty posterior so far
        // that repeatedly visited cells become almost as likely as unseen ones.
        min(1.35, 1 + 0.04 * Double(explorationFailureCount))
    }

    private func nextExplorationUniform() -> Double {
        explorationRandomState = explorationRandomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(explorationRandomState >> 11) / 9_007_199_254_740_992
    }

    private func failCalibration(_ message: String, at monotonicNS: UInt64) {
        calibrationStage = .failed
        calibrationMode = false
        visualEvidenceGeneration += 1
        scanScheduledForEvidenceGeneration = nil
        cancelScan()
        cancelExternalStop()
        idleExplorationGate = nil
        externalGate = nil
        sendExternalStop(state: "calibration_failed", at: monotonicNS)
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "external_gimbal_calibration",
            state: "failed",
            message: message
        ))
    }

    private func nextCommandID(prefix: String) -> String {
        commandSequence += 1
        return "\(prefix)-\(commandSequence)"
    }

    private func startIndicatorReassertionLoop() {
        indicatorReassertionGeneration += 1
        scheduleIndicatorReassertion(generation: indicatorReassertionGeneration)
    }

    private func scheduleIndicatorReassertion(generation: Int) {
        queue.asyncAfter(
            deadline: .now() + .milliseconds(indicatorReassertionIntervalMilliseconds)
        ) { [weak self] in
            guard let self,
                  generation == self.indicatorReassertionGeneration,
                  case .running = self.state,
                  self.helperReady else { return }
            self.reconcileIndicatorPalette(at: monotonicNanoseconds())
            self.scheduleIndicatorReassertion(generation: generation)
        }
    }

    private func refreshIndicator(
        at monotonicNS: UInt64,
        forceHardwareReassertion: Bool = false
    ) {
        guard indicatorCalibrationPreset == nil else { return }
        let next = indicatorInputs.resolvedState
        guard ledSettings.responseMode.permits(next) else {
            guard helperReady, process.isRunning, next != activeIndicatorState || indicatorIlluminated else { return }
            if activeIndicatorRendering?.specialPatternEnabled == true {
                let commandID = nextCommandID(prefix: "indicator-special")
                send("indicator_special_pattern \(commandID) 0")
            }
            if indicatorIlluminated, let previous = activeIndicatorState {
                let commandID = nextCommandID(prefix: "indicator-policy-clear")
                send("indicator_clear \(commandID) \(indicatorFirmwareStateID(previous))")
            }
            activeIndicatorState = next
            activeIndicatorRendering = nil
            indicatorIlluminated = false
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "social_indicator",
                state: "suppressed",
                message: "policy=\(ledSettings.responseMode.rawValue); requested_state=\(next.rawValue); brightness=\(ledSettings.brightness)"
            ))
            return
        }
        guard helperReady,
              process.isRunning,
              forceHardwareReassertion || next != activeIndicatorState || activeIndicatorRendering != indicatorRendering(next) else { return }
        activeIndicatorState = next
        let nextSignal = ledSettings.signal(for: next)
        let nextRendering = nextSignal.deviceRendering
        let commandID = nextCommandID(prefix: "indicator-enforce")
        send(
            "indicator_enforce \(commandID) \(nextRendering.stateID) \(nextRendering.specialPatternEnabled ? 1 : 0)"
        )
        activeIndicatorRendering = nextRendering
        indicatorIlluminated = true
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "social_indicator",
            state: next.rawValue,
            message: "human_meaning=\(next.humanMeaning); visual=\(indicatorInputs.visualState.rawValue); interaction=\(indicatorInputs.interactionState.rawValue); firmware_state_id=\(nextRendering.stateID); special_pattern=\(nextRendering.specialPatternEnabled); color=\(nextSignal.color.rawValue); pattern=\(nextSignal.pattern.rawValue); brightness=\(ledSettings.brightness); policy=\(ledSettings.responseMode.rawValue); enforced=true; rgb_palette=true; arbitrary_rgb=false"
        ))
    }

    private func reconcileIndicatorPalette(at monotonicNS: UInt64) {
        guard indicatorCalibrationPreset == nil else { return }
        let next = indicatorInputs.resolvedState
        guard ledSettings.responseMode.permits(next),
              helperReady,
              process.isRunning,
              indicatorIlluminated,
              next == activeIndicatorState,
              let activeIndicatorRendering,
              activeIndicatorRendering == indicatorRendering(next),
              // Do not run the blind periodic re-assertion while the LED is in
              // a firmware blink (special pattern): re-setting the state id /
              // clearing the palette every second resets the blink phase and
              // produces "one blink, long off-gap" instead of continuous
              // blinking. During a blink the rendering is left undisturbed and
              // colour recovery happens on the next state transition (enforce).
              activeIndicatorRendering.specialPatternEnabled == false else {
            refreshIndicator(at: monotonicNS)
            return
        }
        let commandID = nextCommandID(prefix: "indicator-reconcile")
        send(
            "indicator_reconcile \(commandID) \(activeIndicatorRendering.stateID) \(activeIndicatorRendering.specialPatternEnabled ? 1 : 0)"
        )
    }

    private func indicatorRendering(_ state: SubconsciousIndicatorState) -> SOMALEDDeviceRendering {
        ledSettings.signal(for: state).deviceRendering
    }

    private func indicatorFirmwareStateID(_ state: SubconsciousIndicatorState) -> Int {
        ledSettings.signal(for: state).firmwareStateID
    }

    func calibrateIndicator(
        preset: SOMALEDFirmwarePreset?
    ) -> Result<Void, Error> {
        queue.sync {
            guard case .running = state, helperReady, process.isRunning else {
                return .failure(RuntimeError.unavailable("The local LED bridge is not ready"))
            }
            let commandID = nextCommandID(prefix: "indicator-calibration")
            let nextStateID = preset?.firmwareStateID

            send("indicator_special_pattern \(commandID)-special 0")
            if indicatorIlluminated,
               let activeIndicatorState,
               indicatorFirmwareStateID(activeIndicatorState) != nextStateID {
                send("indicator_clear \(commandID)-normal \(indicatorFirmwareStateID(activeIndicatorState))")
            }
            if let indicatorCalibrationStateID,
               indicatorCalibrationStateID != nextStateID {
                send("indicator_clear \(commandID)-previous \(indicatorCalibrationStateID)")
            }

            indicatorCalibrationPreset = preset
            indicatorCalibrationStateID = nextStateID
            activeIndicatorState = nil
            activeIndicatorRendering = nil
            indicatorIlluminated = nextStateID != nil

            if let preset, let nextStateID {
                send("indicator_set \(commandID) \(nextStateID)")
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "social_indicator",
                    state: "calibration_active",
                    message: "preset=\(preset.rawValue); firmware_state_id=\(nextStateID); local_owner_only=true"
                ))
            } else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "social_indicator",
                    state: "calibration_ended",
                    message: "normal_state_signalling_resumed"
                ))
                refreshIndicator(at: monotonicNanoseconds())
            }
            return .success(())
        }
    }

    private func send(_ command: String) {
        guard let data = (command + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }
}

private final class AudioVADFrame: @unchecked Sendable {
    let samples: [Float]
    let sampleRateHz: Double
    var continuous: Bool
    let captureNS: UInt64
    let levelDB: Double

    init(samples: [Float], sampleRateHz: Double, continuous: Bool, captureNS: UInt64, levelDB: Double) {
        self.samples = samples
        self.sampleRateHz = sampleRateHz
        self.continuous = continuous
        self.captureNS = captureNS
        self.levelDB = levelDB
    }
}

private final class LatestAudioVADMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: AudioVADFrame?
    private var signalPending = false
    private var accepting = true

    func publish(_ frame: AudioVADFrame) -> (shouldWake: Bool, superseded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return (false, false) }
        let superseded = latest != nil
        if superseded { frame.continuous = false }
        latest = frame
        if signalPending { return (false, superseded) }
        signalPending = true
        return (true, superseded)
    }

    func take() -> AudioVADFrame? {
        lock.lock()
        defer { lock.unlock() }
        signalPending = false
        defer { latest = nil }
        return latest
    }

    func stopAccepting() {
        lock.lock()
        accepting = false
        latest = nil
        lock.unlock()
    }
}

private final class AudioVADWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soma.subconscious.audio-vad", qos: .userInitiated)
    private let mailbox = LatestAudioVADMailbox()
    private let detector: NeuralVoiceActivityDetector
    private let stateLock = NSLock()
    private let onEvidence: (NeuralVoiceActivityEvidence, AudioVADFrame, UInt64) -> Void
    private let onError: (String) -> Void
    private var active = false
    private var errorReported = false

    let computeUnits: String
    let warmupMS: Double

    init(
        onEvidence: @escaping (NeuralVoiceActivityEvidence, AudioVADFrame, UInt64) -> Void,
        onError: @escaping (String) -> Void
    ) throws {
        detector = try NeuralVoiceActivityDetector()
        computeUnits = detector.computeUnits
        warmupMS = detector.warmupMS
        self.onEvidence = onEvidence
        self.onError = onError
    }

    func submit(_ frame: AudioVADFrame) -> Bool {
        let result = mailbox.publish(frame)
        guard !result.superseded else { return true }
        guard result.shouldWake else { return false }
        queue.async { [weak self] in self?.processAvailable() }
        return false
    }

    func currentActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return active
    }

    func stop() {
        mailbox.stopAccepting()
        queue.sync {}
    }

    private func processAvailable() {
        while let frame = mailbox.take() {
            do {
                let evidence = try detector.ingest(
                    samples: frame.samples,
                    sampleRateHz: frame.sampleRateHz,
                    continuous: frame.continuous,
                    at: frame.captureNS
                )
                for result in evidence {
                    stateLock.lock()
                    active = result.active
                    stateLock.unlock()
                    onEvidence(result, frame, monotonicNanoseconds())
                }
            } catch {
                detector.reset()
                stateLock.lock()
                active = false
                let shouldReport = !errorReported
                errorReported = true
                stateLock.unlock()
                if shouldReport { onError(error.localizedDescription) }
            }
        }
    }
}

private final class AudioAnalyzer: @unchecked Sendable {
    private var previousAudioEndPTS: CMTime?
    private var nextDirectionAnalysisNS: UInt64 = 0
    private var lastDirection: AudioDirection = .unknown
    private let worldModel: PredictiveWorldModel
    private let publisher: BeliefPublisher
    private let writer: JSONLWriter
    private let counters: LatencyCounters
    private let directionEstimator: StereoTDOAEstimator?
    private let calibrationRecorder: TDOACalibrationRecorder?
    private let voiceWorker: AudioVADWorker
    private let speechInteraction: LocalSpeechInteractionCoordinator?
    private let liveVoiceLauncher: AppServerLiveVoiceLauncher?

    init(
        worldModel: PredictiveWorldModel,
        publisher: BeliefPublisher,
        writer: JSONLWriter,
        counters: LatencyCounters,
        voiceWorker: AudioVADWorker,
        directionEstimator: StereoTDOAEstimator?,
        calibrationRecorder: TDOACalibrationRecorder?,
        speechInteraction: LocalSpeechInteractionCoordinator?,
        liveVoiceLauncher: AppServerLiveVoiceLauncher?
    ) {
        self.worldModel = worldModel
        self.publisher = publisher
        self.writer = writer
        self.counters = counters
        self.voiceWorker = voiceWorker
        self.directionEstimator = directionEstimator
        self.calibrationRecorder = calibrationRecorder
        self.speechInteraction = speechInteraction
        self.liveVoiceLauncher = liveVoiceLauncher
    }

    func ingest(_ sampleBuffer: CMSampleBuffer, at now: UInt64) {
        defer {
            counters.audioCallback(
                at: now,
                processingMS: milliseconds(from: now, to: monotonicNanoseconds())
            )
        }
        guard let audio = monoAudio(from: sampleBuffer) else { return }
        let continuous = audioPacketIsContinuous(sampleBuffer, durationNS: audio.durationNS)
        let frame = AudioVADFrame(
            samples: audio.samples,
            sampleRateHz: audio.sampleRateHz,
            continuous: continuous,
            captureNS: now,
            levelDB: audio.levelDB
        )
        speechInteraction?.ingestAudio(SpeechAudioChunk(
            samples: audio.samples,
            sampleRateHz: audio.sampleRateHz,
            captureNS: now,
            durationNS: audio.durationNS,
            continuous: continuous
        ))
        liveVoiceLauncher?.ingestAudio(
            samples: audio.samples,
            sampleRateHz: audio.sampleRateHz,
            durationNS: audio.durationNS
        )
        if voiceWorker.submit(frame) { counters.supersedeAudioVADFrame() }
        if !continuous { lastDirection = .unknown }
        guard voiceWorker.currentActive(), now >= nextDirectionAnalysisNS else { return }
        nextDirectionAnalysisNS = now + 125_000_000
        let stereoOutcome = stereoSamples(from: sampleBuffer)
        if let calibrationRecorder {
            switch stereoOutcome {
            case let .samples(stereo):
                calibrationRecorder.record(
                    StereoTDOAEstimator.assess(left: stereo.left, right: stereo.right, sampleRateHz: stereo.sampleRateHz)
                )
            case let .rejected(reason): calibrationRecorder.record(.rejected(reason))
            }
        }
        guard case let .samples(stereo) = stereoOutcome else { return }
        guard let directionEstimator else { return }
        let direction = directionEstimator.estimate(left: stereo.left, right: stereo.right, sampleRateHz: stereo.sampleRateHz)
        guard direction.direction != .unknown,
              let lagSamples = direction.lagSamples,
              let fractionalLagSamples = direction.fractionalLagSamples,
              let delayMilliseconds = direction.delayMilliseconds,
              let correlation = direction.correlation else { return }
        let directionalBelief = worldModel.ingestAudioDirection(
            direction.direction,
            confidence: direction.confidence,
            at: now
        )
        publisher.publish(directionalBelief, reason: "audio_direction")
        if direction.direction != lastDirection {
            lastDirection = direction.direction
            writer.write(AudioDirectionEvent(
                monotonicNS: now,
                direction: direction.direction,
                confidence: direction.confidence,
                lagSamples: lagSamples,
                fractionalLagSamples: fractionalLagSamples,
                delayMilliseconds: delayMilliseconds,
                correlation: correlation
            ))
        }
    }

    func stop() {
        voiceWorker.stop()
    }

    private func audioPacketIsContinuous(_ sampleBuffer: CMSampleBuffer, durationNS: UInt64) -> Bool {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else {
            previousAudioEndPTS = nil
            return false
        }
        defer {
            previousAudioEndPTS = CMTimeAdd(
                presentationTime,
                CMTime(value: Int64(durationNS), timescale: 1_000_000_000)
            )
        }
        guard let previousAudioEndPTS else { return false }
        let delta = CMTimeGetSeconds(CMTimeSubtract(presentationTime, previousAudioEndPTS))
        let tolerance = max(0.004, Double(durationNS) / 1_000_000_000 * 0.25)
        return delta.isFinite && abs(delta) <= tolerance
    }
}

private final class TDOACalibrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var position: TDOACalibrationPosition = .left
    private var diagnostics = TDOACalibrationDiagnostics()

    func setPosition(_ position: TDOACalibrationPosition) {
        lock.lock()
        self.position = position
        lock.unlock()
    }

    func record(_ outcome: StereoTDOAMeasurementOutcome) {
        lock.lock()
        diagnostics.record(position: position, outcome: outcome)
        lock.unlock()
    }

    func makeCalibration() -> StereoDirectionCalibration? {
        lock.lock()
        let calibration = diagnostics.makeCalibration()
        lock.unlock()
        return calibration
    }

    func summary() -> String {
        lock.lock()
        let summary = TDOACalibrationPosition.allCases.map { position in
            let diagnostic = diagnostics.diagnostic(for: position)
            let medianLag = diagnostic.medianLagSamples.map(String.init) ?? "none"
            let fractionalLag = diagnostic.medianFractionalLagSamples.map { String(format: "%.3f", $0) } ?? "none"
            let zeroLagCorrelation = diagnostic.medianZeroLagCorrelation.map { String(format: "%.3f", $0) } ?? "none"
            return "\(position.rawValue){attempts=\(diagnostic.attempts),accepted=\(diagnostic.accepted),eligible=\(diagnostic.eligible),lag_median=\(medianLag),fractional_lag_median=\(fractionalLag),zero_lag_correlation_median=\(zeroLagCorrelation),ambiguous=\(diagnostic.ambiguous),low_energy=\(diagnostic.lowEnergy),invalid_input=\(diagnostic.invalidInput)}"
        }.joined(separator: ";")
        lock.unlock()
        return summary
    }
}

private final class ANEObjectDetector: @unchecked Sendable {
    let computeUnits: String
    let warmupMS: Double
    private let model: VNCoreMLModel

    init() throws {
        let modelURL: URL
        if let compiledURL = Bundle.module.url(forResource: "YOLOv3TinyFP16", withExtension: "mlmodelc") {
            modelURL = compiledURL
        } else if let sourceURL = Bundle.module.url(forResource: "YOLOv3TinyFP16", withExtension: "mlmodel") {
            modelURL = try MLModel.compileModel(at: sourceURL)
        } else {
            throw RuntimeError.configuration("Bundled Core ML object detector is missing")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        computeUnits = "cpu_and_neural_engine"
        let loadedModel = try MLModel(contentsOf: modelURL, configuration: configuration)
        model = try VNCoreMLModel(for: loadedModel)
        let startedNS = monotonicNanoseconds()
        try Self.warmUp(model)
        warmupMS = milliseconds(from: startedNS, to: monotonicNanoseconds())
    }

    func detect(in pixelBuffer: CVPixelBuffer) throws -> [VisualObservation] {
        try Self.detect(in: pixelBuffer, model: model)
    }

    private static func warmUp(_ model: VNCoreMLModel) throws {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            416,
            416,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer else {
            throw RuntimeError.configuration("Cannot allocate Core ML warmup frame")
        }
        _ = try detect(in: pixelBuffer, model: model)
    }

    private static func detect(in pixelBuffer: CVPixelBuffer, model: VNCoreMLModel) throws -> [VisualObservation] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        let results = request.results as? [VNRecognizedObjectObservation] ?? []
        return results.compactMap { observation in
            guard let label = observation.labels.max(by: { $0.confidence < $1.confidence }),
                  label.confidence >= 0.35 else {
                return nil
            }
            return VisualObservation(
                rect: SOMACore.NormalizedRect(observation.boundingBox),
                confidence: Double(label.confidence),
                source: .neuralDetector,
                kind: label.identifier == "person" ? .human : .object,
                label: label.identifier
            )
        }
    }
}

private final class ANEFaceDetector: @unchecked Sendable {
    private struct Anchor {
        let x: Double
        let y: Double
    }

    let computeUnits: String
    let warmupMS: Double
    private let model: VNCoreMLModel
    private let anchors: [Anchor]

    init() throws {
        guard let modelURL = Bundle.module.url(forResource: "BlazeFaceShortRange", withExtension: "mlpackage") else {
            throw RuntimeError.configuration("Bundled Core ML face detector is missing")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        computeUnits = "cpu_and_neural_engine"
        let compiledURL = try MLModel.compileModel(at: modelURL)
        let loadedModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
        model = try VNCoreMLModel(for: loadedModel)
        anchors = Self.makeAnchors()
        let startedNS = monotonicNanoseconds()
        try Self.warmUp(model: model, anchors: anchors)
        warmupMS = milliseconds(from: startedNS, to: monotonicNanoseconds())
    }

    func detect(in pixelBuffer: CVPixelBuffer) throws -> [VisualObservation] {
        try Self.detect(in: pixelBuffer, model: model, anchors: anchors)
    }

    private static func warmUp(model: VNCoreMLModel, anchors: [Anchor]) throws {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            128,
            128,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer else {
            throw RuntimeError.configuration("Cannot allocate Core ML face warmup frame")
        }
        _ = try detect(in: pixelBuffer, model: model, anchors: anchors)
    }

    private static func detect(in pixelBuffer: CVPixelBuffer, model: VNCoreMLModel, anchors: [Anchor]) throws -> [VisualObservation] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        let features = request.results?.compactMap { $0 as? VNCoreMLFeatureValueObservation } ?? []
        let featureNames = features.map(\.featureName).joined(separator: ",")
        guard let rawBoxes = features.first(where: { $0.featureName == "raw_boxes" })?.featureValue.multiArrayValue,
              let rawScores = features.first(where: { $0.featureName == "raw_scores" })?.featureValue.multiArrayValue,
              isFloatingPointArray(rawBoxes),
              isFloatingPointArray(rawScores),
              anchors.count == 896 else {
            throw RuntimeError.configuration("Unexpected Core ML face detector output: \(featureNames)")
        }

        let boxStrides = rawBoxes.strides.map(\.intValue)
        let scoreStrides = rawScores.strides.map(\.intValue)
        guard boxStrides.count == 3, scoreStrides.count == 3 else {
            throw RuntimeError.configuration("Unexpected Core ML face detector output layout")
        }

        let crop = cropTransform(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        var candidates: [VisualObservation] = []
        for index in anchors.indices {
            let scoreOffset = index * scoreStrides[1]
            let score = sigmoid(Double(value(in: rawScores, at: scoreOffset)))
            guard score >= 0.75 else { continue }
            let boxOffset = index * boxStrides[1]
            let xCenter = Double(value(in: rawBoxes, at: boxOffset)) / 128 + anchors[index].x
            let yCenter = Double(value(in: rawBoxes, at: boxOffset + boxStrides[2])) / 128 + anchors[index].y
            let width = Double(value(in: rawBoxes, at: boxOffset + boxStrides[2] * 2)) / 128
            let height = Double(value(in: rawBoxes, at: boxOffset + boxStrides[2] * 3)) / 128
            guard width > 0, height > 0 else { continue }

            let top = yCenter - height / 2
            let left = xCenter - width / 2
            let mappedLeft = crop.offsetX + left * crop.scaleX
            let mappedTop = crop.offsetY + top * crop.scaleY
            let mappedWidth = width * crop.scaleX
            let mappedHeight = height * crop.scaleY
            let rect = SOMACore.NormalizedRect(
                x: max(0, mappedLeft),
                y: max(0, 1 - mappedTop - mappedHeight),
                width: min(mappedWidth, 1 - max(0, mappedLeft)),
                height: min(mappedHeight, 1 - max(0, 1 - mappedTop - mappedHeight))
            )
            guard rect.width > 0.02, rect.height > 0.02 else { continue }
            // BlazeFace predicts right eye, left eye, nose, mouth, and ear
            // keypoints after its four box values. A high box score can occur
            // on cable texture; that texture does not normally preserve the
            // bilateral eye -> nose -> mouth geometry of a face.
            func mappedPoint(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
                (
                    crop.offsetX + x * crop.scaleX,
                    1 - (crop.offsetY + y * crop.scaleY)
                )
            }
            let facePoints = (0..<4).map { pointIndex in
                mappedPoint(
                    Double(value(in: rawBoxes, at: boxOffset + boxStrides[2] * (4 + pointIndex * 2))) / 128 + anchors[index].x,
                    Double(value(in: rawBoxes, at: boxOffset + boxStrides[2] * (5 + pointIndex * 2))) / 128 + anchors[index].y
                )
            }
            guard hasPlausibleFaceGeometry(
                rightEye: facePoints[0],
                leftEye: facePoints[1],
                nose: facePoints[2],
                mouth: facePoints[3],
                in: rect
            ) else { continue }
            candidates.append(VisualObservation(
                rect: rect,
                confidence: score,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                isActionEligible: true
            ))
        }
        return suppressOverlaps(candidates)
    }

    private static func hasPlausibleFaceGeometry(
        rightEye: (x: Double, y: Double),
        leftEye: (x: Double, y: Double),
        nose: (x: Double, y: Double),
        mouth: (x: Double, y: Double),
        in rect: SOMACore.NormalizedRect
    ) -> Bool {
        let horizontalInset = rect.width * 0.28
        let verticalInset = rect.height * 0.28
        let containsWithTolerance: ((x: Double, y: Double)) -> Bool = { point in
            point.x >= rect.x - horizontalInset
                && point.x <= rect.x + rect.width + horizontalInset
                && point.y >= rect.y - verticalInset
                && point.y <= rect.y + rect.height + verticalInset
        }
        guard [rightEye, leftEye, nose, mouth].allSatisfy(containsWithTolerance) else { return false }
        let eyeSeparation = abs(rightEye.x - leftEye.x)
        let eyeMidX = (rightEye.x + leftEye.x) / 2
        let eyeY = (rightEye.y + leftEye.y) / 2
        return eyeSeparation >= rect.width * 0.12
            && eyeSeparation <= rect.width * 1.20
            && nose.y < eyeY - rect.height * 0.04
            && mouth.y < nose.y - rect.height * 0.04
            && abs(nose.x - eyeMidX) <= rect.width * 0.45
            && abs(mouth.x - nose.x) <= rect.width * 0.55
    }

    private static func makeAnchors() -> [Anchor] {
        let strides = [8, 16, 16, 16]
        var anchors: [Anchor] = []
        var layer = 0
        while layer < strides.count {
            var sameStrideLayers = 0
            while layer + sameStrideLayers < strides.count,
                  strides[layer + sameStrideLayers] == strides[layer] {
                sameStrideLayers += 1
            }
            let grid = 128 / strides[layer]
            for y in 0..<grid {
                for x in 0..<grid {
                    for _ in 0..<(sameStrideLayers * 2) {
                        anchors.append(Anchor(x: (Double(x) + 0.5) / Double(grid), y: (Double(y) + 0.5) / Double(grid)))
                    }
                }
            }
            layer += sameStrideLayers
        }
        return anchors
    }

    private static func isFloatingPointArray(_ array: MLMultiArray) -> Bool {
        array.dataType == .float32 || array.dataType == .float16
    }

    private static func value(in array: MLMultiArray, at offset: Int) -> Float {
        if array.dataType == .float16 {
            return Float(array.dataPointer.bindMemory(to: Float16.self, capacity: offset + 1)[offset])
        }
        return array.dataPointer.bindMemory(to: Float.self, capacity: offset + 1)[offset]
    }

    private static func cropTransform(width: Int, height: Int) -> (offsetX: Double, offsetY: Double, scaleX: Double, scaleY: Double) {
        guard width > 0, height > 0 else { return (0, 0, 1, 1) }
        if width > height {
            let scaleX = Double(height) / Double(width)
            return ((1 - scaleX) / 2, 0, scaleX, 1)
        }
        let scaleY = Double(width) / Double(height)
        return (0, (1 - scaleY) / 2, 1, scaleY)
    }

    private static func suppressOverlaps(_ candidates: [VisualObservation]) -> [VisualObservation] {
        let sorted = candidates.sorted { $0.confidence > $1.confidence }
        return sorted.reduce(into: []) { accepted, candidate in
            guard !accepted.contains(where: { intersectionOverUnion($0.rect, candidate.rect) > 0.3 }) else { return }
            accepted.append(candidate)
        }
    }

    private static func intersectionOverUnion(_ lhs: SOMACore.NormalizedRect, _ rhs: SOMACore.NormalizedRect) -> Double {
        let x1 = max(lhs.x, rhs.x)
        let y1 = max(lhs.y, rhs.y)
        let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }

    private static func sigmoid(_ value: Double) -> Double {
        1 / (1 + exp(-min(max(value, -100), 100)))
    }
}

/// System objectness proposes visually distinct but unlabelled regions. It is
/// deliberately separate from the COCO classifier, so it can corroborate a
/// label without treating that label as ground truth.
private final class SystemSaliencyDetector: @unchecked Sendable {
    func detect(in pixelBuffer: CVPixelBuffer) throws -> [VisualObservation] {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first as? VNSaliencyImageObservation else { return [] }
        return (result.salientObjects ?? []).compactMap { region in
            let rect = SOMACore.NormalizedRect(region.boundingBox)
            guard rect.width * rect.height >= 0.01 else { return nil }
            return VisualObservation(
                rect: rect,
                confidence: Double(region.confidence),
                source: .systemSaliency,
                kind: .unknown
            )
        }
    }
}

/// System Vision landmarks independently corroborate an ANE face. A face
/// rectangle alone is too permissive around cables and textured objects; a
/// landmark result must contain actual facial feature points before it can
/// promote a face candidate. They are transient observations only; no pixels
/// or landmark data are written.
private struct SystemFaceEvidence: Sendable {
    let rect: SOMACore.NormalizedRect
    let directedEyeContact: Bool
    /// Raw Vision gaze features for diagnostics. Kept separate from the boolean
    /// so the live trace can reveal why a face is (or is not) contact-ready
    /// without re-deriving them.
    let yaw: Double?
    let pitch: Double?
    let pupilOffsetX: Double?
    let pupilOffsetY: Double?
    let alignment: FaceAlignmentEvidence
}

private final class SystemFaceVerifier: @unchecked Sendable {
    /// Scales the pupil-centering thresholds that decide directed eye contact.
    /// 1.0 = default (0.68 X / 0.82 Y). Lower = stricter (pupil must be more
    /// centered); higher = more lenient.
    private let pupilCenteringThreshold: Double

    init(pupilCenteringThreshold: Double = 1.0) {
        self.pupilCenteringThreshold = min(max(pupilCenteringThreshold, 0.1), 2.0)
    }

    func detect(in pixelBuffer: CVPixelBuffer) -> [SystemFaceEvidence] {
        let faceRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([faceRequest])) != nil else { return [] }
        return (faceRequest.results ?? []).compactMap { observation in
            guard let landmarks = observation.landmarks,
                  hasFacialFeatureSet(landmarks) else {
                return nil
            }
            let rect = SOMACore.NormalizedRect(observation.boundingBox)
            guard let alignment = alignmentEvidence(landmarks: landmarks, rect: rect) else {
                return nil
            }
            let gaze = gazeAssessment(
                observation: observation,
                landmarks: landmarks,
                rect: rect
            )
            return SystemFaceEvidence(
                rect: rect,
                directedEyeContact: gaze.directed,
                yaw: gaze.yaw,
                pitch: gaze.pitch,
                pupilOffsetX: gaze.pupilOffsetX,
                pupilOffsetY: gaze.pupilOffsetY,
                alignment: alignment
            )
        }
    }

    private func alignmentEvidence(
        landmarks: VNFaceLandmarks2D,
        rect: SOMACore.NormalizedRect
    ) -> FaceAlignmentEvidence? {
        guard let visionLeftEye = landmarks.leftEye,
              let visionRightEye = landmarks.rightEye,
              let nose = landmarks.nose,
              let firstEye = center(of: visionLeftEye, in: rect),
              let secondEye = center(of: visionRightEye, in: rect),
              let noseCenter = center(of: nose, in: rect) else {
            return nil
        }
        // Vision names eyes anatomically. ArcFace's template is ordered by
        // image position, so normalize the pair explicitly for an unmirrored
        // camera frame.
        let imageLeftEye = firstEye.x <= secondEye.x ? firstEye : secondEye
        let imageRightEye = firstEye.x <= secondEye.x ? secondEye : firstEye
        guard imageRightEye.x - imageLeftEye.x >= rect.width * 0.12,
              noseCenter.y < max(imageLeftEye.y, imageRightEye.y) else {
            return nil
        }
        return FaceAlignmentEvidence(
            rect: rect,
            leftEye: imageLeftEye,
            rightEye: imageRightEye,
            nose: noseCenter
        )
    }

    private func center(
        of region: VNFaceLandmarkRegion2D,
        in rect: SOMACore.NormalizedRect
    ) -> CGPoint? {
        guard region.pointCount > 0 else { return nil }
        var x = 0.0
        var y = 0.0
        for index in 0..<region.pointCount {
            x += Double(region.normalizedPoints[index].x)
            y += Double(region.normalizedPoints[index].y)
        }
        let divisor = Double(region.pointCount)
        return CGPoint(
            x: rect.x + (x / divisor) * rect.width,
            y: rect.y + (y / divisor) * rect.height
        )
    }

    private func hasFacialFeatureSet(_ landmarks: VNFaceLandmarks2D) -> Bool {
        // `allPoints` alone is permissive enough to turn cable texture into a
        // face. A physical face confirmation needs bilateral eyes plus nose
        // and mouth structure. This remains a lightweight System Vision gate,
        // not stored biometric data or identity recognition.
        let eyes = (landmarks.leftEye?.pointCount ?? 0) >= 2
            && (landmarks.rightEye?.pointCount ?? 0) >= 2
        let nose = (landmarks.nose?.pointCount ?? 0) >= 2
        let mouth = (landmarks.outerLips?.pointCount ?? 0) >= 3
        return eyes && nose && mouth
    }

    private func gazeAssessment(
        observation: VNFaceObservation,
        landmarks: VNFaceLandmarks2D,
        rect: SOMACore.NormalizedRect
    ) -> (yaw: Double?, pitch: Double?, pupilOffsetX: Double?, pupilOffsetY: Double?, directed: Bool) {
        let yaw = observation.yaw?.doubleValue
        let pitch = observation.pitch?.doubleValue
        guard rect.centerX >= 0.26, rect.centerX <= 0.74,
              rect.centerY >= 0.13, rect.centerY <= 0.89,
              rect.width * rect.height >= 0.008,
              let yaw, abs(yaw) <= 0.50,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye,
              let leftPupil = landmarks.leftPupil,
              let rightPupil = landmarks.rightPupil else {
            return (yaw, pitch, nil, nil, false)
        }
        let left = pupilOffset(leftPupil, in: leftEye)
        let right = pupilOffset(rightPupil, in: rightEye)
        let directed = pupilIsCentered(leftPupil, in: leftEye)
            && pupilIsCentered(rightPupil, in: rightEye)
        return (yaw, pitch, max(left?.x ?? 0, right?.x ?? 0), max(left?.y ?? 0, right?.y ?? 0), directed)
    }

    private func pupilOffset(
        _ pupil: VNFaceLandmarkRegion2D,
        in eye: VNFaceLandmarkRegion2D
    ) -> (x: Double, y: Double)? {
        guard pupil.pointCount > 0, eye.pointCount >= 2 else { return nil }
        let pupilPoint = pupil.normalizedPoints[0]
        var minimumX = Double.greatestFiniteMagnitude
        var maximumX = -Double.greatestFiniteMagnitude
        var minimumY = Double.greatestFiniteMagnitude
        var maximumY = -Double.greatestFiniteMagnitude
        for index in 0..<eye.pointCount {
            let point = eye.normalizedPoints[index]
            minimumX = min(minimumX, Double(point.x))
            maximumX = max(maximumX, Double(point.x))
            minimumY = min(minimumY, Double(point.y))
            maximumY = max(maximumY, Double(point.y))
        }
        let width = maximumX - minimumX
        let height = maximumY - minimumY
        guard width > 0.001, height > 0.001 else { return nil }
        return (
            x: abs(Double(pupilPoint.x) - (minimumX + maximumX) / 2) / (width / 2),
            y: abs(Double(pupilPoint.y) - (minimumY + maximumY) / 2) / (height / 2)
        )
    }

    private func pupilIsCentered(
        _ pupil: VNFaceLandmarkRegion2D,
        in eye: VNFaceLandmarkRegion2D
    ) -> Bool {
        guard pupil.pointCount > 0, eye.pointCount >= 2 else { return false }
        let pupilPoint = pupil.normalizedPoints[0]
        var minimumX = Double.greatestFiniteMagnitude
        var maximumX = -Double.greatestFiniteMagnitude
        var minimumY = Double.greatestFiniteMagnitude
        var maximumY = -Double.greatestFiniteMagnitude
        for index in 0..<eye.pointCount {
            let point = eye.normalizedPoints[index]
            minimumX = min(minimumX, Double(point.x))
            maximumX = max(maximumX, Double(point.x))
            minimumY = min(minimumY, Double(point.y))
            maximumY = max(maximumY, Double(point.y))
        }
        let width = maximumX - minimumX
        let height = maximumY - minimumY
        guard width > 0.001, height > 0.001 else { return false }
        let normalizedX = abs(Double(pupilPoint.x) - (minimumX + maximumX) / 2) / (width / 2)
        let normalizedY = abs(Double(pupilPoint.y) - (minimumY + maximumY) / 2) / (height / 2)
        // Vision reports the pupil near the eye centre regardless of gaze on
        // this camera (yaw is quantized to 0 / +/-45 / +/-90 and pitch is nil),
        // so the pupil offset cannot discriminate a subtle averted gaze. Keep a
        // permissive threshold so a direct stare — and a slightly turned head
        // that is still making eye contact — is accepted; a clear head turn is
        // rejected by the yaw guard in gazeAssessment instead.
        return normalizedX <= 0.68 * pupilCenteringThreshold
            && normalizedY <= 0.82 * pupilCenteringThreshold
    }

}

private final class DiagnosticPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

/// Explicit, bounded raw-frame capture for diagnosing a failing face lock.
/// It is deliberately outside the normal scalar-only trace and is created
/// only by the opt-in command-line flag.
private final class FaceLockDiagnosticRecorder: @unchecked Sendable {
    private struct StopReport: Encodable {
        let schemaVersion = 1
        let event = "diagnostic.gimbal_stop"
        let monotonicNS: UInt64
        let reason: String
        let faceLockActive: Bool
        let faceLockMotorPermitted: Bool
        let lastObservedFaceMilliseconds: Double?
        let targetID: String?
        let targetKind: AttentionTargetKind?
        let targetLabel: String?
        let targetConfidence: Double?
        let targetCenterX: Double?
        let targetCenterY: Double?
        let targetActionEligible: Bool?
        let posePitchDegrees: Double?
        let posePanDegrees: Double?
        let latestFrame: String?
        let latestFrameState: String?
        let latestFrameMonotonicNS: UInt64?

        init(_ diagnostic: GimbalStopDiagnostic, latestFrame: String?, latestFrameState: String?, latestFrameMonotonicNS: UInt64?) {
            monotonicNS = diagnostic.monotonicNS
            reason = diagnostic.reason
            faceLockActive = diagnostic.faceLockActive
            faceLockMotorPermitted = diagnostic.faceLockMotorPermitted
            lastObservedFaceMilliseconds = diagnostic.lastObservedFaceMilliseconds
            targetID = diagnostic.targetID
            targetKind = diagnostic.targetKind
            targetLabel = diagnostic.targetLabel
            targetConfidence = diagnostic.targetConfidence
            targetCenterX = diagnostic.targetCenterX
            targetCenterY = diagnostic.targetCenterY
            targetActionEligible = diagnostic.targetActionEligible
            posePitchDegrees = diagnostic.posePitchDegrees
            posePanDegrees = diagnostic.posePanDegrees
            self.latestFrame = latestFrame
            self.latestFrameState = latestFrameState
            self.latestFrameMonotonicNS = latestFrameMonotonicNS
        }
    }

    private let directoryURL: URL
    private let ioQueue = DispatchQueue(label: "soma.subconscious.face-lock-diagnostics", qos: .utility)
    private let context = CIContext(options: nil)
    private let admissionLock = NSLock()
    private let sampleIntervalNS: UInt64 = 500_000_000
    private let faceCandidateIntervalNS: UInt64 = 100_000_000
    private let maximumImages = 60
    private var nextCaptureNS: UInt64 = 0
    private var encoding = false
    private var latestFrame: String?
    private var latestFrameState: String?
    private var latestFrameMonotonicNS: UInt64?

    init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func record(pixelBuffer: CVPixelBuffer, at monotonicNS: UInt64, state: String, force: Bool = false) {
        guard monotonicNS >= nextCaptureNS else { return }
        // A diagnostic is a bounded recent-history ring, not a second video
        // recorder. Face candidates need denser evidence than idle frames,
        // but never a 60 Hz stream of retained IOSurfaces.
        nextCaptureNS = monotonicNS + (force ? faceCandidateIntervalNS : sampleIntervalNS)
        admissionLock.lock()
        guard !encoding else {
            admissionLock.unlock()
            return
        }
        encoding = true
        let outputName = "frame-\(monotonicNS)-\(state).jpg"
        latestFrame = outputName
        latestFrameState = state
        latestFrameMonotonicNS = monotonicNS
        admissionLock.unlock()
        let retainedPixelBuffer = DiagnosticPixelBuffer(pixelBuffer)
        ioQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.admissionLock.lock()
                self.encoding = false
                self.admissionLock.unlock()
            }
            let image = CIImage(cvPixelBuffer: retainedPixelBuffer.value)
            let outputURL = self.directoryURL.appendingPathComponent(outputName)
            try? self.context.writeJPEGRepresentation(
                of: image,
                to: outputURL,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [:]
            )
            let images = ((try? FileManager.default.contentsOfDirectory(
                at: self.directoryURL,
                includingPropertiesForKeys: nil
            )) ?? [])
                .filter { $0.pathExtension.lowercased() == "jpg" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for staleURL in images.dropLast(self.maximumImages) {
                try? FileManager.default.removeItem(at: staleURL)
            }
        }
    }

    /// Appends one bounded scalar state record whenever the bridge stops the
    /// gimbal. The frame recorder remains rate limited; this report points to
    /// the most recent retained JPEG rather than duplicating pixels.
    func recordStop(_ diagnostic: GimbalStopDiagnostic) {
        admissionLock.lock()
        let report = StopReport(
            diagnostic,
            latestFrame: latestFrame,
            latestFrameState: latestFrameState,
            latestFrameMonotonicNS: latestFrameMonotonicNS
        )
        admissionLock.unlock()
        ioQueue.async { [directoryURL] in
            guard let data = try? JSONEncoder().encode(report) else { return }
            let reportURL = directoryURL.appendingPathComponent("gimbal-stop-reports.jsonl")
            if !FileManager.default.fileExists(atPath: reportURL.path) {
                FileManager.default.createFile(atPath: reportURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: reportURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
            } catch {
                return
            }
        }
    }
}

private final class VisionWorker: @unchecked Sendable {
    private enum DetectionOutcome {
        case candidates([VisualObservation])
        case miss
    }

    private let mailbox = LatestFrameMailbox()
    private let wake = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "soma.subconscious.vision", qos: .userInitiated)
    private let worldModel: PredictiveWorldModel
    private let publisher: BeliefPublisher
    private let writer: JSONLWriter
    private let counters: LatencyCounters
    private let faceLockDiagnosticRecorder: FaceLockDiagnosticRecorder?
    private let panoramaCompositor: RollingPanoramaCompositor?
    private let onSceneCandidates: (([SceneCandidate], UInt64) -> Void)?
    private let onCoverage: ((GimbalPose, Double, GimbalPoseProjection, CameraProjectionModel, UInt64) -> Void)?
    private let onFatalVisionFailure: (() -> Void)?
    private let poseStore: GimbalPoseStore
    private let externalGimbalCalibration: ExternalGimbalCalibration?
    private let neuralObjectDetector: ANEObjectDetector?
    private let neuralFaceDetector: ANEFaceDetector?
    private let faceIdentityRuntime: FaceIdentityRuntime?
    private let onCameraFrame: ((CVPixelBuffer, UInt64) -> Void)?
    private let onIdentityPresenceEvidence: (@Sendable (Bool, UInt64) -> Void)?
    private let systemSaliencyDetector = SystemSaliencyDetector()
    private let systemFaceVerifier: SystemFaceVerifier
    private let stateLock = NSLock()
    private var sceneField = SceneField(requiresFaceActivity: true)
    private var detectorCountdown = 0
    private var nextObjectNS: UInt64 = 0
    private var nextFaceNS: UInt64 = 0
    private var nextFaceVerificationNS: UInt64 = 0
    private var directedContactEvidence: [(rect: SOMACore.NormalizedRect, observedNS: UInt64)] = []
    private var identityAlignmentEvidence: [(evidence: SystemFaceEvidence, observedNS: UInt64)] = []
    private var nextSaliencyNS: UInt64 = 0
    private var nextSceneSnapshotNS: UInt64 = 0
    private var nextObjectErrorReportNS: UInt64 = 0
    private var visualEvidenceContinuity = VisualEvidenceContinuity()
    private var socialAttentionLease = SocialAttentionLease()
    private var facePersonFusion = FacePersonFusion()
    private var faceConfirmationLease = FaceConfirmationLease()
    private var faceMotorContinuityLease = FaceMotorContinuityLease()
    private var unverifiedFaceRejection = UnverifiedFaceRejectionGate()
    private var panoramaBackgroundAdmission = PanoramaBackgroundAdmission()
    private var trackerRect: CGRect?
    private var lastAttentionEntropy = 0.0
    private var lastFaceInferenceSuccessNS: UInt64 = 0
    private var faceInferenceFailureReported = false
    private var faceInferenceStallReported = false
    private var stopped = false

    private static func faceEvidenceMatches(
        _ lhs: SOMACore.NormalizedRect,
        _ rhs: SOMACore.NormalizedRect
    ) -> Bool {
        let x1 = max(lhs.x, rhs.x)
        let y1 = max(lhs.y, rhs.y)
        let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        if union > 0, intersection / union >= 0.10 { return true }
        return hypot(lhs.centerX - rhs.centerX, lhs.centerY - rhs.centerY) <= 0.14
    }

    init(
        worldModel: PredictiveWorldModel,
        publisher: BeliefPublisher,
        writer: JSONLWriter,
        counters: LatencyCounters,
        poseStore: GimbalPoseStore,
        externalGimbalCalibration: ExternalGimbalCalibration? = nil,
        faceLockDiagnosticRecorder: FaceLockDiagnosticRecorder? = nil,
        panoramaCompositor: RollingPanoramaCompositor? = nil,
        onSceneCandidates: (([SceneCandidate], UInt64) -> Void)? = nil,
        onCoverage: ((GimbalPose, Double, GimbalPoseProjection, CameraProjectionModel, UInt64) -> Void)? = nil,
        onCameraFrame: ((CVPixelBuffer, UInt64) -> Void)? = nil,
        onIdentityDecision: (@Sendable (FaceIdentityRuntimeDecision, SOMACore.NormalizedRect, Bool, UInt64) -> Void)? = nil,
        onIdentityPresenceEvidence: (@Sendable (Bool, UInt64) -> Void)? = nil,
        onFatalVisionFailure: (() -> Void)? = nil,
        anonymousReviewProvider: @escaping @Sendable () -> Bool = { true },
        pupilCenteringThreshold: Double = 1.0
    ) {
        self.worldModel = worldModel
        self.publisher = publisher
        self.writer = writer
        self.counters = counters
        self.poseStore = poseStore
        self.externalGimbalCalibration = externalGimbalCalibration
        self.faceLockDiagnosticRecorder = faceLockDiagnosticRecorder
        self.panoramaCompositor = panoramaCompositor
        self.onSceneCandidates = onSceneCandidates
        self.onCoverage = onCoverage
        self.onCameraFrame = onCameraFrame
        self.onFatalVisionFailure = onFatalVisionFailure
        self.onIdentityPresenceEvidence = onIdentityPresenceEvidence
        self.systemFaceVerifier = SystemFaceVerifier(
            pupilCenteringThreshold: pupilCenteringThreshold
        )
        do {
            let detector = try ANEObjectDetector()
            neuralObjectDetector = detector
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "object_neural_engine",
                state: "configured",
                message: "model=YOLOv3TinyFP16; compute_units=\(detector.computeUnits); labels=person_and_objects; prewarm_ms=\(detector.warmupMS)"
            ))
        } catch {
            neuralObjectDetector = nil
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "object_neural_engine",
                state: "unavailable",
                message: error.localizedDescription
            ))
        }
        do {
            let detector = try ANEFaceDetector()
            neuralFaceDetector = detector
            lastFaceInferenceSuccessNS = monotonicNanoseconds()
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "face_neural_engine",
                state: "configured",
                message: "model=BlazeFaceShortRange; compute_units=\(detector.computeUnits); prewarm_ms=\(detector.warmupMS); max_hz=60"
            ))
        } catch {
            neuralFaceDetector = nil
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "face_neural_engine",
                state: "unavailable",
                message: error.localizedDescription
            ))
        }
        do {
            faceIdentityRuntime = try FaceIdentityRuntime(
                onHealth: { state, message in
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: monotonicNanoseconds(),
                        source: "face_identity",
                        state: state,
                        message: message
                    ))
                },
                onDecision: { decision, rect, isPrimaryFace, observedNS, inferenceMS in
                    writer.write(FaceIdentityEvent(
                        monotonicNS: observedNS,
                        state: decision.state,
                        subject: decision.opaqueSubject,
                        confidence: decision.confidence,
                        inferenceMS: inferenceMS
                    ))
                    onIdentityDecision?(decision, rect, isPrimaryFace, observedNS)
                },
                anonymousReviewProvider: anonymousReviewProvider
            )
        } catch {
            faceIdentityRuntime = nil
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "face_identity",
                state: "unavailable",
                message: error.localizedDescription
            ))
        }
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "system_face_verifier",
            state: "configured",
            message: "source=VNDetectFaceLandmarksRequest; max_hz=20; auxiliary_only"
        ))
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "system_objectness",
            state: "configured",
            message: "source=VNGenerateObjectnessBasedSaliencyImageRequest; max_hz=4; labels=none"
        ))
    }

    func start() {
        queue.async { [weak self] in self?.workLoop() }
    }

    func submit(pixelBuffer: CVPixelBuffer, captureNS: UInt64, exposureNS: UInt64) {
        guard !isStopped else { return }
        onCameraFrame?(pixelBuffer, captureNS)
        let result = mailbox.publish(VideoFrame(
            pixelBuffer: pixelBuffer,
            captureNS: captureNS,
            exposureNS: exposureNS
        ))
        if result.superseded { counters.supersedeFrame() }
        if result.shouldWake { wake.signal() }
    }

    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        wake.signal()
        queue.sync {}
        faceIdentityRuntime?.stop()
    }

    private func workLoop() {
        while true {
            wake.wait()
            if isStopped { return }
            guard let frame = mailbox.take() else { continue }
            // This dispatch work item lives for the whole capture session, so
            // GCD cannot drain an autorelease pool between frames. Vision and
            // Core ML create autoreleased request/result/IOSurface objects;
            // without this boundary they accumulate until VNCoreMLTransform
            // fails and the capture watchdog restarts the process.
            autoreleasepool {
                process(frame)
            }
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func process(_ frame: VideoFrame) {
        let startedNS = monotonicNanoseconds()
        detectorCountdown -= 1
        let outcome: DetectionOutcome
        do {
            if neuralObjectDetector != nil {
                outcome = try detect(in: frame.pixelBuffer)
            } else if let trackerRect, detectorCountdown > 0,
               let tracked = try track(trackerRect, in: frame.pixelBuffer) {
                self.trackerRect = tracked.rect.cgRect
                outcome = .candidates([tracked])
            } else if detectorCountdown <= 0 {
                detectorCountdown = 4
                outcome = try detect(in: frame.pixelBuffer)
                if case let .candidates(candidates) = outcome, let observation = candidates.first {
                    trackerRect = observation.rect.cgRect
                }
            } else {
                counters.visionFrameSkipped()
                return
            }
        } catch {
            outcome = .miss
        }

        let completedNS = monotonicNanoseconds()
        let inferenceMS = milliseconds(from: startedNS, to: completedNS)
        let captureToBeliefMS = milliseconds(from: frame.captureNS, to: completedNS)
        let projection = poseStore.projection(at: frame.captureNS)
        if let pose = projection.pose {
            onCoverage?(
                pose,
                projection.horizontalFieldOfViewDegrees,
                externalGimbalCalibration == nil ? .identity : .obsbotTiny2Lite,
                projection.cameraProjectionModel,
                completedNS
            )
        }
        switch outcome {
        case let .candidates(candidates):
            let sceneCandidates = sceneField.ingest(
                candidates,
                at: completedNS,
                cameraPose: projection.pose,
                horizontalFieldOfViewDegrees: projection.horizontalFieldOfViewDegrees,
                cameraSettled: projection.cameraSettled,
                poseProjection: externalGimbalCalibration == nil ? .identity : .obsbotTiny2Lite,
                cameraProjectionModel: projection.cameraProjectionModel
            )
            writeSceneCandidates(sceneCandidates, at: completedNS)
            onSceneCandidates?(sceneCandidates, completedNS)
            submitPanorama(
                frame,
                sceneCandidates: sceneCandidates,
                projection: projection,
                at: completedNS
            )
            let observedCandidates = sceneCandidates.filter(\.observedThisFrame)
            // A BlazeFace frame can contain a broad, low-confidence face
            // hypothesis around the same physical face as a landmark-verified
            // box. Both remain in SceneField for awareness, but only the
            // verified geometry may become this frame's L0 attention input.
            // Otherwise the selector can alternate between two boxes for one
            // person and make the gimbal chase their disagreement.
            let hasVerifiedFace = observedCandidates.contains {
                $0.observation.kind == .human
                    && $0.observation.label == "face"
                    && $0.faceVerificationEligible
            }
            let attentionCandidates = (hasVerifiedFace
                ? observedCandidates.filter {
                    $0.observation.kind != .human
                        || $0.observation.label != "face"
                        || $0.faceVerificationEligible
                }
                : observedCandidates
            ).map { $0.attentionObservation() }
            if attentionCandidates.contains(where: { $0.kind == .human && $0.isActionEligible }) {
                socialAttentionLease.recordEligibleHuman(at: completedNS)
            }
            if socialAttentionLease.suppressesDefaultNonHumanAttention(
                candidates: attentionCandidates,
                at: completedNS
            ) {
                counters.visionFrameSkipped()
                return
            }
            guard let observation = chooseAttentionCandidate(attentionCandidates) else {
                // A weak or habituated candidate can correctly yield
                // no-target. It still is not proof that the prior visual
                // target vanished; use the same continuous-loss window as an
                // empty detector result before releasing the gimbal.
                guard visualEvidenceContinuity.confirmsLoss(at: completedNS) else {
                    counters.visionFrameSkipped()
                    return
                }
                let belief = worldModel.ingestVisionMiss(at: alignedWorldTimestamp(completedNS))
                counters.visionMiss(inferenceMS: inferenceMS, captureToBeliefMS: captureToBeliefMS)
                publisher.publish(belief, reason: "vision_miss", force: true)
                return
            }
            let belief = worldModel.ingestVisual(observation, at: alignedWorldTimestamp(completedNS))
            visualEvidenceContinuity.recordObservation(at: completedNS)
            counters.visionUpdate(inferenceMS: inferenceMS, captureToBeliefMS: captureToBeliefMS)
            writer.write(VisionEvent(
                monotonicNS: completedNS,
                source: observation.source,
                confidence: observation.confidence,
                kind: observation.kind,
                label: observation.label,
                attentionWeight: observation.attentionWeight,
                attentionProbability: observation.posteriorProbability,
                attentionEntropy: lastAttentionEntropy,
                captureToBeliefMS: captureToBeliefMS
            ))
            publisher.publish(belief, reason: observation.source.rawValue, force: true)
        case .miss:
            let sceneCandidates = sceneField.ingest([], at: completedNS)
            submitPanorama(
                frame,
                sceneCandidates: sceneCandidates,
                projection: projection,
                at: completedNS
            )
            // The scene field is a local spatial map, not just a cache for the
            // attention selector. Emit its offscreen decay at a bounded rate so
            // a trace can reconstruct what remains known outside the frame.
            if completedNS >= nextSceneSnapshotNS {
                nextSceneSnapshotNS = completedNS + 250_000_000
                writeSceneCandidates(sceneCandidates, at: completedNS)
                onSceneCandidates?(sceneCandidates, completedNS)
            }
            guard visualEvidenceContinuity.confirmsLoss(at: completedNS) else {
                counters.visionFrameSkipped()
                return
            }
            let belief = worldModel.ingestVisionMiss(at: alignedWorldTimestamp(completedNS))
            counters.visionMiss(inferenceMS: inferenceMS, captureToBeliefMS: captureToBeliefMS)
            publisher.publish(belief, reason: "vision_miss", force: true)
        }
    }

    private func submitPanorama(
        _ frame: VideoFrame,
        sceneCandidates: [SceneCandidate],
        projection: (
            pose: GimbalPose?,
            horizontalFieldOfViewDegrees: Double,
            fieldOfViewMode: Int,
            cameraProjectionModel: CameraProjectionModel,
            cameraSettled: Bool
        ),
        at monotonicNS: UInt64
    ) {
        let hasObservedHuman = sceneCandidates.contains {
            $0.observedThisFrame && $0.observation.kind == .human
        }
        let admitsUnmaskedBackground = panoramaBackgroundAdmission.admits(
            hasObservedHuman: hasObservedHuman,
            at: monotonicNS
        )
        // A detected person can be removed by the per-frame dynamic mask, so
        // the remaining background is still useful. During a detector gap the
        // prior person rectangle is no longer current, therefore the bounded
        // admission hold continues to reject the whole frame. Feature-print
        // persistence independently requires an empty mask.
        guard hasObservedHuman || admitsUnmaskedBackground else { return }
        let dynamicRects = sceneCandidates.compactMap { candidate -> SOMACore.NormalizedRect? in
            // Detector labels do not imply physical motion. Mask people from
            // the persistent place image, but retain nonhuman objects so a
            // continuous sweep cannot leave permanent detector-shaped holes.
            guard candidate.observedThisFrame,
                  PanoramaEntityMaskPolicy.shouldMask(candidate.observation.kind) else {
                return nil
            }
            return candidate.observation.rect
        }
        panoramaCompositor?.submit(
            pixelBuffer: frame.pixelBuffer,
            captureNS: frame.exposureNS,
            horizontalFieldOfViewDegrees: projection.horizontalFieldOfViewDegrees,
            fieldOfViewMode: projection.fieldOfViewMode,
            cameraProjectionModel: projection.cameraProjectionModel,
            dynamicVisionRects: dynamicRects
        )
    }

    private func track(_ rect: CGRect, in pixelBuffer: CVPixelBuffer) throws -> VisualObservation? {
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: rect))
        request.trackingLevel = .fast
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first as? VNDetectedObjectObservation,
              result.confidence >= 0.35 else {
            trackerRect = nil
            return nil
        }
        return VisualObservation(rect: SOMACore.NormalizedRect(result.boundingBox), confidence: Double(result.confidence), source: .tracker)
    }

    private func detect(in pixelBuffer: CVPixelBuffer) throws -> DetectionOutcome {
        var candidates: [VisualObservation] = []
        if let neuralFaceDetector {
            let now = monotonicNanoseconds()
            if now >= nextFaceNS {
                nextFaceNS = now + 33_333_333
                do {
                    let faces = try neuralFaceDetector.detect(in: pixelBuffer)
                    candidates += faces
                    counters.neuralFaceInference()
                    recordFaceInferenceSuccess(at: monotonicNanoseconds())
                } catch {
                    recordFaceInferenceFailure(error, at: monotonicNanoseconds())
                }
            }
        }
        // The face is the only L0 motor target. Running the heavier scene
        // detector first serializes it behind an unrelated object inference
        // and adds a visible control delay. Keep scene awareness at 12 Hz,
        // but reserve every available frame for the face path.
        let now = monotonicNanoseconds()
        if let neuralObjectDetector, now >= nextObjectNS {
            nextObjectNS = now + 125_000_000
            let startedNS = monotonicNanoseconds()
            do {
                candidates += try neuralObjectDetector.detect(in: pixelBuffer)
                counters.neuralEngineInference(inferenceMS: milliseconds(from: startedNS, to: monotonicNanoseconds()))
            } catch {
                let failedNS = monotonicNanoseconds()
                if failedNS >= nextObjectErrorReportNS {
                    nextObjectErrorReportNS = failedNS + 1_000_000_000
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: failedNS,
                        source: "object_neural_engine",
                        state: "runtime_error",
                        message: error.localizedDescription
                    ))
                }
            }
        }
        let faceVerificationNow = monotonicNanoseconds()
        if faceVerificationNow >= nextFaceVerificationNS {
            nextFaceVerificationNS = faceVerificationNow + 50_000_000
            let systemFaces = systemFaceVerifier.detect(in: pixelBuffer)
            faceConfirmationLease.record(systemFaces.map(\.rect), at: faceVerificationNow)
            directedContactEvidence = systemFaces
                .filter(\.directedEyeContact)
                .map { ($0.rect, faceVerificationNow) }
            identityAlignmentEvidence = systemFaces.map { ($0, faceVerificationNow) }
            // System Vision is an independent confirmation signal, never a
            // steering measurement. Its face box has a different crop and
            // cadence from BlazeFace; alternating the two boxes made the
            // gimbal chase a synthetic zig-zag for one physical face.
        }
        candidates = facePersonFusion.fuse(candidates, at: faceVerificationNow)
        let directedContactFreshnessNS = UInt64(somaEnvDouble(
            "SOMA_L0_EYE_CONTACT_FRESHNESS_MS",
            default: 450
        )) * 1_000_000
        candidates = candidates.map { candidate in
            guard isFaceCandidate(candidate) else { return candidate }
            // FacePersonFusion is the primary motor corroboration boundary.
            // A lone ANE face is admissible only after independent *landmark*
            // confirmation; never promote a System-Vision rectangle by itself.
            let independentlyVerified = candidate.isFaceVerified
                || faceConfirmationLease.permits(candidate.rect, at: faceVerificationNow)
            let directedEyeContact = independentlyVerified
                && directedContactEvidence.contains { evidence in
                    faceVerificationNow >= evidence.observedNS
                        && faceVerificationNow - evidence.observedNS <= directedContactFreshnessNS
                        && Self.faceEvidenceMatches(evidence.rect, candidate.rect)
                }
            if independentlyVerified {
                faceMotorContinuityLease.record(candidate.rect, at: faceVerificationNow)
            }
            return VisualObservation(
                rect: candidate.rect,
                confidence: candidate.confidence,
                source: candidate.source,
                kind: candidate.kind,
                label: candidate.label,
                attentionWeight: candidate.attentionWeight,
                posteriorProbability: candidate.posteriorProbability,
                sceneID: candidate.sceneID,
                stabilityMilliseconds: candidate.stabilityMilliseconds,
                isActionEligible: candidate.isActionEligible
                    || (candidate.source == .neuralFaceDetector && independentlyVerified),
                isFaceVerified: independentlyVerified,
                isEyeContactEligible: directedEyeContact
            )
        }
        for candidate in candidates where isFaceCandidate(candidate) && candidate.isFaceVerified {
            facePersonFusion.promoteValidatedFace(candidate.rect, at: faceVerificationNow)
        }
        let rawFaceCount = candidates.filter(isFaceCandidate).count
        if rawFaceCount == 0 {
            unverifiedFaceRejection.recordNoFace(at: faceVerificationNow)
        }
        var rejectedFaceRects: [SOMACore.NormalizedRect] = []
        candidates = candidates.filter { candidate in
            guard isFaceCandidate(candidate) else { return true }
            let admitted = unverifiedFaceRejection.admits(
                rect: candidate.rect,
                independentlyVerified: candidate.isFaceVerified,
                at: faceVerificationNow
            )
            if !admitted { rejectedFaceRects.append(candidate.rect) }
            return admitted
        }
        candidates = candidates.map { candidate in
            guard isFaceCandidate(candidate),
                  !candidate.isFaceVerified,
                  unverifiedFaceRejection.isValidated(candidate.rect) else {
                return candidate
            }
            return VisualObservation(
                rect: candidate.rect,
                confidence: candidate.confidence,
                source: candidate.source,
                kind: candidate.kind,
                label: candidate.label,
                attentionWeight: candidate.attentionWeight,
                posteriorProbability: candidate.posteriorProbability,
                sceneID: candidate.sceneID,
                stabilityMilliseconds: candidate.stabilityMilliseconds,
                isActionEligible: candidate.isActionEligible,
                isFaceVerified: true,
                isEyeContactEligible: candidate.isEyeContactEligible
            )
        }
        sceneField.invalidateUnverifiedFaceTracks(matching: rejectedFaceRects)
        let verifiedFaceCount = candidates.filter { isFaceCandidate($0) && $0.isFaceVerified }.count
        onIdentityPresenceEvidence?(verifiedFaceCount > 0, faceVerificationNow)
        let verifiedNeuralFaces = candidates.filter { isFaceCandidate($0) && $0.isFaceVerified }
        let identityAlignments: [FaceAlignmentEvidence]
        if verifiedNeuralFaces.isEmpty {
            // BlazeFace (short-range, 0.75 threshold) missed the face this frame,
            // but System Vision independently verified one with landmarks. Feed
            // those alignments straight to identity so a visible person still
            // gets recognized even when the lighter ANE detector cannot confirm
            // a "face" candidate.
            // Person-corroboration gate: only feed System Vision faces to
            // identity when they sit on an actual human body box. This stops
            // face-like objects (e.g. a Dyson purifier) — which systemVision
            // may flag with landmarks but which have no matching "person"
            // detection — from being registered as anonymous identities.
            let humanBodyRects = candidates
                .filter { $0.kind == .human && $0.label != "face" }
                .map(\.rect)
            identityAlignments = identityAlignmentEvidence
                .filter { evidence in
                    faceVerificationNow >= evidence.observedNS
                        && faceVerificationNow - evidence.observedNS <= 250_000_000
                        && humanBodyRects.contains {
                            Self.faceEvidenceMatches(evidence.evidence.rect, $0)
                        }
                }
                .map { $0.evidence.alignment }
        } else {
            identityAlignments = verifiedNeuralFaces
                .sorted {
                    let lhsArea = $0.rect.width * $0.rect.height
                    let rhsArea = $1.rect.width * $1.rect.height
                    if lhsArea != rhsArea { return lhsArea > rhsArea }
                    return $0.confidence > $1.confidence
                }
                .compactMap { identityFace -> FaceAlignmentEvidence? in
                    identityAlignmentEvidence
                        .filter { evidence in
                            faceVerificationNow >= evidence.observedNS
                                && faceVerificationNow - evidence.observedNS <= 250_000_000
                                && Self.faceEvidenceMatches(evidence.evidence.rect, identityFace.rect)
                        }
                        .max(by: { $0.observedNS < $1.observedNS })?
                        .evidence.alignment
                }
        }
        if !identityAlignments.isEmpty {
            faceIdentityRuntime?.submit(
                pixelBuffer: pixelBuffer,
                alignments: identityAlignments,
                at: faceVerificationNow
            )
        }
        let faceLockDiagnosticState: String
        if verifiedFaceCount > 0 {
            faceLockDiagnosticState = "face_verified"
        } else if !rejectedFaceRects.isEmpty {
            faceLockDiagnosticState = "face_rejected"
        } else if rawFaceCount > 0 {
            faceLockDiagnosticState = "face_unverified"
        } else {
            faceLockDiagnosticState = "face_absent"
        }
        faceLockDiagnosticRecorder?.record(
            pixelBuffer: pixelBuffer,
            at: faceVerificationNow,
            state: faceLockDiagnosticState,
            force: rawFaceCount > 0
        )
        let saliencyNow = monotonicNanoseconds()
        if saliencyNow >= nextSaliencyNS {
            nextSaliencyNS = saliencyNow + 250_000_000
            candidates += (try? systemSaliencyDetector.detect(in: pixelBuffer)) ?? []
        }
        guard !candidates.isEmpty else {
            return .miss
        }
        return .candidates(candidates)
    }

    private func recordFaceInferenceSuccess(at monotonicNS: UInt64) {
        if faceInferenceFailureReported {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "face_neural_engine",
                state: "recovered",
                message: "inference_resumed"
            ))
        }
        lastFaceInferenceSuccessNS = monotonicNS
        faceInferenceFailureReported = false
        faceInferenceStallReported = false
    }

    private func recordFaceInferenceFailure(_ error: Error, at monotonicNS: UInt64) {
        if !faceInferenceFailureReported {
            faceInferenceFailureReported = true
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "face_neural_engine",
                state: "runtime_error",
                message: error.localizedDescription
            ))
        }
        guard !faceInferenceStallReported,
              lastFaceInferenceSuccessNS > 0,
              monotonicNS >= lastFaceInferenceSuccessNS + 2_000_000_000 else {
            return
        }
        faceInferenceStallReported = true
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "face_neural_engine",
            state: "runtime_stalled",
            message: "no_successful_inference_for_2000ms; restarting_capture_session"
        ))
        onFatalVisionFailure?()
    }

    private func isFaceCandidate(_ observation: VisualObservation) -> Bool {
        observation.kind == .human && observation.label == "face"
    }

    private func faceRectanglesOverlap(_ lhs: SOMACore.NormalizedRect, _ rhs: SOMACore.NormalizedRect) -> Bool {
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, right - left) * max(0, bottom - top)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 && intersection / union >= 0.20
    }

    private func writeSceneCandidates(_ candidates: [SceneCandidate], at monotonicNS: UInt64) {
        // The session map deliberately retains offscreen spatial evidence, but
        // serialising every retained hypothesis on every frame turns a long
        // run into an unbounded trace and starves the live vision pipeline.
        // A scene event is therefore a current observation, while the map
        // itself remains in memory for spatial re-acquisition.
        for candidate in candidates where candidate.observedThisFrame {
            let observation = candidate.observation
            writer.write(SceneEvent(
                monotonicNS: monotonicNS,
                sceneID: candidate.id,
                source: observation.source,
                kind: observation.kind,
                label: observation.label,
                confidence: observation.confidence,
                centerX: observation.rect.centerX,
                centerY: observation.rect.centerY,
                width: observation.rect.width,
                height: observation.rect.height,
                observedThisFrame: candidate.observedThisFrame,
                observationCount: candidate.observationCount,
                stabilityMilliseconds: candidate.stabilityMilliseconds,
                sourceCount: candidate.sourceCount,
                actionEligible: candidate.isActionEligible,
                faceActivityEligible: candidate.faceActivityEligible,
                faceVerified: candidate.faceVerificationEligible,
                trackingMinimumCenterX: candidate.trackingBoundary.minimumCenterX,
                trackingMaximumCenterX: candidate.trackingBoundary.maximumCenterX,
                trackingMinimumCenterY: candidate.trackingBoundary.minimumCenterY,
                trackingMaximumCenterY: candidate.trackingBoundary.maximumCenterY,
                azimuthDegrees: candidate.bearing?.azimuthDegrees,
                elevationDegrees: candidate.bearing?.elevationDegrees,
                spatialConfidence: candidate.spatialConfidence,
                lastSeenMilliseconds: candidate.lastSeenMilliseconds
            ))
        }
    }

    private func chooseAttentionCandidate(_ candidates: [VisualObservation]) -> VisualObservation? {
        guard !candidates.isEmpty else { return nil }
        let distribution = ProbabilisticAttentionSelector.infer(
            candidates: candidates,
            previousTarget: worldModel.snapshot(at: monotonicNanoseconds()).target
        )
        lastAttentionEntropy = distribution.normalizedEntropy
        return distribution.selected
    }

    /// Audio and Vision complete on independent workers. A late Vision result
    /// must merge at the current belief time rather than being silently dropped
    /// just because a newer audio callback arrived first.
    private func alignedWorldTimestamp(_ completedNS: UInt64) -> UInt64 {
        max(completedNS, worldModel.snapshot(at: completedNS).monotonicNS)
    }
}

private final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let stateLock = NSLock()
    private var accepting = true
    private let worldModel: PredictiveWorldModel
    private let publisher: BeliefPublisher
    private let visionWorker: VisionWorker
    private let audioAnalyzer: AudioAnalyzer
    private let counters: LatencyCounters
    private let videoOutput: AVCaptureVideoDataOutput
    private let audioOutput: AVCaptureAudioDataOutput
    private let l1AuxiliarySemanticBridge: L1AuxiliarySemanticBridge?
    private let embodimentViewCaptureStore: EmbodimentViewCaptureStore?
    private let diagnosticSnapshotURL: URL?
    private var diagnosticSnapshotWritten = false

    init(
        worldModel: PredictiveWorldModel,
        publisher: BeliefPublisher,
        visionWorker: VisionWorker,
        audioAnalyzer: AudioAnalyzer,
        counters: LatencyCounters,
        videoOutput: AVCaptureVideoDataOutput,
        audioOutput: AVCaptureAudioDataOutput,
        diagnosticSnapshotURL: URL?,
        l1AuxiliarySemanticBridge: L1AuxiliarySemanticBridge?,
        embodimentViewCaptureStore: EmbodimentViewCaptureStore?
    ) {
        self.worldModel = worldModel
        self.publisher = publisher
        self.visionWorker = visionWorker
        self.audioAnalyzer = audioAnalyzer
        self.counters = counters
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        self.diagnosticSnapshotURL = diagnosticSnapshotURL
        self.l1AuxiliarySemanticBridge = l1AuxiliarySemanticBridge
        self.embodimentViewCaptureStore = embodimentViewCaptureStore
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isAccepting else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let now = monotonicNanoseconds()
        if output === videoOutput, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let exposureNS = hostAlignedPresentationTimestamp(
                sampleBuffer: sampleBuffer,
                fallbackNS: now
            )
            writeDiagnosticSnapshot(from: pixelBuffer)
            let belief = worldModel.snapshot(at: now)
            publisher.publish(belief, reason: "fast_prediction")
            l1AuxiliarySemanticBridge?.submit(
                pixelBuffer: pixelBuffer,
                context: L1AuxiliaryFrameContext(captureNS: now, trigger: "visual_sample", belief: belief)
            )
            embodimentViewCaptureStore?.submit(
                pixelBuffer: pixelBuffer,
                captureNS: exposureNS
            )
            visionWorker.submit(pixelBuffer: pixelBuffer, captureNS: now, exposureNS: exposureNS)
            counters.videoCallback(
                at: now,
                processingMS: milliseconds(from: now, to: monotonicNanoseconds())
            )
        } else if output === audioOutput {
            audioAnalyzer.ingest(sampleBuffer, at: now)
        }
    }

    private func writeDiagnosticSnapshot(from pixelBuffer: CVPixelBuffer) {
        guard let diagnosticSnapshotURL, !diagnosticSnapshotWritten else { return }
        diagnosticSnapshotWritten = true
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        try? context.writeJPEGRepresentation(
            of: image,
            to: diagnosticSnapshotURL,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [:]
        )
    }

    func stopAccepting() {
        stateLock.lock()
        accepting = false
        stateLock.unlock()
    }

    private var isAccepting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return accepting
    }
}

private final class SessionObserver: NSObject, @unchecked Sendable {
    private let writer: JSONLWriter
    private let stateLock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "soma.subconscious.session-observer")
    private var tokens: [NSObjectProtocol] = []
    private var accepting = true

    init(session: AVCaptureSession, writer: JSONLWriter, videoDevice: AVCaptureDevice, audioDevice: AVCaptureDevice) {
        self.writer = writer
        super.init()
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
                self?.write("session", "runtime_error", notification)
            },
            center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] notification in
                self?.write("session", "interrupted", notification)
            },
            center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] notification in
                self?.write("session", "interruption_ended", notification)
            },
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: videoDevice, queue: nil) { [weak self] notification in
                self?.write("video", "disconnected", notification)
            },
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: audioDevice, queue: nil) { [weak self] notification in
                self?.write("audio", "disconnected", notification)
            },
            center.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil) { [weak self] notification in
                guard let device = notification.object as? AVCaptureDevice else { return }
                if device.uniqueID == videoDevice.uniqueID { self?.write("video", "reconnected", notification) }
                if device.uniqueID == audioDevice.uniqueID { self?.write("audio", "reconnected", notification) }
            },
        ]
    }

    deinit { stop() }

    func stop() {
        stateLock.lock()
        let activeTokens = tokens
        tokens = []
        stateLock.unlock()
        activeTokens.forEach(NotificationCenter.default.removeObserver)
        deliveryQueue.sync { accepting = false }
    }

    private func write(_ source: String, _ state: String, _ notification: Notification) {
        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
        deliveryQueue.async { [weak self] in
            guard let self, accepting else { return }
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: source,
                state: state,
                message: message
            ))
        }
    }
}

private final class PanoramaPlaceMemoryPersistence: @unchecked Sendable {
    private let url: URL
    private let atlas: SphericalSceneAtlasStore
    private let expectedEncoder: String
    private let expectedRevision: Int
    private let onHealth: @Sendable (String, String) -> Void
    private let lock = NSLock()
    private let writeIntervalNS: UInt64 = 5_000_000_000
    private var lastWriteNS: UInt64 = 0
    private var dirty = false
    private var saveReported = false
    private var failureActive = false

    init(
        url: URL,
        atlas: SphericalSceneAtlasStore,
        expectedEncoder: String,
        expectedRevision: Int,
        onHealth: @escaping @Sendable (String, String) -> Void
    ) {
        self.url = url
        self.atlas = atlas
        self.expectedEncoder = expectedEncoder
        self.expectedRevision = expectedRevision
        self.onHealth = onHealth
    }

    func restore() {
        do {
            guard let snapshot = try SphericalPlaceMemoryFile.load(
                from: url,
                expectedEncoder: expectedEncoder,
                expectedRevision: expectedRevision
            ) else {
                onHealth(
                    "empty",
                    "schema=1; encoder=\(expectedEncoder); revision=\(expectedRevision); path=\(String(url.path.prefix(192)))"
                )
                return
            }
            let restored = atlas.restorePlaceMemory(
                snapshot,
                expectedEncoder: expectedEncoder,
                expectedRevision: expectedRevision
            )
            onHealth(
                "restored",
                "schema=1; encoder=\(expectedEncoder); revision=\(expectedRevision); cells=\(restored); path=\(String(url.path.prefix(192)))"
            )
        } catch {
            onHealth("rejected", String(error.localizedDescription.prefix(192)))
        }
    }

    func recordObservation(at monotonicNS: UInt64) {
        lock.lock()
        dirty = true
        let shouldWrite = lastWriteNS == 0 || monotonicNS - lastWriteNS >= writeIntervalNS
        lock.unlock()
        if shouldWrite { persist(at: monotonicNS, force: false) }
    }

    func flush(at monotonicNS: UInt64) {
        persist(at: monotonicNS, force: true)
    }

    private func persist(at monotonicNS: UInt64, force: Bool) {
        lock.lock()
        guard dirty,
              force || lastWriteNS == 0 || monotonicNS - lastWriteNS >= writeIntervalNS else {
            lock.unlock()
            return
        }
        dirty = false
        lastWriteNS = monotonicNS
        lock.unlock()

        let unixMilliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        let snapshot = atlas.placeMemorySnapshot(
            generatedAtUnixMilliseconds: unixMilliseconds
        )
        do {
            try SphericalPlaceMemoryFile.write(snapshot, to: url)
            lock.lock()
            let report = !saveReported || failureActive
            saveReported = true
            failureActive = false
            lock.unlock()
            if report {
                onHealth(
                    "saved",
                    "schema=1; encoder=\(expectedEncoder); revision=\(expectedRevision); cells=\(snapshot.cells.count); path=\(String(url.path.prefix(192)))"
                )
            }
        } catch {
            lock.lock()
            dirty = true
            let report = !failureActive
            failureActive = true
            lock.unlock()
            if report { onHealth("write_error", String(error.localizedDescription.prefix(192))) }
        }
    }
}

private func run(_ options: Options) throws {
    let termination = GracefulShutdown(signals: [SIGTERM, SIGINT])
    try requestAccess(for: .video, label: "camera")
    try requestAccess(for: .audio, label: "microphone")
    guard let videoDevice = obsbotDevice(for: .video, uniqueID: options.videoID) else {
        throw RuntimeError.unavailable("The requested OBSBOT video device is unavailable")
    }
    guard let audioDevice = obsbotDevice(for: .audio, uniqueID: options.audioID) else {
        throw RuntimeError.unavailable("The requested OBSBOT microphone is unavailable")
    }
    let selectedFormat = try requestLowLatencyFormat(on: videoDevice)

    let writer = try JSONLWriter(
        url: options.outputURL,
        rotationPolicy: options.traceRotationPolicy,
        importantURL: options.importantOutputURL,
        importantRotationPolicy: options.importantRotationPolicy
    )
    defer { writer.close() }
    let liveDiagnostics = LiveDiagnosticsWriter(
        rootURL: options.outputURL.deletingLastPathComponent().deletingLastPathComponent()
    )
    let controlSettings: SOMAControlSettings
    do {
        controlSettings = try SOMAControlSettingsStore(fileURL: options.controlSettingsURL).load()
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "control_settings",
            state: "loaded",
            message: "voice=\(controlSettings.realtimeVoice.rawValue); voice_enabled=\(controlSettings.realtimeVoiceEnabled); led=\(controlSettings.led.responseMode.rawValue); brightness=\(controlSettings.led.brightness); led_signals=\(controlSettings.led.signals.count); admin_enrolled=\(controlSettings.administrator != nil)"
        ))
    } catch {
        controlSettings = .init()
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "control_settings",
            state: "rejected",
            message: String(error.localizedDescription.prefix(192))
        ))
    }
    let identityPresence = IdentityPresenceCoordinator(
        administrator: controlSettings.administrator,
        openWithUnknownIdentity: somaEnvBool("SOMA_L1_OPEN_WITH_UNKNOWN", default: false)
    )
    let presentIdentityRoster = PresentIdentityRoster()
    let latestPrimaryIdentity = LatestIdentityBox()
    // A dedicated always-current identity file lets the menu bar read the
    // present face without scanning a huge trace tail. The trace detail path is
    // <runtime>/detail/<prefix>; the runtime root is two levels up.
    let identityStateURL = options.outputURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("identity-current.json")
    let liveSessionCapabilities = SOMASessionCapabilityStore()
    let spatialAtlas = SphericalSceneAtlasStore()
    let placeEmbeddingEncoder = PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder
    let placeEmbeddingRevision = VNGenerateImageFeaturePrintRequest().revision
    let placeMemoryPersistence = options.panoramaPlaceMemoryURL.map { memoryURL in
        PanoramaPlaceMemoryPersistence(
            url: memoryURL,
            atlas: spatialAtlas,
            expectedEncoder: placeEmbeddingEncoder,
            expectedRevision: placeEmbeddingRevision,
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "panorama_place_memory",
                    state: state,
                    message: message
                ))
            }
        )
    }
    placeMemoryPersistence?.restore()
    let panoramaStatus = PanoramaMapStatusStore()
    let liveVisualContextRelay = LiveVisualContextRelay()
    let auxiliaryReactionRelay = L1AuxiliaryReactionRelay()
    let auxiliaryWakeRelay = L1AuxiliaryWakeRelay()
    let l1AuxiliaryBridgeBox = L1AuxiliaryBridgeBox()
    let poseStoreBox = PoseStoreBox()
    let memoryContextBox = MemoryContextBox()
    let objectKnowledgeStore = ObjectKnowledgeStore()
    let objectRecognitionQueue = ObjectRecognitionQueue(
        maxPending: 4,
        cooldownMilliseconds: 20_000
    ) { item in
        let result = performL1ObjectIdentification(jpeg: item.jpeg)
        let atNS = DispatchTime.now().uptimeNanoseconds
        if let data = result.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let name = obj["name"] as? String {
            let category = obj["category"] as? String ?? ""
            let description = obj["description"] as? String ?? obj["raw"] as? String ?? ""
            objectKnowledgeStore.record(
                name: name,
                category: category,
                description: description,
                panDegrees: item.panDegrees,
                tiltDegrees: item.tiltDegrees,
                atNS: atNS
            )
            // Persist as a durable taste/preference fact tied to the person
            // present (or the owner), so it accumulates into a long-lived
            // profile rather than living only in the transient conversation
            // inventory.
            var factState = "nobody"
            if let entityID = item.personEntityID {
                if let provider = memoryContextBox.provider {
                    let fact = "The user has/collects \(name)\(category.isEmpty ? "" : " (\(category))"). Hobby/taste item worth remembering."
                    let stored = l1StorePersonFact(provider, for: entityID, fact: fact)
                    factState = stored.contains("\"ok\":true") ? "stored" : "store_failed"
                } else {
                    factState = "provider_unavailable"
                }
            }
            writer.write(RuntimeEvent(
                event: "l1.object_recognition",
                monotonicNS: atNS,
                source: "l1_object_recognition",
                state: "recognized",
                message: "name=\(name); category=\(category); person_fact=\(factState)"
            ))
        } else {
            writer.write(RuntimeEvent(
                event: "l1.object_recognition",
                monotonicNS: atNS,
                source: "l1_object_recognition",
                state: "failed",
                message: String(result.prefix(200))
            ))
        }
    }
    let liveCameraFrameRelay = options.l2LiveVoice && controlSettings.realtimeVoiceEnabled
        ? LiveCameraFrameRelay()
        : nil
    let embodimentArbiter = options.embodimentShadowSocketURL.map { _ in
        ShadowEmbodimentArbiter(
            spatialAtlas: spatialAtlas,
            panoramaStatus: panoramaStatus,
            physicalActuationEnabled: options.allowEmbodimentMotorControl
        )
    }
    let l1AuxiliarySemanticBridge: L1AuxiliarySemanticBridge?
    if let pythonURL = options.l1AuxiliaryVLMPythonURL,
       let workerURL = options.l1AuxiliaryVLMWorkerURL,
       let model = options.l1AuxiliaryVLMModel {
        l1AuxiliarySemanticBridge = try L1AuxiliarySemanticBridge(
            pythonURL: pythonURL,
            workerURL: workerURL,
            model: model,
            wakeMinimumScore: somaEnvDouble("SOMA_L0_E2B_WAKE_SCORE", default: 0.65),
            wakeMinimumConfidence: somaEnvDouble("SOMA_L0_E2B_WAKE_CONFIDENCE", default: 0.55),
            wakeRepeatIntervalMilliseconds: UInt64(somaEnvDouble("SOMA_L0_E2B_WAKE_INTERVAL_MS", default: 5_000)),
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "l1_auxiliary_vlm",
                    state: state,
                    message: message
                ))
            },
            onCue: { cue in
                liveVisualContextRelay.record(cue)
                auxiliaryReactionRelay.record(cue.reaction, at: cue.completedNS)
                writer.write(L1AuxiliarySemanticTraceEvent(cue))
                // Parallel object recognition: when L1's visual helper flags an
                // object (presented to the robot, or encountered while scanning
                // an environment with no dominant person) that is worth talking
                // about, enqueue it. A bounded worker drains the queue one at a
                // time with a pacing pause, asking the Gemma model to identify
                // each object in an independent inference — separate from the
                // conscious-stream cycle.
                let presentedObject = cue.situation == .objectPresentation
                    || cue.attentionHint == .object
                let emptyExploration = cue.socialPresence < 0.3
                    && cue.situation != .socialBid
                let worthTalkingAbout = cue.conversationValue
                    >= somaEnvDouble("SOMA_OBJECT_CONVERSATION_THRESHOLD", default: 0.55)
                if (presentedObject || emptyExploration), worthTalkingAbout,
                   let jpeg = l1AuxiliaryBridgeBox.bridge?.latestFrameJPEG() {
                    // Capture where the camera was looking when this object was
                    // detected, so the inventory is spatially grounded. Pose is
                    // read now (not after the async inference) because the scan
                    // keeps moving while Gemma identifies the object.
                    let seenPose = poseStoreBox.store?.latest(
                        at: cue.captureNS,
                        maximumAgeNS: 250_000_000
                    )
                    let posePan: Double? = seenPose.flatMap { $0.panDegrees.isFinite ? $0.panDegrees : nil }
                    let poseTilt: Double? = seenPose.flatMap { $0.pitchDegrees.isFinite ? $0.pitchDegrees : nil }
                    // Attribute to the present person, falling back to the
                    // enrolled owner (administrator) for objects seen while no
                    // one is engaged — a personal home robot treats items in its
                    // own environment as the owner's by default.
                    let personEntityID = identityPresence.recognizedPersonEntityID()
                        ?? controlSettings.administrator?.entityID
                    objectRecognitionQueue.enqueue(ObjectRecognitionQueue.Item(
                        jpeg: jpeg,
                        panDegrees: posePan,
                        tiltDegrees: poseTilt,
                        summary: cue.summary,
                        objectLabel: cue.objectLabel,
                        personEntityID: personEntityID
                    ))
                    writer.write(RuntimeEvent(
                        event: "l1.object_recognition",
                        monotonicNS: cue.completedNS,
                        source: "l1_object_recognition",
                        state: "queued",
                        message: "label=\(cue.objectLabel); conversation_value=\(String(format: "%.2f", cue.conversationValue)); summary=\(String(cue.summary.prefix(80)))"
                    ))
                }
            },
            onInterrupt: { interrupt in
                auxiliaryWakeRelay.record(interrupt)
                writer.write(L1AuxiliarySemanticInterruptTraceEvent(interrupt))
            }
        )
        l1AuxiliaryBridgeBox.bridge = l1AuxiliarySemanticBridge
    } else {
        l1AuxiliarySemanticBridge = nil
    }
    defer { l1AuxiliarySemanticBridge?.stop() }
    let loadedDirectionCalibration: StereoDirectionCalibration?
    if let calibrationURL = options.tdoaCalibrationURL {
        do {
            let calibration = try JSONDecoder().decode(StereoDirectionCalibration.self, from: Data(contentsOf: calibrationURL))
            guard calibration.schemaVersion == 1 else {
                throw RuntimeError.invalidArgument("Unsupported TDOA calibration schema: \(calibration.schemaVersion)")
            }
            loadedDirectionCalibration = calibration
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.invalidArgument("Cannot read TDOA calibration: \(error.localizedDescription)")
        }
    } else {
        loadedDirectionCalibration = nil
    }
    let externalGimbalCalibration: ExternalGimbalCalibration?
    if let calibrationURL = options.externalGimbalCalibrationURL {
        do {
            let calibration = try JSONDecoder().decode(ExternalGimbalCalibration.self, from: Data(contentsOf: calibrationURL))
            guard calibration.isValid else {
                throw RuntimeError.invalidArgument("External gimbal calibration must have schema 1, signs of -1 or 1, pan 0...180, and pitch 0...90")
            }
            externalGimbalCalibration = calibration
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.invalidArgument("Cannot read external gimbal calibration: \(error.localizedDescription)")
        }
    } else {
        externalGimbalCalibration = nil
    }
    let cameraGeometryCalibration: CameraGeometryCalibration?
    if let calibrationURL = options.cameraGeometryCalibrationURL {
        do {
            let calibration = try JSONDecoder().decode(
                CameraGeometryCalibration.self,
                from: Data(contentsOf: calibrationURL)
            )
            guard calibration.isValid else {
                throw RuntimeError.invalidArgument("Camera geometry calibration failed schema, optical, or residual validation")
            }
            cameraGeometryCalibration = calibration
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.invalidArgument("Cannot read camera geometry calibration: \(error.localizedDescription)")
        }
    } else {
        cameraGeometryCalibration = nil
    }
    let calibrationRecorder = options.tdoaCalibrationOutputURL.map { _ in TDOACalibrationRecorder() }
    let worldModel = PredictiveWorldModel()
    let counters = LatencyCounters()
    let poseStore = GimbalPoseStore(geometryCalibration: cameraGeometryCalibration)
    poseStoreBox.store = poseStore
    let panoramaPoseProjection: GimbalPoseProjection = externalGimbalCalibration == nil
        ? .identity
        : .obsbotTiny2Lite
    let panoramaCompositor = try options.panoramaOutputURL.map { outputURL in
        try RollingPanoramaCompositor(
            outputURL: outputURL,
            geometryCaptureDirectoryURL: options.cameraGeometryCaptureDirectoryURL,
            statusStore: panoramaStatus,
            poseProjection: panoramaPoseProjection,
            poseAtCapture: { poseStore.captureAlignedPose(at: $0) },
            onSpatialObservation: { pose, horizontalFieldOfViewDegrees, cameraProjectionModel, dynamicVisionRects, frameQuality, embedding, monotonicNS in
                spatialAtlas.observePanorama(
                    pose: pose,
                    horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                    frameQuality: frameQuality,
                    dynamicVisionRects: dynamicVisionRects,
                    poseProjection: panoramaPoseProjection,
                    cameraProjectionModel: cameraProjectionModel,
                    at: monotonicNS
                )
                guard let embedding else { return nil }
                let recognition = spatialAtlas.observePlace(
                    embedding: embedding,
                    pose: pose,
                    observationQuality: frameQuality,
                    at: monotonicNS
                )
                if recognition != nil {
                    placeMemoryPersistence?.recordObservation(at: monotonicNS)
                }
                return recognition
            },
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "panorama",
                    state: state,
                    message: message
                ))
            }
        )
    }
    defer {
        panoramaCompositor?.stop()
        placeMemoryPersistence?.flush(at: monotonicNanoseconds())
    }
    if let outputURL = options.panoramaOutputURL {
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "panorama",
            state: "configured",
            message: "projection=equirectangular_band; resolution=1024x256; elevation=-45...45; max_hz=4; pose_wait_ms=125; max_pose_distance_ms=120; max_bracket_ms=200; registration=vision_translation; photometric=opencv_channels; seam=opencv_feather; place_encoder=\(placeEmbeddingEncoder); place_revision=\(placeEmbeddingRevision); rolling_output=\(String(outputURL.path.prefix(192)))"
        ))
    }
    if let cameraGeometryCalibration {
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "camera_geometry",
            state: "calibrated",
            message: String(
                format: "schema=%d; fov_mode=%d; horizontal_degrees=%.4f; vertical_degrees=%.4f; pairs=%d; rmse_px=%.3f; p90_px=%.3f",
                cameraGeometryCalibration.schemaVersion,
                cameraGeometryCalibration.fovMode,
                cameraGeometryCalibration.projection.horizontalFieldOfViewDegrees,
                cameraGeometryCalibration.projection.verticalFieldOfViewDegrees,
                cameraGeometryCalibration.fittedPairs,
                cameraGeometryCalibration.calibratedRMSEPixels,
                cameraGeometryCalibration.calibratedP90Pixels
            )
        ))
    }
    let complete = DispatchSemaphore(value: 0)
    let conversationContact = ConversationContactRuntime(
        eyeContactFreshnessMilliseconds: UInt64(somaEnvDouble(
            "SOMA_L0_EYE_CONTACT_FRESHNESS_MS",
            default: 450
        ))
    )
    let faceLockDiagnosticRecorder = try options.faceLockDiagnosticDirectoryURL.map {
        try FaceLockDiagnosticRecorder(directoryURL: $0)
    }
    let embodimentViewCaptureStore = try options.embodimentViewDirectoryURL.map { directoryURL in
        try EmbodimentViewCaptureStore(
            directoryURL: directoryURL,
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "embodiment_view",
                    state: state,
                    message: message
                ))
            }
        )
    }
    let attentionGimbalBridge: AttentionGimbalBridge?
    if let helperURL = options.nativeGimbalHelperURL, let gimbalOutputURL = options.gimbalOutputURL {
        // Native human tracking owns only a confirmed face. Keep the external
        // coverage controller available for the genuine no-human state.
        let autonomousExplorationEnabled = options.allowAutonomousScan
            && options.allowCameraMotion
            && somaEnvBool("SOMA_L0_EXPLORE_ENABLED", default: controlSettings.autonomousExplorationEnabled)
        attentionGimbalBridge = try AttentionGimbalBridge(
            helperURL: helperURL,
            outputURL: gimbalOutputURL,
            traceRotationPolicy: options.gimbalTraceRotationPolicy,
            duration: options.duration,
            externalCalibration: externalGimbalCalibration,
            autonomousScanEnabled: autonomousExplorationEnabled,
            idleExplorationEnabled: autonomousExplorationEnabled,
            nativeHumanTrackingEnabled: options.allowNativeHumanTracking
                && somaEnvBool("SOMA_L0_TRACKING_ENABLED", default: controlSettings.nativeHumanTrackingEnabled),
            ledSettings: controlSettings.led,
            calibrationOutputURL: options.externalGimbalCalibrationOutputURL,
            cameraGeometryCalibrationMode: options.cameraGeometryCaptureDirectoryURL != nil,
            panoramaStripScanMode: options.panoramaStripScan,
            poseStore: poseStore,
            spatialAtlas: spatialAtlas,
            faceLockDiagnosticRecorder: faceLockDiagnosticRecorder,
            embodimentViewCaptureStore: embodimentViewCaptureStore,
            onOutgoingSocialPulse: { monotonicNS in
                conversationContact.issueSocialPulse(at: monotonicNS)
            },
            writer: writer
        )
        attentionGimbalBridge?.recognizedIdentityProvider = {
            latestPrimaryIdentity.snapshot()?.label
        }
        attentionGimbalBridge?.recognizedPersonEntityIDProvider = {
            identityPresence.recognizedPersonEntityID()
        }
        // The auxiliary VLM cue closure runs before the bridge exists, so E2B's
        // proportional reaction is buffered in the relay and attached here once
        // the bridge is up.
        auxiliaryReactionRelay.attach { [weak attentionGimbalBridge] reaction, monotonicNS in
            attentionGimbalBridge?.applyAuxiliaryReaction(reaction, at: monotonicNS)
        }
    } else {
        attentionGimbalBridge = nil
    }
    defer { attentionGimbalBridge?.stop() }
    // On stop (menu bar "Stop SOMA" = launchctl bootout), turn off the camera's
    // built-in AI tracking and park the gimbal before the process exits.
    termination.onTerminate { attentionGimbalBridge?.stop() }
    let liveVoiceLanguageRelay = LiveVoiceInstructionRelay()
    let l1LanguageInstructions = L1LanguageInstructionCache(
        onHealth: { state, message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "l1_language_instruction",
                state: state,
                message: message
            ))
        },
        onReady: { _, directive in
            liveVoiceLanguageRelay.publish(directive)
        }
    )
    let l1ThoughtRelay = L1ThoughtStreamRelay()
    let l1LiveConversationState = L1LiveConversationStateRelay()
    let l1MemoryContext = L1MemoryContextProvider(
        onHealth: { state, message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "l1_memory",
                state: state,
                message: message
            ))
        },
        onPreferredLanguageChanged: { _, languageTag in
            l1LanguageInstructions.prepare(for: languageTag)
        },
        onSocialContactPersisted: { personEntityID in
            l1ThoughtRelay.invalidateMemoryContext(for: personEntityID)
        },
        transcriptRetentionSeconds: somaEnvDouble("SOMA_MEMORY_SHORT_TERM_RETENTION_HOURS", default: 24) * 60 * 60
    )
    memoryContextBox.provider = l1MemoryContext
    if let administratorID = controlSettings.administrator?.entityID {
        l1MemoryContext.warmContext(for: administratorID)
        Task {
            await l1MemoryContext.seedAdministratorContext(
                entityID: administratorID,
                preferredAddress: controlSettings.administrator?.preferredAddress
            )
        }
    }
    let dailyWorldMemoryRelay = L1DailyWorldMemoryRelay()
    let dailyWorldMemoryCollector = AppServerDailyWorldMemoryCollector(
        onWorldMemory: { memory in
            dailyWorldMemoryRelay.publish(memory)
            Task {
                await l1MemoryContext.storeDailyWorldMemory(memory)
            }
        },
        onHealth: { state, message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "daily_world_memory",
                state: state,
                message: message
            ))
        }
    )
    Task {
        let current = await l1MemoryContext.currentDailyWorldMemory()
        dailyWorldMemoryRelay.publish(current)
        guard current == nil,
              await l1MemoryContext.claimDailyWorldMemoryCollectionSlot() else {
            return
        }
        dailyWorldMemoryCollector.collectIfNeeded(current: current)
    }
    defer { dailyWorldMemoryCollector.stop() }
    // Language detected from the participant's most recent speech. L1 and L2
    // both read this so a person who speaks first in a language is answered in
    // that same language even without a stored preferred language.
    let activeLanguage = L1ActiveLanguage()
    let speechInteractionBox = SpeechInteractionBox()
    let liveVoiceLauncher: AppServerLiveVoiceLauncher?
    let liveVoiceBox = LiveVoiceLauncherBox()
    if options.l2LiveVoice, controlSettings.realtimeVoiceEnabled {
        let launcher = AppServerLiveVoiceLauncher(
            voice: controlSettings.realtimeVoice,
            currentCameraImageDataURI: {
                liveCameraFrameRelay?.currentImageDataURI(at: monotonicNanoseconds())
            }
        ) { event in
            let eventNS = monotonicNanoseconds()
            switch event {
            case let .launchRequested(authorization, _):
                l1LiveConversationState.begin()
                liveCameraFrameRelay?.setEnabled(true)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.ready)
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "launch_requested",
                    message: "authorization=\(authorization)"
                ))
            case let .active(threadID, personEntityID):
                l1LiveConversationState.begin()
                conversationContact.markConversationOpened(at: eventNS)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.ready)
                if let personEntityID {
                    Task {
                        await l1MemoryContext.recordSocialContact(
                            .conversationOpened,
                            with: personEntityID,
                            purpose: "A Live voice conversation became active."
                        )
                    }
                }
                if let threadID {
                    l1MemoryContext.beginConversation(
                        threadID: threadID,
                        personEntityID: personEntityID
                    )
                }
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "active",
                    message: threadID.map { "thread_id=\(String($0.prefix(96)))" }
                ))
            case .inputTransportStarted:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "input_streaming",
                    message: "audio_worklet_to_webrtc"
                ))
            case .outputPlaybackReady:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "output_ready",
                    message: "webrtc_audio_to_system_output"
                ))
            case .proactiveOpeningTriggered:
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "opening_triggered",
                    message: "origin=controller_not_user_speech"
                ))
            case .hearingUser:
                l1LiveConversationState.setParticipantSpeaking(true)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.hearingUser)
            case .contextAppended:
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "context_appended",
                    message: nil
                ))
            case .visualContextAttached:
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "visual_context_attached",
                    message: "source=current_camera_frame; retention=live_turn_only"
                ))
            case let .visualContextRejected(reason):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "visual_context_rejected",
                    message: String(reason.prefix(192))
                ))
            case .embodimentMCPReady:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "embodiment_mcp_ready",
                    message: "capture_view_and_identity_tools_available"
                ))
            case let .embodimentMCPUnavailable(reason):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "embodiment_mcp_unavailable",
                    message: String(reason.prefix(192))
                ))
            case let .contextRejected(reason):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "context_rejected",
                    message: String(reason.prefix(192))
                ))
            case let .inputAccepted(characters):
                conversationContact.recordConversationActivity(at: eventNS)
                attentionGimbalBridge?.ingestLiveVoiceTurnAccepted()
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "input_transcript_ready",
                    message: "characters=\(min(characters, 65_535)); transcript_trace=false; local_archive=on_final"
                ))
            case let .transcriptFinalized(threadID, role, text):
                if let threadID {
                    l1MemoryContext.archiveConversationTurn(
                        threadID: threadID,
                        role: role,
                        rawText: text
                    )
                    if role == .user {
                        // Detect the participant's spoken language from their
                        // transcript so L1/L2 answer in the same language, and
                        // switch the on-device recognizer to that locale so
                        // subsequent turns transcribe more accurately.
                        if let detected = activeLanguage.detectAndSet(from: text) {
                            speechInteractionBox.coordinator?.setRecognitionLocale(detected)
                            writer.write(RuntimeEvent(
                                event: "source.health",
                                monotonicNS: monotonicNanoseconds(),
                                source: "l1_language",
                                state: "detected",
                                message: "language=\(detected)"
                            ))
                        }
                        Task {
                            await l1MemoryContext.captureUserPreferences(
                                threadID: threadID,
                                role: role,
                                rawText: text,
                                at: Date()
                            )
                        }
                        // Just-in-time episodic recall: surface shared history
                        // relevant to the user's latest message into the active
                        // conversation so L2 can reference it mid-conversation.
                        Task {
                            let recalled = await l1MemoryContext.recallEpisodesForTurn(
                                threadID: threadID,
                                text: text,
                                at: Date()
                            )
                            guard !recalled.isEmpty else { return }
                            liveVoiceBox.launcher?.appendActiveContext(
                                "Recalled shared history relevant to the user's last message: "
                                    + recalled.joined(separator: " | ")
                            )
                        }
                    }
                }
            case .preparingResponse:
                l1LiveConversationState.setParticipantSpeaking(false)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.preparingResponse)
            case .responding:
                l1LiveConversationState.setParticipantSpeaking(false)
                conversationContact.recordConversationActivity(at: eventNS)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.responding)
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "responding",
                    message: "output_audio=true"
                ))
            case .responseCompleted:
                l1LiveConversationState.setParticipantSpeaking(false)
                conversationContact.recordConversationActivity(at: eventNS)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.ready)
            case let .ended(threadID, personEntityID, reason):
                l1LiveConversationState.end()
                liveCameraFrameRelay?.setEnabled(false)
                conversationContact.closeConversation()
                attentionGimbalBridge?.ingestLiveVoicePresentation(.inactive)
                Task {
                    await l1MemoryContext.endConversation(
                        threadID: threadID,
                        personEntityID: personEntityID,
                        interrupted: false,
                        reason: reason
                    )
                }
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "ended",
                    message: reason
                ))
            case let .failed(threadID, personEntityID, reason):
                l1LiveConversationState.end()
                liveCameraFrameRelay?.setEnabled(false)
                conversationContact.closeConversation()
                attentionGimbalBridge?.ingestLiveVoicePresentation(.inactive)
                if reason == "service_shutdown" {
                    _ = l1MemoryContext.endConversationBeforeShutdown(
                        threadID: threadID,
                        personEntityID: personEntityID,
                        reason: reason
                    )
                } else {
                    Task {
                        await l1MemoryContext.endConversation(
                            threadID: threadID,
                            personEntityID: personEntityID,
                            interrupted: true,
                            reason: reason
                        )
                    }
                }
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "failed",
                    message: String(reason.prefix(192))
                ))
            }
        }
        liveVisualContextRelay.attach(to: launcher)
        liveVoiceLanguageRelay.attach { directive in
            launcher.appendActiveContext(directive)
        }
        liveVoiceBox.launcher = launcher
        liveVoiceLauncher = launcher
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "l2_live_voice",
            state: "configured",
            message: "transport=codex_app_server_webrtc_v3; auth=chatgpt_account; voice=\(controlSettings.realtimeVoice.rawValue); contact_gate=eye_contact_plus_voice_or_social_pulse; user_silence_timeout_seconds=60; visual_context=l1_summary_plus_current_camera_jpeg_per_live_turn; mcp_status_checked=on_session_start; text_context=initial_items_plus_append_text"
        ))
    } else {
        liveVoiceLauncher = nil
    }
    defer { liveVoiceLauncher?.stop() }
    // Gate for promoting a face to a registered anonymous identity: L1 reviews
    // the current frame and decides whether it is a real person worth tracking.
    let anonymousReviewBox = AnonymousReviewBox()
    let liveFrameURL = options.outputURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("live-frame.jpg")
    anonymousReviewBox.reviewer = {
        performL1AnonymousReview(frameURL: liveFrameURL, onHealth: { state, message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "l1_anonymous_review",
                state: state,
                message: message
            ))
        })
    }
    let l1ToolDefinitions: [OllamaToolDefinition] = [
        .init(function: .init(name: "get_person_context", description: "Read the stored context, rapport, and preferences for a person (needs entity_id). Use when you need to recall who this person is before deciding how to engage.", parameters: .init(properties: [
            "entity_id": .init(type: "string", description: "The person's entity_id from present_entity_ids"),
            "reason": .init(type: "string", description: "Why you are calling this tool")
        ], required: ["entity_id", "reason"]))),
        .init(function: .init(name: "add_memory_fact", description: "Store an observed fact about a person (needs entity_id and fact). Use only for a concrete, new observation worth remembering.", parameters: .init(properties: [
            "entity_id": .init(type: "string", description: "The person's entity_id"),
            "fact": .init(type: "string", description: "The observed fact to remember"),
            "reason": .init(type: "string", description: "Why you are recording this fact")
        ], required: ["entity_id", "fact", "reason"]))),
        .init(function: .init(name: "recall_episodes", description: "Recall past conversation episodes relevant to a query (optionally scoped to one person via entity_id). Use when you need to remember what was discussed with this person before, or to ground an opening in shared history.", parameters: .init(properties: [
            "query": .init(type: "string", description: "What you want to remember (topic, person, event)"),
            "entity_id": .init(type: "string", description: "Optional person entity ID to scope the recall"),
            "reason": .init(type: "string", description: "Why you are recalling past episodes")
        ], required: ["query", "reason"]))),
        .init(function: .init(name: "orient_camera", description: "Turn the camera to face a direction. Prefer behavior_directive unless you specifically need to look elsewhere now.", parameters: .init(properties: [
            "direction": .init(type: "string", description: "Compass direction or target to face"),
            "reason": .init(type: "string", description: "Why you are reorienting the camera")
        ], required: ["direction", "reason"]))),
        .init(function: .init(name: "web_search", description: "Search the web and return recent snippets. Use when you are genuinely curious about a topic or need current information relevant to an opening — not for facts the packet already has.", parameters: .init(properties: [
            "query": .init(type: "string", description: "The search query"),
            "max_results": .init(type: "string", description: "Max results (1-10, default 5)"),
            "reason": .init(type: "string", description: "Why you are searching the web")
        ], required: ["query", "reason"]))),
        .init(function: .init(name: "web_fetch", description: "Fetch the main content of a single web page by URL (needs a url from web_search). Use to read deeper into a topic you already found.", parameters: .init(properties: [
            "url": .init(type: "string", description: "The URL to fetch"),
            "reason": .init(type: "string", description: "Why you are fetching this page")
        ], required: ["url", "reason"])))
    ]
    let l1ToolExecutor: @Sendable (String, String) -> String = { [weak attentionGimbalBridge] name, arguments in
        switch name {
        case "get_person_context":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idString = args["entity_id"] as? String,
                  let entityID = UUID(uuidString: idString) else {
                return #"{"ok":false,"error":"missing or invalid entity_id"}"#
            }
            return l1PersonContextSummary(l1MemoryContext, for: entityID)
        case "add_memory_fact":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idString = args["entity_id"] as? String,
                  let entityID = UUID(uuidString: idString),
                  let fact = args["fact"] as? String else {
                return #"{"ok":false,"error":"missing entity_id or fact"}"#
            }
            return l1StorePersonFact(l1MemoryContext, for: entityID, fact: fact)
        case "recall_episodes":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = args["query"] as? String, !query.isEmpty else {
                return #"{"ok":false,"error":"missing query"}"#
            }
            let entityID = (args["entity_id"] as? String).flatMap(UUID.init(uuidString:))
            return l1RecallEpisodes(l1MemoryContext, query: query, entityID: entityID)
        case "orient_camera":
            attentionGimbalBridge?.resumeCoverageScan(priority: .l2)
            return #"{"ok":true,"orient_requested":true}"#
        case "web_search":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = args["query"] as? String, !query.isEmpty else {
                return #"{"ok":false,"error":"missing query"}"#
            }
            let maxResults = (args["max_results"] as? String).flatMap(Int.init) ?? 5
            return performL1WebSearch(query: query, maxResults: max(1, min(10, maxResults)))
        case "web_fetch":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = args["url"] as? String, !url.isEmpty else {
                return #"{"ok":false,"error":"missing url"}"#
            }
            return performL1WebFetch(url: url)
        default:
            return #"{"ok":false,"error":"unknown_tool"}"#
        }
    }
    let l1CuriosityCollector = L1CuriosityCollector { state, message in
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "l1_curiosity",
            state: state,
            message: message
        ))
    }
    do {
        let l1ThoughtStream = try L1PresenceThoughtStream(
            memoryContext: l1MemoryContext,
            runtimeContext: {
                let nowNS = monotonicNanoseconds()
                let atlas = spatialAtlas.snapshot(at: nowNS)
                let panorama = panoramaStatus.snapshot()
                let expiresAt = Date().addingTimeInterval(60)
                let visualOffers: [L1VisualResourceOffer]
                if let panorama,
                   FileManager.default.fileExists(atPath: panorama.imagePath) {
                    visualOffers = [L1VisualResourceOffer(
                        resourceID: "spherical_atlas_current",
                        projection: .sphericalAtlas,
                        description: "Current rolling equirectangular panorama of the reachable camera space.",
                        expiresAt: expiresAt
                    )]
                } else {
                    visualOffers = []
                }
                return L1SituationRuntimeContext(
                    spatialContext: L1SpatialContext(
                        panoramaAvailable: panorama != nil,
                        panoramaRevision: panorama?.revision,
                        reachableCoverageFraction: panorama?.reachableCoverageFraction ?? 0,
                        reachableQualityCoverageFraction: panorama?.reachableQualityCoverageFraction ?? 0,
                        placeRevisits: panorama?.placeRevisits ?? 0,
                        activeSceneEntityCount: atlas.entities.count
                    ),
                    dailyWorldMemory: dailyWorldMemoryRelay.snapshot(),
                    visualResourceOffers: visualOffers
                )
            },
            socialAvailability: {
                l1LiveConversationState.snapshot()
            },
            visualResourceResolver: { requestedIDs in
                guard requestedIDs == ["spherical_atlas_current"],
                      let panorama = panoramaStatus.snapshot(),
                      FileManager.default.isReadableFile(atPath: panorama.imagePath),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: panorama.imagePath),
                      let size = attributes[.size] as? NSNumber,
                      size.intValue > 0,
                      size.intValue <= 2 * 1_024 * 1_024 else {
                    return []
                }
                return [L1VisualResource(
                    resourceID: "spherical_atlas_current",
                    projection: .sphericalAtlas,
                    localPath: panorama.imagePath,
                    expiresAt: Date().addingTimeInterval(60)
                )]
            },
            currentFrameProvider: {
                let frameURL = options.outputURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("live-frame.jpg")
                guard FileManager.default.isReadableFile(atPath: frameURL.path),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: frameURL.path),
                      let size = attributes[.size] as? NSNumber,
                      size.intValue > 0,
                      size.intValue <= 2 * 1_024 * 1_024 else {
                    return nil
                }
                return L1VisualResource(
                    resourceID: "current_frame",
                    projection: .currentView,
                    localPath: frameURL.path,
                    expiresAt: Date().addingTimeInterval(5)
                )
            },
            curiosityContextProvider: {
                let summary = l1CuriosityCollector.contextSummary(limit: 4)
                return summary.isEmpty ? nil : summary
            },
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "l1_situation",
                    state: state,
                    message: message
                ))
                liveDiagnostics.recordL1Event(
                    state: state,
                    message: message,
                    at: monotonicNanoseconds()
                )
            },
            onFrame: { request, frame, presence, completedNS in
                let action = frame.socialDecision?.action.rawValue ?? "no_social_action"
                writer.write(RuntimeEvent(
                    event: "l1.situation",
                    monotonicNS: completedNS,
                    source: "gemma4_31b_cloud",
                    state: "frame",
                    message: "cycle=\(request.cycleID.uuidString.lowercased()); action=\(action); uncertainty=\(String(format: "%.2f", frame.uncertainty))"
                ))
                liveDiagnostics.recordL1Event(
                    state: "frame",
                    message: l1ThoughtStreamMessage(for: frame, action: action),
                    at: completedNS
                )
                guard let opportunity = request.socialOpportunity,
                      let decision = frame.socialDecision else { return }
                guard !l1LiveConversationState.snapshot().conversationActive else {
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: completedNS,
                        source: "l1_situation",
                        state: "decision_suppressed",
                        message: "live_conversation_active"
                    ))
                    return
                }
                do {
                    try L1SocialDecisionValidator().validate(
                        decision,
                        for: opportunity,
                        currentPresence: presence,
                        at: completedNS
                    )
                } catch {
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: completedNS,
                        source: "l1_situation",
                        state: "decision_rejected",
                        message: String(error.localizedDescription.prefix(192))
                    ))
                    return
                }
                guard decision.action != .remainSilent else { return }
                guard identityPresence.hasCurrentParticipant(decision.entityID) else {
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: completedNS,
                        source: "l1_situation",
                        state: "opening_suppressed",
                        message: "participant_no_longer_present"
                    ))
                    return
                }
                if decision.action == .spokenOpening,
                   somaEnvBool("SOMA_L2_PROACTIVE_OPENINGS", default: true) {
                    guard let opening = L1PurposefulOpeningGate.resolve(
                        decision: decision,
                        informationNeeds: request.informationNeeds
                    ) else {
                        writer.write(RuntimeEvent(
                            event: "source.health",
                            monotonicNS: completedNS,
                            source: "l1_situation",
                            state: "opening_suppressed",
                            message: "closed_purpose_required"
                        ))
                        return
                    }
                    let interactionAuthority = identityPresence.authority(for: decision.entityID)
                    let sessionCapability = liveSessionCapabilities.issue(
                        personEntityID: decision.entityID,
                        authority: interactionAuthority,
                        at: completedNS
                    )
                    let context = l1ProactiveInteractionContext(
                        request: request,
                        frame: frame,
                        decision: decision,
                        purpose: opening,
                        languageStartInstruction: l1LanguageInstructions.directive(
                            for: request.preferredLanguageTag
                        ),
                        sessionCapability: sessionCapability,
                        interactionAuthority: interactionAuthority,
                        personMemoryMission: l1MemoryContext.cachedPersonMemoryMission(
                            for: decision.entityID
                        ),
                        objectKnowledge: objectKnowledgeStore.recentSummaries()
                    )
                    // L1 owns social initiation and transfers directly to the
                    // conversation runtime. L0 may mirror the outcome through
                    // embodiment, but cannot become a serial gate for speech.
                    liveVoiceLauncher?.startProactiveOpening(
                        text: opening.question,
                        context: context,
                        personEntityID: decision.entityID,
                        at: completedNS
                    )
                    conversationContact.issueSocialPulse(at: completedNS)
                    Task {
                        await l1MemoryContext.recordSocialContact(
                            .proactiveOpening,
                            with: decision.entityID,
                            purpose: opening.objective
                        )
                    }
                }
                let requestID = "l1-social-\(decision.opportunityID.uuidString.lowercased())"
                // A greeting is a short physical overlay, not a long-lived
                // attention claim. Completion releases this lease sooner; the
                // deadline only guarantees recovery if an attitude sample is
                // unavailable while the gesture starts.
                let expiration = completedNS + 600_000_000
                attentionGimbalBridge?.ingestEmbodimentIntent(.express(
                    requestID: requestID,
                    expression: .greeting,
                    expiresAtNS: expiration
                ))
                if decision.action != .spokenOpening {
                    // The durable event becomes L1 context for later social
                    // judgment; L0 does not impose a relationship cooldown.
                    l1ThoughtRelay.recordNonverbalInvitation(
                        with: decision.entityID,
                        at: completedNS
                    )
                }
            },
            behaviorContextProvider: { [weak attentionGimbalBridge] in
                attentionGimbalBridge?.makeBehaviorContext(at: monotonicNanoseconds())
            },
            onBehaviorDirective: { [weak attentionGimbalBridge] directive, atNS in
                switch directive.action {
                case .resumeScanning, .seekPeople:
                    attentionGimbalBridge?.resumeCoverageScan(priority: .l1)
                case .acknowledgePerson:
                    attentionGimbalBridge?.acknowledgePersonIfEligible(at: atNS)
                case .keepObserving, .none:
                    break
                }
            },
            onBehaviorThought: { frame, atNS in
                var parts: [String] = ["mode=behavior_awareness"]
                if !frame.summary.isEmpty {
                    parts.append(frame.summary)
                }
                if let stream = frame.thoughtState?.streamOfConsciousness, !stream.isEmpty {
                    parts.append("stream: \(stream)")
                }
                if let hypothesis = frame.thoughtState?.workingHypothesis, !hypothesis.isEmpty {
                    parts.append("hypothesis: \(hypothesis)")
                }
                if let directive = frame.behaviorDirective {
                    parts.append("directive: \(directive.action.rawValue)")
                }
                liveDiagnostics.recordL1Event(
                    state: "thought",
                    message: parts.joined(separator: " · "),
                    at: atNS
                )
            },
            toolDefinitions: l1ToolDefinitions,
            toolExecutor: l1ToolExecutor,
            onCuriosityNeeds: { needs in
                l1CuriosityCollector.registerTopics(from: needs)
            },
            onMemoryProposals: { proposals, entityID in
                Task {
                    await l1MemoryContext.proposeMemories(proposals, personEntityID: entityID)
                }
            },
            activeLanguageProvider: {
                activeLanguage.recent()
            }
        )
        l1ThoughtRelay.install(l1ThoughtStream)
        // E2B's wake proposals are buffered in the relay (the interrupt closure
        // runs before the L1 stream exists) and forwarded here once the stream is
        // up, so the primary L1 cycle can accept or revise each proposal.
        auxiliaryWakeRelay.attach { [weak l1ThoughtStream] interrupt in
            l1ThoughtStream?.wakeFromAuxiliary(interrupt)
        }
        l1CuriosityCollector.start()
    } catch {
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "l1_situation",
            state: "unavailable",
            message: String(error.localizedDescription.prefix(192))
        ))
    }
    defer { l1ThoughtRelay.stop() }
    let embodimentMotorAdapter: CognitiveEmbodimentMotorAdapter?
    if options.allowEmbodimentMotorControl {
        guard let attentionGimbalBridge else {
            throw RuntimeError.configuration("Embodiment motor control requires the L0 gimbal bridge")
        }
        embodimentMotorAdapter = CognitiveEmbodimentMotorAdapter(
            bridge: attentionGimbalBridge,
            writer: writer
        )
    } else {
        embodimentMotorAdapter = nil
    }
    if let embodimentViewCaptureStore,
       let embodimentArbiter,
       let embodimentMotorAdapter {
        embodimentViewCaptureStore.setTerminalHandler { [weak embodimentArbiter, weak embodimentMotorAdapter] requestID, succeeded in
            _ = embodimentArbiter?.completeMotorGoal(
                requestID: requestID,
                at: monotonicNanoseconds()
            )
            embodimentMotorAdapter?.completeCapture(
                requestID: requestID,
                succeeded: succeeded
            )
        }
    }
    defer { embodimentMotorAdapter?.stop() }
    let embodimentShadowServer: EmbodimentShadowSocketServer?
    if let socketURL = options.embodimentShadowSocketURL {
        guard let embodimentArbiter else {
            throw RuntimeError.configuration("Embodiment arbiter initialization failed")
        }
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            arbiter: embodimentArbiter,
            onDecision: { request, decision in
                writer.write(EmbodimentShadowTraceEvent(decision))
                embodimentMotorAdapter?.submit(request, decision: decision)
            },
            captureResultProvider: { requestID, monotonicNS in
                embodimentViewCaptureStore?.result(requestID: requestID, at: monotonicNS)
            },
            personContextProvider: { request in
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<PersonContextSnapshot>()
                Task {
                    do {
                        resultBox.set(.success(try await l1MemoryContext.applyPersonContext(request)))
                    } catch {
                        resultBox.set(.failure(error))
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                let result = resultBox.get() ?? .failure(EmbodimentIPCError.timeout)
                if case let .success(snapshot) = result {
                    writer.write(RuntimeEvent(
                        event: "person_context.mission",
                        monotonicNS: monotonicNanoseconds(),
                        source: "person_context_mcp",
                        state: snapshot.mission.isSatisfied ? "satisfied" : "pending",
                        message: "operation=\(request.operation.rawValue); missing_required=\(snapshot.mission.missingRequiredKeys.count); recommended=\(snapshot.mission.recommendedKeys.count)"
                    ))
                }
                if request.operation != .get, case let .success(snapshot) = result,
                   let personEntityID = request.personEntityID {
                    l1ThoughtRelay.invalidateMemoryContext(for: personEntityID)
                    writer.write(RuntimeEvent(
                        event: "person_context.updated",
                        monotonicNS: monotonicNanoseconds(),
                        source: "person_context_mcp",
                        state: request.operation.rawValue,
                        message: "storage=encrypted_local; disclosure=remote_summary_allowed; explicit_confirmation=true"
                    ))
                    switch request.operation {
                    case .setPreferredLanguage, .clearPreferredLanguage:
                        if let languageTag = snapshot.preferredLanguageTag {
                            l1LanguageInstructions.prepare(for: languageTag)
                            if let directive = l1LanguageInstructions.directive(for: languageTag) {
                                liveVoiceLauncher?.appendActiveContext(directive)
                            }
                        } else {
                            liveVoiceLauncher?.appendActiveContext(
                                "The participant has cleared their explicit language preference. Follow the language they use in the conversation."
                            )
                        }
                    default:
                        break
                    }
                }
                return result
            },
            recallEpisodesProvider: { request in
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<[String]>()
                Task {
                    let recalled = await l1MemoryContext.recallEpisodes(
                        query: request.query ?? "",
                        entityID: request.personEntityID,
                        at: Date()
                    )
                    resultBox.set(.success(recalled))
                    semaphore.signal()
                }
                semaphore.wait()
                return resultBox.get() ?? .failure(EmbodimentIPCError.timeout)
            },
            identityRosterProvider: { query in
                let now = monotonicNanoseconds()
                let presence = presentIdentityRoster.entries(at: now)
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<[PersonContextSnapshot]>()
                Task {
                    do {
                        let values = try await l1MemoryContext.registeredPersonContexts()
                        resultBox.set(.success(values))
                    } catch {
                        resultBox.set(.failure(error))
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                let contexts: [UUID: PersonContextSnapshot]
                switch resultBox.get() ?? .failure(EmbodimentIPCError.timeout) {
                case let .success(values):
                    contexts = Dictionary(uniqueKeysWithValues: values.map { ($0.personEntityID, $0) })
                case let .failure(error):
                    return .failure(error)
                }
                let entries: [IdentityRosterEntry]
                switch query {
                case .present:
                    entries = presence.map { entry in
                        IdentityRosterEntry(
                            personEntityID: entry.identity.entityID,
                            recognitionKind: entry.identity.kind.rawValue,
                            confidence: entry.confidence,
                            lastSeenMillisecondsAgo: entry.ageMS,
                            personContext: contexts[entry.identity.entityID]
                        )
                    }
                case .registered:
                    entries = contexts.values.map { context in
                        IdentityRosterEntry(
                            personEntityID: context.personEntityID,
                            recognitionKind: "registered",
                            personContext: context
                        )
                    }.sorted { $0.personEntityID.uuidString < $1.personEntityID.uuidString }
                }
                return .success(.init(query: query, entries: entries))
            },
            identityEnrollmentProvider: { request in
                guard request.confirmedByUser,
                      let handle = presentIdentityRoster.promoteableAnonymousHandle(
                          for: request.personEntityID,
                          at: monotonicNanoseconds()
                      ) else {
                    return .failure(RuntimeError.unavailable("present_anonymous_identity_not_available"))
                }
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<(entityID: UUID, referenceCount: Int)>()
                Task {
                    do {
                        let result = try await FaceIdentityRuntime.promoteAnonymousIdentity(handle: handle)
                        resultBox.set(.success(result))
                    } catch {
                        resultBox.set(.failure(error))
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                switch resultBox.get() ?? .failure(EmbodimentIPCError.timeout) {
                case let .success(result):
                    guard result.entityID == request.personEntityID else {
                        return .failure(RuntimeError.unavailable("identity_enrollment_reference_mismatch"))
                    }
                    writer.write(RuntimeEvent(
                        event: "identity.enrollment",
                        monotonicNS: monotonicNanoseconds(),
                        source: "person_identity_mcp",
                        state: "persistent_profile_created",
                        message: "references=\(result.referenceCount); metadata_disclosure=person_context_only"
                    ))
                    return .success(.init(
                        personEntityID: result.entityID,
                        referenceCount: result.referenceCount
                    ))
                case let .failure(error):
                    return .failure(error)
                }
            },
            indicatorCalibrationHandler: { preset in
                guard let attentionGimbalBridge else {
                    return .failure(RuntimeError.unavailable("The local LED bridge is unavailable"))
                }
                return attentionGimbalBridge.calibrateIndicator(preset: preset)
            },
            sessionAuthorizationProvider: { token, scope in
                switch liveSessionCapabilities.authorize(
                    token: token,
                    scope: scope,
                    at: monotonicNanoseconds()
                ) {
                case .success:
                    return .success(())
                case let .failure(error):
                    return .failure(error)
                }
            },
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "embodiment",
                    state: state,
                    message: message
                ))
            }
        )
        try server.start()
        embodimentShadowServer = server
    } else {
        embodimentShadowServer = nil
    }
    defer { embodimentShadowServer?.stop() }
    let embodimentSceneBridge = embodimentArbiter.map {
        EmbodimentSceneBridge(
            arbiter: $0,
            writer: writer,
            onSnapshot: { embodimentMotorAdapter?.update($0) }
        )
    }
    defer { embodimentSceneBridge?.stop() }
    let publisher = BeliefPublisher(writer: writer) { belief, reason in
        attentionGimbalBridge?.ingest(belief, reason: reason)
    }
    let visionWorker = VisionWorker(
        worldModel: worldModel,
        publisher: publisher,
        writer: writer,
        counters: counters,
        poseStore: poseStore,
        externalGimbalCalibration: externalGimbalCalibration,
        faceLockDiagnosticRecorder: faceLockDiagnosticRecorder,
        panoramaCompositor: panoramaCompositor,
        onSceneCandidates: { candidates, monotonicNS in
            conversationContact.observe(candidates, at: monotonicNS)
            embodimentSceneBridge?.submit(candidates, at: monotonicNS)
            attentionGimbalBridge?.ingestSceneCandidates(candidates, at: monotonicNS)
            liveDiagnostics.recordSceneCandidates(candidates, at: monotonicNS)
        },
        onCoverage: { pose, horizontalFieldOfViewDegrees, poseProjection, cameraProjectionModel, monotonicNS in
            attentionGimbalBridge?.ingestCoverage(
                pose: pose,
                horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                poseProjection: poseProjection,
                cameraProjectionModel: cameraProjectionModel,
                at: monotonicNS
            )
        },
        onCameraFrame: { pixelBuffer, captureNS in
            liveCameraFrameRelay?.record(pixelBuffer: pixelBuffer, capturedAtNS: captureNS)
            liveDiagnostics.recordCameraFrame(pixelBuffer, at: captureNS)
        },
        onIdentityDecision: { decision, faceRect, isPrimaryFace, monotonicNS in
            presentIdentityRoster.record(decision, at: monotonicNS)
            liveDiagnostics.recordIdentity(
                rect: faceRect,
                label: identityDiagnosticLabel(for: decision, administrator: controlSettings.administrator),
                at: monotonicNS
            )
            guard isPrimaryFace else { return }
            latestPrimaryIdentity.update(
                state: decision.state,
                subject: decision.opaqueSubject,
                label: identityDiagnosticLabel(for: decision, administrator: controlSettings.administrator),
                confidence: decision.confidence,
                observedNS: monotonicNS
            )
            writeIdentityState(
                state: decision.state,
                subject: decision.opaqueSubject,
                confidence: decision.confidence,
                to: identityStateURL
            )
            for update in identityPresence.observe(decision, at: monotonicNS) {
                writer.write(identityPresenceRuntimeEvent(for: update.transition, at: monotonicNS))
                if case let .arrived(identity) = update.transition {
                    attentionGimbalBridge?.enqueueAcknowledgment(for: identity.entityID, at: monotonicNS)
                }
                if case let .departed(identity) = update.transition {
                    l1ThoughtRelay.depart(identity.entityID)
                    attentionGimbalBridge?.clearAcknowledgment(for: identity.entityID)
                }
                if update.participant?.authority == .administrator {
                    writer.write(RuntimeEvent(
                        event: "administrator.identity",
                        monotonicNS: monotonicNS,
                        source: "administrator_identity",
                        state: "verified_presence",
                        message: "recognized_local_profile; metadata_disclosure=local_only"
                    ))
                }
                if let l1Decision = update.l1Decision {
                    l1ThoughtRelay.observe(
                        l1Decision,
                        label: identityDiagnosticLabel(for: decision, administrator: controlSettings.administrator),
                        at: monotonicNS
                    )
                }
            }
        },
        onIdentityPresenceEvidence: { verifiedFacePresent, monotonicNS in
            if !verifiedFacePresent {
                latestPrimaryIdentity.clear()
                clearIdentityState(at: identityStateURL)
            }
            for update in identityPresence.observeVerifiedFace(verifiedFacePresent, at: monotonicNS) {
                writer.write(identityPresenceRuntimeEvent(for: update.transition, at: monotonicNS))
                if case let .departed(identity) = update.transition {
                    l1ThoughtRelay.depart(identity.entityID)
                    attentionGimbalBridge?.clearAcknowledgment(for: identity.entityID)
                }
            }
        },
        onFatalVisionFailure: {
            complete.signal()
        },
        anonymousReviewProvider: { anonymousReviewBox.approve() },
        pupilCenteringThreshold: somaEnvDouble("SOMA_L0_EYE_CONTACT_PUPIL_THRESHOLD", default: 1.0)
    )
    let eventImportanceModel = EventImportanceModel()
    let speechInteraction: LocalSpeechInteractionCoordinator?
    if let localeIdentifier = options.localSpeechLocaleIdentifier {
        speechInteraction = try LocalSpeechInteractionCoordinator(
            localeIdentifier: localeIdentifier,
            codexBridgeURL: options.l2CodexBridgeURL,
            codexWorkingDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SOMA/L2Codex", isDirectory: true),
            onState: { state in
                let stateNS = monotonicNanoseconds()
                switch state {
                case let .recognitionCompleted(_, _, _, _, _, _, handedToL2):
                    if handedToL2 {
                        conversationContact.markConversationOpened(at: stateNS)
                    }
                case .l2Completed:
                    conversationContact.recordConversationActivity(at: stateNS)
                case .l2Failed:
                    conversationContact.closeConversation()
                case .turnStarted, .turnCancelled, .recognitionFailed,
                     .speechStarted, .speechCompleted, .speechCancelled:
                    break
                }
                attentionGimbalBridge?.ingestSpeechInteractionState(state)
                writer.write(SpeechInteractionTraceEvent(
                    state,
                    at: stateNS
                ))
            }
        )
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "local_speech_recognition",
            state: "configured",
            message: "engine=speech_analyzer; locale=\(String(localeIdentifier.prefix(32))); on_device=true; audio_persistence=false; pre_roll_ms=900; l2_handoff=\(options.l2CodexBridgeURL != nil)"
        ))
        speechInteractionBox.coordinator = speechInteraction
    } else {
        speechInteraction = nil
    }
    defer { speechInteraction?.stop() }
    let voiceWorker = try AudioVADWorker(
        onEvidence: { evidence, frame, completedNS in
            if evidence.inferenceMS > 0 {
                counters.neuralVADInference(
                    inferenceMS: evidence.inferenceMS,
                    windowEndToEvidenceMS: milliseconds(from: frame.captureNS, to: completedNS)
                )
            }
            let belief = worldModel.ingestVoice(
                active: evidence.active,
                confidence: evidence.probability,
                at: completedNS
            )
            if evidence.active, evidence.changed {
                conversationContact.recordConversationActivity(at: completedNS)
            }
            let openingAuthorization = evidence.active && evidence.changed
                ? conversationContact.authorizeSpeechOnset(at: completedNS)
                : nil
            if evidence.changed, options.l2LiveVoice {
                attentionGimbalBridge?.ingestLiveVoiceUserActivity(active: evidence.active)
            }
            let recognizedParticipant = identityPresence.currentParticipant()
            let interactionParticipant = recognizedParticipant ?? InteractionParticipant(
                entityID: UUID(),
                authority: .participant
            )
            let personContextAvailable = recognizedParticipant != nil
            let recognizedPersonEntityID = recognizedParticipant?.entityID
            let preferredLanguageTag = recognizedPersonEntityID.flatMap {
                l1MemoryContext.cachedPreferredLanguage(for: $0)
            } ?? activeLanguage.recent()
            let languageStartInstruction = l1LanguageInstructions.directive(for: preferredLanguageTag)
            if let openingAuthorization {
                let sessionCapability = liveSessionCapabilities.issue(
                    personEntityID: interactionParticipant.entityID,
                    authority: interactionParticipant.authority,
                    at: completedNS
                )
                let context = speechInteractionContext(
                    from: belief,
                    visualSummary: liveVisualContextRelay.latestSummary,
                    identityReference: personContextAvailable ? identityPresence.interactionReference() : nil,
                    participant: interactionParticipant,
                    personContextAvailable: personContextAvailable,
                    sessionCapability: sessionCapability,
                    personMemoryMission: recognizedPersonEntityID.flatMap {
                        l1MemoryContext.cachedPersonMemoryMission(for: $0)
                    },
                    preferredLanguageTag: preferredLanguageTag,
                    languageStartInstruction: languageStartInstruction,
                    objectKnowledge: objectKnowledgeStore.recentSummaries()
                )
                liveVoiceLauncher?.startIfNeeded(
                    authorization: openingAuthorization.rawValue,
                    context: context,
                    personEntityID: interactionParticipant.entityID,
                    at: completedNS
                )
            }
            if let speechInteraction {
                let sessionCapability = liveSessionCapabilities.issue(
                    personEntityID: interactionParticipant.entityID,
                    authority: interactionParticipant.authority,
                    at: completedNS
                )
                guard let context = speechInteractionContext(
                    from: belief,
                    visualSummary: liveVisualContextRelay.latestSummary,
                    identityReference: personContextAvailable ? identityPresence.interactionReference() : nil,
                    participant: interactionParticipant,
                    personContextAvailable: personContextAvailable,
                    sessionCapability: sessionCapability,
                    personMemoryMission: recognizedPersonEntityID.flatMap {
                        l1MemoryContext.cachedPersonMemoryMission(for: $0)
                    },
                    preferredLanguageTag: preferredLanguageTag,
                    languageStartInstruction: languageStartInstruction,
                    objectKnowledge: objectKnowledgeStore.recentSummaries()
                ) else { return }
                let wake = openingAuthorization.flatMap {
                    speechInteractionWake(
                        model: eventImportanceModel,
                        belief: belief,
                        voiceConfidence: evidence.probability,
                        authorization: $0,
                        at: completedNS
                    )
                }
                speechInteraction.observeVAD(
                    active: evidence.active,
                    at: completedNS,
                    authorizedWake: wake,
                    context: context
                )
            }
            guard evidence.changed else { return }
            writer.write(VoiceEvent(
                monotonicNS: completedNS,
                source: "coreml_vad",
                active: evidence.active,
                confidence: evidence.probability,
                levelDB: frame.levelDB
            ))
            publisher.publish(
                belief,
                reason: evidence.active ? "voice_onset" : "voice_offset",
                force: true
            )
        },
        onError: { message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "neural_vad",
                state: "runtime_error",
                message: message
            ))
        }
    )
    let audioAnalyzer = AudioAnalyzer(
        worldModel: worldModel,
        publisher: publisher,
        writer: writer,
        counters: counters,
        voiceWorker: voiceWorker,
        directionEstimator: loadedDirectionCalibration.map { StereoTDOAEstimator(calibration: $0) },
        calibrationRecorder: calibrationRecorder,
        speechInteraction: speechInteraction,
        liveVoiceLauncher: liveVoiceLauncher
    )
    let session = AVCaptureSession()

    let videoInput = try AVCaptureDeviceInput(device: videoDevice)
    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]

    session.beginConfiguration()
    guard session.canAddInput(videoInput), session.canAddInput(audioInput),
          session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else {
        throw RuntimeError.configuration("Cannot create an OBSBOT video/audio capture session")
    }
    session.addInput(videoInput)
    session.addInput(audioInput)
    session.addOutput(videoOutput)
    session.addOutput(audioOutput)
    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }

    let delegate = CaptureDelegate(
        worldModel: worldModel,
        publisher: publisher,
        visionWorker: visionWorker,
        audioAnalyzer: audioAnalyzer,
        counters: counters,
        videoOutput: videoOutput,
        audioOutput: audioOutput,
        diagnosticSnapshotURL: options.diagnosticSnapshotURL,
        l1AuxiliarySemanticBridge: l1AuxiliarySemanticBridge,
        embodimentViewCaptureStore: embodimentViewCaptureStore
    )
    let videoQueue = DispatchQueue(label: "soma.subconscious.video", qos: .userInteractive)
    let audioQueue = DispatchQueue(label: "soma.subconscious.audio", qos: .userInteractive)
    videoOutput.setSampleBufferDelegate(delegate, queue: videoQueue)
    audioOutput.setSampleBufferDelegate(delegate, queue: audioQueue)
    session.commitConfiguration()
    let observer = SessionObserver(session: session, writer: writer, videoDevice: videoDevice, audioDevice: audioDevice)

    writer.write(RuntimeEvent(
        event: "source.health",
        monotonicNS: monotonicNanoseconds(),
        source: "video",
        state: selectedFormat.applied ? "selected" : "configuration_fallback",
        message: "\(identity(videoDevice).name); requested=\(selectedFormat.requested); \(selectedFormat.detail)"
    ))
    writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio", state: "selected", message: "\(identity(audioDevice).name)"))
    if let directoryURL = options.faceLockDiagnosticDirectoryURL {
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "face_lock_diagnostics",
            state: "enabled",
            message: "jpeg_dir=\(directoryURL.path); nonface_sample_ms=500; face_candidate_max_hz=10; maximum_images=60"
        ))
    }
    let neuralVADConfiguration = String(
        format: "model=silero_vad_unified_256ms_v6.2.1; compute_units=%@; warmup_ms=%.2f; window_ms=260; threshold=0.50",
        voiceWorker.computeUnits,
        voiceWorker.warmupMS
    )
    writer.write(RuntimeEvent(
        event: "source.health",
        monotonicNS: monotonicNanoseconds(),
        source: "neural_vad",
        state: "configured",
        message: neuralVADConfiguration
    ))
    if loadedDirectionCalibration != nil {
        writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio_tdoa", state: "configured", message: "calibrated_stereo_tdoa"))
    } else if calibrationRecorder != nil {
        writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio_tdoa", state: "calibrating", message: "three_positions=left,center,right"))
    } else {
        writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio_tdoa", state: "calibration_required", message: "direction remains unknown until a three-position calibration is supplied"))
    }
    visionWorker.start()
    session.startRunning()
    let startedNS = monotonicNanoseconds()
    if options.guidedScenario, let firstPhase = GuidedScenarioPhase.phases.first {
        writer.write(RuntimeEvent(
            event: "scenario.phase",
            monotonicNS: startedNS,
            source: "guided_scenario",
            state: firstPhase.state,
            message: firstPhase.instruction
        ))
    }
    if let calibrationRecorder, let firstPhase = TDOACalibrationPhase.phases.first {
        calibrationRecorder.setPosition(firstPhase.position)
        writer.write(RuntimeEvent(
            event: "scenario.phase",
            monotonicNS: startedNS,
            source: "tdoa_calibration",
            state: firstPhase.position.rawValue,
            message: firstPhase.instruction
        ))
    }
    var nextScenarioPhaseIndex = options.guidedScenario ? 1 : GuidedScenarioPhase.phases.count
    var nextTDOAPhaseIndex = calibrationRecorder == nil ? TDOACalibrationPhase.phases.count : 1
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "soma.subconscious.metrics"))
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let now = monotonicNanoseconds()
        let elapsed = Double(now - startedNS) / 1_000_000_000
        while nextScenarioPhaseIndex < GuidedScenarioPhase.phases.count,
              elapsed >= GuidedScenarioPhase.phases[nextScenarioPhaseIndex].startsAfterSeconds {
            let phase = GuidedScenarioPhase.phases[nextScenarioPhaseIndex]
            writer.write(RuntimeEvent(
                event: "scenario.phase",
                monotonicNS: now,
                source: "guided_scenario",
                state: phase.state,
                message: phase.instruction
            ))
            nextScenarioPhaseIndex += 1
        }
        while nextTDOAPhaseIndex < TDOACalibrationPhase.phases.count,
              elapsed >= TDOACalibrationPhase.phases[nextTDOAPhaseIndex].startsAfterSeconds {
            let phase = TDOACalibrationPhase.phases[nextTDOAPhaseIndex]
            calibrationRecorder?.setPosition(phase.position)
            writer.write(RuntimeEvent(
                event: "scenario.phase",
                monotonicNS: now,
                source: "tdoa_calibration",
                state: phase.position.rawValue,
                message: phase.instruction
            ))
            nextTDOAPhaseIndex += 1
        }
        writer.write(counters.snapshot(at: now))
        // Re-emit the current primary-face identity so it never scrolls out of
        // the menu bar's short trace-tail read window while the face is present.
        if let identity = latestPrimaryIdentity.snapshot() {
            writer.write(FaceIdentityEvent(
                monotonicNS: identity.observedNS,
                state: identity.state,
                subject: identity.subject,
                confidence: identity.confidence,
                inferenceMS: 0
            ))
        }
        publisher.publish(worldModel.snapshot(at: now), reason: "periodic")
        if options.duration > 0, elapsed >= options.duration {
            if options.guidedScenario {
                writer.write(RuntimeEvent(
                    event: "scenario.completed",
                    monotonicNS: now,
                    source: "guided_scenario",
                    state: "capture_accepting_stopped",
                    message: "scheduled_seconds=50"
                ))
            }
            delegate.stopAccepting()
            timer.cancel()
            complete.signal()
        }
    }
    timer.resume()
    complete.wait()
    timer.cancel()
    session.stopRunning()
    delegate.stopAccepting()
    videoQueue.sync {}
    audioQueue.sync {}
    visionWorker.stop()
    audioAnalyzer.stop()
    l1AuxiliarySemanticBridge?.stop()
    observer.stop()
    // Finalize a live conversation while the runtime writer and L1 relay are
    // still available; the later defer remains the error-path backstop.
    liveVoiceLauncher?.stop()
    let stoppedNS = monotonicNanoseconds()
    if let calibrationRecorder, let calibrationOutputURL = options.tdoaCalibrationOutputURL {
        let diagnosticSummary = calibrationRecorder.summary()
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: stoppedNS,
            source: "audio_tdoa",
            state: "calibration_summary",
            message: diagnosticSummary
        ))
        if let calibration = calibrationRecorder.makeCalibration() {
            try write(calibration, to: calibrationOutputURL)
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: stoppedNS,
                source: "audio_tdoa",
                state: "calibration_written",
                message: "\(calibrationOutputURL.path); sample_rate_hz=\(calibration.sampleRateHz)"
            ))
        } else {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: stoppedNS,
                source: "audio_tdoa",
                state: "calibration_failed",
                message: "Need at least three high-correlation speech measurements at left, center, and right; \(diagnosticSummary)"
            ))
        }
    }
    writer.write(counters.snapshot(at: stoppedNS))
    publisher.publish(worldModel.snapshot(at: stoppedNS), reason: "stopped", force: true)
    let lateEventsDropped = writer.drain()
    writer.write(RuntimeEvent(
        event: "source.health",
        monotonicNS: stoppedNS,
        source: "session",
        state: "stopped",
        message: "late_events_dropped=\(lateEventsDropped)"
    ))
    withExtendedLifetime(observer) {}
    print("Wrote subconscious trace: \(options.outputURL.path)")
}

private func write(_ calibration: StereoDirectionCalibration, to url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw RuntimeError.invalidArgument("TDOA calibration output already exists: \(url.path)")
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(calibration).write(to: url, options: .atomic)
}

private func requestLowLatencyFormat(on device: AVCaptureDevice) throws -> VideoConfiguration {
    let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, Int32, Int32, Double)? in
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let maximumFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        guard dimensions.width == 1280, dimensions.height == 720, maximumFPS >= 30 else { return nil }
        return (format, dimensions.width, dimensions.height, maximumFPS)
    }
    guard let selected = candidates.max(by: { $0.3 < $1.3 }) else {
        throw RuntimeError.configuration("The OBSBOT camera does not expose 1280x720 at 30 fps")
    }
    let requested = "\(selected.1)x\(selected.2)@30fps"
    do {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = selected.0
        let frameDuration = selected.0.videoSupportedFrameRateRanges
            .min(by: { abs($0.maxFrameRate - 30) < abs($1.maxFrameRate - 30) })?
            .minFrameDuration ?? CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        return VideoConfiguration(requested: requested, applied: true, detail: "active_format_applied")
    } catch {
        return VideoConfiguration(
            requested: requested,
            applied: false,
            detail: "active_format_unavailable=\(error.localizedDescription)"
        )
    }
}

private func obsbotDevice(for mediaType: AVMediaType, uniqueID: String) -> AVCaptureDevice? {
    let matches: (AVCaptureDevice) -> Bool = {
        $0.uniqueID == uniqueID && $0.localizedName.range(of: "obsbot", options: .caseInsensitive) != nil
    }
    if mediaType == .video {
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown],
            mediaType: mediaType,
            position: .unspecified
        ).devices.first(where: matches)
    }
    if #available(macOS 14.0, *) {
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: mediaType,
            position: .unspecified
        ).devices.first(where: matches)
    }
    return AVCaptureDevice.devices(for: mediaType).first(where: matches)
}

private func requestAccess(for mediaType: AVMediaType, label: String) throws {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized:
        return
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        let result = AccessResult()
        AVCaptureDevice.requestAccess(for: mediaType) { granted in
            result.set(granted)
            semaphore.signal()
        }
        semaphore.wait()
        guard result.value else { throw RuntimeError.unauthorized("Access to the \(label) was not granted") }
    case .denied, .restricted:
        throw RuntimeError.unauthorized("Access to the \(label) is denied or restricted")
    @unknown default:
        throw RuntimeError.unauthorized("Access to the \(label) has an unknown authorization state")
    }
}

private func speechInteractionWake(
    model: EventImportanceModel,
    belief: BeliefSnapshot,
    voiceConfidence: Double,
    authorization: ConversationOpeningAuthorization,
    at monotonicNS: UInt64
) -> HumanInteractionWakeRequest? {
    let target = belief.targetStatus == .tracked ? belief.target : nil
    if authorization == .eyeContact {
        guard let target, target.isFaceMotorTarget else { return nil }
    }
    let eventID = "voice-contact-\(monotonicNS)"
    let visualConfidence = target?.confidence ?? belief.presenceProbability
    let decision = model.evaluate(EventImportanceInput(
        eventID: eventID,
        monotonicNS: monotonicNS,
        evidenceIDs: [
            "voice:\(monotonicNS)",
            "contact:\(authorization.rawValue)",
            target.map { "vision:\(String($0.id.prefix(96)))" } ?? "vision:not_required_for_active_contact",
        ],
        features: EventImportanceFeatures(
            explicitContact: max(0.80, min(visualConfidence, voiceConfidence)),
            socialSalience: visualConfidence,
            persistence: min((target?.stabilityMilliseconds ?? 1_000) / 1_000, 1),
            crossModalCorroboration: min(visualConfidence, voiceConfidence),
            humanPresence: belief.presenceProbability
        )
    ))
    return try? HumanInteractionWakeRequest(
        decision: decision,
        audioPreRollMilliseconds: 900
    )
}

private func speechInteractionContext(
    from belief: BeliefSnapshot,
    visualSummary: String? = nil,
    identityReference: String? = nil,
    participant: InteractionParticipant? = nil,
    personContextAvailable: Bool? = nil,
    sessionCapability: String? = nil,
    personMemoryMission: PersonContextMission? = nil,
    preferredLanguageTag: String? = nil,
    languageStartInstruction: String? = nil,
    objectKnowledge: [String] = []
) -> CodexInteractionContext? {
    let targetSummary: String
    if let target = belief.target {
        targetSummary = "L0 tracks a \(target.kind.rawValue) hypothesis labelled \(target.label ?? "unlabelled") with confidence \(String(format: "%.2f", target.confidence))."
    } else {
        targetSummary = "L0 has no current visual target."
    }
    let situationSummary = [targetSummary, visualSummary, objectKnowledge.isEmpty ? nil : "Objects the robot has identified recently: \(objectKnowledge.joined(separator: " | "))"]
        .compactMap { $0 }
        .joined(separator: " ")
    return try? CodexInteractionContext(
        situationSummary: situationSummary,
        identityReference: identityReference,
        personEntityID: participant?.entityID,
        personContextAvailable: personContextAvailable,
        sessionCapability: sessionCapability,
        interactionAuthority: participant?.authority,
        personMemoryMission: personMemoryMission,
        preferredLanguageTag: preferredLanguageTag,
        languageStartInstruction: languageStartInstruction,
        embodimentSummary: "Camera policy is \(belief.policy.rawValue); interaction readiness is \(String(format: "%.2f", belief.readyProbability))."
    )
}

private func l1ProactiveInteractionContext(
    request: L1SituationRequest,
    frame: L1SituationFrame,
    decision: L1SocialDecision,
    purpose: L1PurposefulOpening,
    languageStartInstruction: String?,
    sessionCapability: String?,
    interactionAuthority: SOMAInteractionAuthority,
    personMemoryMission: PersonContextMission?,
    objectKnowledge: [String] = []
) -> CodexInteractionContext? {
    let objective = "Conversation objective: \(purpose.objective)"
    let completion = "Conversation completion condition: \(purpose.completionCondition)"
    let thought = frame.thoughtState ?? request.priorThoughtState
    let hypothesis = thought.map { state in
        "L1 working hypothesis: \(state.workingHypothesis)"
    }
    let rationale = String(decision.rationale.prefix(512))
    let situation = [
        "L1 situation: \(frame.summary)",
        hypothesis,
        "Why L1 opened now: \(rationale)",
        objectKnowledge.isEmpty ? nil : "Objects the robot has identified recently: \(objectKnowledge.joined(separator: " | "))",
    ].compactMap { $0 }.joined(separator: " ")
    let identityScope = request.beliefSummary.localizedCaseInsensitiveContains("pseudonymous")
        ? "locally pseudonymous recurring person; no name or biometric material is available"
        : "locally recognized person; do not infer an identity beyond supplied context"
    let identity = "\(identityScope). Person context is available only through the supplied local MCP reference."
    let rapport: String
    if let value = request.rapport {
        rapport = String(
            format: "L1 rapport estimate: familiarity %.2f; interaction comfort %.2f; communication alignment %.2f; proactive-contact preference %@.",
            value.familiarity,
            value.interactionComfort,
            value.communicationAlignment,
            value.proactiveContact.rawValue
        )
    } else {
        rapport = "L1 has no established rapport record; keep the first exchange light, reciprocal, and easy to decline."
    }
    let language = request.preferredLanguageTag.map {
        "The person's explicitly stated preferred language is \($0); use it when naturally appropriate."
    }
    let preferences = request.personPreferences.map {
        "The person's explicitly stated durable preferences — honor these as binding rules in how you engage them: \($0)"
    }
    return try? CodexInteractionContext(
        situationSummary: situation,
        identityReference: identity,
        personEntityID: decision.entityID,
        sessionCapability: sessionCapability,
        interactionAuthority: interactionAuthority,
        personMemoryMission: personMemoryMission,
        preferredLanguageTag: request.preferredLanguageTag,
        languageStartInstruction: languageStartInstruction,
        rapportSummary: rapport,
        activeTaskSummaries: [objective, completion] + (language.map { [$0] } ?? []) + (preferences.map { [$0] } ?? []),
        memorySummaries: request.memory.map(\.summary) + request.recalledEpisodes,
        embodimentSummary: "L0 is maintaining visual attention while L2 leads the interaction. Do not issue camera-control instructions as part of ordinary conversation."
    )
}

/// Weak holder for the live-voice launcher so the @Sendable event closure can
/// append context to the active conversation without capturing the not-yet-
/// initialized local `let`.
private final class LiveVoiceLauncherBox: @unchecked Sendable {
    weak var launcher: AppServerLiveVoiceLauncher?
}

private final class SpeechInteractionBox: @unchecked Sendable {
    weak var coordinator: LocalSpeechInteractionCoordinator?
}

private final class L1AuxiliaryBridgeBox: @unchecked Sendable {
    weak var bridge: L1AuxiliarySemanticBridge?
}

private final class PoseStoreBox: @unchecked Sendable {
    weak var store: GimbalPoseStore?
}

private final class MemoryContextBox: @unchecked Sendable {
    weak var provider: L1MemoryContextProvider?
}

/// Bounded FIFO queue for parallel L1 object identifications. Detections are
/// enqueued (never dropped by a hard cooldown gate) and drained one at a time
/// by a single worker with a pacing pause between inferences, so the robot
/// does not hammer the model but also does not skip a queued object.
private final class ObjectRecognitionQueue: @unchecked Sendable {
    struct Item {
        let jpeg: Data
        let panDegrees: Double?
        let tiltDegrees: Double?
        let summary: String
        let objectLabel: String
        let personEntityID: UUID?
    }
    private let lock = NSLock()
    private var pending: [Item] = []
    private var draining = false
    private var recentLabels: [(label: String, atNS: UInt64)] = []
    private let maxPending: Int
    private let cooldownSeconds: Double
    private let dedupSeconds: Double
    private let process: @Sendable (Item) -> Void

    init(
        maxPending: Int = 4,
        cooldownMilliseconds: Int = 20_000,
        dedupMilliseconds: Int = 90_000,
        process: @escaping @Sendable (Item) -> Void
    ) {
        self.maxPending = max(1, maxPending)
        self.cooldownSeconds = Double(max(1_000, cooldownMilliseconds)) / 1_000.0
        self.dedupSeconds = Double(max(0, dedupMilliseconds)) / 1_000.0
        self.process = process
    }

    func enqueue(_ item: Item) {
        let nowNS = DispatchTime.now().uptimeNanoseconds
        let label = item.objectLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        // Skip if the same object label was already enqueued (still pending) or
        // processed recently — avoids re-identifying the same object on loop.
        if !label.isEmpty {
            let isPending = pending.contains { $0.objectLabel.caseInsensitiveCompare(label) == .orderedSame }
            let recentlyDone = recentLabels.contains { recent in
                recent.label.caseInsensitiveCompare(label) == .orderedSame
                    && nowNS >= recent.atNS
                    && nowNS - recent.atNS < UInt64(dedupSeconds * 1_000_000_000)
            }
            if isPending || recentlyDone {
                lock.unlock()
                return
            }
        }
        guard pending.count < maxPending else { lock.unlock(); return }
        pending.append(item)
        lock.unlock()
        pump()
    }

    private func pump() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        lock.lock()
        guard !draining else { lock.unlock(); return }
        draining = true
        lock.unlock()
        defer {
            lock.lock()
            draining = false
            lock.unlock()
        }
        while true {
            lock.lock()
            guard !pending.isEmpty else { return }
            let item = pending.removeFirst()
            lock.unlock()
            process(item)
            let label = item.objectLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                lock.lock()
                recentLabels.append((label, DispatchTime.now().uptimeNanoseconds))
                if recentLabels.count > 12 { recentLabels.removeFirst(recentLabels.count - 12) }
                lock.unlock()
            }
            if cooldownSeconds > 0 {
                Thread.sleep(forTimeInterval: cooldownSeconds)
            }
        }
    }
}

/// Thread-safe store of recently identified objects, injected into the L2
/// conversation context so Codex can reference objects the robot has seen.
/// Used by object-based exploration: each identified object is recorded with
/// the camera pan/tilt it was observed at, building a spatial inventory.
private final class ObjectKnowledgeStore: @unchecked Sendable {
    private struct Entry {
        let name: String
        let category: String
        let description: String
        let panDegrees: Double?
        let tiltDegrees: Double?
        let atNS: UInt64
    }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(
        name: String,
        category: String,
        description: String,
        panDegrees: Double?,
        tiltDegrees: Double?,
        atNS: UInt64
    ) {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Avoid immediately repeating the same named object.
        if entries.last?.name.caseInsensitiveCompare(trimmed) == .orderedSame { return }
        entries.append(Entry(
            name: trimmed,
            category: category,
            description: description,
            panDegrees: panDegrees,
            tiltDegrees: tiltDegrees,
            atNS: atNS
        ))
        if entries.count > 16 { entries.removeFirst(entries.count - 16) }
    }

    func recentSummaries(limit: Int = 6) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.suffix(limit).map { entry in
            var parts = [entry.name]
            if !entry.category.isEmpty { parts.append("category: \(entry.category)") }
            if !entry.description.isEmpty { parts.append(entry.description) }
            if let pan = entry.panDegrees, let tilt = entry.tiltDegrees,
               pan.isFinite, tilt.isFinite {
                parts.append(String(format: "seen at pan %.0f°, tilt %.0f°", pan, tilt))
            }
            return parts.joined(separator: "; ")
        }
    }
}

private final class AccessResult: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false
    func set(_ granted: Bool) { lock.lock(); self.granted = granted; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return granted }
}

private final class SynchronousResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Value, Error>?

    func set(_ value: Result<Value, Error>) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func get() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct MonoAudio {
    let samples: [Float]
    let sampleRateHz: Double
    let durationNS: UInt64
    let levelDB: Double
}

private func monoAudio(from sampleBuffer: CMSampleBuffer) -> MonoAudio? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM,
          let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        return nil
    }
    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(
        blockBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer
    ) == kCMBlockBufferNoErr,
          let dataPointer,
          totalLength > 0 else {
        return nil
    }

    let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
    let bytesPerFrame = Int(asbd.mBytesPerFrame)
    guard bytesPerSample > 0, bytesPerFrame >= bytesPerSample else { return nil }
    let scalarStride = max(1, bytesPerFrame / bytesPerSample)
    let valuesPerFrame = min(max(1, Int(asbd.mChannelsPerFrame)), scalarStride)
    let frameCount = totalLength / bytesPerFrame
    guard frameCount > 0, asbd.mSampleRate > 0 else { return nil }
    let durationNS = UInt64((Double(frameCount) / asbd.mSampleRate * 1_000_000_000).rounded())
    guard durationNS > 0 else { return nil }

    let flags = asbd.mFormatFlags
    let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
    let raw = UnsafeRawPointer(dataPointer)
    var samples: [Float] = []
    samples.reserveCapacity(frameCount)
    if isFloat, asbd.mBitsPerChannel == 32 {
        let input = raw.bindMemory(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size)
        for frame in 0..<frameCount {
            let base = frame * scalarStride
            var sum: Float = 0
            for channel in 0..<valuesPerFrame {
                sum += input[base + channel]
            }
            samples.append(sum / Float(valuesPerFrame))
        }
    } else if isSignedInteger, asbd.mBitsPerChannel == 16 {
        let input = raw.bindMemory(to: Int16.self, capacity: totalLength / MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            let base = frame * scalarStride
            var sum: Float = 0
            for channel in 0..<valuesPerFrame {
                sum += Float(input[base + channel]) / Float(Int16.max)
            }
            samples.append(sum / Float(valuesPerFrame))
        }
    } else {
        return nil
    }
    guard !samples.isEmpty else { return nil }
    let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    return MonoAudio(
        samples: samples,
        sampleRateHz: asbd.mSampleRate,
        durationNS: durationNS,
        levelDB: 20 * log10(max(rms, 0.000_001))
    )
}

private struct StereoSamples {
    let left: [Float]
    let right: [Float]
    let sampleRateHz: Double
}

private enum StereoSampleOutcome {
    case samples(StereoSamples)
    case rejected(StereoTDOARejection)
}

private func stereoSamples(from sampleBuffer: CMSampleBuffer) -> StereoSampleOutcome {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM,
          asbd.mChannelsPerFrame >= 2,
          asbd.mSampleRate > 0,
          let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        return .rejected(.invalidInput)
    }
    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(
        blockBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
          totalLengthOut: &totalLength,
          dataPointerOut: &dataPointer
    ) == kCMBlockBufferNoErr,
          let dataPointer else {
        return .rejected(.invalidInput)
    }
    let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
    let bytesPerFrame = Int(asbd.mBytesPerFrame)
    guard bytesPerSample > 0, bytesPerFrame >= bytesPerSample * 2 else { return .rejected(.invalidInput) }
    let scalarStride = bytesPerFrame / bytesPerSample
    let frameCount = totalLength / bytesPerFrame
    guard scalarStride >= 2, frameCount >= 64 else { return .rejected(.invalidInput) }

    var left: [Float] = []
    var right: [Float] = []
    left.reserveCapacity(frameCount)
    right.reserveCapacity(frameCount)
    let raw = UnsafeRawPointer(dataPointer)
    let flags = asbd.mFormatFlags
    if (flags & kAudioFormatFlagIsFloat) != 0, asbd.mBitsPerChannel == 32 {
        let samples = raw.bindMemory(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size)
        for frame in 0..<frameCount {
            let offset = frame * scalarStride
            left.append(samples[offset])
            right.append(samples[offset + 1])
        }
    } else if (flags & kAudioFormatFlagIsSignedInteger) != 0, asbd.mBitsPerChannel == 16 {
        let samples = raw.bindMemory(to: Int16.self, capacity: totalLength / MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            let offset = frame * scalarStride
            left.append(Float(samples[offset]) / Float(Int16.max))
            right.append(Float(samples[offset + 1]) / Float(Int16.max))
        }
    } else {
        return .rejected(.invalidInput)
    }
    return .samples(StereoSamples(left: left, right: right, sampleRateHz: asbd.mSampleRate))
}

private extension SOMACore.NormalizedRect {
    init(_ rect: CGRect) {
        self.init(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width), height: Double(rect.height))
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

private func identity(_ device: AVCaptureDevice) -> DeviceIdentity {
    DeviceIdentity(name: device.localizedName, uniqueID: device.uniqueID, modelID: device.modelID)
}

private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

private func milliseconds(from earlier: UInt64, to later: UInt64) -> Double {
    guard later >= earlier else { return 0 }
    return Double(later - earlier) / 1_000_000
}

/// AVCapture video timestamps normally share the macOS host-time epoch. Keep
/// the measured presentation timestamp only when it agrees with Dispatch
/// uptime; a different session clock falls back to callback time rather than
/// corrupting the spatial map.
private func hostAlignedPresentationTimestamp(
    sampleBuffer: CMSampleBuffer,
    fallbackNS: UInt64
) -> UInt64 {
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let seconds = CMTimeGetSeconds(timestamp)
    guard timestamp.isValid,
          !timestamp.isIndefinite,
          seconds.isFinite,
          seconds >= 0,
          seconds <= Double(UInt64.max) / 1_000_000_000 else {
        return fallbackNS
    }
    let candidate = UInt64((seconds * 1_000_000_000).rounded())
    let difference = candidate > fallbackNS ? candidate - fallbackNS : fallbackNS - candidate
    return difference <= 1_000_000_000 ? candidate : fallbackNS
}

private func monotonicNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func printUsage() {
    print("Usage: soma-subconscious --video-id <OBSBOT video ID> --audio-id <OBSBOT audio ID> [--duration seconds] [--soma-settings /absolute/settings.json] [--guided-scenario] [--tdoa-calibration calibration.json | --tdoa-calibrate calibration.json --duration 45] [--output trace.jsonl [--trace-max-megabytes MB --trace-retained-files count] [--important-output important.jsonl --important-max-megabytes MB --important-retained-files count]] [--diagnostic-snapshot frame.jpg | --face-lock-diagnostics jpeg-directory] [--panorama-output /absolute/panorama.jpg [--panorama-place-memory /absolute/place-memory.json] [--camera-geometry-calibration /absolute/calibration.json] [--capture-camera-geometry /absolute/new-directory | --panorama-strip-scan]] [--l2-live-voice | --local-speech-recognition locale [--l2-codex-bridge /absolute/soma-codex-bridge]] [--l1-auxiliary-vlm-python python --l1-auxiliary-vlm-worker worker.py --l1-auxiliary-vlm-model local-model-directory] [--embodiment-shadow-socket /absolute/path.sock [--allow-embodiment-motor-control --embodiment-view-directory /absolute/private-directory]] [--allow-camera-motion --native-gimbal-helper /path/to/soma-native-track --gimbal-output actuator.jsonl [--gimbal-trace-max-megabytes MB --gimbal-trace-retained-files count] --duration 0=continuous|positive-seconds] [--allow-external-gimbal-control --external-gimbal-calibration calibration.json [--allow-autonomous-scan] | --calibrate-external-gimbal calibration.json --duration 12..30] [--allow-native-human-tracking]")
    print("       soma-subconscious --speech-recognition-status [locale]")
    print("       soma-subconscious --speech-recognition-file <locale> <absolute-audio-path>")
    print("       soma-subconscious --speech-synthesis-test <locale> <text>")
    print("       soma-subconscious --live-voice-test")
    print("       soma-subconscious --face-identity-status")
    print("       soma-subconscious --promote-anonymous-face <anon_handle>")
    print("       soma-subconscious --remove-face-identity <entity_uuid>")
}

let somaArguments = Array(CommandLine.arguments.dropFirst())
if somaArguments.first == "--speech-recognition-status" {
    let localeIdentifier = somaArguments.count > 1
        ? somaArguments[1]
        : Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    let capability = localSpeechCapability(localeIdentifier: localeIdentifier)
    print("engine=speech_analyzer")
    print("locale=\(capability.localeIdentifier)")
    print("supported=\(capability.supported)")
    print("installed=\(capability.installed)")
    print("on_device=true")
    Foundation.exit(capability.supported && capability.installed ? EXIT_SUCCESS : EXIT_FAILURE)
} else if somaArguments.first == "--speech-recognition-file" {
    guard somaArguments.count == 3, somaArguments[2].hasPrefix("/") else {
        fputs("soma-subconscious: --speech-recognition-file requires a locale and absolute audio path\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    do {
        let startedNS = monotonicNanoseconds()
        let result = try transcribeLocalSpeechFile(
            at: URL(fileURLWithPath: somaArguments[2]),
            localeIdentifier: somaArguments[1]
        )
        print("engine=speech_analyzer")
        print("locale=\(result.localeIdentifier)")
        print("latency_ms=\(milliseconds(from: startedNS, to: result.completedNS))")
        print("transcript=\(result.transcript)")
        Foundation.exit(result.transcript.isEmpty ? EXIT_FAILURE : EXIT_SUCCESS)
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
} else if somaArguments.first == "--speech-synthesis-test" {
    guard somaArguments.count == 3 else {
        fputs("soma-subconscious: --speech-synthesis-test requires a locale and text\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    do {
        let durationMilliseconds = try testLocalSpeechOutput(
            text: somaArguments[2],
            localeIdentifier: somaArguments[1]
        )
        print("engine=av_speech_synthesizer")
        print("locale=\(somaArguments[1])")
        print("duration_ms=\(durationMilliseconds)")
        Foundation.exit(EXIT_SUCCESS)
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
} else if somaArguments.first == "--live-voice-test" {
    guard somaArguments.count == 1 else {
        fputs("soma-subconscious: --live-voice-test takes no additional arguments\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    let result = testAppServerLiveVoiceLauncher()
    print("live_voice=\(result)")
        Foundation.exit(result == "active" ? EXIT_SUCCESS : EXIT_FAILURE)
} else if somaArguments.first == "--face-identity-status" {
    guard somaArguments.count == 1 else {
        fputs("soma-subconscious: --face-identity-status takes no additional arguments\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    do {
        let counts = try await FaceIdentityRuntime.referenceCounts()
        print("known_profiles=\(counts.knownProfileReferenceCounts.count)")
        print("known_references_per_profile=\(counts.knownProfileReferenceCounts.map(String.init).joined(separator: ","))")
        print("anonymous_clusters=\(counts.anonymousClusterReferenceCounts.count)")
        print("anonymous_references_per_cluster=\(counts.anonymousClusterReferenceCounts.map(String.init).joined(separator: ","))")
        Foundation.exit(EXIT_SUCCESS)
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
} else if somaArguments.first == "--promote-anonymous-face" {
    guard somaArguments.count == 2,
          let handle = try? AnonymousFaceHandle(rawValue: somaArguments[1]) else {
        fputs("soma-subconscious: --promote-anonymous-face requires an anon handle\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    do {
        let result = try await FaceIdentityRuntime.promoteAnonymousIdentity(handle: handle)
        print("entity_id=\(result.entityID.uuidString.lowercased())")
        print("references=\(result.referenceCount)")
        print("profile=encrypted_local_v2")
        Foundation.exit(EXIT_SUCCESS)
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
} else if somaArguments.first == "--remove-face-identity" {
    guard somaArguments.count == 2,
          let entityID = UUID(uuidString: somaArguments[1]) else {
        fputs("soma-subconscious: --remove-face-identity requires a profile UUID\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    do {
        try await FaceIdentityRuntime.removeKnownIdentity(entityID: entityID)
        print("entity_id=\(entityID.uuidString.lowercased())")
        print("profile=removed")
        Foundation.exit(EXIT_SUCCESS)
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
} else {
    do {
        try run(Options.parse(somaArguments))
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
}
