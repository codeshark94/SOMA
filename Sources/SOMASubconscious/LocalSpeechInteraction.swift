@preconcurrency import AVFoundation
import Foundation
import SOMACore
@preconcurrency import Speech

struct LocalSpeechCapability: Sendable {
    let localeIdentifier: String
    let supported: Bool
    let installed: Bool
}

func localSpeechCapability(localeIdentifier: String) -> LocalSpeechCapability {
    let locale = Locale(identifier: localeIdentifier)
    guard #available(macOS 26.0, *) else {
        return LocalSpeechCapability(
            localeIdentifier: locale.identifier,
            supported: false,
            installed: false
        )
    }
    let result = LocalSpeechCapabilityResult()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        let installed = await SpeechTranscriber.installedLocales
        let resolvedIdentifier = supportedLocale?.identifier ?? locale.identifier
        let installedIdentifiers = Set(installed.map { normalizedLocaleIdentifier($0.identifier) })
        result.set(LocalSpeechCapability(
            localeIdentifier: resolvedIdentifier,
            supported: supportedLocale != nil,
            installed: installedIdentifiers.contains(normalizedLocaleIdentifier(resolvedIdentifier))
        ))
        semaphore.signal()
    }
    semaphore.wait()
    return result.value ?? LocalSpeechCapability(
        localeIdentifier: locale.identifier,
        supported: false,
        installed: false
    )
}

private func normalizedLocaleIdentifier(_ identifier: String) -> String {
    identifier.replacingOccurrences(of: "_", with: "-").lowercased()
}

private final class LocalSpeechCapabilityResult: @unchecked Sendable {
    private let lock = NSLock()
    private var capability: LocalSpeechCapability?

    func set(_ value: LocalSpeechCapability) {
        lock.lock()
        capability = value
        lock.unlock()
    }

    var value: LocalSpeechCapability? {
        lock.lock()
        defer { lock.unlock() }
        return capability
    }
}

struct SpeechAudioChunk: Sendable {
    let samples: [Float]
    let sampleRateHz: Double
    let captureNS: UInt64
    let durationNS: UInt64
    let continuous: Bool

    var endNS: UInt64 { captureNS &+ durationNS }
}

struct LocalSpeechRecognitionResult: Sendable {
    let transcript: String
    let localeIdentifier: String
    let confidence: Double?
    let completedNS: UInt64
}

enum LocalSpeechInteractionState: Sendable {
    case turnStarted(
        speechStartedAtNS: UInt64,
        preRollMilliseconds: UInt64,
        chunkCount: Int,
        contactAuthorization: String
    )
    case turnCancelled(reason: String)
    case recognitionCompleted(
        speechStartedAtNS: UInt64,
        speechEndedAtNS: UInt64,
        transcriptCharacters: Int,
        localeIdentifier: String,
        confidence: Double?,
        latencyMilliseconds: Double,
        handedToL2: Bool
    )
    case recognitionFailed(reason: String)
    case l2Completed(turnID: String, responseCharacters: Int, latencyMilliseconds: Double)
    case l2Failed(turnID: String?, reason: String)
    case speechStarted(turnID: String, responseCharacters: Int, localeIdentifier: String?)
    case speechCompleted(turnID: String, durationMilliseconds: Double)
    case speechCancelled(turnID: String, reason: String)
}

enum LocalSpeechInteractionError: LocalizedError {
    case unsupportedOperatingSystem
    case recognizerUnavailable(String)
    case modelNotInstalled(String)
    case invalidAudioFormat
    case audioDurationExceeded
    case codexBridgeUnavailable(String)
    case speechOutputFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOperatingSystem:
            return "Local SpeechAnalyzer requires macOS 26 or later"
        case .recognizerUnavailable(let locale):
            return "Speech recognition is unavailable for \(locale)"
        case .modelNotInstalled(let locale):
            return "The on-device speech model is not installed for \(locale)"
        case .invalidAudioFormat:
            return "Speech audio has an invalid PCM format"
        case .audioDurationExceeded:
            return "Speech audio exceeds the 20-second utterance bound"
        case .codexBridgeUnavailable(let message):
            return message
        case .speechOutputFailed(let message):
            return message
        }
    }
}

private final class LocalOnDeviceSpeechRecognizer: @unchecked Sendable {
    private let localeIdentifier: String
    private let lock = NSLock()
    private var queuedTurns = 0

    init(localeIdentifier: String) throws {
        guard #available(macOS 26.0, *) else {
            throw LocalSpeechInteractionError.unsupportedOperatingSystem
        }
        let capability = localSpeechCapability(localeIdentifier: localeIdentifier)
        guard capability.supported else {
            throw LocalSpeechInteractionError.recognizerUnavailable(localeIdentifier)
        }
        guard capability.installed else {
            throw LocalSpeechInteractionError.modelNotInstalled(localeIdentifier)
        }
        self.localeIdentifier = capability.localeIdentifier
    }

    func transcribe(
        _ chunks: [SpeechAudioChunk],
        completion: @escaping @Sendable (Result<LocalSpeechRecognitionResult, Error>) -> Void
    ) {
        guard #available(macOS 26.0, *) else {
            completion(.failure(LocalSpeechInteractionError.unsupportedOperatingSystem))
            return
        }
        lock.lock()
        guard queuedTurns < 2 else {
            lock.unlock()
            completion(.failure(LocalSpeechInteractionError.recognizerUnavailable("backpressure")))
            return
        }
        queuedTurns += 1
        lock.unlock()

        let completionGate = RecognitionCompletionGate()
        let recognitionTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let result = try await analyze(chunks)
                guard completionGate.claim() else { return }
                finishOne()
                completion(.success(result))
            } catch {
                guard completionGate.claim() else { return }
                finishOne()
                completion(.failure(error))
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard completionGate.claim() else { return }
            recognitionTask.cancel()
            self?.finishOne()
            completion(.failure(LocalSpeechInteractionError.recognizerUnavailable("recognition_timeout")))
        }
    }

    @available(macOS 26.0, *)
    private func analyze(_ chunks: [SpeechAudioChunk]) async throws -> LocalSpeechRecognitionResult {
        guard !chunks.isEmpty else { throw LocalSpeechInteractionError.invalidAudioFormat }
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: localeIdentifier),
            preset: .transcription
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw LocalSpeechInteractionError.invalidAudioFormat
        }
        let buffers = try chunks.map { chunk in
            try Self.convert(Self.buffer(from: chunk), to: targetFormat)
        }
        let input = AsyncStream<AnalyzerInput> { continuation in
            for buffer in buffers { continuation.yield(AnalyzerInput(buffer: buffer)) }
            continuation.finish()
        }
        async let transcriptFuture = transcriber.results.reduce(into: "") { transcript, result in
            guard result.isFinal else { return }
            transcript += String(result.text.characters)
        }
        do {
            try await analyzer.start(inputSequence: input)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let rawTranscript = try await transcriptFuture
            let transcript = rawTranscript.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
            return LocalSpeechRecognitionResult(
                transcript: transcript,
                localeIdentifier: localeIdentifier,
                confidence: nil,
                completedNS: DispatchTime.now().uptimeNanoseconds
            )
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func buffer(from chunk: SpeechAudioChunk) throws -> AVAudioPCMBuffer {
        guard chunk.sampleRateHz.isFinite,
              chunk.sampleRateHz > 0,
              chunk.samples.count <= Int(UInt32.max),
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: chunk.sampleRateHz,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(chunk.samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            throw LocalSpeechInteractionError.invalidAudioFormat
        }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: source.count)
        }
        return buffer
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        if input.format == format { return input }
        guard let converter = AVAudioConverter(from: input.format, to: format) else {
            throw LocalSpeechInteractionError.invalidAudioFormat
        }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw LocalSpeechInteractionError.invalidAudioFormat
        }
        let inputSupply = AudioConverterInputSupply(input)
        var conversionError: NSError?
        _ = converter.convert(to: output, error: &conversionError) { _, status in
            guard let input = inputSupply.take() else {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil, output.frameLength > 0 else {
            throw conversionError ?? LocalSpeechInteractionError.invalidAudioFormat
        }
        return output
    }

    private func finishOne() {
        lock.lock()
        queuedTurns = max(0, queuedTurns - 1)
        lock.unlock()
    }
}

func transcribeLocalSpeechFile(
    at url: URL,
    localeIdentifier: String
) throws -> LocalSpeechRecognitionResult {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard format.sampleRate.isFinite,
          format.sampleRate > 0,
          format.channelCount > 0 else {
        throw LocalSpeechInteractionError.invalidAudioFormat
    }
    guard Double(file.length) / format.sampleRate <= 20 else {
        throw LocalSpeechInteractionError.audioDurationExceeded
    }

    let framesPerChunk: AVAudioFrameCount = 4_096
    var chunks: [SpeechAudioChunk] = []
    var frameOffset: AVAudioFramePosition = 0
    while file.framePosition < file.length {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: framesPerChunk
        ) else {
            throw LocalSpeechInteractionError.invalidAudioFormat
        }
        try file.read(into: buffer, frameCount: framesPerChunk)
        guard buffer.frameLength > 0,
              let channels = buffer.floatChannelData else {
            break
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var samples = [Float](repeating: 0, count: frameCount)
        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                samples[frameIndex] += channel[frameIndex] / Float(channelCount)
            }
        }
        let captureNS = UInt64(
            (Double(frameOffset) / format.sampleRate * 1_000_000_000).rounded()
        )
        let durationNS = UInt64(
            (Double(frameCount) / format.sampleRate * 1_000_000_000).rounded()
        )
        chunks.append(SpeechAudioChunk(
            samples: samples,
            sampleRateHz: format.sampleRate,
            captureNS: captureNS,
            durationNS: durationNS,
            continuous: true
        ))
        frameOffset += AVAudioFramePosition(frameCount)
    }
    guard !chunks.isEmpty else {
        throw LocalSpeechInteractionError.invalidAudioFormat
    }

    let recognizer = try LocalOnDeviceSpeechRecognizer(localeIdentifier: localeIdentifier)
    let result = BlockingRecognitionResult()
    let semaphore = DispatchSemaphore(value: 0)
    recognizer.transcribe(chunks) { recognition in
        result.set(recognition)
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 20) == .success,
          let recognition = result.value else {
        throw LocalSpeechInteractionError.recognizerUnavailable("recognition_timeout")
    }
    return try recognition.get()
}

private final class BlockingRecognitionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<LocalSpeechRecognitionResult, Error>?

    func set(_ value: Result<LocalSpeechRecognitionResult, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    var value: Result<LocalSpeechRecognitionResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private final class AudioConverterInputSupply: @unchecked Sendable {
    private let lock = NSLock()
    private var input: AVAudioPCMBuffer?

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func take() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let value = input
        input = nil
        return value
    }
}

private final class RecognitionCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

final class LocalSpeechInteractionCoordinator: @unchecked Sendable {
    private struct ActiveCapture {
        let start: SpeechTurnStart
        let context: CodexInteractionContext
        var chunks: [SpeechAudioChunk]
    }

    private let lock = NSLock()
    private var recognizer: LocalOnDeviceSpeechRecognizer
    private var currentLocaleIdentifier: String
    private let codexBridge: CodexVoiceHandoff?
    private let speechOutput: LocalSpeechOutput?
    private let onState: @Sendable (LocalSpeechInteractionState) -> Void
    private let interactionID: String
    private var segmenter = SpeechTurnSegmenter()
    private var preRoll: [SpeechAudioChunk] = []
    private var activeCapture: ActiveCapture?
    private var turnSequence: UInt64 = 0

    init(
        localeIdentifier: String,
        codexBridgeURL: URL?,
        codexWorkingDirectoryURL: URL,
        onState: @escaping @Sendable (LocalSpeechInteractionState) -> Void
    ) throws {
        recognizer = try LocalOnDeviceSpeechRecognizer(localeIdentifier: localeIdentifier)
        currentLocaleIdentifier = localeIdentifier
        self.onState = onState
        interactionID = "voice-\(ProcessInfo.processInfo.processIdentifier)-\(DispatchTime.now().uptimeNanoseconds)"
        if let codexBridgeURL {
            let speechOutput = LocalSpeechOutput(onState: onState)
            self.speechOutput = speechOutput
            codexBridge = try CodexVoiceHandoff(
                executableURL: codexBridgeURL,
                workingDirectoryURL: codexWorkingDirectoryURL,
                onState: onState,
                onResponse: { turnID, text, languageTag in
                    speechOutput.speak(text, turnID: turnID, languageTag: languageTag)
                }
            )
        } else {
            speechOutput = nil
            codexBridge = nil
        }
    }

    /// Switch the on-device speech recognizer to a new locale (e.g. the language
    /// detected from the participant's speech). Recreates the recognizer only
    /// when the locale actually changes, and only between recognition turns.
    func setRecognitionLocale(_ localeIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        guard localeIdentifier != currentLocaleIdentifier else { return }
        guard let newRecognizer = try? LocalOnDeviceSpeechRecognizer(localeIdentifier: localeIdentifier) else {
            return
        }
        recognizer = newRecognizer
        currentLocaleIdentifier = localeIdentifier
    }

    func ingestAudio(_ chunk: SpeechAudioChunk) {
        var cancellation: String?
        lock.lock()
        if !chunk.continuous, activeCapture != nil {
            activeCapture = nil
            segmenter.reset(at: chunk.captureNS)
            cancellation = "audio_discontinuity"
        }
        preRoll.append(chunk)
        let retainAfterNS = chunk.endNS > 1_500_000_000 ? chunk.endNS - 1_500_000_000 : 0
        preRoll.removeAll { $0.endNS < retainAfterNS }
        if activeCapture != nil {
            activeCapture?.chunks.append(chunk)
        }
        lock.unlock()
        if let cancellation { onState(.turnCancelled(reason: cancellation)) }
    }

    func observeVAD(
        active: Bool,
        at monotonicNS: UInt64,
        authorizedWake: HumanInteractionWakeRequest?,
        context: CodexInteractionContext
    ) {
        if speechOutput?.suppressesMicrophone(at: monotonicNS) == true {
            return
        }
        var started: SpeechTurnStart?
        var completed: (SpeechTurnFinish, [SpeechAudioChunk], CodexInteractionContext)?
        lock.lock()
        if let transition = segmenter.observe(
            voiceActive: active,
            at: monotonicNS,
            authorizedWake: authorizedWake
        ) {
            switch transition {
            case .started(let start):
                let preRollNS = start.wake.audioPreRollMilliseconds * 1_000_000
                let retainAfterNS = start.speechStartedAtNS > preRollNS
                    ? start.speechStartedAtNS - preRollNS
                    : 0
                let chunks = preRoll.filter { $0.endNS >= retainAfterNS }
                activeCapture = ActiveCapture(start: start, context: context, chunks: chunks)
                started = start
            case .finished(let finish):
                if let capture = activeCapture {
                    activeCapture = nil
                    completed = (finish, capture.chunks, capture.context)
                }
            }
        }
        let startChunkCount = activeCapture?.chunks.count ?? 0
        lock.unlock()

        if let started {
            let authorization = started.wake.evidenceIDs
                .first(where: { $0.hasPrefix("contact:") })
                .map { String($0.dropFirst("contact:".count)) }
                ?? "unknown"
            onState(.turnStarted(
                speechStartedAtNS: started.speechStartedAtNS,
                preRollMilliseconds: started.wake.audioPreRollMilliseconds,
                chunkCount: startChunkCount,
                contactAuthorization: authorization
            ))
        }
        if let completed {
            recognize(completed.0, chunks: completed.1, context: completed.2)
        }
    }

    func stop() {
        lock.lock()
        activeCapture = nil
        preRoll.removeAll(keepingCapacity: false)
        segmenter.reset(at: DispatchTime.now().uptimeNanoseconds)
        lock.unlock()
        codexBridge?.stop()
        speechOutput?.stop(reason: "coordinator_stopped")
    }

    private func recognize(
        _ finish: SpeechTurnFinish,
        chunks: [SpeechAudioChunk],
        context: CodexInteractionContext
    ) {
        recognizer.transcribe(chunks) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.onState(.recognitionFailed(reason: String(error.localizedDescription.prefix(192))))
            case .success(let recognition):
                guard !recognition.transcript.isEmpty else {
                    self.onState(.recognitionFailed(reason: "empty_transcript"))
                    return
                }
                self.lock.lock()
                self.turnSequence += 1
                let turnID = "turn-\(self.turnSequence)"
                self.lock.unlock()
                do {
                    let turn = try CodexInteractionTurn(
                        interactionID: self.interactionID,
                        turnID: turnID,
                        transcript: recognition.transcript,
                        languageTag: recognition.localeIdentifier,
                        speechStartedAtNS: finish.speechStartedAtNS,
                        transcriptFinalizedAtNS: recognition.completedNS,
                        evidenceIDs: finish.wake.evidenceIDs
                    )
                    let request = try CodexAccountTurnRequest(turn: turn, context: context)
                    let handedToL2 = self.codexBridge?.submit(request) ?? false
                    self.onState(.recognitionCompleted(
                        speechStartedAtNS: finish.speechStartedAtNS,
                        speechEndedAtNS: finish.speechEndedAtNS,
                        transcriptCharacters: recognition.transcript.count,
                        localeIdentifier: recognition.localeIdentifier,
                        confidence: recognition.confidence,
                        latencyMilliseconds: Double(recognition.completedNS - finish.speechEndedAtNS) / 1_000_000,
                        handedToL2: handedToL2
                    ))
                } catch {
                    self.onState(.recognitionFailed(reason: String(error.localizedDescription.prefix(192))))
                }
            }
        }
    }
}

private final class LocalSpeechOutput: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private struct ActiveUtterance {
        let turnID: String
        let utterance: AVSpeechUtterance
        let startedNS: UInt64
    }

    private let lock = NSLock()
    private let synthesizer = AVSpeechSynthesizer()
    private let onState: @Sendable (LocalSpeechInteractionState) -> Void
    private var active: ActiveUtterance?
    private var suppressMicrophoneUntilNS: UInt64 = 0

    init(onState: @escaping @Sendable (LocalSpeechInteractionState) -> Void) {
        self.onState = onState
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ rawText: String, turnID: String, languageTag: String?) {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            onState(.speechCancelled(turnID: turnID, reason: "empty_response"))
            return
        }
        let text = String(normalized.prefix(1_200))
        let utterance = AVSpeechUtterance(string: text)
        if let languageTag,
           let voice = AVSpeechSynthesisVoice(language: languageTag.replacingOccurrences(of: "_", with: "-")) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        utterance.volume = 0.88
        utterance.preUtteranceDelay = 0.04
        utterance.postUtteranceDelay = 0.08

        lock.lock()
        let previous = active
        active = ActiveUtterance(
            turnID: turnID,
            utterance: utterance,
            startedNS: DispatchTime.now().uptimeNanoseconds
        )
        suppressMicrophoneUntilNS = UInt64.max
        lock.unlock()
        if let previous {
            onState(.speechCancelled(turnID: previous.turnID, reason: "superseded"))
        }
        onState(.speechStarted(
            turnID: turnID,
            responseCharacters: text.count,
            localeIdentifier: languageTag
        ))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
            synthesizer.speak(utterance)
        }
    }

    func suppressesMicrophone(at monotonicNS: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active != nil || monotonicNS < suppressMicrophoneUntilNS
    }

    func stop(reason: String) {
        lock.lock()
        let previous = active
        active = nil
        suppressMicrophoneUntilNS = DispatchTime.now().uptimeNanoseconds + 700_000_000
        lock.unlock()
        guard let previous else { return }
        DispatchQueue.main.async { [weak self] in
            self?.synthesizer.stopSpeaking(at: .immediate)
        }
        onState(.speechCancelled(turnID: previous.turnID, reason: reason))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finish(utterance, cancelled: false)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        finish(utterance, cancelled: true)
    }

    private func finish(_ utterance: AVSpeechUtterance, cancelled: Bool) {
        lock.lock()
        guard let active, active.utterance === utterance else {
            lock.unlock()
            return
        }
        self.active = nil
        let completedNS = DispatchTime.now().uptimeNanoseconds
        suppressMicrophoneUntilNS = completedNS + 700_000_000
        lock.unlock()
        if cancelled {
            onState(.speechCancelled(turnID: active.turnID, reason: "synthesizer_cancelled"))
        } else {
            onState(.speechCompleted(
                turnID: active.turnID,
                durationMilliseconds: Double(completedNS - active.startedNS) / 1_000_000
            ))
        }
    }
}

func testLocalSpeechOutput(text: String, localeIdentifier: String) throws -> Double {
    let completion = BlockingSpeechOutputResult()
    let output = LocalSpeechOutput { state in
        switch state {
        case let .speechCompleted(_, durationMilliseconds):
            completion.set(.success(durationMilliseconds))
        case let .speechCancelled(_, reason):
            completion.set(.failure(LocalSpeechInteractionError.speechOutputFailed(reason)))
        default:
            break
        }
    }
    output.speak(text, turnID: "speech-output-test", languageTag: localeIdentifier)
    let deadline = Date(timeIntervalSinceNow: 30)
    while completion.value == nil, Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    guard let result = completion.value else {
        output.stop(reason: "speech_output_timeout")
        throw LocalSpeechInteractionError.speechOutputFailed("speech_output_timeout")
    }
    return try result.get()
}

private final class BlockingSpeechOutputResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Double, Error>?

    func set(_ value: Result<Double, Error>) {
        lock.lock()
        if result == nil { result = value }
        lock.unlock()
    }

    var value: Result<Double, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private final class CodexVoiceHandoff: @unchecked Sendable {
    private struct BridgeEvent: Decodable {
        let event: String
        let turnID: String?
        let assistantText: String?
        let latencyMilliseconds: Double?
        let error: String?
    }

    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let onState: @Sendable (LocalSpeechInteractionState) -> Void
    private let onResponse: @Sendable (String, String, String?) -> Void
    private let decoder: JSONDecoder
    private var receiveBuffer = Data()
    private var ready = false
    private var stopped = false
    private var pendingRequest: CodexAccountTurnRequest?
    private var languageByTurnID: [String: String] = [:]

    init(
        executableURL: URL,
        workingDirectoryURL: URL,
        onState: @escaping @Sendable (LocalSpeechInteractionState) -> Void,
        onResponse: @escaping @Sendable (String, String, String?) -> Void
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LocalSpeechInteractionError.codexBridgeUnavailable("Codex bridge is not executable")
        }
        self.onState = onState
        self.onResponse = onResponse
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        process.executableURL = executableURL
        process.arguments = ["--working-directory", workingDirectoryURL.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.onState(.l2Failed(turnID: nil, reason: "bridge_exit_\(process.terminationStatus)"))
        }
        try process.run()
    }

    func submit(_ request: CodexAccountTurnRequest) -> Bool {
        lock.lock()
        guard !stopped, process.isRunning else {
            lock.unlock()
            return false
        }
        if !ready {
            guard pendingRequest == nil else {
                lock.unlock()
                return false
            }
            pendingRequest = request
            if let languageTag = request.turn.languageTag {
                languageByTurnID[request.turn.turnID] = languageTag
            }
            lock.unlock()
            return true
        }
        if let languageTag = request.turn.languageTag {
            languageByTurnID[request.turn.turnID] = languageTag
        }
        lock.unlock()
        return write(request)
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        receiveBuffer.append(data)
        var lines: [Data] = []
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            lines.append(receiveBuffer.prefix(upTo: newline))
            receiveBuffer.removeSubrange(...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let event = try? decoder.decode(BridgeEvent.self, from: line) else { continue }
            switch event.event {
            case "bridge.ready":
                lock.lock()
                ready = true
                let queued = pendingRequest
                pendingRequest = nil
                lock.unlock()
                if let queued { _ = write(queued) }
            case "turn.completed":
                let turnID = event.turnID ?? "unknown"
                lock.lock()
                let languageTag = languageByTurnID.removeValue(forKey: turnID)
                lock.unlock()
                if let assistantText = event.assistantText {
                    onResponse(turnID, assistantText, languageTag)
                }
                onState(.l2Completed(
                    turnID: turnID,
                    responseCharacters: event.assistantText?.count ?? 0,
                    latencyMilliseconds: event.latencyMilliseconds ?? 0
                ))
            case "turn.failed":
                if let turnID = event.turnID {
                    lock.lock()
                    languageByTurnID.removeValue(forKey: turnID)
                    lock.unlock()
                }
                onState(.l2Failed(
                    turnID: event.turnID,
                    reason: String((event.error ?? "unknown").prefix(192))
                ))
            default:
                break
            }
        }
    }

    private func write(_ request: CodexAccountTurnRequest) -> Bool {
        guard let data = try? JSONEncoder().encode(request) else { return false }
        do {
            try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
            return true
        } catch {
            onState(.l2Failed(turnID: request.turn.turnID, reason: "bridge_write_failed"))
            return false
        }
    }
}
