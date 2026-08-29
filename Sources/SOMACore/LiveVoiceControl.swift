import Foundation

public struct LiveVoiceLaunchGate: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case inactive
        case starting
        case active
    }

    public private(set) var phase: Phase = .inactive
    public private(set) var retryAfterNS: UInt64 = 0

    public init() {}

    public mutating func beginLaunch(at monotonicNS: UInt64) -> Bool {
        guard phase == .inactive, monotonicNS >= retryAfterNS else { return false }
        phase = .starting
        return true
    }

    public mutating func observeActive() {
        phase = .active
        retryAfterNS = 0
    }

    public mutating func observeEnded() {
        phase = .inactive
        retryAfterNS = 0
    }

    public mutating func fail(
        at monotonicNS: UInt64,
        retryMilliseconds: UInt64 = 5_000
    ) {
        phase = .inactive
        let delta = retryMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        if delta.overflow {
            retryAfterNS = UInt64.max
            return
        }
        let deadline = monotonicNS.addingReportingOverflow(delta.partialValue)
        retryAfterNS = deadline.overflow ? UInt64.max : deadline.partialValue
    }
}

/// Owns the local lifetime of one active Live voice session. Only confirmed
/// user activity renews this lease; assistant speech must not keep an idle
/// microphone session alive indefinitely.
public struct LiveVoiceSessionInactivityGate: Equatable, Sendable {
    public let timeoutMilliseconds: UInt64
    public private(set) var deadlineNS: UInt64?

    public init(timeoutMilliseconds: UInt64 = 60_000) {
        precondition(timeoutMilliseconds > 0)
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    @discardableResult
    public mutating func activate(at monotonicNS: UInt64) -> UInt64 {
        renew(at: monotonicNS)
    }

    @discardableResult
    public mutating func recordUserActivity(at monotonicNS: UInt64) -> UInt64? {
        guard deadlineNS != nil else { return nil }
        return renew(at: monotonicNS)
    }

    public func shouldClose(at monotonicNS: UInt64) -> Bool {
        guard let deadlineNS else { return false }
        return monotonicNS >= deadlineNS
    }

    public mutating func close() {
        deadlineNS = nil
    }

    @discardableResult
    private mutating func renew(at monotonicNS: UInt64) -> UInt64 {
        let delta = timeoutMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        let result = monotonicNS.addingReportingOverflow(delta.partialValue)
        let deadline = delta.overflow || result.overflow ? UInt64.max : result.partialValue
        deadlineNS = deadline
        return deadline
    }
}

/// Keeps microphone turns from being assembled out of the assistant's own
/// rendered audio. The short trailing interval lets the microphone settle
/// after output playback ends without turning normal silence into a user turn.
public struct LiveVoicePlaybackCaptureGate: Sendable {
    private let trailingSuppressionNS: UInt64
    private var assistantOutputActive = false
    private var suppressUntilNS: UInt64 = 0

    public init(trailingSuppressionMilliseconds: UInt64 = 500) {
        precondition(trailingSuppressionMilliseconds > 0)
        trailingSuppressionNS = trailingSuppressionMilliseconds * 1_000_000
    }

    public mutating func beginAssistantOutput(at monotonicNS: UInt64) {
        assistantOutputActive = true
        suppressUntilNS = max(suppressUntilNS, monotonicNS)
    }

    public mutating func endAssistantOutput(at monotonicNS: UInt64) {
        assistantOutputActive = false
        let deadline = monotonicNS.addingReportingOverflow(trailingSuppressionNS)
        suppressUntilNS = deadline.overflow ? UInt64.max : max(suppressUntilNS, deadline.partialValue)
    }

    public func suppressesMicrophone(at monotonicNS: UInt64) -> Bool {
        assistantOutputActive || monotonicNS < suppressUntilNS
    }
}

public struct LiveVoiceConditionedAudio: Equatable, Sendable {
    public let samples: [Float]
    public let inputPeakDBFS: Double
    public let appliedGainDB: Double

    public init(samples: [Float], inputPeakDBFS: Double, appliedGainDB: Double) {
        self.samples = samples
        self.inputPeakDBFS = inputPeakDBFS
        self.appliedGainDB = appliedGainDB
    }
}

/// Aligns microphone speech admitted by the local VAD with the level expected
/// by the realtime conversation transport. Non-speech audio is never boosted;
/// a peak limiter bounds transitions from quiet to loud speech.
public struct LiveVoiceInputLeveler: Sendable {
    private let targetRMS: Float
    private let maximumGain: Float
    private let peakCeiling: Float
    private var voiceActive = false
    private var appliedGain: Float = 1

    public init(
        targetDBFS: Double = -26,
        maximumGainDB: Double = 24,
        peakCeiling: Float = 0.92
    ) {
        precondition(targetDBFS < 0)
        precondition(maximumGainDB >= 0)
        precondition(peakCeiling > 0 && peakCeiling <= 1)
        targetRMS = Float(pow(10, targetDBFS / 20))
        maximumGain = Float(pow(10, maximumGainDB / 20))
        self.peakCeiling = peakCeiling
    }

    public mutating func observeVoiceActivity(_ active: Bool) {
        voiceActive = active
        if !active { appliedGain = 1 }
    }

    public mutating func reset() {
        voiceActive = false
        appliedGain = 1
    }

    public mutating func process(_ samples: [Float]) -> LiveVoiceConditionedAudio {
        guard !samples.isEmpty else {
            return LiveVoiceConditionedAudio(
                samples: [],
                inputPeakDBFS: -.infinity,
                appliedGainDB: 0
            )
        }
        var squareSum: Double = 0
        var peak: Float = 0
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            peak = max(peak, abs(finite))
            squareSum += Double(finite * finite)
        }
        let rms = Float(sqrt(squareSum / Double(samples.count)))
        let inputPeakDBFS = peak > 0 ? 20 * log10(Double(peak)) : -.infinity
        guard voiceActive, rms > 0 else {
            appliedGain = 1
            return LiveVoiceConditionedAudio(
                samples: samples.map { $0.isFinite ? $0 : 0 },
                inputPeakDBFS: inputPeakDBFS,
                appliedGainDB: 0
            )
        }

        let speechGain = max(1, targetRMS / rms)
        let limiterGain = peak > 0 ? peakCeiling / peak : maximumGain
        let desiredGain = max(0.1, min(maximumGain, speechGain, limiterGain))
        // Quiet speech needs a fast attack. A sudden loud packet must reduce
        // gain immediately so the leveler cannot turn an ordinary transition
        // into clipping.
        if desiredGain < appliedGain {
            appliedGain = desiredGain
        } else {
            appliedGain += (desiredGain - appliedGain) * 0.85
        }
        let conditioned = samples.map { sample in
            max(-0.98, min(0.98, (sample.isFinite ? sample : 0) * appliedGain))
        }
        return LiveVoiceConditionedAudio(
            samples: conditioned,
            inputPeakDBFS: inputPeakDBFS,
            appliedGainDB: 20 * log10(Double(max(appliedGain, 0.000_001)))
        )
    }
}

public enum LiveVoiceAudioRoutingPolicy {
    public static func forwards(
        sessionActive: Bool,
        requiresVerifiedSpeakerForEveryTurn: Bool,
        currentTurnAdmitted: Bool
    ) -> Bool {
        sessionActive
            && (!requiresVerifiedSpeakerForEveryTurn || currentTurnAdmitted)
    }
}

/// Retains a short timestamped detector history, then cuts one bounded episode
/// at the VAD onset capture. This preserves audio queued while VAD inference is
/// in flight without admitting older inter-episode sound or duplicating the
/// onset frame.
public struct LiveVoiceTimestampedEpisodeBuffer<Element: Sendable>: Sendable {
    private struct Entry: Sendable {
        let value: Element
        let captureNS: UInt64
        let durationNS: UInt64
    }

    private let detectorHistoryNS: UInt64
    private let maximumEpisodeDurationNS: UInt64
    private var episodeActive = false
    private var detectorHistory: [Entry] = []
    private var episode: [Entry] = []
    private var episodeDurationNS: UInt64 = 0

    public init(
        detectorHistoryNS: UInt64,
        maximumEpisodeDurationNS: UInt64
    ) {
        precondition(detectorHistoryNS > 0)
        precondition(maximumEpisodeDurationNS > 0)
        self.detectorHistoryNS = detectorHistoryNS
        self.maximumEpisodeDurationNS = maximumEpisodeDurationNS
    }

    public mutating func ingest(
        _ value: Element,
        captureNS: UInt64,
        durationNS: UInt64
    ) {
        guard durationNS > 0 else { return }
        let entry = Entry(value: value, captureNS: captureNS, durationNS: durationNS)
        if episodeActive {
            appendToEpisode(entry)
            return
        }
        detectorHistory.append(entry)
        detectorHistory.removeAll {
            captureNS >= $0.captureNS && captureNS - $0.captureNS > detectorHistoryNS
        }
    }

    public mutating func begin(at onsetCaptureNS: UInt64) {
        episodeActive = true
        episode.removeAll(keepingCapacity: true)
        episodeDurationNS = 0
        for entry in detectorHistory where entry.captureNS >= onsetCaptureNS {
            appendToEpisode(entry)
        }
        detectorHistory.removeAll(keepingCapacity: true)
    }

    /// Starts an episode at an exact timestamp. If the onset falls inside a
    /// captured chunk, only the post-onset suffix enters the episode.
    public mutating func begin(
        at onsetCaptureNS: UInt64,
        splitting: (Element, UInt64) -> (prefix: Element, suffix: Element)?
    ) {
        episodeActive = true
        episode.removeAll(keepingCapacity: true)
        episodeDurationNS = 0
        for entry in detectorHistory where entry.captureNS > onsetCaptureNS {
            let startNS = entry.captureNS >= entry.durationNS
                ? entry.captureNS - entry.durationNS
                : 0
            if startNS < onsetCaptureNS,
               onsetCaptureNS < entry.captureNS {
                let prefixDurationNS = onsetCaptureNS - startNS
                if let split = splitting(entry.value, prefixDurationNS) {
                    appendToEpisode(Entry(
                        value: split.suffix,
                        captureNS: entry.captureNS,
                        durationNS: entry.durationNS - prefixDurationNS
                    ))
                }
            } else {
                appendToEpisode(entry)
            }
        }
        detectorHistory.removeAll(keepingCapacity: true)
    }

    public mutating func take() -> [Element] {
        let result = episode.map(\.value)
        episode.removeAll(keepingCapacity: true)
        episodeDurationNS = 0
        return result
    }

    public mutating func take(throughCaptureNS maximumCaptureNS: UInt64) -> [Element] {
        var boundary = 0
        while boundary < episode.count,
              episode[boundary].captureNS <= maximumCaptureNS {
            boundary += 1
        }
        guard boundary > 0 else { return [] }
        let released = Array(episode[..<boundary])
        episode.removeFirst(boundary)
        for entry in released { episodeDurationNS -= entry.durationNS }
        return released.map(\.value)
    }

    /// Releases exactly the portion covered by the latest detector result.
    /// A chunk crossing the boundary is split so a following offset or
    /// rejection cannot discard audio that has already been verified.
    public mutating func take(
        throughCaptureNS maximumCaptureNS: UInt64,
        splitting: (Element, UInt64) -> (prefix: Element, suffix: Element)?
    ) -> [Element] {
        var boundary = 0
        while boundary < episode.count,
              episode[boundary].captureNS <= maximumCaptureNS {
            boundary += 1
        }

        var released = boundary > 0 ? Array(episode[..<boundary]) : []
        if boundary > 0 {
            episode.removeFirst(boundary)
            for entry in released { episodeDurationNS -= entry.durationNS }
        }

        guard let crossing = episode.first else {
            return released.map(\.value)
        }
        let crossingStartNS = crossing.captureNS >= crossing.durationNS
            ? crossing.captureNS - crossing.durationNS
            : 0
        guard crossingStartNS < maximumCaptureNS,
              maximumCaptureNS < crossing.captureNS else {
            return released.map(\.value)
        }
        let prefixDurationNS = maximumCaptureNS - crossingStartNS
        guard prefixDurationNS < crossing.durationNS,
              let split = splitting(crossing.value, prefixDurationNS) else {
            return released.map(\.value)
        }
        let suffixDurationNS = crossing.durationNS - prefixDurationNS
        released.append(Entry(
            value: split.prefix,
            captureNS: maximumCaptureNS,
            durationNS: prefixDurationNS
        ))
        episode[0] = Entry(
            value: split.suffix,
            captureNS: crossing.captureNS,
            durationNS: suffixDurationNS
        )
        episodeDurationNS -= prefixDurationNS
        return released.map(\.value)
    }

    public mutating func end(keepingCapacity: Bool = true) {
        episodeActive = false
        episode.removeAll(keepingCapacity: keepingCapacity)
        detectorHistory.removeAll(keepingCapacity: keepingCapacity)
        episodeDurationNS = 0
    }

    public mutating func end(
        preservingDetectorHistoryFrom captureNS: UInt64,
        keepingCapacity: Bool = true
    ) {
        let preserved = (detectorHistory + episode).filter { $0.captureNS >= captureNS }
        episodeActive = false
        episode.removeAll(keepingCapacity: keepingCapacity)
        detectorHistory = preserved
        episodeDurationNS = 0
    }

    private mutating func appendToEpisode(_ entry: Entry) {
        episode.append(entry)
        let (sum, overflow) = episodeDurationNS.addingReportingOverflow(entry.durationNS)
        episodeDurationNS = overflow ? UInt64.max : sum
        while episodeDurationNS > maximumEpisodeDurationNS, episode.count > 1 {
            episodeDurationNS -= episode.removeFirst().durationNS
        }
    }
}
