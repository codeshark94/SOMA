import Foundation
import SOMACore

private struct L1LanguageInstructionResponse: Decodable {
    let directive: String?
}

/// Decouples language-instruction generation from the lifetime of a Live
/// Voice session. A directive is delivered only while a session is attached;
/// launch-time context still obtains the cached directive directly.
final class LiveVoiceInstructionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (String) -> Void)?

    func attach(_ sink: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    func publish(_ directive: String) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(directive)
    }
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

    init(
        configuration: L1ModelConfiguration = .gemma31,
        endpoint: URL? = nil,
        onHealth: @escaping @Sendable (String, String) -> Void,
        onReady: @escaping @Sendable (String, String) -> Void
    ) {
        let configuredEndpoint: URL
        if let endpoint {
            configuredEndpoint = endpoint
        } else if let rawEndpoint = ProcessInfo.processInfo.environment["SOMA_L1_OLLAMA_ENDPOINT"],
                  let resolved = URL(string: rawEndpoint) {
            configuredEndpoint = resolved
        } else {
            configuredEndpoint = URL(string: "http://127.0.0.1:11434/api/generate")!
        }
        self.endpoint = configuredEndpoint
        model = configuration.model
        self.onHealth = onHealth
        self.onReady = onReady
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 4
        sessionConfiguration.timeoutIntervalForResource = 5
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
        return queue.sync { directives[languageTag] }
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
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async(execute: {
                guard let http = response as? HTTPURLResponse,
                      (200 ... 299).contains(http.statusCode),
                      error == nil,
                      let data,
                      let response = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: data),
                      let raw = response.response,
                      let generated = Self.decodeDirectiveResponse(raw),
                      let directive = Self.normalizedDirective(generated.directive) else {
                    self.finish(languageTag, directive: nil, state: "unavailable")
                    return
                }
                self.finish(languageTag, directive: directive, state: "ready")
            })
        }.resume()
    }

    private func finish(_ languageTag: String, directive: String?, state: String) {
        inFlight.remove(languageTag)
        guard let directive else {
            onHealth(state, "workload=language_instruction; language=\(languageTag)")
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
