import CoreImage
import CoreVideo
import Foundation
import SOMACore
import SOMAOpenCV
import Vision

private final class PanoramaPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

private enum PanoramaCompositorError: Error {
    case unsupportedFeaturePrint
}

private struct CameraGeometryCaptureRecord: Encodable {
    let schemaVersion = 1
    let filename: String
    let captureNS: UInt64
    let panDegrees: Double
    let pitchDegrees: Double
    let imageWidth: Int
    let imageHeight: Int
    let fovMode: Int
    let reportedHorizontalFieldOfViewDegrees: Double
    let angularVelocityDegreesPerSecond: Double
}

/// Builds a rolling, local-only equirectangular band without blocking the
/// capture or Vision queues. Only the newest admitted frame is retained while
/// the compositor waits for the attitude sample after its exposure timestamp.
final class RollingPanoramaCompositor: @unchecked Sendable {
    private struct Pending: Sendable {
        let pixelBuffer: PanoramaPixelBuffer
        let captureNS: UInt64
        let horizontalFieldOfViewDegrees: Double
        let fieldOfViewMode: Int
        let cameraProjectionModel: CameraProjectionModel
        let dynamicVisionRects: [SOMACore.NormalizedRect]
    }

    private struct AlignmentReference: Sendable {
        let pixelBuffer: PanoramaPixelBuffer
        let pose: GimbalPose
        let cameraProjectionModel: CameraProjectionModel
    }

    private struct AlignmentOutcome {
        let estimate: PanoramaPoseAlignment?
        let attempted: Bool
    }

    private let outputURL: URL
    private let metadataURL: URL
    private let geometryCaptureDirectoryURL: URL?
    private let geometryCaptureManifest: FileHandle?
    private let statusStore: PanoramaMapStatusStore
    private let poseAtCapture: @Sendable (UInt64) -> CaptureAlignedPoseResolution
    private let poseProjection: GimbalPoseProjection
    private let onSpatialObservation: @Sendable (
        GimbalPose,
        Double,
        CameraProjectionModel,
        [SOMACore.NormalizedRect],
        Double,
        PanoramaPlaceEmbedding?,
        UInt64
    ) -> SphericalPlaceRecognition?
    private let onHealth: @Sendable (String, String) -> Void
    private let queue = DispatchQueue(label: "soma.panorama.compositor", qos: .utility)
    private let admissionLock = NSLock()
    private let imageContext = CIContext(options: [.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let width = 1024
    private let height = 256
    private let minimumElevationDegrees = -45.0
    private let maximumElevationDegrees = 45.0
    private let admissionIntervalNS: UInt64 = 250_000_000
    private let poseWaitMilliseconds = 125
    private let writeIntervalNS: UInt64 = 1_000_000_000
    private let placeObservationIntervalNS: UInt64 = 1_000_000_000
    private let minimumProjectionQuality = 0.45
    private let placeEmbeddingEncoder = PanoramaPlaceEmbedding.appleVisionFeaturePrintEncoder
    private let placeEmbeddingRevision = VNGenerateImageFeaturePrintRequest().revision
    private var pending: Pending?
    private var drainScheduled = false
    private var accepting = true
    private var nextAdmissionNS: UInt64 = 0
    private var pixels: [UInt8]
    private var qualities: [Float]
    private var acceptedFrames: UInt64 = 0
    private var lowQualityRejectedFrames: UInt64 = 0
    private var poseInterpolationMisses: UInt64 = 0
    private var poseMissReasons: [String: UInt64] = [:]
    private var dynamicallyMaskedPixels: UInt64 = 0
    private var qualityProtectedPixels: UInt64 = 0
    private var alignmentReference: AlignmentReference?
    private var alignmentAttempts: UInt64 = 0
    private var alignmentAccepted: UInt64 = 0
    private var alignmentRejected: UInt64 = 0
    private var alignmentTotalMilliseconds = 0.0
    private var maximumAlignmentMilliseconds = 0.0
    private var alignmentConfidenceTotal = 0.0
    private var alignmentCorrectionTotalDegrees = 0.0
    private var stitchBlendAttempts: UInt64 = 0
    private var stitchPhotometricCompensations: UInt64 = 0
    private var stitchBlendTotalMilliseconds = 0.0
    private var maximumStitchBlendMilliseconds = 0.0
    private var stitchRedGainTotal = 0.0
    private var stitchGreenGainTotal = 0.0
    private var stitchBlueGainTotal = 0.0
    private var nextPlaceObservationNS: UInt64 = 0
    private var placeObservations: UInt64 = 0
    private var placeRevisits: UInt64 = 0
    private var placeFamiliarityTotal = 0.0
    private var placeEmbeddingAttempts: UInt64 = 0
    private var placeEmbeddingFailures: UInt64 = 0
    private var placeEmbeddingTotalMilliseconds = 0.0
    private var maximumPlaceEmbeddingMilliseconds = 0.0
    private var placeEmbeddingFailureActive = false
    private var revision: UInt64 = 0
    private var lastWriteNS: UInt64 = 0
    private var lastUpdatedNS: UInt64?
    private var lastProjectedCaptureNS: UInt64?
    private var reachableMask: [Bool]?
    private var reachablePixelCount = 0
    private var geometryCapturedFrames = 0
    private var lastGeometryCapturePose: GimbalPose?

    init(
        outputURL: URL,
        geometryCaptureDirectoryURL: URL? = nil,
        statusStore: PanoramaMapStatusStore,
        poseProjection: GimbalPoseProjection,
        poseAtCapture: @escaping @Sendable (UInt64) -> CaptureAlignedPoseResolution,
        onSpatialObservation: @escaping @Sendable (
            GimbalPose,
            Double,
            CameraProjectionModel,
            [SOMACore.NormalizedRect],
            Double,
            PanoramaPlaceEmbedding?,
            UInt64
        ) -> SphericalPlaceRecognition?,
        onHealth: @escaping @Sendable (String, String) -> Void
    ) throws {
        self.outputURL = outputURL
        metadataURL = outputURL.deletingPathExtension().appendingPathExtension("json")
        self.geometryCaptureDirectoryURL = geometryCaptureDirectoryURL
        if let geometryCaptureDirectoryURL {
            try FileManager.default.createDirectory(
                at: geometryCaptureDirectoryURL,
                withIntermediateDirectories: false
            )
            let manifestURL = geometryCaptureDirectoryURL.appendingPathComponent("frames.jsonl")
            guard FileManager.default.createFile(atPath: manifestURL.path, contents: nil),
                  let manifest = try? FileHandle(forWritingTo: manifestURL) else {
                throw CocoaError(.fileWriteUnknown)
            }
            geometryCaptureManifest = manifest
        } else {
            geometryCaptureManifest = nil
        }
        self.statusStore = statusStore
        self.poseAtCapture = poseAtCapture
        self.poseProjection = poseProjection
        self.onSpatialObservation = onSpatialObservation
        self.onHealth = onHealth
        pixels = [UInt8](repeating: 18, count: width * height * 4)
        qualities = [Float](repeating: 0, count: width * height)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        publishStatus(state: "configured")
        // The panorama is session-scoped. Publish the new empty map
        // immediately so a human-occluded startup cannot leave the previous
        // process's image looking like current spatial state.
        writeSnapshot(at: DispatchTime.now().uptimeNanoseconds)
    }

    func submit(
        pixelBuffer: CVPixelBuffer,
        captureNS: UInt64,
        horizontalFieldOfViewDegrees: Double,
        fieldOfViewMode: Int,
        cameraProjectionModel: CameraProjectionModel,
        dynamicVisionRects: [SOMACore.NormalizedRect]
    ) {
        admissionLock.lock()
        guard accepting, captureNS >= nextAdmissionNS else {
            admissionLock.unlock()
            return
        }
        nextAdmissionNS = captureNS + admissionIntervalNS
        pending = Pending(
            pixelBuffer: PanoramaPixelBuffer(pixelBuffer),
            captureNS: captureNS,
            horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
            fieldOfViewMode: fieldOfViewMode,
            cameraProjectionModel: cameraProjectionModel,
            dynamicVisionRects: Array(dynamicVisionRects.prefix(32))
        )
        guard !drainScheduled else {
            admissionLock.unlock()
            return
        }
        drainScheduled = true
        admissionLock.unlock()
        scheduleDrain()
    }

    func stop() {
        admissionLock.lock()
        accepting = false
        pending = nil
        admissionLock.unlock()
        queue.sync {}
        try? geometryCaptureManifest?.close()
    }

    private func scheduleDrain() {
        queue.asyncAfter(deadline: .now() + .milliseconds(poseWaitMilliseconds)) { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        admissionLock.lock()
        let frame = pending
        pending = nil
        drainScheduled = false
        admissionLock.unlock()
        guard let frame else { return }
        autoreleasepool { process(frame) }

        admissionLock.lock()
        let shouldContinue = accepting && pending != nil && !drainScheduled
        if shouldContinue { drainScheduled = true }
        admissionLock.unlock()
        if shouldContinue { scheduleDrain() }
    }

    private func process(_ frame: Pending) {
        let resolution = poseAtCapture(frame.captureNS)
        guard let estimate = resolution.estimate else {
            poseInterpolationMisses += 1
            poseMissReasons[resolution.failure?.rawValue ?? "unknown", default: 0] += 1
            return
        }
        guard CVPixelBufferGetPixelFormatType(frame.pixelBuffer.value) == kCVPixelFormatType_32BGRA else {
            onHealth("unsupported_pixel_format", "expected=32BGRA")
            return
        }
        let sourceWidth = CVPixelBufferGetWidth(frame.pixelBuffer.value)
        let sourceHeight = CVPixelBufferGetHeight(frame.pixelBuffer.value)
        ensureReachableMask(cameraProjectionModel: frame.cameraProjectionModel)
        let motionQuality = PanoramaObservationQuality.motionQuality(
            angularVelocityDegreesPerSecond: estimate.angularVelocityDegreesPerSecond
        )
        let admitsFullFrame = PanoramaObservationQuality.admitsProjection(
            angularVelocityDegreesPerSecond: estimate.angularVelocityDegreesPerSecond
        )
        let elapsedSinceProjection = lastProjectedCaptureNS.flatMap { previousNS in
            frame.captureNS > previousNS
                ? Double(frame.captureNS - previousNS) / 1_000_000_000
                : nil
        } ?? Double(admissionIntervalNS) / 1_000_000_000
        let stripHalfWidth = PanoramaObservationQuality.continuousStripHalfWidthNormalized(
            angularVelocityDegreesPerSecond: estimate.angularVelocityDegreesPerSecond,
            horizontalFieldOfViewDegrees: frame.cameraProjectionModel.horizontalFieldOfViewDegrees,
            admissionIntervalSeconds: elapsedSinceProjection
        )
        guard admitsFullFrame || stripHalfWidth != nil else {
            lowQualityRejectedFrames += 1
            let now = DispatchTime.now().uptimeNanoseconds
            if lastWriteNS == 0 || now - lastWriteNS >= writeIntervalNS {
                writeSnapshot(at: now)
            }
            return
        }
        // Calibration evidence has a stricter independent stillness gate and
        // must not depend on the current panorama registration succeeding.
        // Otherwise a geometry error can prevent collecting the very evidence
        // needed to correct it.
        captureGeometryFrameIfNeeded(
            frame,
            pose: estimate.pose,
            angularVelocityDegreesPerSecond: estimate.angularVelocityDegreesPerSecond,
            motionQuality: motionQuality
        )
        let alignment: AlignmentOutcome
        if frame.dynamicVisionRects.isEmpty {
            alignment = align(
                frame.pixelBuffer,
                measuredPose: estimate.pose,
                horizontalFieldOfViewDegrees: frame.horizontalFieldOfViewDegrees,
                cameraProjectionModel: frame.cameraProjectionModel,
                width: sourceWidth,
                height: sourceHeight
            )
        } else {
            // Translation registration cannot mask independent foreground
            // motion. Keep the last clean background reference rather than
            // letting a transient object bias the spherical pose correction.
            alignment = AlignmentOutcome(estimate: nil, attempted: false)
        }
        // Once two nominally overlapping views disagree, accepting the raw
        // attitude creates a permanent duplicate seam. A rejected registration
        // is missing evidence, not a lower-quality observation.
        if admitsFullFrame, alignment.attempted, alignment.estimate?.accepted != true {
            lowQualityRejectedFrames += 1
            let now = DispatchTime.now().uptimeNanoseconds
            if lastWriteNS == 0 || now - lastWriteNS >= writeIntervalNS {
                writeSnapshot(at: now)
            }
            return
        }
        let projectedPose = alignment.estimate?.correctedPose ?? estimate.pose
        let alignmentQuality: Double
        if alignment.estimate?.accepted == true {
            alignmentQuality = 0.55 + 0.45 * (alignment.estimate?.confidence ?? 0)
        } else if alignment.attempted {
            // A failed still-frame registration is rejected above. During a
            // moving strip the capture-aligned SDK attitude remains usable,
            // but receives a bounded quality penalty rather than inventing a
            // visual correction.
            alignmentQuality = 0.85
        } else {
            alignmentQuality = 1
        }
        let frameQuality = motionQuality * alignmentQuality
        let requiredProjectionQuality = stripHalfWidth == nil
            ? minimumProjectionQuality
            : PanoramaObservationQuality.motionQuality(
                angularVelocityDegreesPerSecond:
                    PanoramaObservationQuality.maximumStripAngularVelocityDegreesPerSecond
            )
        guard frameQuality >= requiredProjectionQuality else {
            lowQualityRejectedFrames += 1
            let now = DispatchTime.now().uptimeNanoseconds
            if lastWriteNS == 0 || now - lastWriteNS >= writeIntervalNS {
                writeSnapshot(at: now)
            }
            return
        }
        if frame.dynamicVisionRects.isEmpty {
            alignmentReference = AlignmentReference(
                pixelBuffer: frame.pixelBuffer,
                pose: estimate.pose,
                cameraProjectionModel: frame.cameraProjectionModel
            )
        }
        let placeEmbedding: PanoramaPlaceEmbedding?
        if admitsFullFrame,
           frame.captureNS >= nextPlaceObservationNS,
           frame.dynamicVisionRects.isEmpty {
            nextPlaceObservationNS = frame.captureNS + placeObservationIntervalNS
            placeEmbedding = makePlaceEmbedding(from: frame.pixelBuffer.value)
        } else {
            placeEmbedding = nil
        }
        CVPixelBufferLockBaseAddress(frame.pixelBuffer.value, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer.value, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(frame.pixelBuffer.value) else { return }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(frame.pixelBuffer.value)
        let source = baseAddress.assumingMemoryBound(to: UInt8.self)
        var incomingPixels = [UInt8](repeating: 0, count: pixels.count)
        var incomingQualities = [Float](repeating: 0, count: qualities.count)
        var maskedThisFrame: UInt64 = 0
        var protectedThisFrame: UInt64 = 0
        let cameraAzimuthDegrees = projectedPose.panDegrees
            * (poseProjection.panImageSign >= 0 ? 1 : -1)
        let cameraElevationDegrees = projectedPose.pitchDegrees
            * (poseProjection.pitchImageSign >= 0 ? 1 : -1)
        guard let preparedCameraView = SphericalPanoramaProjection.PreparedCameraView(
            cameraPose: projectedPose,
            horizontalFieldOfViewDegrees: frame.horizontalFieldOfViewDegrees,
            poseProjection: poseProjection,
            cameraProjectionModel: frame.cameraProjectionModel
        ) else {
            onHealth("invalid_camera_projection", "frame_rejected")
            return
        }
        // The old implementation evaluated every panorama pixel for every
        // camera frame even though a perspective frame occupies only a small
        // spherical window. That made the worker slower than the strip sweep,
        // so newer frames replaced one another before projection and left
        // holes. The generous bounds include lens/extrinsic residuals; the
        // exact gnomonic projection below remains the final admission test.
        let horizontalCandidateRadius = min(
            89,
            frame.cameraProjectionModel.horizontalFieldOfViewDegrees * 0.65 + 6
        )
        let verticalCandidateRadius = min(
            89,
            frame.cameraProjectionModel.verticalFieldOfViewDegrees * 0.65 + 6
        )
        let candidateColumns = (0..<width).filter { panoramaX in
            let azimuth = -180
                + (Double(panoramaX) + 0.5) / Double(width) * 360
            return abs(circularDifferenceDegrees(azimuth, cameraAzimuthDegrees))
                <= horizontalCandidateRadius
        }
        let candidateRows = (0..<height).filter { panoramaY in
            let elevation = maximumElevationDegrees
                - (Double(panoramaY) + 0.5) / Double(height)
                    * (maximumElevationDegrees - minimumElevationDegrees)
            return abs(elevation - cameraElevationDegrees) <= verticalCandidateRadius
        }

        for panoramaY in candidateRows {
            for panoramaX in candidateColumns {
                let outputBearing = SphericalPanoramaProjection.outputBearing(
                    column: panoramaX,
                    row: panoramaY,
                    width: width,
                    height: height,
                    minimumElevationDegrees: minimumElevationDegrees,
                    maximumElevationDegrees: maximumElevationDegrees
                )
                guard let coordinate = preparedCameraView.sourceCoordinate(for: outputBearing) else {
                    continue
                }
                if let stripHalfWidth,
                   abs(coordinate.normalizedX - frame.cameraProjectionModel.principalXNormalized)
                    > stripHalfWidth {
                    continue
                }
                let destinationPixel = panoramaY * width + panoramaX
                let destinationIndex = destinationPixel * 4
                let isDynamicEntity = SphericalPanoramaProjection.isDynamicallyMasked(
                    sourceCoordinate: coordinate,
                    visionRects: frame.dynamicVisionRects
                )
                if isDynamicEntity {
                    maskedThisFrame += 1
                    // Preserve an existing background, but do not render an
                    // unexplained black hole when the first view is occluded.
                    // The provisional low-quality entity pixel is guaranteed
                    // to yield to a later unobstructed observation.
                    if qualities[destinationPixel] > 0 {
                        protectedThisFrame += 1
                        continue
                    }
                }
                let sourceX = min(sourceWidth - 1, max(0, Int(coordinate.normalizedX * Double(sourceWidth))))
                let sourceY = min(sourceHeight - 1, max(0, Int(coordinate.normalizedY * Double(sourceHeight))))
                let sourceIndex = sourceY * sourceBytesPerRow + sourceX * 4
                let stripCentreWeight: Double
                if let stripHalfWidth {
                    let normalizedOffset = min(
                        1,
                        abs(coordinate.normalizedX - frame.cameraProjectionModel.principalXNormalized)
                            / stripHalfWidth
                    )
                    let edgeProgress = max(0, (normalizedOffset - 0.78) / 0.22)
                    let smoothEdge = edgeProgress * edgeProgress * (3 - 2 * edgeProgress)
                    // Keep a small non-zero edge contribution so a single
                    // pass cannot reopen holes. Its low quality lets the next
                    // strip's central pixels replace the overlap cleanly.
                    stripCentreWeight = max(0.05, 1 - smoothEdge)
                } else {
                    stripCentreWeight = 1
                }
                let projectionQuality = stripHalfWidth == nil
                    ? frameQuality
                    : frameQuality * 0.78 * stripCentreWeight
                let observedQuality = projectionQuality * coordinate.viewWeight
                let incomingQuality = Float(
                    isDynamicEntity ? min(observedQuality, 0.18) : observedQuality
                )
                let priorQuality = qualities[destinationPixel]
                guard PanoramaObservationQuality.shouldReplace(
                    existingQuality: Double(priorQuality),
                    incomingQuality: Double(incomingQuality)
                ) else {
                    protectedThisFrame += 1
                    continue
                }
                for channel in 0..<3 {
                    let sourceChannel = channel == 0 ? 2 : (channel == 2 ? 0 : 1)
                    incomingPixels[destinationIndex + channel] = source[sourceIndex + sourceChannel]
                }
                incomingPixels[destinationIndex + 3] = 255
                incomingQualities[destinationPixel] = incomingQuality
            }
        }
        let blendResult = pixels.withUnsafeMutableBufferPointer { panoramaPixels in
            qualities.withUnsafeMutableBufferPointer { panoramaQualities in
                incomingPixels.withUnsafeBufferPointer { observationPixels in
                    incomingQualities.withUnsafeBufferPointer { observationQualities in
                        soma_photometric_feather_rgba(
                            panoramaPixels.baseAddress,
                            panoramaQualities.baseAddress,
                            observationPixels.baseAddress,
                            observationQualities.baseAddress,
                            Int32(width),
                            Int32(height)
                        )
                    }
                }
            }
        }
        stitchBlendAttempts += 1
        stitchBlendTotalMilliseconds += blendResult.elapsed_milliseconds
        maximumStitchBlendMilliseconds = max(
            maximumStitchBlendMilliseconds,
            blendResult.elapsed_milliseconds
        )
        if blendResult.success == 0 {
            onHealth("stitch_blend_error", "engine=opencv_channels_feather")
            return
        }
        if blendResult.exposure_compensated != 0 {
            stitchPhotometricCompensations += 1
            stitchRedGainTotal += Double(blendResult.red_gain)
            stitchGreenGainTotal += Double(blendResult.green_gain)
            stitchBlueGainTotal += Double(blendResult.blue_gain)
        }
        acceptedFrames += 1
        lastProjectedCaptureNS = frame.captureNS
        dynamicallyMaskedPixels += maskedThisFrame
        qualityProtectedPixels += protectedThisFrame
        let placeRecognition = onSpatialObservation(
            projectedPose,
            frame.horizontalFieldOfViewDegrees,
            frame.cameraProjectionModel,
            frame.dynamicVisionRects,
            frameQuality,
            placeEmbedding,
            frame.captureNS
        )
        if let placeRecognition {
            placeObservations += 1
            if placeRecognition.isRevisit {
                placeRevisits += 1
                placeFamiliarityTotal += placeRecognition.familiarity
            }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastWriteNS == 0 || now - lastWriteNS >= writeIntervalNS else { return }
        writeSnapshot(at: now)
    }

    private func align(
        _ current: PanoramaPixelBuffer,
        measuredPose: GimbalPose,
        horizontalFieldOfViewDegrees: Double,
        cameraProjectionModel: CameraProjectionModel,
        width: Int,
        height: Int
    ) -> AlignmentOutcome {
        guard let reference = alignmentReference,
              CVPixelBufferGetWidth(reference.pixelBuffer.value) == width,
              CVPixelBufferGetHeight(reference.pixelBuffer.value) == height,
              reference.cameraProjectionModel == cameraProjectionModel else {
            return AlignmentOutcome(estimate: nil, attempted: false)
        }
        let horizontalFOV = min(max(horizontalFieldOfViewDegrees, 1), 170)
        let verticalHalf = atan(tan(horizontalFOV * .pi / 360) / (16.0 / 9.0))
        let verticalFOV = verticalHalf * 360 / .pi
        guard abs(measuredPose.panDegrees - reference.pose.panDegrees) <= horizontalFOV * 0.65,
              abs(measuredPose.pitchDegrees - reference.pose.pitchDegrees) <= verticalFOV * 0.65 else {
            return AlignmentOutcome(estimate: nil, attempted: false)
        }
        let startedNS = DispatchTime.now().uptimeNanoseconds
        alignmentAttempts += 1
        let refinement: PanoramaPoseAlignment
        do {
            let request = VNTranslationalImageRegistrationRequest(
                targetedCVPixelBuffer: current.value,
                orientation: .up,
                options: [:]
            )
            try VNImageRequestHandler(
                cvPixelBuffer: reference.pixelBuffer.value,
                orientation: .up,
                options: [:]
            ).perform([request])
            guard let observation = request.results?.first else {
                throw PanoramaCompositorError.unsupportedFeaturePrint
            }
            let transform = observation.alignmentTransform
            refinement = PanoramaPoseRefinement.refine(
                previousPose: reference.pose,
                currentPose: measuredPose,
                alignmentTranslationX: Double(transform.tx),
                alignmentTranslationY: Double(transform.ty),
                imageWidth: width,
                imageHeight: height,
                horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                cameraProjectionModel: cameraProjectionModel,
                confidence: Double(observation.confidence),
                poseProjection: poseProjection
            )
        } catch {
            let duration = Double(DispatchTime.now().uptimeNanoseconds - startedNS) / 1_000_000
            alignmentTotalMilliseconds += duration
            maximumAlignmentMilliseconds = max(maximumAlignmentMilliseconds, duration)
            alignmentRejected += 1
            return AlignmentOutcome(estimate: nil, attempted: true)
        }
        let duration = Double(DispatchTime.now().uptimeNanoseconds - startedNS) / 1_000_000
        alignmentTotalMilliseconds += duration
        maximumAlignmentMilliseconds = max(maximumAlignmentMilliseconds, duration)
        alignmentConfidenceTotal += refinement.confidence
        if refinement.accepted {
            alignmentAccepted += 1
            alignmentCorrectionTotalDegrees += hypot(
                refinement.panCorrectionDegrees,
                refinement.pitchCorrectionDegrees
            )
        } else {
            alignmentRejected += 1
        }
        return AlignmentOutcome(estimate: refinement, attempted: true)
    }

    private func makePlaceEmbedding(from pixelBuffer: CVPixelBuffer) -> PanoramaPlaceEmbedding? {
        let startedNS = DispatchTime.now().uptimeNanoseconds
        placeEmbeddingAttempts += 1
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedNS) / 1_000_000
            placeEmbeddingTotalMilliseconds += elapsed
            maximumPlaceEmbeddingMilliseconds = max(maximumPlaceEmbeddingMilliseconds, elapsed)
        }
        do {
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = placeEmbeddingRevision
            try VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up,
                options: [:]
            ).perform([request])
            guard let observation = request.results?.first,
                  observation.elementType == .float,
                  observation.elementCount >= 8,
                  observation.elementCount <= PanoramaPlaceEmbedding.maximumElementCount,
                  observation.data.count == observation.elementCount * MemoryLayout<Float>.size else {
                throw PanoramaCompositorError.unsupportedFeaturePrint
            }
            var values = [Float](repeating: 0, count: observation.elementCount)
            _ = values.withUnsafeMutableBytes { destination in
                observation.data.copyBytes(to: destination)
            }
            guard let embedding = PanoramaPlaceEmbedding(
                encoder: placeEmbeddingEncoder,
                revision: placeEmbeddingRevision,
                values: values
            ) else {
                throw PanoramaCompositorError.unsupportedFeaturePrint
            }
            if placeEmbeddingFailureActive {
                onHealth("place_embedding_recovered", "encoder=\(placeEmbeddingEncoder); revision=\(placeEmbeddingRevision)")
                placeEmbeddingFailureActive = false
            }
            return embedding
        } catch {
            placeEmbeddingFailures += 1
            if !placeEmbeddingFailureActive {
                onHealth(
                    "place_embedding_error",
                    "encoder=\(placeEmbeddingEncoder); revision=\(placeEmbeddingRevision); error=\(String(error.localizedDescription.prefix(128)))"
                )
                placeEmbeddingFailureActive = true
            }
            return nil
        }
    }

    private func captureGeometryFrameIfNeeded(
        _ frame: Pending,
        pose: GimbalPose,
        angularVelocityDegreesPerSecond: Double,
        motionQuality: Double
    ) {
        guard let geometryCaptureDirectoryURL,
              let geometryCaptureManifest,
              geometryCapturedFrames < 96,
              PanoramaObservationQuality.admitsCalibration(
                  angularVelocityDegreesPerSecond: angularVelocityDegreesPerSecond
              ),
              motionQuality >= 0.99 else {
            return
        }
        if let lastGeometryCapturePose,
           hypot(
               circularDifferenceDegrees(pose.panDegrees, lastGeometryCapturePose.panDegrees),
               pose.pitchDegrees - lastGeometryCapturePose.pitchDegrees
           ) < 3 {
            return
        }
        let filename = String(format: "frame-%03d-%llu.jpg", geometryCapturedFrames, frame.captureNS)
        let destination = geometryCaptureDirectoryURL.appendingPathComponent(filename)
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer.value)
        guard let jpeg = imageContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [:]
        ) else {
            onHealth("geometry_capture_encode_error", "index=\(geometryCapturedFrames)")
            return
        }
        do {
            try jpeg.write(to: destination, options: .atomic)
            let record = CameraGeometryCaptureRecord(
                filename: filename,
                captureNS: frame.captureNS,
                panDegrees: pose.panDegrees,
                pitchDegrees: pose.pitchDegrees,
                imageWidth: CVPixelBufferGetWidth(frame.pixelBuffer.value),
                imageHeight: CVPixelBufferGetHeight(frame.pixelBuffer.value),
                fovMode: frame.fieldOfViewMode,
                reportedHorizontalFieldOfViewDegrees: frame.horizontalFieldOfViewDegrees,
                angularVelocityDegreesPerSecond: angularVelocityDegreesPerSecond
            )
            var line = try JSONEncoder().encode(record)
            line.append(0x0A)
            try geometryCaptureManifest.write(contentsOf: line)
            geometryCapturedFrames += 1
            lastGeometryCapturePose = pose
            if geometryCapturedFrames == 1 || geometryCapturedFrames % 8 == 0 {
                onHealth(
                    "geometry_capture_progress",
                    "frames=\(geometryCapturedFrames); maximum=96; directory=\(String(geometryCaptureDirectoryURL.path.prefix(160)))"
                )
            }
        } catch {
            onHealth("geometry_capture_write_error", String(error.localizedDescription.prefix(160)))
        }
    }

    private func circularDifferenceDegrees(_ lhs: Double, _ rhs: Double) -> Double {
        var difference = (lhs - rhs).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        return difference
    }

    private func ensureReachableMask(cameraProjectionModel: CameraProjectionModel) {
        guard reachableMask == nil else { return }
        var mask = [Bool](repeating: false, count: width * height)
        var count = 0
        for panoramaY in 0..<height {
            for panoramaX in 0..<width {
                let bearing = SphericalPanoramaProjection.outputBearing(
                    column: panoramaX,
                    row: panoramaY,
                    width: width,
                    height: height,
                    minimumElevationDegrees: minimumElevationDegrees,
                    maximumElevationDegrees: maximumElevationDegrees
                )
                guard SphericalPanoramaProjection.isReachable(
                    bearing,
                    cameraProjectionModel: cameraProjectionModel,
                    poseProjection: poseProjection,
                    kinematicEnvelope: .obsbotTiny2Lite
                ) else { continue }
                mask[panoramaY * width + panoramaX] = true
                count += 1
            }
        }
        reachableMask = mask
        reachablePixelCount = count
    }

    private func writeSnapshot(at monotonicNS: UInt64) {
        let bitmap = Data(pixels)
        let image = CIImage(
            bitmapData: bitmap,
            bytesPerRow: width * 4,
            size: CGSize(width: width, height: height),
            format: .RGBA8,
            colorSpace: colorSpace
        )
        guard let jpeg = imageContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: [:]) else {
            onHealth("encode_error", "format=equirectangular_jpeg")
            return
        }
        do {
            try jpeg.write(to: outputURL, options: .atomic)
            revision += 1
            lastWriteNS = monotonicNS
            lastUpdatedNS = monotonicNS
            let status = makeStatus(state: "ready")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(status).write(to: metadataURL, options: .atomic)
            statusStore.update(status)
        } catch {
            publishStatus(state: "write_error")
            onHealth("write_error", String(error.localizedDescription.prefix(192)))
        }
    }

    private func publishStatus(state: String) {
        statusStore.update(makeStatus(state: state))
    }

    private func makeStatus(state: String) -> PanoramaMapStatus {
        let covered = qualities.reduce(into: 0) { count, quality in
            if quality > 0 { count += 1 }
        }
        let qualityCovered = qualities.reduce(into: 0) { count, quality in
            if quality >= 0.45 { count += 1 }
        }
        var reachableCovered = 0
        var reachableQualityCovered = 0
        if let reachableMask {
            for (index, reachable) in reachableMask.enumerated() where reachable {
                if qualities[index] > 0 { reachableCovered += 1 }
                if qualities[index] >= 0.45 { reachableQualityCovered += 1 }
            }
        }
        let qualityTotal = qualities.reduce(0) { $0 + Double($1) }
        return PanoramaMapStatus(
            state: state,
            imagePath: outputURL.path,
            metadataPath: metadataURL.path,
            width: width,
            height: height,
            minimumElevationDegrees: minimumElevationDegrees,
            maximumElevationDegrees: maximumElevationDegrees,
            azimuthIncreasesLeftToRight: true,
            elevationIncreasesBottomToTop: true,
            revision: revision,
            acceptedFrames: acceptedFrames,
            lowQualityRejectedFrames: lowQualityRejectedFrames,
            poseInterpolationMisses: poseInterpolationMisses,
            poseMissReasons: poseMissReasons,
            dynamicallyMaskedPixels: dynamicallyMaskedPixels,
            coverageFraction: Double(covered) / Double(qualities.count),
            qualityCoverageFraction: Double(qualityCovered) / Double(qualities.count),
            reachablePixelFraction: Double(reachablePixelCount) / Double(qualities.count),
            reachableCoverageFraction: reachablePixelCount == 0
                ? 0
                : Double(reachableCovered) / Double(reachablePixelCount),
            reachableQualityCoverageFraction: reachablePixelCount == 0
                ? 0
                : Double(reachableQualityCovered) / Double(reachablePixelCount),
            meanObservationQuality: qualityTotal / Double(qualities.count),
            qualityProtectedPixels: qualityProtectedPixels,
            alignmentAttempts: alignmentAttempts,
            alignmentAccepted: alignmentAccepted,
            alignmentRejected: alignmentRejected,
            averageAlignmentMilliseconds: alignmentAttempts == 0
                ? 0
                : alignmentTotalMilliseconds / Double(alignmentAttempts),
            maximumAlignmentMilliseconds: maximumAlignmentMilliseconds,
            meanAlignmentConfidence: alignmentAttempts == 0
                ? 0
                : alignmentConfidenceTotal / Double(alignmentAttempts),
            meanAlignmentCorrectionDegrees: alignmentAccepted == 0
                ? 0
                : alignmentCorrectionTotalDegrees / Double(alignmentAccepted),
            stitchBlendAttempts: stitchBlendAttempts,
            stitchPhotometricCompensations: stitchPhotometricCompensations,
            averageStitchBlendMilliseconds: stitchBlendAttempts == 0
                ? 0
                : stitchBlendTotalMilliseconds / Double(stitchBlendAttempts),
            maximumStitchBlendMilliseconds: maximumStitchBlendMilliseconds,
            meanStitchRedGain: stitchPhotometricCompensations == 0
                ? 1
                : stitchRedGainTotal / Double(stitchPhotometricCompensations),
            meanStitchGreenGain: stitchPhotometricCompensations == 0
                ? 1
                : stitchGreenGainTotal / Double(stitchPhotometricCompensations),
            meanStitchBlueGain: stitchPhotometricCompensations == 0
                ? 1
                : stitchBlueGainTotal / Double(stitchPhotometricCompensations),
            placeObservations: placeObservations,
            placeRevisits: placeRevisits,
            meanPlaceFamiliarity: placeRevisits == 0
                ? 0
                : placeFamiliarityTotal / Double(placeRevisits),
            placeEmbeddingEncoder: placeEmbeddingEncoder,
            placeEmbeddingRevision: placeEmbeddingRevision,
            placeEmbeddingAttempts: placeEmbeddingAttempts,
            placeEmbeddingFailures: placeEmbeddingFailures,
            averagePlaceEmbeddingMilliseconds: placeEmbeddingAttempts == 0
                ? 0
                : placeEmbeddingTotalMilliseconds / Double(placeEmbeddingAttempts),
            maximumPlaceEmbeddingMilliseconds: maximumPlaceEmbeddingMilliseconds,
            lastUpdatedNS: lastUpdatedNS
        )
    }
}
