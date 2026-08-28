import Foundation
import SOMACore

private struct L1LanguageInstructionResponse: Decodable {
    let directive: String?
}

/// L1 turns a BCP-47 preference into a concise native-language instruction for
/// the next L2 Live session. It receives only a language tag, never a person
/// identifier, face data, image, or conversation content.
final class L1LanguageInstructionCache: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soma.l1.language-instruction", qos: .utility)
    private let session: URLSession
    private let endpoint: URL
    private let model: String
    private let onHealth: @Sendable (String, String) -> Void
    private let onReady: @Sendable (String, String) -> Void
    private var directives: [String: String] = [:]
    private var inFlight: Set<String> = []
    /// When the last generation attempt finished for each language, so an
    /// on-demand re-trigger is paced instead of spamming the shared L1 model.
    private var lastAttemptByLanguageTag: [String: Date] = [:]
    /// Minimum gap between re-triggers once a generation has already run.
    private let reTriggerInterval: TimeInterval = 120

    init(
        configuration: L1ModelConfiguration = .gemma31,
        endpoint: URL? = nil,
        onHealth: @escaping @Sendable (String, String) -> Void,
        onReady: @escaping @Sendable (String, String) -> Void
    ) {
        let configuredEndpoint: URL
        if let endpoint {
            configuredEndpoint = endpoint
        } else if let rawEndpoint = ProcessInfo.processInfo.environment["SOMA_L1_LANGUAGE_ENDPOINT"],
                  let resolved = URL(string: rawEndpoint) {
            // Explicit generate-style endpoint override (optional).
            configuredEndpoint = resolved
        } else {
            // This cache sends an /api/generate payload (model + prompt). Never
            // reuse SOMA_L1_OLLAMA_ENDPOINT, which points at /api/chat; build the
            // generate URL from OLLAMA_HOST so the payload and endpoint match.
            let host = ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "http://127.0.0.1:11434"
            let normalizedHost = host.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
            configuredEndpoint = URL(string: normalizedHost + "/api/generate")!
        }
        self.endpoint = configuredEndpoint
        model = configuration.model
        self.onHealth = onHealth
        self.onReady = onReady
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 20
        sessionConfiguration.timeoutIntervalForResource = 25
        session = URLSession(configuration: sessionConfiguration)
    }

    func prepare(for rawLanguageTag: String?) {
        guard let rawLanguageTag,
              let languageTag = PersonContextFormat.normalizedLanguageTag(rawLanguageTag) else {
            return
        }
        queue.async { [weak self] in
            guard let self,
                  self.directives[languageTag] == nil,
                  !self.inFlight.contains(languageTag) else {
                return
            }
            self.inFlight.insert(languageTag)
            self.requestDirective(for: languageTag)
        }
    }

    func directive(for rawLanguageTag: String?) -> String? {
        guard let rawLanguageTag,
              let languageTag = PersonContextFormat.normalizedLanguageTag(rawLanguageTag) else {
            return nil
        }
        let ready = queue.sync {
            directives[languageTag]
        }
        if ready == nil {
            // The directive is not ready yet (e.g. the initial generation ran
            // during a cold cloud-model load). Re-trigger a fresh generation so
            // it succeeds once the model is free, but pace it so it does not
            // keep polling the shared L1 model every session.
            queue.sync {
                if !inFlight.contains(languageTag),
                   Date().timeIntervalSince(lastAttemptByLanguageTag[languageTag] ?? .distantPast) >= reTriggerInterval {
                    lastAttemptByLanguageTag[languageTag] = Date()
                    prepare(for: languageTag)
                }
            }
        }
        return ready
    }

    private func requestDirective(for languageTag: String) {
        let prompt = """
        Write exactly one concise developer instruction for a voice assistant.
        The participant's explicit BCP-47 response-language preference is \(languageTag).
        Write the instruction itself fully in that preferred language. It must say to respond naturally in that language unless the participant explicitly changes language or asks otherwise. Do not mention BCP-47, translation, model names, memory, or this request.
        Return only JSON: {\"directive\":\"...\"}.
        """
        let payload = OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            format: "json",
            stream: false,
            images: nil,
            options: .init(temperature: 0, numPredict: 120)
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            finish(languageTag, directive: nil, state: "encoding_failed")
            return
        }
        sendDirectiveRequest(languageTag: languageTag, body: data, attempt: 1)
    }

    /// Sends the directive generation request. A cloud L1 model can return an
    /// empty completion with `done_reason == "load"` while it is still loading;
    /// that is not a real failure, so we retry after a short delay up to a few
    /// attempts before giving up.
    private func sendDirectiveRequest(languageTag: String, body: Data, attempt: Int) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async(execute: {
                guard let http = response as? HTTPURLResponse,
                      (200 ... 299).contains(http.statusCode),
                      error == nil,
                      let data,
                      let response = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: data) else {
                    let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no_data"
                    let detail = "status=\(String(describing: (response as? HTTPURLResponse)?.statusCode)); err=\(error?.localizedDescription ?? "nil"); raw=\(String(raw.prefix(240)).replacingOccurrences(of: "\"", with: "'"))"
                    self.finish(languageTag, directive: nil, state: "unavailable", detail: detail)
                    return
                }
                // A still-loading cloud model returns an empty completion.
                if response.doneReason == "load"
                    || response.response == nil
                    || response.response?.isEmpty == true {
                    guard attempt < 6 else {
                        self.finish(languageTag, directive: nil, state: "unavailable", detail: "model_still_loading")
                        return
                    }
                    let retryAfter = min(3.0 * Double(attempt), 20)
                    self.queue.asyncAfter(deadline: .now() + retryAfter) { [weak self] in
                        guard let self else { return }
                        self.sendDirectiveRequest(languageTag: languageTag, body: body, attempt: attempt + 1)
                    }
                    return
                }
                guard let raw = response.response,
                      let generated = Self.decodeDirectiveResponse(raw),
                      let directive = Self.normalizedDirective(generated.directive) else {
                    self.finish(languageTag, directive: nil, state: "unavailable", detail: "unparseable=\(String((response.response ?? "").prefix(200)))")
                    return
                }
                self.finish(languageTag, directive: directive, state: "ready")
            })
        }.resume()
    }

    private func finish(_ languageTag: String, directive: String?, state: String, detail: String? = nil) {
        inFlight.remove(languageTag)
        guard let directive else {
            onHealth(state, "workload=language_instruction; language=\(languageTag)" + (detail.map { "; \($0)" } ?? ""))
            return
        }
        directives[languageTag] = directive
        onHealth(state, "workload=language_instruction; language=\(languageTag)")
        onReady(languageTag, directive)
    }

    private static func normalizedDirective(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 1_024 else { return nil }
        return normalized
    }

    private static func decodeDirectiveResponse(_ raw: String) -> L1LanguageInstructionResponse? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.hasPrefix("```"),
           let firstNewline = trimmed.firstIndex(of: "\n"),
           let closingFence = trimmed.range(of: "```", options: .backwards) {
            candidate = String(trimmed[trimmed.index(after: firstNewline)..<closingFence.lowerBound])
        } else {
            candidate = trimmed
        }
        guard let objectStart = candidate.firstIndex(of: "{"),
              let objectEnd = candidate.lastIndex(of: "}") else {
            return nil
        }
        return try? JSONDecoder().decode(
            L1LanguageInstructionResponse.self,
            from: Data(candidate[objectStart...objectEnd].utf8)
        )
    }
}
