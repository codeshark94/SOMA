import Accelerate
import Foundation

public enum LiveVoiceEchoRelationship: String, Equatable, Sendable {
    case insufficientEvidence = "insufficient_evidence"
    case ambiguous
    case echoDominated = "echo_dominated"
    case acousticallyIndependent = "acoustically_independent"
}

public struct LiveVoiceEchoAssessment: Equatable, Sendable {
    public let relationship: LiveVoiceEchoRelationship
    public let maximumCorrelation: Double
    public let microphoneSamples: Int
    public let referenceSamples: Int

    public init(
        relationship: LiveVoiceEchoRelationship,
        maximumCorrelation: Double,
        microphoneSamples: Int,
        referenceSamples: Int
    ) {
        self.relationship = relationship
        self.maximumCorrelation = maximumCorrelation
        self.microphoneSamples = microphoneSamples
        self.referenceSamples = referenceSamples
    }

    public var permitsBargeIn: Bool { relationship == .acousticallyIndependent }
}

public struct LiveVoiceAcousticBargeInObservation: Equatable, Sendable {
    public let admitted: Bool
    public let becameAdmitted: Bool
    public let becameRevoked: Bool

    public init(admitted: Bool, becameAdmitted: Bool, becameRevoked: Bool) {
        self.admitted = admitted
        self.becameAdmitted = becameAdmitted
        self.becameRevoked = becameRevoked
    }
}

/// Requires acoustic independence to remain stable before microphone audio can
/// interrupt assistant playback. A single early correlation estimate is not
/// authoritative because the loudspeaker reference and room echo arrive on
/// different buffers. Independence is therefore provisional until it persists,
/// and any later loss of independence revokes the admission for that episode.
public struct LiveVoiceAcousticBargeInGate: Sendable {
    private let requiredIndependentNS: UInt64
    private var independentSinceNS: UInt64?
    private var admitted = false

    public init(requiredIndependentMilliseconds: UInt64 = 500) {
        precondition(requiredIndependentMilliseconds > 0)
        precondition(requiredIndependentMilliseconds <= UInt64.max / 1_000_000)
        requiredIndependentNS = requiredIndependentMilliseconds * 1_000_000
    }

    public mutating func observe(
        speechActive: Bool,
        speakerVerified: Bool,
        relationship: LiveVoiceEchoRelationship,
        at monotonicNS: UInt64
    ) -> LiveVoiceAcousticBargeInObservation {
        let wasAdmitted = admitted
        guard speechActive, speakerVerified else {
            reset()
            return .init(
                admitted: false,
                becameAdmitted: false,
                becameRevoked: wasAdmitted
            )
        }

        guard relationship == .acousticallyIndependent else {
            independentSinceNS = nil
            admitted = false
            return .init(
                admitted: false,
                becameAdmitted: false,
                becameRevoked: wasAdmitted
            )
        }

        if independentSinceNS == nil {
            independentSinceNS = monotonicNS
        }
        if let independentSinceNS,
           monotonicNS >= independentSinceNS,
           monotonicNS - independentSinceNS >= requiredIndependentNS {
            admitted = true
        }
        return .init(
            admitted: admitted,
            becameAdmitted: admitted && !wasAdmitted,
            becameRevoked: false
        )
    }

    public mutating func reset() {
        independentSinceNS = nil
        admitted = false
    }
}

/// Binds an interruption to a new speech onset inside the current assistant
/// output episode. Speech that opened the turn can still be active when the
/// model begins responding; its detector tail is not a participant barge-in.
public struct LiveVoiceBargeInEpisodeBoundary: Equatable, Sendable {
    private var assistantOutputStartedNS: UInt64?
    public private(set) var hasNewSpeechOnset = false

    public init() {}

    public mutating func beginAssistantOutput(at monotonicNS: UInt64) {
        assistantOutputStartedNS = monotonicNS
        hasNewSpeechOnset = false
    }

    public mutating func observeSpeechOnset(at monotonicNS: UInt64) {
        guard let assistantOutputStartedNS,
              monotonicNS > assistantOutputStartedNS else { return }
        hasNewSpeechOnset = true
    }

    public func admitsSpeakerEvidence(observedAt monotonicNS: UInt64?) -> Bool {
        guard hasNewSpeechOnset,
              let assistantOutputStartedNS,
              let monotonicNS,
              monotonicNS > assistantOutputStartedNS else { return false }
        return true
    }

    public mutating func endAssistantOutput() {
        assistantOutputStartedNS = nil
        hasNewSpeechOnset = false
    }

    public mutating func reset() {
        endAssistantOutput()
    }
}

public enum LiveVoicePlaybackReferenceSource: String, Sendable {
    case appServer = "app_server"
    case webRTCPlayback = "webrtc_playback"
}

public struct LiveVoicePlaybackReferenceDecision: Equatable, Sendable {
    public let accepted: Bool
    public let resetsReference: Bool

    public init(accepted: Bool, resetsReference: Bool) {
        self.accepted = accepted
        self.resetsReference = resetsReference
    }
}

/// Prefers the PCM that actually enters the speaker render graph. Upstream
/// app-server audio is only a temporary fallback because codec, resampling,
/// concealment, and render processing can change the acoustic waveform.
public struct LiveVoicePlaybackReferenceArbiter: Sendable {
    public private(set) var selectedSource: LiveVoicePlaybackReferenceSource?

    public init() {}

    public mutating func observe(
        _ source: LiveVoicePlaybackReferenceSource
    ) -> LiveVoicePlaybackReferenceDecision {
        guard let selectedSource else {
            self.selectedSource = source
            return .init(accepted: true, resetsReference: false)
        }
        if selectedSource == source {
            return .init(accepted: true, resetsReference: false)
        }
        if source == .webRTCPlayback {
            self.selectedSource = source
            return .init(accepted: true, resetsReference: true)
        }
        return .init(accepted: false, resetsReference: false)
    }
}

/// Compares the exact assistant-output PCM with the camera microphone stream.
/// The comparison is delay- and gain-invariant so loudspeaker leakage remains
/// identifiable after room delay, device gain, and polarity changes. Visual
/// speaker evidence may strengthen a participant turn, but can never override
/// an acoustically matching playback reference.
public struct LiveVoiceEchoReferenceMatcher: Sendable {
    public static let analysisSampleRate = 8_000

    private let minimumAnalysisSamples: Int
    private let maximumAnalysisSamples: Int
    private let maximumReferenceSamples: Int
    private let maximumMicrophoneSamples: Int
    private let echoCorrelationThreshold: Double
    private let independentCorrelationThreshold: Double

    private var reference: [Float] = []
    private var microphone: [Float] = []

    public init(
        minimumAnalysisMilliseconds: Int = 120,
        maximumAnalysisMilliseconds: Int = 420,
        referenceRetentionMilliseconds: Int = 3_000,
        microphoneRetentionMilliseconds: Int = 1_200,
        echoCorrelationThreshold: Double = 0.36,
        independentCorrelationThreshold: Double = 0.24
    ) {
        precondition(minimumAnalysisMilliseconds > 0)
        precondition(maximumAnalysisMilliseconds >= minimumAnalysisMilliseconds)
        precondition(referenceRetentionMilliseconds >= maximumAnalysisMilliseconds)
        precondition(microphoneRetentionMilliseconds >= maximumAnalysisMilliseconds)
        precondition((0...1).contains(independentCorrelationThreshold))
        precondition((0...1).contains(echoCorrelationThreshold))
        precondition(independentCorrelationThreshold < echoCorrelationThreshold)
        minimumAnalysisSamples = minimumAnalysisMilliseconds * Self.analysisSampleRate / 1_000
        maximumAnalysisSamples = maximumAnalysisMilliseconds * Self.analysisSampleRate / 1_000
        maximumReferenceSamples = referenceRetentionMilliseconds * Self.analysisSampleRate / 1_000
        maximumMicrophoneSamples = microphoneRetentionMilliseconds * Self.analysisSampleRate / 1_000
        self.echoCorrelationThreshold = echoCorrelationThreshold
        self.independentCorrelationThreshold = independentCorrelationThreshold
    }

    public mutating func reset() {
        reference.removeAll(keepingCapacity: true)
        microphone.removeAll(keepingCapacity: true)
    }

    public mutating func appendReference(
        _ samples: [Float],
        sampleRate: Int,
        channels: Int = 1
    ) {
        append(
            Self.resampledMono(samples, sampleRate: sampleRate, channels: channels),
            to: &reference,
            retaining: maximumReferenceSamples
        )
    }

    public mutating func appendMicrophone(_ samples: [Float], sampleRate: Int) {
        append(
            Self.resampledMono(samples, sampleRate: sampleRate, channels: 1),
            to: &microphone,
            retaining: maximumMicrophoneSamples
        )
    }

    public func assess() -> LiveVoiceEchoAssessment {
        let sampleCount = min(maximumAnalysisSamples, microphone.count)
        guard sampleCount >= minimumAnalysisSamples,
              reference.count >= sampleCount else {
            return LiveVoiceEchoAssessment(
                relationship: .insufficientEvidence,
                maximumCorrelation: 0,
                microphoneSamples: microphone.count,
                referenceSamples: reference.count
            )
        }

        let microphoneWindow = Array(microphone.suffix(sampleCount))
        let microphoneDifference = Self.firstDifference(microphoneWindow)
        let microphoneEnergy = Self.energy(microphoneDifference)
        guard microphoneEnergy > 0.000_001 else {
            return LiveVoiceEchoAssessment(
                relationship: .insufficientEvidence,
                maximumCorrelation: 0,
                microphoneSamples: microphone.count,
                referenceSamples: reference.count
            )
        }

        // Only recent output can have reached the microphone. The retained
        // window is longer than ordinary acoustic delay and WebRTC buffering,
        // while avoiding accidental matches against old repeated phrases.
        let latestSearchStart = max(0, reference.count - maximumReferenceSamples)
        let latestCandidateStart = reference.count - sampleCount
        guard latestCandidateStart >= latestSearchStart else {
            return LiveVoiceEchoAssessment(
                relationship: .insufficientEvidence,
                maximumCorrelation: 0,
                microphoneSamples: microphone.count,
                referenceSamples: reference.count
            )
        }

        let referenceWindow = Array(reference[latestSearchStart...])
        let referenceDifference = Self.firstDifference(referenceWindow)
        let candidateCount = latestCandidateStart - latestSearchStart + 1
        var dotProducts = [Float](repeating: 0, count: candidateCount)
        vDSP.correlate(
            referenceDifference,
            withKernel: microphoneDifference,
            result: &dotProducts
        )
        var energyPrefix = [Double](repeating: 0, count: referenceDifference.count + 1)
        for index in referenceDifference.indices {
            let value = Double(referenceDifference[index])
            energyPrefix[index + 1] = energyPrefix[index] + value * value
        }
        var bestCorrelation = 0.0
        let differenceCount = microphoneDifference.count
        for candidate in 0..<candidateCount {
            let referenceEnergy = energyPrefix[candidate + differenceCount]
                - energyPrefix[candidate]
            guard referenceEnergy > 0.000_001 else { continue }
            let normalized = abs(Double(dotProducts[candidate]))
                / sqrt(microphoneEnergy * referenceEnergy)
            bestCorrelation = max(bestCorrelation, min(1, normalized))
        }

        let relationship: LiveVoiceEchoRelationship
        if bestCorrelation >= echoCorrelationThreshold {
            relationship = .echoDominated
        } else if bestCorrelation <= independentCorrelationThreshold {
            relationship = .acousticallyIndependent
        } else {
            relationship = .ambiguous
        }
        return LiveVoiceEchoAssessment(
            relationship: relationship,
            maximumCorrelation: bestCorrelation,
            microphoneSamples: microphone.count,
            referenceSamples: reference.count
        )
    }

    private func append(_ samples: [Float], to buffer: inout [Float], retaining limit: Int) {
        guard !samples.isEmpty else { return }
        buffer.append(contentsOf: samples)
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
    }

    private static func resampledMono(
        _ samples: [Float],
        sampleRate: Int,
        channels: Int
    ) -> [Float] {
        guard sampleRate > 0,
              channels > 0,
              samples.count >= channels else { return [] }
        let frameCount = samples.count / channels
        guard frameCount > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channels {
                let value = samples[frame * channels + channel]
                sum += value.isFinite ? value : 0
            }
            mono[frame] = sum / Float(channels)
        }
        guard sampleRate != analysisSampleRate, frameCount > 1 else { return mono }
        let outputCount = max(1, Int((Double(frameCount) * Double(analysisSampleRate)
            / Double(sampleRate)).rounded(.down)))
        let scale = Double(sampleRate) / Double(analysisSampleRate)
        return (0..<outputCount).map { index in
            let position = min(Double(frameCount - 1), Double(index) * scale)
            let lower = Int(position.rounded(.down))
            let upper = min(frameCount - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            return mono[lower] + (mono[upper] - mono[lower]) * fraction
        }
    }

    private static func firstDifference(_ samples: [Float]) -> [Float] {
        guard samples.count > 1 else { return [] }
        return (1..<samples.count).map { samples[$0] - samples[$0 - 1] }
    }

    private static func energy(_ samples: [Float]) -> Double {
        samples.reduce(into: 0.0) { result, value in
            result += Double(value) * Double(value)
        }
    }

}
