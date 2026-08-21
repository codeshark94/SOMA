import CoreVideo
import Foundation
import SOMACore
import SOMAOpenCV

/// Holds one short-lived camera image for L1 reasoning independently of the
/// menu-bar diagnostics. Closing the panel must never turn L1's visual context
/// into an old screenshot.
final class L1CurrentFrameRelay: @unchecked Sendable {
    private struct Pending: Sendable {
        let pixels: Data
        let capturedAtNS: UInt64
        let capturedAt: Date
        let bytesPerRow: Int32
        let width: Int32
        let height: Int32
    }

    private struct Latest: Sendable {
        let capturedAtNS: UInt64
        let capturedAt: Date
        let jpeg: Data
    }

    private let directoryURL: URL
    private let lock = NSLock()
    private let encodeQueue = DispatchQueue(label: "soma.l1.current-frame", qos: .utility)
    private let l1AdmissionIntervalNS: UInt64 = 750_000_000
    private let panoramaAdmissionIntervalNS: UInt64 = 250_000_000
    private let freshnessWindowNS: UInt64 = 2_000_000_000
    private let maximumJPEGBytes = 2_000_000
    private let maximumImageDimension: Int32 = 640
    // OBSBOT can deliver a 3840×2160 BGRA surface (about 33.2 MB). The
    // bounded CPU handoff must cover that source while still rejecting an
    // implausibly large camera allocation.
    private let maximumSourceBytes = 48_000_000

    private var nextAdmissionNS: UInt64 = 0
    private var pending: Pending?
    private var latest: Latest?
    private var encoding = false
    private var activeSnapshots: [URL: Date] = [:]
    private var encodedFrameObserver: (@Sendable (Data, UInt64) -> Void)?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let stale = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in stale where file.lastPathComponent.hasPrefix("l1-frame-")
            || file.lastPathComponent == "l1-current-latest.jpg" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func record(pixelBuffer: CVPixelBuffer, capturedAtNS: UInt64, capturedAt: Date = Date()) {
        lock.lock()
        let admissionIntervalNS = encodedFrameObserver == nil
            ? l1AdmissionIntervalNS
            : panoramaAdmissionIntervalNS
        guard capturedAtNS >= nextAdmissionNS else {
            lock.unlock()
            return
        }
        nextAdmissionNS = capturedAtNS &+ admissionIntervalNS
        lock.unlock()

        // AVCapture owns this IOSurface. Copy it while handling this admission
        // and release the surface before any asynchronous JPEG work begins.
        // The CPU copy is rate-limited (4 Hz only while panorama is enabled).
        guard let frame = copyToCPUMemory(
            pixelBuffer: pixelBuffer,
            capturedAtNS: capturedAtNS,
            capturedAt: capturedAt
        ) else {
            return
        }

        lock.lock()
        pending = frame
        guard !encoding else {
            lock.unlock()
            return
        }
        encoding = true
        lock.unlock()
        encodeQueue.async { [weak self] in self?.drain() }
    }

    /// Delivers the already-throttled local JPEG to another local consumer.
    /// The observer receives bytes only; it never receives a camera-owned
    /// CVPixelBuffer or participates in the capture queue.
    func setEncodedFrameObserver(_ observer: (@Sendable (Data, UInt64) -> Void)?) {
        lock.lock()
        encodedFrameObserver = observer
        nextAdmissionNS = 0
        lock.unlock()
    }

    func currentResource(at monotonicNS: UInt64) -> L1VisualResource? {
        lock.lock()
        let frame = latest
        purgeExpiredSnapshotsLocked(at: Date())
        lock.unlock()
        guard let frame,
              monotonicNS >= frame.capturedAtNS,
              monotonicNS - frame.capturedAtNS <= freshnessWindowNS else {
            return nil
        }
        let expiresAt = Date().addingTimeInterval(30)
        let snapshotURL = directoryURL.appendingPathComponent("l1-frame-\(frame.capturedAtNS).jpg")
        if !FileManager.default.fileExists(atPath: snapshotURL.path) {
            do {
                try frame.jpeg.write(to: snapshotURL, options: .atomic)
            } catch {
                return nil
            }
        }
        lock.lock()
        activeSnapshots[snapshotURL] = expiresAt
        lock.unlock()
        scheduleSnapshotExpiry(snapshotURL, at: expiresAt)
        return L1VisualResource(
            resourceID: "current_frame",
            projection: .currentView,
            localPath: snapshotURL.path,
            expiresAt: expiresAt,
            capturedAt: frame.capturedAt
        )
    }

    func removeRetainedFrame() {
        lock.lock()
        pending = nil
        latest = nil
        nextAdmissionNS = 0
        let snapshots = Array(activeSnapshots.keys)
        activeSnapshots.removeAll()
        lock.unlock()
        encodeQueue.sync { [directoryURL, snapshots] in
            for snapshot in snapshots {
                try? FileManager.default.removeItem(at: snapshot)
            }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )) ?? []
            for file in files where file.lastPathComponent.hasPrefix("l1-frame-")
                || file.lastPathComponent == "l1-current-latest.jpg" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func drain() {
        while let frame = takePending() {
            autoreleasepool { encode(frame) }
        }
    }

    private func takePending() -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        guard let pending else {
            encoding = false
            return nil
        }
        self.pending = nil
        return pending
    }

    private func encode(_ frame: Pending) {
        var encoded = [UInt8](repeating: 0, count: maximumJPEGBytes)
        let result = frame.pixels.withUnsafeBytes { source in
            encoded.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return SOMAJPEGEncodeResult(success: 0, encoded_length: 0)
                }
                return soma_encode_jpeg_4channel(
                    sourceBase,
                    frame.bytesPerRow,
                    frame.width,
                    frame.height,
                    1,
                    maximumImageDimension,
                    destinationBase,
                    Int32(destination.count)
                )
            }
        }
        guard result.success != 0,
              result.encoded_length > 0,
              result.encoded_length <= encoded.count else { return }
        let jpeg = Data(encoded.prefix(Int(result.encoded_length)))
        lock.lock()
        latest = Latest(capturedAtNS: frame.capturedAtNS, capturedAt: frame.capturedAt, jpeg: jpeg)
        let observer = encodedFrameObserver
        lock.unlock()
        observer?(jpeg, frame.capturedAtNS)
    }

    private func copyToCPUMemory(
        pixelBuffer: CVPixelBuffer,
        capturedAtNS: UInt64,
        capturedAt: Date
    ) -> Pending? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let byteCount = bytesPerRow.multipliedReportingOverflow(by: height)
        guard width > 0,
              height > 0,
              bytesPerRow >= width * 4,
              !byteCount.overflow,
              byteCount.partialValue > 0,
              byteCount.partialValue <= maximumSourceBytes else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        return Pending(
            pixels: Data(bytes: baseAddress, count: byteCount.partialValue),
            capturedAtNS: capturedAtNS,
            capturedAt: capturedAt,
            bytesPerRow: Int32(bytesPerRow),
            width: Int32(width),
            height: Int32(height)
        )
    }

    private func purgeExpiredSnapshotsLocked(at date: Date) {
        let expired = activeSnapshots.filter { $0.value <= date }.map(\.key)
        for snapshot in expired {
            activeSnapshots.removeValue(forKey: snapshot)
            try? FileManager.default.removeItem(at: snapshot)
        }
    }

    private func scheduleSnapshotExpiry(_ snapshotURL: URL, at expiresAt: Date) {
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        encodeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.activeSnapshots[snapshotURL] == expiresAt else {
                self.lock.unlock()
                return
            }
            self.activeSnapshots.removeValue(forKey: snapshotURL)
            self.lock.unlock()
            try? FileManager.default.removeItem(at: snapshotURL)
        }
    }
}
