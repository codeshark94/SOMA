import CoreImage
import CoreVideo
import Foundation
import SOMACore

private final class L1CurrentFramePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

/// Holds one short-lived camera image for L1 reasoning independently of the
/// menu-bar diagnostics. Closing the panel must never turn L1's visual context
/// into an old screenshot.
final class L1CurrentFrameRelay: @unchecked Sendable {
    private struct Pending: @unchecked Sendable {
        let pixelBuffer: L1CurrentFramePixelBuffer
        let capturedAtNS: UInt64
        let capturedAt: Date
    }

    private struct Latest: Sendable {
        let capturedAtNS: UInt64
        let capturedAt: Date
        let jpeg: Data
    }

    private let directoryURL: URL
    private let lock = NSLock()
    private let encodeQueue = DispatchQueue(label: "soma.l1.current-frame", qos: .utility)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let admissionIntervalNS: UInt64 = 750_000_000
    private let freshnessWindowNS: UInt64 = 2_000_000_000
    private let maximumJPEGBytes = 2_000_000
    private let maximumImageDimension = 640.0

    private var nextAdmissionNS: UInt64 = 0
    private var pending: Pending?
    private var latest: Latest?
    private var encoding = false
    private var activeSnapshots: [URL: Date] = [:]

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let stale = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in stale where file.lastPathComponent.hasPrefix("l1-frame-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func record(pixelBuffer: CVPixelBuffer, capturedAtNS: UInt64, capturedAt: Date = Date()) {
        lock.lock()
        guard capturedAtNS >= nextAdmissionNS else {
            lock.unlock()
            return
        }
        nextAdmissionNS = capturedAtNS &+ admissionIntervalNS
        pending = Pending(
            pixelBuffer: L1CurrentFramePixelBuffer(pixelBuffer),
            capturedAtNS: capturedAtNS,
            capturedAt: capturedAt
        )
        guard !encoding else {
            lock.unlock()
            return
        }
        encoding = true
        lock.unlock()
        encodeQueue.async { [weak self] in self?.drain() }
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
            for file in files where file.lastPathComponent.hasPrefix("l1-frame-") {
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
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer.value)
        let extent = source.extent
        guard extent.width > 0,
              extent.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return
        }
        let scale = min(1, maximumImageDimension / max(extent.width, extent.height))
        let image = scale < 1
            ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : source
        guard let jpeg = imageContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [:]
        ), jpeg.count <= maximumJPEGBytes else {
            return
        }
        lock.lock()
        latest = Latest(capturedAtNS: frame.capturedAtNS, capturedAt: frame.capturedAt, jpeg: jpeg)
        lock.unlock()
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
