@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

private enum ProbeError: LocalizedError {
    case invalidArguments(String)
    case deviceUnavailable(String)
    case accessDenied(String)
    case sessionConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message),
                .deviceUnavailable(let message),
                .accessDenied(let message),
                .sessionConfiguration(let message):
            return message
        }
    }
}

private struct ProbeOptions {
    let duration: TimeInterval
    let outputURL: URL
    let listOnly: Bool
    let listFormats: Bool
    let videoID: String?
    let audioID: String?

    static func parse(_ arguments: [String]) throws -> ProbeOptions {
        var duration: TimeInterval = 60
        var outputURL = defaultOutputURL()
        var listOnly = false
        var listFormats = false
        var videoID: String?
        var audioID: String?
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--duration":
                index += 1
                guard index < arguments.count,
                      let parsed = TimeInterval(arguments[index]),
                      parsed > 0 else {
                    throw ProbeError.invalidArguments("--duration must be a positive number of seconds")
                }
                duration = parsed
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw ProbeError.invalidArguments("--output requires a file path")
                }
                outputURL = URL(fileURLWithPath: arguments[index])
            case "--list":
                listOnly = true
            case "--list-formats":
                listFormats = true
            case "--video-id":
                index += 1
                guard index < arguments.count else {
                    throw ProbeError.invalidArguments("--video-id requires a device unique ID")
                }
                videoID = arguments[index]
            case "--audio-id":
                index += 1
                guard index < arguments.count else {
                    throw ProbeError.invalidArguments("--audio-id requires a device unique ID")
                }
                audioID = arguments[index]
            case "--help", "-h":
                printUsage()
                Foundation.exit(EXIT_SUCCESS)
            default:
                throw ProbeError.invalidArguments("Unknown argument: \(arguments[index])")
            }
            index += 1
        }

        return ProbeOptions(
            duration: duration,
            outputURL: outputURL,
            listOnly: listOnly,
            listFormats: listFormats,
            videoID: videoID,
            audioID: audioID
        )
    }

    private static func defaultOutputURL() -> URL {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/probes/soma-probe-\(stamp).jsonl")
    }
}

private struct DeviceDescription {
    let name: String
    let uniqueID: String
    let manufacturer: String?
    let modelID: String?

    var json: [String: Any] {
        var value: [String: Any] = [
            "name": name,
            "unique_id": uniqueID,
        ]
        if let manufacturer { value["manufacturer"] = manufacturer }
        if let modelID { value["model_id"] = modelID }
        return value
    }
}

private struct StreamSnapshot {
    let callbacks: Int
    let dropped: Int
    let gaps: Int
    let startupGaps: Int
    let timestampResets: Int
    let nonMonotonicPresentationTimestamps: Int
    let maximumCallbackIntervalMilliseconds: Double?
    let firstCaptureNS: UInt64?
    let lastCaptureNS: UInt64?
    let lastPresentationSeconds: Double?
    let maximumPresentationIntervalMilliseconds: Double?
    let width: Int?
    let height: Int?
    let sampleRate: Double?
    let channels: Int?

    var json: [String: Any] {
        var value: [String: Any] = [
            "callbacks": callbacks,
            "dropped": dropped,
            "gaps": gaps,
            "startup_gaps": startupGaps,
            "timestamp_resets": timestampResets,
            "non_monotonic_presentation_timestamps": nonMonotonicPresentationTimestamps,
        ]
        if let maximumCallbackIntervalMilliseconds {
            value["maximum_callback_interval_ms"] = maximumCallbackIntervalMilliseconds
        }
        if let firstCaptureNS { value["first_capture_monotonic_ns"] = firstCaptureNS }
        if let lastCaptureNS { value["last_capture_monotonic_ns"] = lastCaptureNS }
        if let lastPresentationSeconds { value["last_presentation_seconds"] = lastPresentationSeconds }
        if let maximumPresentationIntervalMilliseconds {
            value["maximum_presentation_interval_ms"] = maximumPresentationIntervalMilliseconds
        }
        if let width { value["width"] = width }
        if let height { value["height"] = height }
        if let sampleRate { value["sample_rate_hz"] = sampleRate }
        if let channels { value["channels"] = channels }
        return value
    }
}

private final class CaptureStats {
    private struct StreamState {
        var callbacks = 0
        var dropped = 0
        var gaps = 0
        var startupGaps = 0
        var timestampResets = 0
        var nonMonotonicPresentationTimestamps = 0
        var firstCaptureNS: UInt64?
        var lastCaptureNS: UInt64?
        var maximumCallbackIntervalMilliseconds: Double?
        var lastPresentationSeconds: Double?
        var maximumPresentationIntervalMilliseconds: Double?
        var width: Int?
        var height: Int?
        var sampleRate: Double?
        var channels: Int?

        mutating func record(
            captureNS: UInt64,
            presentationTime: CMTime,
            width: Int? = nil,
            height: Int? = nil,
            sampleRate: Double? = nil,
            channels: Int? = nil
        ) {
            if let previousCaptureNS = lastCaptureNS {
                let intervalNS = captureNS - previousCaptureNS
                maximumCallbackIntervalMilliseconds = max(
                    maximumCallbackIntervalMilliseconds ?? 0,
                    Double(intervalNS) / 1_000_000
                )
                if intervalNS > 250_000_000 {
                    if let firstCaptureNS, captureNS - firstCaptureNS < 1_000_000_000 {
                        startupGaps += 1
                    } else {
                        gaps += 1
                    }
                }
            }
            callbacks += 1
            firstCaptureNS = firstCaptureNS ?? captureNS
            lastCaptureNS = captureNS
            self.width = width ?? self.width
            self.height = height ?? self.height
            self.sampleRate = sampleRate ?? self.sampleRate
            self.channels = channels ?? self.channels

            let presentationSeconds = seconds(from: presentationTime)
            if let presentationSeconds,
               let previousPresentation = lastPresentationSeconds {
                let interval = presentationSeconds - previousPresentation
                if interval <= 0 {
                    nonMonotonicPresentationTimestamps += 1
                } else {
                    if interval >= 10 {
                        timestampResets += 1
                    } else {
                        maximumPresentationIntervalMilliseconds = max(
                            maximumPresentationIntervalMilliseconds ?? 0,
                            interval * 1_000
                        )
                    }
                }
            }
            lastPresentationSeconds = presentationSeconds ?? lastPresentationSeconds
        }

        mutating func recordDrop() {
            dropped += 1
        }

        func snapshot() -> StreamSnapshot {
            StreamSnapshot(
                callbacks: callbacks,
                dropped: dropped,
                gaps: gaps,
                startupGaps: startupGaps,
                timestampResets: timestampResets,
                nonMonotonicPresentationTimestamps: nonMonotonicPresentationTimestamps,
                maximumCallbackIntervalMilliseconds: maximumCallbackIntervalMilliseconds,
                firstCaptureNS: firstCaptureNS,
                lastCaptureNS: lastCaptureNS,
                lastPresentationSeconds: lastPresentationSeconds,
                maximumPresentationIntervalMilliseconds: maximumPresentationIntervalMilliseconds,
                width: width,
                height: height,
                sampleRate: sampleRate,
                channels: channels
            )
        }
    }

    private let lock = NSLock()
    private var video = StreamState()
    private var audio = StreamState()

    func recordVideo(_ sampleBuffer: CMSampleBuffer) {
        let dimensions = videoDimensions(from: sampleBuffer)
        lock.lock()
        video.record(
            captureNS: monotonicNanoseconds(),
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            width: dimensions?.width,
            height: dimensions?.height
        )
        lock.unlock()
    }

    func recordVideoDrop() {
        lock.lock()
        video.recordDrop()
        lock.unlock()
    }

    func recordAudio(_ sampleBuffer: CMSampleBuffer) {
        let audioInfo = audioFormat(from: sampleBuffer)
        lock.lock()
        audio.record(
            captureNS: monotonicNanoseconds(),
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            sampleRate: audioInfo?.sampleRate,
            channels: audioInfo?.channels
        )
        lock.unlock()
    }

    func videoSnapshot() -> StreamSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return video.snapshot()
    }

    func audioSnapshot() -> StreamSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return audio.snapshot()
    }
}

private final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let stats: CaptureStats
    private let videoOutput: AVCaptureVideoDataOutput
    private let audioOutput: AVCaptureAudioDataOutput

    init(stats: CaptureStats, videoOutput: AVCaptureVideoDataOutput, audioOutput: AVCaptureAudioDataOutput) {
        self.stats = stats
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if output === videoOutput {
            stats.recordVideo(sampleBuffer)
        } else if output === audioOutput {
            stats.recordAudio(sampleBuffer)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            stats.recordVideoDrop()
        }
    }
}

private final class SessionObserver: NSObject, @unchecked Sendable {
    private let writer: JSONLWriter
    private let videoDevice: AVCaptureDevice
    private let audioDevice: AVCaptureDevice
    private let stats: CaptureStats
    private var tokens: [NSObjectProtocol] = []

    init(session: AVCaptureSession, writer: JSONLWriter, videoDevice: AVCaptureDevice, audioDevice: AVCaptureDevice, stats: CaptureStats) {
        self.writer = writer
        self.videoDevice = videoDevice
        self.audioDevice = audioDevice
        self.stats = stats
        super.init()
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: session,
                queue: nil
            ) { [weak self] notification in
                self?.writeRuntimeEvent(notification, state: "runtime_error")
            },
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted,
                object: session,
                queue: nil
            ) { [weak self] notification in
                self?.writeRuntimeEvent(notification, state: "interrupted")
            },
            center.addObserver(
                forName: .AVCaptureSessionInterruptionEnded,
                object: session,
                queue: nil
            ) { [weak self] notification in
                self?.writeRuntimeEvent(notification, state: "interruption_ended")
            },
            center.addObserver(
                forName: .AVCaptureDeviceWasDisconnected,
                object: videoDevice,
                queue: nil
            ) { [weak self] notification in
                self?.writeDisconnectEvent(notification, source: "video")
            },
            center.addObserver(
                forName: .AVCaptureDeviceWasDisconnected,
                object: audioDevice,
                queue: nil
            ) { [weak self] notification in
                self?.writeDisconnectEvent(notification, source: "audio")
            },
            center.addObserver(
                forName: .AVCaptureDeviceWasConnected,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.writeReconnectEvent(notification)
            },
        ]
    }

    deinit {
        let center = NotificationCenter.default
        tokens.forEach(center.removeObserver)
    }

    private func writeRuntimeEvent(_ notification: Notification, state: String) {
        let error = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
        writer.write(healthEvent(
            source: "session",
            state: state,
            snapshot: stats.videoSnapshot(),
            error: error
        ))
    }

    private func writeDisconnectEvent(_ notification: Notification, source: String) {
        let device = source == "video" ? videoDevice : audioDevice
        writer.write(healthEvent(
            source: source,
            state: "disconnected",
            device: describe(device),
            snapshot: source == "video" ? stats.videoSnapshot() : stats.audioSnapshot()
        ))
    }

    private func writeReconnectEvent(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice else { return }
        let source: String
        if device.uniqueID == videoDevice.uniqueID {
            source = "video"
        } else if device.uniqueID == audioDevice.uniqueID {
            source = "audio"
        } else {
            return
        }
        writer.write(healthEvent(
            source: source,
            state: "reconnected",
            device: describe(device),
            snapshot: source == "video" ? stats.videoSnapshot() : stats.audioSnapshot()
        ))
    }
}

private final class JSONLWriter {
    private let queue = DispatchQueue(label: "soma.probe.trace")
    private let handle: FileHandle

    init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ProbeError.invalidArguments("Output already exists: \(url.path). Choose a new trace path.")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ProbeError.sessionConfiguration("Cannot create trace output: \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ value: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(value),
              var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return
        }
        data.append(0x0A)
        queue.async { [handle, data] in
            try? handle.write(contentsOf: data)
        }
    }

    func close() {
        queue.sync {
            try? handle.close()
        }
    }
}

private func run(options: ProbeOptions) throws {
    let videoDevices = AVCaptureDevice.devices(for: .video)
    let audioDevices = AVCaptureDevice.devices(for: .audio)

    if options.listOnly || options.listFormats {
        print("Video devices:")
        videoDevices.forEach { printDevice($0, includeFormats: options.listFormats) }
        print("Audio devices:")
        audioDevices.forEach { printDevice($0) }
        return
    }

    guard let videoID = options.videoID, let audioID = options.audioID else {
        throw ProbeError.invalidArguments("--video-id and --audio-id are required for capture. Use --list first.")
    }
    guard let videoDevice = obsbotDevice(in: videoDevices, matching: videoID) else {
        throw ProbeError.deviceUnavailable("No OBSBOT video device is available")
    }
    guard let audioDevice = obsbotDevice(in: audioDevices, matching: audioID) else {
        throw ProbeError.deviceUnavailable("No OBSBOT audio device is available")
    }

    try requestAccess(for: .video, label: "camera")
    try requestAccess(for: .audio, label: "microphone")

    let writer = try JSONLWriter(url: options.outputURL)
    defer { writer.close() }
    let stats = CaptureStats()
    let session = AVCaptureSession()

    let videoInput = try AVCaptureDeviceInput(device: videoDevice)
    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    ]

    session.beginConfiguration()
    guard session.canAddInput(videoInput), session.canAddInput(audioInput),
          session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else {
        throw ProbeError.sessionConfiguration("AVCaptureSession cannot add the selected OBSBOT inputs and outputs")
    }
    session.addInput(videoInput)
    session.addInput(audioInput)
    session.addOutput(videoOutput)
    session.addOutput(audioOutput)
    if session.canSetSessionPreset(.hd1280x720) {
        session.sessionPreset = .hd1280x720
    }

    let delegate = CaptureDelegate(stats: stats, videoOutput: videoOutput, audioOutput: audioOutput)
    let observer = SessionObserver(session: session, writer: writer, videoDevice: videoDevice, audioDevice: audioDevice, stats: stats)
    let videoQueue = DispatchQueue(label: "soma.probe.video", qos: .userInitiated)
    let audioQueue = DispatchQueue(label: "soma.probe.audio", qos: .userInitiated)
    videoOutput.setSampleBufferDelegate(delegate, queue: videoQueue)
    audioOutput.setSampleBufferDelegate(delegate, queue: audioQueue)
    session.commitConfiguration()
    let requestedVideoFormat = try configureVideoFormat(videoDevice)

    writer.write(healthEvent(
        source: "video",
        state: "selected",
        device: describe(videoDevice),
        requestedVideoFormat: requestedVideoFormat,
        snapshot: stats.videoSnapshot()
    ))
    writer.write(healthEvent(
        source: "audio",
        state: "selected",
        device: describe(audioDevice),
        snapshot: stats.audioSnapshot()
    ))

    let complete = DispatchSemaphore(value: 0)
    let timerQueue = DispatchQueue(label: "soma.probe.timer")
    let healthTimer = DispatchSource.makeTimerSource(queue: timerQueue)
    healthTimer.schedule(deadline: .now(), repeating: 1)
    session.startRunning()
    let startedNS = monotonicNanoseconds()
    healthTimer.setEventHandler {
        let elapsed = Double(monotonicNanoseconds() - startedNS) / 1_000_000_000
        writer.write(healthEvent(
            source: "video",
            state: elapsed >= options.duration ? "stopping" : "capturing",
            device: describe(videoDevice),
            snapshot: stats.videoSnapshot()
        ))
        writer.write(healthEvent(
            source: "audio",
            state: elapsed >= options.duration ? "stopping" : "capturing",
            device: describe(audioDevice),
            snapshot: stats.audioSnapshot()
        ))
        if elapsed >= options.duration {
            healthTimer.cancel()
            complete.signal()
        }
    }

    healthTimer.resume()
    complete.wait()
    session.stopRunning()

    writer.write(healthEvent(
        source: "video",
        state: "stopped",
        device: describe(videoDevice),
        snapshot: stats.videoSnapshot()
    ))
    writer.write(healthEvent(
        source: "audio",
        state: "stopped",
        device: describe(audioDevice),
        snapshot: stats.audioSnapshot()
    ))
    withExtendedLifetime(observer) {}
    print("Wrote health trace: \(options.outputURL.path)")
}

private func requestAccess(for mediaType: AVMediaType, label: String) throws {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized:
        return
    case .notDetermined:
        let complete = DispatchSemaphore(value: 0)
        let result = AuthorizationResult()
        AVCaptureDevice.requestAccess(for: mediaType) {
            result.set($0)
            complete.signal()
        }
        complete.wait()
        guard result.value else {
            throw ProbeError.accessDenied("Access to the \(label) was not granted")
        }
    case .denied, .restricted:
        throw ProbeError.accessDenied("Access to the \(label) is denied or restricted in macOS privacy settings")
    @unknown default:
        throw ProbeError.accessDenied("Access to the \(label) has an unknown authorization state")
    }
}

private func configureVideoFormat(_ device: AVCaptureDevice) throws -> [String: Any] {
    let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, Int, Int, Double)? in
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        let maximumFrameRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return (format, Int(dimensions.width), Int(dimensions.height), maximumFrameRate)
    }
    guard let selected = candidates
        .filter({ $0.1 <= 1280 && $0.2 <= 720 })
        .sorted(by: { ($0.1 * $0.2, $0.3) > ($1.1 * $1.2, $1.3) })
        .first ?? candidates.sorted(by: { ($0.1 * $0.2, $0.3) < ($1.1 * $1.2, $1.3) }).first else {
        throw ProbeError.sessionConfiguration("The OBSBOT camera exposes no usable video format")
    }

    return [
        "width": selected.1,
        "height": selected.2,
        "max_frame_rate": selected.3,
        "requested_frame_rate": min(30, selected.3),
    ]
}

private func obsbotDevice(in devices: [AVCaptureDevice], matching uniqueID: String) -> AVCaptureDevice? {
    devices.first {
        $0.uniqueID == uniqueID
            && $0.localizedName.range(of: "obsbot", options: .caseInsensitive) != nil
    }
}

private func describe(_ device: AVCaptureDevice) -> DeviceDescription {
    DeviceDescription(
        name: device.localizedName,
        uniqueID: device.uniqueID,
        manufacturer: device.manufacturer,
        modelID: device.modelID
    )
}

private func printDevice(_ device: AVCaptureDevice, includeFormats: Bool = false) {
    let description = describe(device)
    let modelID = description.modelID ?? "unknown"
    print("  \(description.name) | unique_id=\(description.uniqueID) | model=\(modelID)")
    guard includeFormats else { return }
    for format in videoFormats(for: device) {
        print("    format=\(format.width)x\(format.height) max_fps=\(format.maximumFrameRate)")
    }
}

private func healthEvent(
    source: String,
    state: String,
    device: DeviceDescription? = nil,
    requestedVideoFormat: [String: Any]? = nil,
    snapshot: StreamSnapshot,
    error: String? = nil
) -> [String: Any] {
    var event: [String: Any] = [
        "event": "source.health",
        "monotonic_ns": monotonicNanoseconds(),
        "source": source,
        "state": state,
        "stats": snapshot.json,
    ]
    if let device { event["device"] = device.json }
    if let requestedVideoFormat {
        event["requested_video_format"] = requestedVideoFormat
    }
    if let error { event["error"] = error }
    return event
}

private func videoFormats(for device: AVCaptureDevice) -> [(width: Int, height: Int, maximumFrameRate: Double)] {
    device.formats.compactMap { format in
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        return (
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            maximumFrameRate: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        )
    }
}

private func videoDimensions(from sampleBuffer: CMSampleBuffer) -> (width: Int, height: Int)? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    return (Int(dimensions.width), Int(dimensions.height))
}

private func audioFormat(from sampleBuffer: CMSampleBuffer) -> (sampleRate: Double, channels: Int)? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
        return nil
    }
    return (basicDescription.pointee.mSampleRate, Int(basicDescription.pointee.mChannelsPerFrame))
}

private func seconds(from time: CMTime) -> Double? {
    guard time.isValid, !time.isIndefinite else { return nil }
    return CMTimeGetSeconds(time)
}

private func monotonicNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func printUsage() {
    print("Usage: soma-probe [--list | --list-formats] [--duration seconds] [--output trace.jsonl] [--video-id unique_id] [--audio-id unique_id]")
}

private final class AuthorizationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false

    func set(_ granted: Bool) {
        lock.lock()
        self.granted = granted
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }
}

do {
    try run(options: ProbeOptions.parse(Array(CommandLine.arguments.dropFirst())))
} catch {
    fputs("soma-probe: \(error.localizedDescription)\n", stderr)
    Foundation.exit(EXIT_FAILURE)
}
