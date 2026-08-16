import CoreImage
import CoreVideo
import Foundation

private final class LiveCameraRetainedPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

/// Holds one recent, downscaled camera image in memory for the active Live
/// Voice turn. It never writes pixels to a trace, diagnostic report, or disk.
final class LiveCameraFrameRelay: @unchecked Sendable {
    private struct EncodedFrame: Sendable {
        let capturedAtNS: UInt64
        let dataURI: String
    }

    private struct PendingFrame: @unchecked Sendable {
        let pixelBuffer: LiveCameraRetainedPixelBuffer
        let capturedAtNS: UInt64
    }

    private let lock = NSLock()
    private let encodeQueue = DispatchQueue(label: "soma.live-voice.camera-frame", qos: .utility)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let admissionIntervalNS: UInt64 = 500_000_000
    private let freshnessWindowNS: UInt64 = 2_000_000_000
    private let maximumJPEGBytes = 2_000_000
    private let maximumImageDimension = 640.0

    private var nextAdmissionNS: UInt64 = 0
    private var pending: PendingFrame?
    private var latest: EncodedFrame?
    private var encoding = false
    private var enabled = false

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        if !enabled {
            pending = nil
            latest = nil
            nextAdmissionNS = 0
        }
        lock.unlock()
    }

    func record(pixelBuffer: CVPixelBuffer, capturedAtNS: UInt64) {
        lock.lock()
        guard enabled, capturedAtNS >= nextAdmissionNS else {
            lock.unlock()
            return
        }
        nextAdmissionNS = capturedAtNS &+ admissionIntervalNS
        pending = PendingFrame(
            pixelBuffer: LiveCameraRetainedPixelBuffer(pixelBuffer),
            capturedAtNS: capturedAtNS
        )
        guard !encoding else {
            lock.unlock()
            return
        }
        encoding = true
        lock.unlock()
        encodeQueue.async { [weak self] in self?.drain() }
    }

    /// Returns a short-lived data URI suitable for one app-server input item.
    func currentImageDataURI(at monotonicNS: UInt64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest,
              monotonicNS >= latest.capturedAtNS,
              monotonicNS - latest.capturedAtNS <= freshnessWindowNS else {
            return nil
        }
        return latest.dataURI
    }

    private func drain() {
        while let frame = takePendingFrame() {
            autoreleasepool { encode(frame) }
        }
    }

    private func takePendingFrame() -> PendingFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let frame = pending else {
            encoding = false
            return nil
        }
        pending = nil
        return frame
    }

    private func encode(_ frame: PendingFrame) {
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer.value)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0,
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
        let encoded = EncodedFrame(
            capturedAtNS: frame.capturedAtNS,
            dataURI: "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        )
        lock.lock()
        latest = encoded
        lock.unlock()
    }
}
