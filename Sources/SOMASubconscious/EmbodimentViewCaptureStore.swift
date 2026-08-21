import CoreImage
import CoreVideo
import Darwin
import Foundation
import SOMACore

private final class EmbodimentCapturedPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

/// Owns one-shot camera views requested through the cognitive embodiment API.
/// The trace receives only scalar lifecycle events; JPEGs live in a private,
/// bounded, short-lived directory and never become scene evidence themselves.
final class EmbodimentViewCaptureStore: @unchecked Sendable {
    typealias TerminalHandler = @Sendable (_ requestID: String, _ succeeded: Bool) -> Void
    typealias HealthHandler = @Sendable (_ state: String, _ message: String?) -> Void

    private struct Entry: Sendable {
        let requestID: String
        let targetReference: String?
        let sceneID: String?
        let requestedBearing: GimbalRelativeBearing?
        let isCurrentFrame: Bool
        let fieldOfViewDegrees: Double
        let leaseExpiresAtNS: UInt64
        let createdAtNS: UInt64
        var state: EmbodimentViewCaptureState
        var alignedAtNS: UInt64?
        var cameraBearing: GimbalRelativeBearing?
        var imagePath: String?
        var capturedAtNS: UInt64?
        var resourceExpiresAtNS: UInt64?
        var failureReason: String?

        var resource: EmbodimentViewResource {
            EmbodimentViewResource(
                requestID: requestID,
                state: state,
                imagePath: imagePath,
                mimeType: state == .ready ? "image/jpeg" : nil,
                width: state == .ready ? 640 : nil,
                height: state == .ready ? 360 : nil,
                capturedAtNS: capturedAtNS,
                resourceExpiresAtNS: resourceExpiresAtNS,
                targetReference: targetReference,
                sceneID: sceneID,
                bearing: requestedBearing,
                cameraBearing: cameraBearing,
                fieldOfViewDegrees: fieldOfViewDegrees,
                failureReason: failureReason
            )
        }
    }

    private let directoryURL: URL
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let encodeQueue = DispatchQueue(label: "soma.embodiment.view-capture", qos: .userInitiated)
    private let lock = NSLock()
    private let onHealth: HealthHandler
    private let resourceTTLNS: UInt64 = 60_000_000_000
    private let maximumEntries = 16
    private let cameraHorizontalFieldOfViewDegrees = 86.0
    private var entries: [String: Entry] = [:]
    private var terminalHandler: TerminalHandler?

    init(directoryURL: URL, onHealth: @escaping HealthHandler) throws {
        self.directoryURL = directoryURL
        self.onHealth = onHealth
        try prepareDirectory()
    }

    func setTerminalHandler(_ handler: @escaping TerminalHandler) {
        lock.lock()
        terminalHandler = handler
        lock.unlock()
    }

    func prepare(
        requestID: String,
        targetReference: String?,
        sceneID: String?,
        bearing: GimbalRelativeBearing,
        fieldOfViewDegrees: Double,
        leaseExpiresAtNS: UInt64,
        at monotonicNS: UInt64
    ) {
        lock.lock()
        cleanupLocked(at: monotonicNS)
        if let existing = entries[requestID], existing.state != .pendingAlignment {
            lock.unlock()
            return
        }
        entries[requestID] = Entry(
            requestID: requestID,
            targetReference: targetReference,
            sceneID: sceneID,
            requestedBearing: bearing,
            isCurrentFrame: false,
            fieldOfViewDegrees: min(max(fieldOfViewDegrees, 5), cameraHorizontalFieldOfViewDegrees),
            leaseExpiresAtNS: leaseExpiresAtNS,
            createdAtNS: monotonicNS,
            state: .pendingAlignment
        )
        evictLocked()
        lock.unlock()
        onHealth(
            "requested",
            "request_id=\(String(requestID.prefix(96))); target=\(String((targetReference ?? "bearing").prefix(96)))"
        )
    }

    /// Arms the next incoming camera sample without requiring an alignment or
    /// a motor lease. The capture is intentionally one-shot, so it cannot
    /// retain a pixel buffer or accumulate camera resources between requests.
    func prepareCurrent(
        requestID: String,
        fieldOfViewDegrees: Double,
        leaseExpiresAtNS: UInt64,
        cameraPose: GimbalPose?,
        at monotonicNS: UInt64
    ) {
        lock.lock()
        cleanupLocked(at: monotonicNS)
        if let existing = entries[requestID], existing.state != .pendingAlignment {
            lock.unlock()
            return
        }
        entries[requestID] = Entry(
            requestID: requestID,
            targetReference: nil,
            sceneID: nil,
            requestedBearing: nil,
            isCurrentFrame: true,
            fieldOfViewDegrees: min(max(fieldOfViewDegrees, 5), cameraHorizontalFieldOfViewDegrees),
            leaseExpiresAtNS: leaseExpiresAtNS,
            createdAtNS: monotonicNS,
            state: .awaitingFrame,
            alignedAtNS: monotonicNS,
            cameraBearing: cameraPose.map {
                GimbalRelativeBearing(
                    azimuthDegrees: $0.panDegrees,
                    elevationDegrees: $0.pitchDegrees
                )
            }
        )
        evictLocked()
        lock.unlock()
        onHealth("current_frame_requested", "request_id=\(String(requestID.prefix(96)))")
    }

    func fail(
        requestID: String,
        reason: String,
        leaseExpiresAtNS: UInt64,
        at monotonicNS: UInt64
    ) {
        lock.lock()
        cleanupLocked(at: monotonicNS)
        entries[requestID] = Entry(
            requestID: requestID,
            targetReference: nil,
            sceneID: nil,
            requestedBearing: nil,
            isCurrentFrame: false,
            fieldOfViewDegrees: cameraHorizontalFieldOfViewDegrees,
            leaseExpiresAtNS: leaseExpiresAtNS,
            createdAtNS: monotonicNS,
            state: .failed,
            failureReason: String(reason.prefix(240))
        )
        let handler = terminalHandler
        lock.unlock()
        onHealth(
            "failed",
            "request_id=\(String(requestID.prefix(96))); reason=\(String(reason.prefix(120)))"
        )
        handler?(requestID, false)
    }

    func markAligned(requestID: String, cameraPose: GimbalPose, at monotonicNS: UInt64) {
        lock.lock()
        cleanupLocked(at: monotonicNS)
        guard var entry = entries[requestID], entry.state == .pendingAlignment else {
            lock.unlock()
            return
        }
        guard monotonicNS < entry.leaseExpiresAtNS else {
            entry.state = .expired
            entry.failureReason = "capture_lease_expired_before_alignment"
            entries[requestID] = entry
            let handler = terminalHandler
            lock.unlock()
            onHealth("expired", "request_id=\(String(requestID.prefix(96))); stage=alignment")
            handler?(requestID, false)
            return
        }
        entry.state = .awaitingFrame
        entry.alignedAtNS = monotonicNS
        entry.cameraBearing = GimbalRelativeBearing(
            azimuthDegrees: cameraPose.panDegrees,
            elevationDegrees: cameraPose.pitchDegrees
        )
        entries[requestID] = entry
        lock.unlock()
        onHealth("aligned", "request_id=\(String(requestID.prefix(96)))")
    }

    func submit(pixelBuffer: CVPixelBuffer, captureNS: UInt64) {
        lock.lock()
        cleanupLocked(at: captureNS)
        guard let selected = entries.values
            .filter({ entry in
                entry.state == .awaitingFrame
                    && (entry.isCurrentFrame || entry.alignedAtNS.map { captureNS >= $0 } == true)
                    && captureNS < entry.leaseExpiresAtNS
            })
            .min(by: { $0.createdAtNS < $1.createdAtNS }) else {
            lock.unlock()
            return
        }
        var entry = selected
        entry.state = .encoding
        entries[entry.requestID] = entry
        lock.unlock()

        let retained = EmbodimentCapturedPixelBuffer(pixelBuffer)
        let queuedEntry = entry
        encodeQueue.async { [weak self] in
            self?.encode(retained, entry: queuedEntry, captureNS: captureNS)
        }
    }

    func cancel(requestID: String, reason: String, at monotonicNS: UInt64) {
        lock.lock()
        cleanupLocked(at: monotonicNS)
        guard var entry = entries[requestID], entry.state != .ready,
              entry.state != .failed, entry.state != .expired else {
            lock.unlock()
            return
        }
        entry.state = .failed
        entry.failureReason = String(reason.prefix(240))
        entries[requestID] = entry
        let handler = terminalHandler
        lock.unlock()
        onHealth(
            "failed",
            "request_id=\(String(requestID.prefix(96))); reason=\(String(reason.prefix(120)))"
        )
        handler?(requestID, false)
    }

    func result(requestID: String, at monotonicNS: UInt64) -> EmbodimentViewResource? {
        lock.lock()
        cleanupLocked(at: monotonicNS)
        let result = entries[requestID]?.resource
        lock.unlock()
        return result
    }

    private func encode(
        _ retained: EmbodimentCapturedPixelBuffer,
        entry: Entry,
        captureNS: UInt64
    ) {
        let name = "view-\(captureNS)-\(UUID().uuidString.lowercased()).jpg"
        let outputURL = directoryURL.appendingPathComponent(name)
        let temporaryURL = directoryURL.appendingPathComponent(".\(name).tmp")
        do {
            try autoreleasepool {
                let source = CIImage(cvPixelBuffer: retained.value)
                let crop = centerCrop(
                    source.extent,
                    requestedHorizontalFieldOfViewDegrees: entry.fieldOfViewDegrees
                )
                let normalized = source
                    .cropped(to: crop)
                    .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                    .transformed(by: CGAffineTransform(
                        scaleX: 640 / crop.width,
                        y: 360 / crop.height
                    ))
                try context.writeJPEGRepresentation(
                    of: normalized,
                    to: temporaryURL,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    options: [:]
                )
            }
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            guard chmod(outputURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }

            let readyNS = DispatchTime.now().uptimeNanoseconds
            let resourceExpiresAtNS = readyNS + resourceTTLNS
            lock.lock()
            guard var current = entries[entry.requestID], current.state == .encoding else {
                lock.unlock()
                try? FileManager.default.removeItem(at: outputURL)
                return
            }
            current.state = .ready
            current.imagePath = outputURL.path
            current.capturedAtNS = captureNS
            current.resourceExpiresAtNS = resourceExpiresAtNS
            entries[entry.requestID] = current
            let handler = terminalHandler
            lock.unlock()
            onHealth(
                "ready",
                "request_id=\(String(entry.requestID.prefix(96))); ttl_ms=60000; width=640; height=360"
            )
            handler?(entry.requestID, true)
            encodeQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(resourceTTLNS))) { [weak self] in
                self?.expireResource(
                    requestID: entry.requestID,
                    expectedExpiresAtNS: resourceExpiresAtNS
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: outputURL)
            lock.lock()
            if var current = entries[entry.requestID], current.state == .encoding {
                current.state = .failed
                current.failureReason = "jpeg_encode_failed"
                entries[entry.requestID] = current
            }
            let handler = terminalHandler
            lock.unlock()
            onHealth(
                "failed",
                "request_id=\(String(entry.requestID.prefix(96))); reason=jpeg_encode_failed"
            )
            handler?(entry.requestID, false)
        }
    }

    private func centerCrop(
        _ extent: CGRect,
        requestedHorizontalFieldOfViewDegrees: Double
    ) -> CGRect {
        let requestedRadians = requestedHorizontalFieldOfViewDegrees * .pi / 180
        let cameraRadians = cameraHorizontalFieldOfViewDegrees * .pi / 180
        let widthRatio = min(1, tan(requestedRadians / 2) / tan(cameraRadians / 2))
        let cropWidth = max(1, floor(extent.width * widthRatio))
        let cropHeight = min(extent.height, cropWidth * 9 / 16)
        return CGRect(
            x: extent.midX - cropWidth / 2,
            y: extent.midY - cropHeight / 2,
            width: cropWidth,
            height: cropHeight
        ).integral
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard chmod(directoryURL.path, S_IRWXU) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let files = try manager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        for file in files where file.lastPathComponent.hasPrefix("view-")
            || file.lastPathComponent.hasPrefix(".view-") {
            try manager.removeItem(at: file)
        }
    }

    private func cleanupLocked(at monotonicNS: UInt64) {
        for requestID in entries.keys {
            guard var entry = entries[requestID] else { continue }
            if entry.state == .ready,
               let expiresAtNS = entry.resourceExpiresAtNS,
               expiresAtNS <= monotonicNS {
                if let imagePath = entry.imagePath {
                    try? FileManager.default.removeItem(atPath: imagePath)
                }
                entry.state = .expired
                entry.imagePath = nil
                entry.failureReason = "view_resource_expired"
                entries[requestID] = entry
            } else if entry.state != .ready,
                      entry.state != .failed,
                      entry.state != .expired,
                      entry.leaseExpiresAtNS <= monotonicNS {
                entry.state = .expired
                entry.failureReason = "capture_lease_expired"
                entries[requestID] = entry
            }
        }
    }

    private func expireResource(requestID: String, expectedExpiresAtNS: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard var entry = entries[requestID],
              entry.state == .ready,
              entry.resourceExpiresAtNS == expectedExpiresAtNS,
              expectedExpiresAtNS <= now else {
            lock.unlock()
            return
        }
        let imagePath = entry.imagePath
        entry.state = .expired
        entry.imagePath = nil
        entry.failureReason = "view_resource_expired"
        entries[requestID] = entry
        lock.unlock()
        if let imagePath {
            try? FileManager.default.removeItem(atPath: imagePath)
        }
        onHealth("expired", "request_id=\(String(requestID.prefix(96))); stage=resource_ttl")
    }

    private func evictLocked() {
        guard entries.count > maximumEntries else { return }
        let ordered = entries.values.sorted { $0.createdAtNS < $1.createdAtNS }
        for entry in ordered.prefix(entries.count - maximumEntries) {
            if let imagePath = entry.imagePath {
                try? FileManager.default.removeItem(atPath: imagePath)
            }
            entries.removeValue(forKey: entry.requestID)
        }
    }
}
