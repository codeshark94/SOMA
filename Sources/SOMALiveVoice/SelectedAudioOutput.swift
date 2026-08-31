import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import SOMACore

private struct RenderedFloatPCMSnapshot: @unchecked Sendable {
    let planarSamples: Data
    let sampleRate: Int
    let channels: Int
    let samplesPerChannel: Int
}

/// Keeps post-effect echo-reference work off AVAudioEngine's realtime render
/// callback. A bounded queue is intentional: a late reference is no longer
/// useful for acoustic comparison and must not build backpressure on playback.
private final class RenderedPCMReferencePipeline: @unchecked Sendable {
    typealias Handler = @Sendable (SelectedAudioOutput.RenderedPCM) -> Void

    private let handler: Handler
    private let queue = DispatchQueue(
        label: "soma.live-voice.rendered-reference",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var pendingSnapshots = 0
    private let maximumPendingSnapshots = 2

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func capture(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard pendingSnapshots < maximumPendingSnapshots else {
            lock.unlock()
            return
        }
        pendingSnapshots += 1
        lock.unlock()

        guard let snapshot = Self.snapshot(buffer) else {
            finishSnapshot()
            return
        }
        queue.async { [self] in
            defer { finishSnapshot() }
            guard let rendered = Self.encode(snapshot) else { return }
            handler(rendered)
        }
    }

    private func finishSnapshot() {
        lock.lock()
        pendingSnapshots = max(0, pendingSnapshots - 1)
        lock.unlock()
    }

    /// The render callback performs one bounded allocation and memcpy per
    /// channel. Sample conversion, RMS measurement, JSON encoding, and IPC all
    /// happen later on `queue`.
    private static func snapshot(_ buffer: AVAudioPCMBuffer) -> RenderedFloatPCMSnapshot? {
        let samplesPerChannel = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard samplesPerChannel > 0,
              channels > 0,
              let channelData = buffer.floatChannelData else { return nil }
        let bytesPerChannel = samplesPerChannel * MemoryLayout<Float>.size
        var planarSamples = Data(count: bytesPerChannel * channels)
        planarSamples.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else { return }
            for channel in 0..<channels {
                memcpy(
                    baseAddress.advanced(by: channel * bytesPerChannel),
                    channelData[channel],
                    bytesPerChannel
                )
            }
        }
        return RenderedFloatPCMSnapshot(
            planarSamples: planarSamples,
            sampleRate: Int(buffer.format.sampleRate.rounded()),
            channels: channels,
            samplesPerChannel: samplesPerChannel
        )
    }

    private static func encode(_ snapshot: RenderedFloatPCMSnapshot) -> SelectedAudioOutput.RenderedPCM? {
        var sumOfSquares: Double = 0
        var encoded = Data(count: snapshot.samplesPerChannel * snapshot.channels * 2)
        snapshot.planarSamples.withUnsafeBytes { source in
            let samples = source.bindMemory(to: Float.self)
            encoded.withUnsafeMutableBytes { destination in
                let bytes = destination.bindMemory(to: UInt8.self)
                for frame in 0..<snapshot.samplesPerChannel {
                    for channel in 0..<snapshot.channels {
                        let sourceIndex = channel * snapshot.samplesPerChannel + frame
                        let sample = max(-1, min(1, samples[sourceIndex]))
                        sumOfSquares += Double(sample * sample)
                        let integer = Int16((sample * 32_767).rounded())
                        let bits = UInt16(bitPattern: integer)
                        let destinationIndex = (frame * snapshot.channels + channel) * 2
                        bytes[destinationIndex] = UInt8(bits & 0x00ff)
                        bytes[destinationIndex + 1] = UInt8((bits >> 8) & 0x00ff)
                    }
                }
            }
        }
        let rms = sqrt(sumOfSquares / Double(snapshot.samplesPerChannel * snapshot.channels))
        guard rms >= 0.00005 else { return nil }
        return SelectedAudioOutput.RenderedPCM(
            data: encoded,
            sampleRate: snapshot.sampleRate,
            channels: snapshot.channels,
            samplesPerChannel: snapshot.samplesPerChannel
        )
    }
}

@MainActor
final class SelectedAudioOutput {
    struct PlayoutStatus: Sendable {
        let state: String
        let sampleRate: Int
        let channels: Int
        let chunkDurationMilliseconds: Double
        let arrivalGapMilliseconds: Double?
        let queuedDurationMilliseconds: Double
        let underruns: Int
    }

    struct RenderedPCM: Sendable {
        let data: Data
        let sampleRate: Int
        let channels: Int
        let samplesPerChannel: Int
    }

    enum OutputError: LocalizedError {
        case noOutputDevice
        case deviceSelectionFailed(OSStatus)
        case invalidPCM
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .noOutputDevice:
                "No audio output device is available"
            case let .deviceSelectionFailed(status):
                "Could not select the audio output device (OSStatus \(status))"
            case .invalidPCM:
                "Realtime audio output was malformed"
            case let .engineStartFailed(message):
                "Could not start audio output: \(message)"
            }
        }
    }

    let selectedUID: String?
    let selectedName: String
    let resolution: String
    let isSystemDefault: Bool

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let voiceMode: SOMARealtimeVoiceMode
    private let effectProfile: SOMARealtimeVoiceDSPProfile?
    private let timePitch: AVAudioUnitTimePitch?
    private let dynamics: AVAudioUnitEffect?
    private let tonalEqualizer: AVAudioUnitEQ?
    private let echoUnits: [(delay: AVAudioUnitDelay, equalizer: AVAudioUnitEQ)]
    private let reverb: AVAudioUnitReverb?
    private let renderedReferencePipeline: RenderedPCMReferencePipeline?
    private let playoutStatusHandler: ((PlayoutStatus) -> Void)?
    private var sourceFormat: AVAudioFormat?
    private var renderTapInstalled = false
    private var queuedBuffers = 0
    private var queuedDurationSeconds: TimeInterval = 0
    private var playbackGeneration: UInt64 = 0
    private var primingWorkItem: DispatchWorkItem?
    private var speechStreamActive = false
    private var lastEnqueueNS: UInt64?
    private var underrunCount = 0
    private var currentSpeechUnderruns = 0
    private var adaptivePlayoutLeadSeconds: TimeInterval

    /// WebRTC delivers small PCM blocks through a WebKit-to-Swift bridge.
    /// Starting playback on the first block exposes ordinary bridge jitter as
    /// audible gaps, so retain a short playout lead before releasing audio.
    private let baselinePlayoutLeadSeconds: TimeInterval
    private let maximumPlayoutLeadSeconds: TimeInterval = 0.36

    init(
        preferredUID: String?,
        voiceMode: SOMARealtimeVoiceMode = .natural,
        renderedPCMHandler: (@Sendable (RenderedPCM) -> Void)? = nil,
        playoutStatusHandler: ((PlayoutStatus) -> Void)? = nil
    ) throws {
        self.voiceMode = voiceMode
        renderedReferencePipeline = renderedPCMHandler.map(RenderedPCMReferencePipeline.init(handler:))
        self.playoutStatusHandler = playoutStatusHandler
        baselinePlayoutLeadSeconds = voiceMode.requiresProcessedPlayback ? 0.22 : 0.16
        adaptivePlayoutLeadSeconds = baselinePlayoutLeadSeconds
        let profile: SOMARealtimeVoiceDSPProfile? = voiceMode == .spaceMarine
            ? .spaceMarine
            : nil
        effectProfile = profile
        if let profile {
            timePitch = AVAudioUnitTimePitch()
            dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_DynamicsProcessor,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            ))
            tonalEqualizer = AVAudioUnitEQ(numberOfBands: profile.equalizerBands.count)
            echoUnits = profile.echoStages.map { stage in
                (
                    delay: AVAudioUnitDelay(),
                    equalizer: AVAudioUnitEQ(numberOfBands: stage.successiveEqualization.count)
                )
            }
            reverb = AVAudioUnitReverb()
        } else {
            timePitch = nil
            dynamics = nil
            tonalEqualizer = nil
            echoUnits = []
            reverb = nil
        }
        let snapshot = SOMAAudioDeviceCatalog.snapshot()
        let selected: SOMAAudioDeviceDescriptor?
        if let preferredUID,
           let preferred = snapshot.outputs.first(where: { $0.uid == preferredUID }) {
            selected = preferred
            resolution = "preferred"
        } else if let defaultUID = snapshot.defaultOutputUID,
                  let systemDefault = snapshot.outputs.first(where: { $0.uid == defaultUID }) {
            selected = systemDefault
            resolution = preferredUID == nil
                ? "system_default"
                : "preferred_unavailable_system_fallback"
        } else {
            selected = snapshot.outputs.first
            resolution = preferredUID == nil
                ? "first_available_fallback"
                : "preferred_unavailable_first_available_fallback"
        }
        guard let selected else { throw OutputError.noOutputDevice }
        selectedUID = selected.uid
        selectedName = selected.name
        isSystemDefault = selected.uid == snapshot.defaultOutputUID

        guard let deviceID = SOMAAudioDeviceCatalog.deviceID(
            forUID: selected.uid,
            scope: .output
        ), let audioUnit = engine.outputNode.audioUnit else {
            throw OutputError.noOutputDevice
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw OutputError.deviceSelectionFailed(status) }
        engine.attach(player)
        attachEffectGraphNodes()
        configureEffectParameters()
    }

    func enqueuePCM16(
        _ data: Data,
        sampleRate: Double,
        channels: Int,
        samplesPerChannel: Int
    ) throws {
        let renderChannels = effectProfile == nil ? channels : max(2, channels)
        guard sampleRate >= 8_000,
              sampleRate <= 96_000,
              (1...8).contains(channels),
              (1...8).contains(renderChannels),
              samplesPerChannel > 0,
              data.count == samplesPerChannel * channels * 2,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(renderChannels),
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samplesPerChannel)
              ),
              let channelData = buffer.floatChannelData else {
            throw OutputError.invalidPCM
        }
        try configureIfNeeded(format)
        buffer.frameLength = AVAudioFrameCount(samplesPerChannel)
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for frame in 0..<samplesPerChannel {
                for channel in 0..<renderChannels {
                    let sourceChannel = min(channel, channels - 1)
                    let index = (frame * channels + sourceChannel) * 2
                    let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                    channelData[channel][frame] = Float(Int16(bitPattern: bits)) / 32_768
                }
            }
        }
        let duration = Double(samplesPerChannel) / sampleRate
        let enqueueNS = DispatchTime.now().uptimeNanoseconds
        let arrivalGapMilliseconds = lastEnqueueNS.map {
            Double(enqueueNS >= $0 ? enqueueNS - $0 : 0) / 1_000_000
        }
        lastEnqueueNS = enqueueNS
        let generation = playbackGeneration
        queuedBuffers += 1
        queuedDurationSeconds += duration
        if queuedBuffers == 1 || (arrivalGapMilliseconds ?? 0) > max(45, duration * 1_750) {
            emitPlayoutStatus(
                state: queuedBuffers == 1 ? "chunk_received" : "arrival_gap",
                sampleRate: Int(sampleRate.rounded()),
                channels: renderChannels,
                chunkDuration: duration,
                arrivalGapMilliseconds: arrivalGapMilliseconds
            )
        }
        player.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedBuffers = max(0, self.queuedBuffers - 1)
                self.queuedDurationSeconds = max(0, self.queuedDurationSeconds - duration)
                if self.queuedBuffers == 0 {
                    self.primingWorkItem?.cancel()
                    self.primingWorkItem = nil
                    if self.speechStreamActive {
                        // Once the producer has starved the player, continuing
                        // its clock turns every subsequent small chunk into a
                        // separate audible fragment. Pause once and rebuild a
                        // bounded lead before resuming the continuous stream.
                        if self.player.isPlaying { self.player.pause() }
                        self.underrunCount += 1
                        self.currentSpeechUnderruns += 1
                        self.adaptivePlayoutLeadSeconds = min(
                            self.maximumPlayoutLeadSeconds,
                            max(
                                self.adaptivePlayoutLeadSeconds + 0.04,
                                ((arrivalGapMilliseconds ?? 0) / 1_000) * 1.5
                            )
                        )
                        self.emitPlayoutStatus(
                            state: "underrun",
                            sampleRate: Int(sampleRate.rounded()),
                            channels: renderChannels,
                            chunkDuration: duration,
                            arrivalGapMilliseconds: arrivalGapMilliseconds
                        )
                    } else if self.player.isPlaying {
                        self.player.pause()
                    }
                }
            }
        }
        primePlaybackIfNeeded()
    }

    func beginSpeech() {
        if !speechStreamActive {
            currentSpeechUnderruns = 0
        }
        speechStreamActive = true
        lastEnqueueNS = nil
    }

    func finishSpeech() {
        speechStreamActive = false
        primingWorkItem?.cancel()
        primingWorkItem = nil
        if queuedBuffers > 0 {
            if !player.isPlaying { player.play() }
        } else if player.isPlaying {
            player.pause()
        }
        // Retain evidence from a real underrun across turns, but recover
        // gradually after a response drains normally.
        if currentSpeechUnderruns == 0 {
            adaptivePlayoutLeadSeconds = max(
                baselinePlayoutLeadSeconds,
                adaptivePlayoutLeadSeconds - 0.02
            )
        }
        currentSpeechUnderruns = 0
        lastEnqueueNS = nil
    }

    func flush() {
        playbackGeneration &+= 1
        primingWorkItem?.cancel()
        primingWorkItem = nil
        queuedBuffers = 0
        queuedDurationSeconds = 0
        speechStreamActive = false
        lastEnqueueNS = nil
        player.stop()
    }

    func stop() {
        player.stop()
        engine.stop()
        if renderTapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            renderTapInstalled = false
        }
    }

    private func configureIfNeeded(_ format: AVAudioFormat) throws {
        if let sourceFormat,
           sourceFormat.sampleRate == format.sampleRate,
           sourceFormat.channelCount == format.channelCount,
           engine.isRunning {
            return
        }
        flush()
        engine.stop()
        if renderTapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            renderTapInstalled = false
        }
        engine.disconnectNodeOutput(player)
        for node in effectGraphNodes {
            engine.disconnectNodeOutput(node)
        }
        let nodes = effectGraphNodes
        if let first = nodes.first {
            engine.connect(player, to: first, format: format)
            for (upstream, downstream) in zip(nodes, nodes.dropFirst()) {
                engine.connect(upstream, to: downstream, format: nil)
            }
            engine.connect(nodes[nodes.count - 1], to: engine.mainMixerNode, format: nil)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        installRenderedPCMTapIfNeeded()
        engine.prepare()
        do {
            try engine.start()
            sourceFormat = format
        } catch {
            throw OutputError.engineStartFailed(error.localizedDescription)
        }
    }

    private var effectGraphNodes: [AVAudioNode] {
        var nodes: [AVAudioNode] = []
        if let timePitch { nodes.append(timePitch) }
        if let dynamics { nodes.append(dynamics) }
        if let tonalEqualizer { nodes.append(tonalEqualizer) }
        for echo in echoUnits {
            nodes.append(echo.delay)
            nodes.append(echo.equalizer)
        }
        if let reverb { nodes.append(reverb) }
        return nodes
    }

    private func attachEffectGraphNodes() {
        for node in effectGraphNodes {
            engine.attach(node)
        }
    }

    private func configureEffectParameters() {
        guard let effectProfile else { return }
        timePitch?.pitch = effectProfile.pitchCents
        timePitch?.rate = 1
        timePitch?.overlap = effectProfile.pitchOverlap
        setDynamicsParameter(kDynamicsProcessorParam_Threshold, effectProfile.compressorThreshold)
        setDynamicsParameter(kDynamicsProcessorParam_HeadRoom, effectProfile.compressorHeadRoom)
        setDynamicsParameter(kDynamicsProcessorParam_AttackTime, effectProfile.compressorAttackTime)
        setDynamicsParameter(kDynamicsProcessorParam_ReleaseTime, effectProfile.compressorReleaseTime)
        setDynamicsParameter(kDynamicsProcessorParam_ExpansionRatio, 1)
        setDynamicsParameter(kDynamicsProcessorParam_OverallGain, effectProfile.compressorMasterGain)
        if let tonalEqualizer {
            Self.configure(tone: tonalEqualizer, from: effectProfile.equalizerBands)
        }
        for (index, stage) in effectProfile.echoStages.enumerated() {
            let unit = echoUnits[index]
            unit.delay.delayTime = stage.delaySeconds
            unit.delay.feedback = stage.feedbackPercent
            unit.delay.wetDryMix = stage.wetDryMixPercent
            unit.delay.lowPassCutoff = 20_000
            Self.configure(tone: unit.equalizer, from: stage.successiveEqualization)
        }
        reverb?.loadFactoryPreset(.largeHall2)
        reverb?.wetDryMix = effectProfile.reverbWetDryMix
    }

    private func setDynamicsParameter(_ parameter: AudioUnitParameterID, _ value: Float) {
        guard let audioUnit = dynamics?.audioUnit else { return }
        AudioUnitSetParameter(
            audioUnit,
            parameter,
            kAudioUnitScope_Global,
            0,
            value,
            0
        )
    }

    private static func configure(tone equalizer: AVAudioUnitEQ, from bands: [SOMARealtimeVoiceDSPProfile.EQBand]) {
        for (unitBand, profileBand) in zip(equalizer.bands, bands) {
            switch profileBand.kind {
            case .highPass:
                unitBand.filterType = .highPass
            case .lowShelf:
                unitBand.filterType = .lowShelf
            case .parametric:
                unitBand.filterType = .parametric
            case .highShelf:
                unitBand.filterType = .highShelf
            }
            unitBand.frequency = min(20_000, max(20, profileBand.frequency))
            unitBand.gain = profileBand.gain
            unitBand.bandwidth = profileBand.bandwidth
            unitBand.bypass = false
        }
        equalizer.globalGain = 0
        equalizer.bypass = false
    }

    private func installRenderedPCMTapIfNeeded() {
        guard voiceMode.requiresProcessedPlayback,
              let renderedReferencePipeline else { return }
        let tapBlock = Self.makeRenderedPCMTap(pipeline: renderedReferencePipeline)
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: nil,
            block: tapBlock
        )
        renderTapInstalled = true
    }

    /// AVAudioEngine invokes taps on a realtime render queue. Constructing the
    /// block in a nonisolated context prevents Swift from inheriting the
    /// surrounding MainActor executor onto that callback.
    private nonisolated static func makeRenderedPCMTap(
        pipeline: RenderedPCMReferencePipeline
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            pipeline.capture(buffer)
        }
    }

    private func primePlaybackIfNeeded() {
        guard !player.isPlaying, queuedBuffers > 0 else { return }
        if queuedDurationSeconds >= adaptivePlayoutLeadSeconds {
            primingWorkItem?.cancel()
            primingWorkItem = nil
            player.play()
            return
        }
        guard primingWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            primingWorkItem = nil
            if queuedBuffers > 0, !player.isPlaying { player.play() }
        }
        primingWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + adaptivePlayoutLeadSeconds,
            execute: work
        )
    }

    private func emitPlayoutStatus(
        state: String,
        sampleRate: Int,
        channels: Int,
        chunkDuration: TimeInterval,
        arrivalGapMilliseconds: Double?
    ) {
        playoutStatusHandler?(PlayoutStatus(
            state: state,
            sampleRate: sampleRate,
            channels: channels,
            chunkDurationMilliseconds: chunkDuration * 1_000,
            arrivalGapMilliseconds: arrivalGapMilliseconds,
            queuedDurationMilliseconds: queuedDurationSeconds * 1_000,
            underruns: underrunCount
        ))
    }
}
