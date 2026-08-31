import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import SOMACore

@MainActor
final class SelectedAudioOutput {
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
    private var sourceFormat: AVAudioFormat?
    private var queuedBuffers = 0
    private var queuedDurationSeconds: TimeInterval = 0
    private var playbackGeneration: UInt64 = 0
    private var primingWorkItem: DispatchWorkItem?

    /// WebRTC delivers small PCM blocks through a WebKit-to-Swift bridge.
    /// Starting playback on the first block exposes ordinary bridge jitter as
    /// audible gaps, so retain a short playout lead before releasing audio.
    private let targetPlayoutLeadSeconds: TimeInterval = 0.16

    init(preferredUID: String?) throws {
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
    }

    func enqueuePCM16(
        _ data: Data,
        sampleRate: Double,
        channels: Int,
        samplesPerChannel: Int
    ) throws {
        guard sampleRate >= 8_000,
              sampleRate <= 96_000,
              (1...8).contains(channels),
              samplesPerChannel > 0,
              data.count == samplesPerChannel * channels * 2,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels),
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
                for channel in 0..<channels {
                    let index = (frame * channels + channel) * 2
                    let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                    channelData[channel][frame] = Float(Int16(bitPattern: bits)) / 32_768
                }
            }
        }
        let duration = Double(samplesPerChannel) / sampleRate
        let generation = playbackGeneration
        queuedBuffers += 1
        queuedDurationSeconds += duration
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
                    if self.player.isPlaying { self.player.pause() }
                }
            }
        }
        primePlaybackIfNeeded()
    }

    func finishSpeech() {
        primingWorkItem?.cancel()
        primingWorkItem = nil
        if queuedBuffers > 0, !player.isPlaying { player.play() }
    }

    func flush() {
        playbackGeneration &+= 1
        primingWorkItem?.cancel()
        primingWorkItem = nil
        queuedBuffers = 0
        queuedDurationSeconds = 0
        player.stop()
    }

    func stop() {
        player.stop()
        engine.stop()
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
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
            sourceFormat = format
        } catch {
            throw OutputError.engineStartFailed(error.localizedDescription)
        }
    }

    private func primePlaybackIfNeeded() {
        guard !player.isPlaying, queuedBuffers > 0 else { return }
        if queuedDurationSeconds >= targetPlayoutLeadSeconds {
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
            deadline: .now() + targetPlayoutLeadSeconds,
            execute: work
        )
    }
}
