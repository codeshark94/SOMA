import Foundation

public enum CaptureAlignedPoseInterpolationMode: String, Codable, Sendable {
    case exact
    case bracketed
}

public struct CaptureAlignedPoseEstimate: Codable, Equatable, Sendable {
    public let pose: GimbalPose
    public let mode: CaptureAlignedPoseInterpolationMode
    public let beforeMonotonicNS: UInt64
    public let afterMonotonicNS: UInt64
    public let interpolationFraction: Double
    public let angularVelocityDegreesPerSecond: Double

    public init(
        pose: GimbalPose,
        mode: CaptureAlignedPoseInterpolationMode,
        beforeMonotonicNS: UInt64,
        afterMonotonicNS: UInt64,
        interpolationFraction: Double,
        angularVelocityDegreesPerSecond: Double = 0
    ) {
        self.pose = pose
        self.mode = mode
        self.beforeMonotonicNS = beforeMonotonicNS
        self.afterMonotonicNS = afterMonotonicNS
        self.interpolationFraction = min(max(interpolationFraction, 0), 1)
        self.angularVelocityDegreesPerSecond = max(0, angularVelocityDegreesPerSecond)
    }
}

public enum CaptureAlignedPoseFailure: String, Codable, Sendable {
    case noSamples = "no_samples"
    case noEarlierSample = "no_earlier_sample"
    case noLaterSample = "no_later_sample"
    case earlierSampleTooFar = "earlier_sample_too_far"
    case laterSampleTooFar = "later_sample_too_far"
    case bracketTooWide = "bracket_too_wide"
}

public struct CaptureAlignedPoseResolution: Sendable {
    public let estimate: CaptureAlignedPoseEstimate?
    public let failure: CaptureAlignedPoseFailure?

    public init(estimate: CaptureAlignedPoseEstimate?, failure: CaptureAlignedPoseFailure?) {
        self.estimate = estimate
        self.failure = failure
    }
}

/// Resolves a camera attitude at the frame exposure timestamp. A panorama
/// update is rejected when the exposure is not bracketed by nearby measured
/// attitudes; it never guesses from a stale pre-motion pose.
public enum CaptureAlignedPoseInterpolator {
    public static func estimate(
        samples: [GimbalPose],
        at captureNS: UInt64,
        maximumSampleDistanceNS: UInt64 = 50_000_000,
        maximumBracketSpanNS: UInt64 = 80_000_000
    ) -> CaptureAlignedPoseEstimate? {
        resolve(
            samples: samples,
            at: captureNS,
            maximumSampleDistanceNS: maximumSampleDistanceNS,
            maximumBracketSpanNS: maximumBracketSpanNS
        ).estimate
    }

    public static func resolve(
        samples: [GimbalPose],
        at captureNS: UInt64,
        maximumSampleDistanceNS: UInt64 = 50_000_000,
        maximumBracketSpanNS: UInt64 = 80_000_000
    ) -> CaptureAlignedPoseResolution {
        let ordered = samples.sorted { $0.monotonicNS < $1.monotonicNS }
        guard !ordered.isEmpty else {
            return CaptureAlignedPoseResolution(estimate: nil, failure: .noSamples)
        }
        if let exactIndex = ordered.lastIndex(where: { $0.monotonicNS == captureNS }) {
            let exact = ordered[exactIndex]
            let velocity: Double
            if exactIndex > ordered.startIndex, exactIndex + 1 < ordered.endIndex {
                velocity = angularVelocity(
                    from: ordered[exactIndex - 1],
                    to: ordered[exactIndex + 1]
                )
            } else if exactIndex > ordered.startIndex {
                velocity = angularVelocity(from: ordered[exactIndex - 1], to: exact)
            } else if exactIndex + 1 < ordered.endIndex {
                velocity = angularVelocity(from: exact, to: ordered[exactIndex + 1])
            } else {
                velocity = 0
            }
            return CaptureAlignedPoseResolution(
                estimate: CaptureAlignedPoseEstimate(
                    pose: GimbalPose(
                        pitchDegrees: exact.pitchDegrees,
                        panDegrees: exact.panDegrees,
                        monotonicNS: captureNS
                    ),
                    mode: .exact,
                    beforeMonotonicNS: captureNS,
                    afterMonotonicNS: captureNS,
                    interpolationFraction: 0,
                    angularVelocityDegreesPerSecond: velocity
                ),
                failure: nil
            )
        }
        guard let before = ordered.last(where: { $0.monotonicNS < captureNS }) else {
            return CaptureAlignedPoseResolution(estimate: nil, failure: .noEarlierSample)
        }
        guard let after = ordered.first(where: { $0.monotonicNS > captureNS }) else {
            return CaptureAlignedPoseResolution(estimate: nil, failure: .noLaterSample)
        }
        guard captureNS - before.monotonicNS <= maximumSampleDistanceNS else {
            return CaptureAlignedPoseResolution(estimate: nil, failure: .earlierSampleTooFar)
        }
        guard after.monotonicNS - captureNS <= maximumSampleDistanceNS else {
            return CaptureAlignedPoseResolution(estimate: nil, failure: .laterSampleTooFar)
        }
        guard after.monotonicNS > before.monotonicNS,
              after.monotonicNS - before.monotonicNS <= maximumBracketSpanNS else {
            return CaptureAlignedPoseResolution(estimate: nil, failure: .bracketTooWide)
        }
        let fraction = Double(captureNS - before.monotonicNS)
            / Double(after.monotonicNS - before.monotonicNS)
        let angularVelocity = angularVelocity(from: before, to: after)
        return CaptureAlignedPoseResolution(
            estimate: CaptureAlignedPoseEstimate(
                pose: GimbalPose(
                    pitchDegrees: before.pitchDegrees + (after.pitchDegrees - before.pitchDegrees) * fraction,
                    panDegrees: before.panDegrees + (after.panDegrees - before.panDegrees) * fraction,
                    monotonicNS: captureNS
                ),
                mode: .bracketed,
                beforeMonotonicNS: before.monotonicNS,
                afterMonotonicNS: after.monotonicNS,
                interpolationFraction: fraction,
                angularVelocityDegreesPerSecond: angularVelocity
            ),
            failure: nil
        )
    }

    private static func angularVelocity(from before: GimbalPose, to after: GimbalPose) -> Double {
        guard after.monotonicNS > before.monotonicNS else { return 0 }
        let seconds = Double(after.monotonicNS - before.monotonicNS) / 1_000_000_000
        return hypot(
            after.panDegrees - before.panDegrees,
            after.pitchDegrees - before.pitchDegrees
        ) / seconds
    }
}

public enum PanoramaObservationQuality {
    public static let maximumProjectionAngularVelocityDegreesPerSecond = 2.0
    public static let maximumStripAngularVelocityDegreesPerSecond = 40.0
    public static let maximumCalibrationAngularVelocityDegreesPerSecond = 0.75

    /// Motion quality is continuous so the compositor can reject an unstable
    /// frame before it reaches the spherical raster.
    public static func motionQuality(angularVelocityDegreesPerSecond: Double) -> Double {
        let normalized = max(0, angularVelocityDegreesPerSecond) / 24
        return 1 / (1 + normalized * normalized)
    }

    public static func admitsProjection(angularVelocityDegreesPerSecond: Double) -> Bool {
        angularVelocityDegreesPerSecond.isFinite
            && angularVelocityDegreesPerSecond >= 0
            && angularVelocityDegreesPerSecond <= maximumProjectionAngularVelocityDegreesPerSecond
    }

    public static func admitsCalibration(angularVelocityDegreesPerSecond: Double) -> Bool {
        angularVelocityDegreesPerSecond.isFinite
            && angularVelocityDegreesPerSecond >= 0
            && angularVelocityDegreesPerSecond <= maximumCalibrationAngularVelocityDegreesPerSecond
    }

    /// During a continuous sweep, only the optically central strip is used.
    /// Its width covers one admission interval plus a small overlap, while the
    /// distorted and parallax-sensitive frame edges are excluded.
    public static func continuousStripHalfWidthNormalized(
        angularVelocityDegreesPerSecond: Double,
        horizontalFieldOfViewDegrees: Double,
        admissionIntervalSeconds: Double = 0.25
    ) -> Double? {
        guard angularVelocityDegreesPerSecond.isFinite,
              angularVelocityDegreesPerSecond > maximumProjectionAngularVelocityDegreesPerSecond,
              angularVelocityDegreesPerSecond <= maximumStripAngularVelocityDegreesPerSecond,
              horizontalFieldOfViewDegrees.isFinite,
              horizontalFieldOfViewDegrees >= 1 else {
            return nil
        }
        let angularWidth = angularVelocityDegreesPerSecond
            * min(max(admissionIntervalSeconds, 0.05), 1.0) + 2
        return min(0.28, max(0.035, angularWidth / (2 * horizontalFieldOfViewDegrees)))
    }

    public static func shouldReplace(
        existingQuality: Double,
        incomingQuality: Double,
        minimumImprovement: Double = 0.025
    ) -> Bool {
        guard incomingQuality > 0 else { return false }
        guard existingQuality > 0 else { return true }
        return incomingQuality >= existingQuality + min(max(minimumImprovement, 0.001), 0.2)
    }
}

public enum PanoramaEntityMaskPolicy {
    /// People remain in the entity layer instead of becoming persistent place
    /// pixels. A detector class alone does not prove a nonhuman object is
    /// moving, so ordinary objects remain part of the observed scene.
    public static func shouldMask(_ kind: AttentionTargetKind) -> Bool {
        kind == .human
    }
}

public struct PanoramaPoseAlignment: Equatable, Sendable {
    public let correctedPose: GimbalPose
    public let confidence: Double
    public let panCorrectionDegrees: Double
    public let pitchCorrectionDegrees: Double
    public let residualDegrees: Double
    public let accepted: Bool

    public init(
        correctedPose: GimbalPose,
        confidence: Double,
        panCorrectionDegrees: Double,
        pitchCorrectionDegrees: Double,
        residualDegrees: Double,
        accepted: Bool
    ) {
        self.correctedPose = correctedPose
        self.confidence = min(max(confidence, 0), 1)
        self.panCorrectionDegrees = panCorrectionDegrees
        self.pitchCorrectionDegrees = pitchCorrectionDegrees
        self.residualDegrees = max(0, residualDegrees)
        self.accepted = accepted
    }
}

/// Converts Vision's current-to-reference pixel translation into a bounded
/// correction of the capture-aligned gimbal pose. The previous measured pose
/// anchors every pair, so registration errors cannot accumulate as odometry.
public enum PanoramaPoseRefinement {
    public static func refine(
        previousPose: GimbalPose,
        currentPose: GimbalPose,
        alignmentTranslationX: Double,
        alignmentTranslationY: Double,
        imageWidth: Int,
        imageHeight: Int,
        horizontalFieldOfViewDegrees: Double,
        cameraProjectionModel: CameraProjectionModel? = nil,
        confidence: Double,
        poseProjection: GimbalPoseProjection
    ) -> PanoramaPoseAlignment {
        let boundedConfidence = min(max(confidence, 0), 1)
        let projection = cameraProjectionModel ?? .pinhole(
            horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
            aspectRatio: Double(max(imageWidth, 1)) / Double(max(imageHeight, 1))
        )
        let horizontalFOV = projection.horizontalFieldOfViewDegrees
        let verticalFOV = projection.verticalFieldOfViewDegrees
        guard imageWidth > 0, imageHeight > 0,
              alignmentTranslationX.isFinite, alignmentTranslationY.isFinite,
              projection.isValid,
              boundedConfidence >= 0.55 else {
            return rejected(currentPose, confidence: boundedConfidence)
        }

        func idealAngles(normalizedX: Double, normalizedY: Double) -> (pan: Double, pitchDown: Double) {
            let actual = (
                (normalizedX - projection.principalXNormalized) / projection.focalXNormalized,
                (normalizedY - projection.principalYNormalized) / projection.focalYNormalized,
                1.0
            )
            let ideal = projection.actualToIdeal(actual)
            return (
                atan2(ideal.0, ideal.2) * 180 / .pi,
                atan2(ideal.1, hypot(ideal.0, ideal.2)) * 180 / .pi
            )
        }
        let opticalAxis = idealAngles(
            normalizedX: projection.principalXNormalized,
            normalizedY: projection.principalYNormalized
        )
        let translatedAxis = idealAngles(
            normalizedX: projection.principalXNormalized
                + alignmentTranslationX / Double(imageWidth),
            normalizedY: projection.principalYNormalized
                + alignmentTranslationY / Double(imageHeight)
        )
        let visualPanDelta = (translatedAxis.pan - opticalAxis.pan) * poseProjection.panImageSign
        let visualPitchDelta = (translatedAxis.pitchDown - opticalAxis.pitchDown) * poseProjection.pitchImageSign
        let measuredPanDelta = currentPose.panDegrees - previousPose.panDegrees
        let measuredPitchDelta = currentPose.pitchDegrees - previousPose.pitchDegrees
        let panResidual = visualPanDelta - measuredPanDelta
        let pitchResidual = visualPitchDelta - measuredPitchDelta
        let residual = hypot(panResidual, pitchResidual)

        // Translation registration is only a local refinement. Once the
        // visual motion consumes most of the FOV, parallax and rotation make a
        // translational model underdetermined and the measured pose wins.
        guard abs(visualPanDelta) <= horizontalFOV * 0.65,
              abs(visualPitchDelta) <= verticalFOV * 0.65 else {
            return rejected(currentPose, confidence: boundedConfidence, residual: residual)
        }
        let robustScale = max(1, min(horizontalFOV, verticalFOV) * 0.08)
        let consistency = 1 / (1 + pow(residual / robustScale, 2))
        let correctionWeight = boundedConfidence * consistency
        guard correctionWeight >= 0.35 else {
            return rejected(currentPose, confidence: correctionWeight, residual: residual)
        }
        let maximumPanCorrection = horizontalFOV * 0.04
        let maximumPitchCorrection = verticalFOV * 0.04
        let panCorrection = clampSigned(panResidual * correctionWeight, maximum: maximumPanCorrection)
        let pitchCorrection = clampSigned(pitchResidual * correctionWeight, maximum: maximumPitchCorrection)
        return PanoramaPoseAlignment(
            correctedPose: GimbalPose(
                pitchDegrees: currentPose.pitchDegrees + pitchCorrection,
                panDegrees: currentPose.panDegrees + panCorrection,
                monotonicNS: currentPose.monotonicNS
            ),
            confidence: boundedConfidence * consistency,
            panCorrectionDegrees: panCorrection,
            pitchCorrectionDegrees: pitchCorrection,
            residualDegrees: residual,
            accepted: true
        )
    }

    private static func rejected(
        _ pose: GimbalPose,
        confidence: Double,
        residual: Double = 0
    ) -> PanoramaPoseAlignment {
        PanoramaPoseAlignment(
            correctedPose: pose,
            confidence: confidence,
            panCorrectionDegrees: 0,
            pitchCorrectionDegrees: 0,
            residualDegrees: residual,
            accepted: false
        )
    }

    private static func clampSigned(_ value: Double, maximum: Double) -> Double {
        min(max(value, -maximum), maximum)
    }
}

public struct PanoramaBackgroundAdmission: Sendable {
    public let humanHoldNS: UInt64
    private var suppressedUntilNS: UInt64 = 0

    public init(humanHoldNS: UInt64 = 750_000_000) {
        self.humanHoldNS = humanHoldNS
    }

    /// A static place map must not learn an intermittently detected person.
    /// Hold rejection across short detector gaps, then resume automatically
    /// after the scene has been human-free for the bounded interval.
    public mutating func admits(hasObservedHuman: Bool, at monotonicNS: UInt64) -> Bool {
        if hasObservedHuman {
            let (candidate, overflow) = monotonicNS.addingReportingOverflow(humanHoldNS)
            suppressedUntilNS = max(suppressedUntilNS, overflow ? UInt64.max : candidate)
            return false
        }
        return monotonicNS >= suppressedUntilNS
    }
}

public struct PanoramaSourceCoordinate: Equatable, Sendable {
    public let normalizedX: Double
    /// Top-left image coordinates, matching the pixel buffer memory layout.
    public let normalizedY: Double
    public let viewWeight: Double

    public init(normalizedX: Double, normalizedY: Double, viewWeight: Double) {
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.viewWeight = min(max(viewWeight, 0), 1)
    }
}

/// Shared gnomonic projection used by the panorama compositor and its tests.
/// The output bearing is a conventional visual sphere: azimuth increases to
/// the right and elevation increases upward. SDK attitude axes are converted
/// to that canonical frame exactly once before projection. The returned pixel
/// coordinate uses the source buffer's top-left origin.
public enum SphericalPanoramaProjection {
    /// A validated camera view with pose trigonometry prepared once per
    /// frame. Panorama projection is a per-pixel hot path, so repeating model
    /// validation and camera-basis construction for every output pixel can
    /// make the compositor fall behind the capture stream.
    public struct PreparedCameraView: Sendable {
        private let projection: CameraProjectionModel
        private let forwardX: Double
        private let forwardY: Double
        private let forwardZ: Double
        private let rightX: Double
        private let rightZ: Double
        private let upX: Double
        private let upY: Double
        private let upZ: Double

        public init?(
            cameraPose: GimbalPose,
            horizontalFieldOfViewDegrees: Double,
            aspectRatio: Double = 16.0 / 9.0,
            poseProjection: GimbalPoseProjection = .identity,
            cameraProjectionModel: CameraProjectionModel? = nil
        ) {
            let projection = cameraProjectionModel ?? .pinhole(
                horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                aspectRatio: aspectRatio
            )
            guard projection.isValid else { return nil }
            self.projection = projection
            let panImageSign = poseProjection.panImageSign >= 0 ? 1.0 : -1.0
            let pitchImageSign = poseProjection.pitchImageSign >= 0 ? 1.0 : -1.0
            let cameraAzimuth = cameraPose.panDegrees * panImageSign * .pi / 180
            let cameraElevation = cameraPose.pitchDegrees * pitchImageSign * .pi / 180
            forwardX = cos(cameraElevation) * sin(cameraAzimuth)
            forwardY = sin(cameraElevation)
            forwardZ = cos(cameraElevation) * cos(cameraAzimuth)
            rightX = cos(cameraAzimuth)
            rightZ = -sin(cameraAzimuth)
            upX = -sin(cameraElevation) * sin(cameraAzimuth)
            upY = cos(cameraElevation)
            upZ = -sin(cameraElevation) * cos(cameraAzimuth)
        }

        public func sourceCoordinate(
            for worldBearing: GimbalRelativeBearing
        ) -> PanoramaSourceCoordinate? {
            let azimuth = worldBearing.azimuthDegrees * .pi / 180
            let elevation = worldBearing.elevationDegrees * .pi / 180
            let worldX = cos(elevation) * sin(azimuth)
            let worldY = sin(elevation)
            let worldZ = cos(elevation) * cos(azimuth)
            let ideal = (
                worldX * rightX + worldZ * rightZ,
                -(worldX * upX + worldY * upY + worldZ * upZ),
                worldX * forwardX + worldY * forwardY + worldZ * forwardZ
            )
            let camera = projection.idealToActual(ideal)
            guard camera.2 > 0 else { return nil }
            let visionX = projection.principalXNormalized
                + projection.focalXNormalized * camera.0 / camera.2
            let visionY = projection.principalYNormalized
                + projection.focalYNormalized * camera.1 / camera.2
            guard visionX >= 0, visionX < 1, visionY >= 0, visionY < 1 else { return nil }
            let horizontalRadius = max(0.01, min(
                projection.principalXNormalized,
                1 - projection.principalXNormalized
            ))
            let verticalRadius = max(0.01, min(
                projection.principalYNormalized,
                1 - projection.principalYNormalized
            ))
            let horizontalWeight = max(
                0,
                1 - abs(visionX - projection.principalXNormalized) / horizontalRadius
            )
            let verticalWeight = max(
                0,
                1 - abs(visionY - projection.principalYNormalized) / verticalRadius
            )
            return PanoramaSourceCoordinate(
                normalizedX: visionX,
                normalizedY: visionY,
                viewWeight: sqrt(horizontalWeight * verticalWeight)
            )
        }
    }

    public static func outputBearing(
        column: Int,
        row: Int,
        width: Int,
        height: Int,
        minimumElevationDegrees: Double,
        maximumElevationDegrees: Double
    ) -> GimbalRelativeBearing {
        let boundedWidth = max(1, width)
        let boundedHeight = max(1, height)
        let horizontalFraction = (Double(min(max(0, column), boundedWidth - 1)) + 0.5)
            / Double(boundedWidth)
        let verticalFraction = (Double(min(max(0, row), boundedHeight - 1)) + 0.5)
            / Double(boundedHeight)
        let elevationSpan = maximumElevationDegrees - minimumElevationDegrees
        return GimbalRelativeBearing(
            azimuthDegrees: -180 + horizontalFraction * 360,
            elevationDegrees: maximumElevationDegrees - verticalFraction * elevationSpan
        )
    }

    public static func sourceCoordinate(
        for worldBearing: GimbalRelativeBearing,
        cameraPose: GimbalPose,
        horizontalFieldOfViewDegrees: Double,
        aspectRatio: Double = 16.0 / 9.0,
        poseProjection: GimbalPoseProjection = .identity,
        cameraProjectionModel: CameraProjectionModel? = nil
    ) -> PanoramaSourceCoordinate? {
        PreparedCameraView(
            cameraPose: cameraPose,
            horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
            aspectRatio: aspectRatio,
            poseProjection: poseProjection,
            cameraProjectionModel: cameraProjectionModel
        )?.sourceCoordinate(for: worldBearing)
    }

    public static func isDynamicallyMasked(
        sourceCoordinate: PanoramaSourceCoordinate,
        visionRects: [NormalizedRect],
        dilation: Double = 0.03
    ) -> Bool {
        // Vision rectangles use a bottom-left origin while the camera pixel
        // buffer and projection coordinates use a top-left origin.
        let visionY = 1 - sourceCoordinate.normalizedY
        return visionRects.contains { rect in
            let minimumX = max(0, rect.x - dilation)
            let maximumX = min(1, rect.x + rect.width + dilation)
            let minimumY = max(0, rect.y - dilation)
            let maximumY = min(1, rect.y + rect.height + dilation)
            return sourceCoordinate.normalizedX >= minimumX
                && sourceCoordinate.normalizedX <= maximumX
                && visionY >= minimumY
                && visionY <= maximumY
        }
    }

    public static func isReachable(
        _ bearing: GimbalRelativeBearing,
        cameraProjectionModel: CameraProjectionModel,
        poseProjection: GimbalPoseProjection = .identity,
        kinematicEnvelope: GimbalKinematicEnvelope = .obsbotTiny2Lite
    ) -> Bool {
        let panSign = poseProjection.panImageSign >= 0 ? 1.0 : -1.0
        let pitchSign = poseProjection.pitchImageSign >= 0 ? 1.0 : -1.0
        let pose = GimbalPose(
            pitchDegrees: min(
                max(
                    bearing.elevationDegrees * pitchSign,
                    -kinematicEnvelope.maximumAutonomousPitchDegrees
                ),
                kinematicEnvelope.maximumAutonomousPitchDegrees
            ),
            panDegrees: min(
                max(
                    bearing.azimuthDegrees * panSign,
                    -kinematicEnvelope.maximumAutonomousPanDegrees
                ),
                kinematicEnvelope.maximumAutonomousPanDegrees
            ),
            monotonicNS: 0
        )
        return sourceCoordinate(
            for: bearing,
            cameraPose: pose,
            horizontalFieldOfViewDegrees: cameraProjectionModel.horizontalFieldOfViewDegrees,
            poseProjection: poseProjection,
            cameraProjectionModel: cameraProjectionModel
        ) != nil
    }

}

public struct PanoramaMapStatus: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let state: String
    public let imagePath: String
    public let metadataPath: String
    public let width: Int
    public let height: Int
    public let minimumElevationDegrees: Double
    public let maximumElevationDegrees: Double
    public let azimuthIncreasesLeftToRight: Bool
    public let elevationIncreasesBottomToTop: Bool
    public let revision: UInt64
    public let acceptedFrames: UInt64
    public let lowQualityRejectedFrames: UInt64
    public let poseInterpolationMisses: UInt64
    public let poseMissReasons: [String: UInt64]
    public let dynamicallyMaskedPixels: UInt64
    public let coverageFraction: Double
    public let qualityCoverageFraction: Double
    public let reachablePixelFraction: Double
    public let reachableCoverageFraction: Double
    public let reachableQualityCoverageFraction: Double
    public let meanObservationQuality: Double
    public let qualityProtectedPixels: UInt64
    public let alignmentAttempts: UInt64
    public let alignmentAccepted: UInt64
    public let alignmentRejected: UInt64
    public let averageAlignmentMilliseconds: Double
    public let maximumAlignmentMilliseconds: Double
    public let meanAlignmentConfidence: Double
    public let meanAlignmentCorrectionDegrees: Double
    public let stitchBlendAttempts: UInt64
    public let stitchPhotometricCompensations: UInt64
    public let averageStitchBlendMilliseconds: Double
    public let maximumStitchBlendMilliseconds: Double
    public let meanStitchRedGain: Double
    public let meanStitchGreenGain: Double
    public let meanStitchBlueGain: Double
    public let placeObservations: UInt64
    public let placeRevisits: UInt64
    public let meanPlaceFamiliarity: Double
    public let placeEmbeddingEncoder: String
    public let placeEmbeddingRevision: Int
    public let placeEmbeddingAttempts: UInt64
    public let placeEmbeddingFailures: UInt64
    public let averagePlaceEmbeddingMilliseconds: Double
    public let maximumPlaceEmbeddingMilliseconds: Double
    public let lastUpdatedNS: UInt64?

    public init(
        state: String,
        imagePath: String,
        metadataPath: String,
        width: Int,
        height: Int,
        minimumElevationDegrees: Double,
        maximumElevationDegrees: Double,
        azimuthIncreasesLeftToRight: Bool = true,
        elevationIncreasesBottomToTop: Bool = true,
        revision: UInt64,
        acceptedFrames: UInt64,
        lowQualityRejectedFrames: UInt64 = 0,
        poseInterpolationMisses: UInt64,
        poseMissReasons: [String: UInt64] = [:],
        dynamicallyMaskedPixels: UInt64,
        coverageFraction: Double,
        qualityCoverageFraction: Double = 0,
        reachablePixelFraction: Double = 0,
        reachableCoverageFraction: Double = 0,
        reachableQualityCoverageFraction: Double = 0,
        meanObservationQuality: Double = 0,
        qualityProtectedPixels: UInt64 = 0,
        alignmentAttempts: UInt64 = 0,
        alignmentAccepted: UInt64 = 0,
        alignmentRejected: UInt64 = 0,
        averageAlignmentMilliseconds: Double = 0,
        maximumAlignmentMilliseconds: Double = 0,
        meanAlignmentConfidence: Double = 0,
        meanAlignmentCorrectionDegrees: Double = 0,
        stitchBlendAttempts: UInt64 = 0,
        stitchPhotometricCompensations: UInt64 = 0,
        averageStitchBlendMilliseconds: Double = 0,
        maximumStitchBlendMilliseconds: Double = 0,
        meanStitchRedGain: Double = 1,
        meanStitchGreenGain: Double = 1,
        meanStitchBlueGain: Double = 1,
        placeObservations: UInt64 = 0,
        placeRevisits: UInt64 = 0,
        meanPlaceFamiliarity: Double = 0,
        placeEmbeddingEncoder: String = "none",
        placeEmbeddingRevision: Int = 0,
        placeEmbeddingAttempts: UInt64 = 0,
        placeEmbeddingFailures: UInt64 = 0,
        averagePlaceEmbeddingMilliseconds: Double = 0,
        maximumPlaceEmbeddingMilliseconds: Double = 0,
        lastUpdatedNS: UInt64?
    ) {
        schemaVersion = 7
        self.state = String(state.prefix(48))
        self.imagePath = imagePath
        self.metadataPath = metadataPath
        self.width = max(1, width)
        self.height = max(1, height)
        self.minimumElevationDegrees = minimumElevationDegrees
        self.maximumElevationDegrees = maximumElevationDegrees
        self.azimuthIncreasesLeftToRight = azimuthIncreasesLeftToRight
        self.elevationIncreasesBottomToTop = elevationIncreasesBottomToTop
        self.revision = revision
        self.acceptedFrames = acceptedFrames
        self.lowQualityRejectedFrames = lowQualityRejectedFrames
        self.poseInterpolationMisses = poseInterpolationMisses
        self.poseMissReasons = poseMissReasons
        self.dynamicallyMaskedPixels = dynamicallyMaskedPixels
        self.coverageFraction = min(max(coverageFraction, 0), 1)
        self.qualityCoverageFraction = min(max(qualityCoverageFraction, 0), 1)
        self.reachablePixelFraction = min(max(reachablePixelFraction, 0), 1)
        self.reachableCoverageFraction = min(max(reachableCoverageFraction, 0), 1)
        self.reachableQualityCoverageFraction = min(
            max(reachableQualityCoverageFraction, 0),
            1
        )
        self.meanObservationQuality = min(max(meanObservationQuality, 0), 1)
        self.qualityProtectedPixels = qualityProtectedPixels
        self.alignmentAttempts = alignmentAttempts
        self.alignmentAccepted = alignmentAccepted
        self.alignmentRejected = alignmentRejected
        self.averageAlignmentMilliseconds = max(0, averageAlignmentMilliseconds)
        self.maximumAlignmentMilliseconds = max(0, maximumAlignmentMilliseconds)
        self.meanAlignmentConfidence = min(max(meanAlignmentConfidence, 0), 1)
        self.meanAlignmentCorrectionDegrees = max(0, meanAlignmentCorrectionDegrees)
        self.stitchBlendAttempts = stitchBlendAttempts
        self.stitchPhotometricCompensations = min(
            stitchPhotometricCompensations,
            stitchBlendAttempts
        )
        self.averageStitchBlendMilliseconds = max(0, averageStitchBlendMilliseconds)
        self.maximumStitchBlendMilliseconds = max(0, maximumStitchBlendMilliseconds)
        self.meanStitchRedGain = min(max(meanStitchRedGain, 0), 2)
        self.meanStitchGreenGain = min(max(meanStitchGreenGain, 0), 2)
        self.meanStitchBlueGain = min(max(meanStitchBlueGain, 0), 2)
        self.placeObservations = placeObservations
        self.placeRevisits = placeRevisits
        self.meanPlaceFamiliarity = min(max(meanPlaceFamiliarity, 0), 1)
        self.placeEmbeddingEncoder = String(placeEmbeddingEncoder.prefix(64))
        self.placeEmbeddingRevision = max(0, placeEmbeddingRevision)
        self.placeEmbeddingAttempts = placeEmbeddingAttempts
        self.placeEmbeddingFailures = min(placeEmbeddingFailures, placeEmbeddingAttempts)
        self.averagePlaceEmbeddingMilliseconds = max(0, averagePlaceEmbeddingMilliseconds)
        self.maximumPlaceEmbeddingMilliseconds = max(0, maximumPlaceEmbeddingMilliseconds)
        self.lastUpdatedNS = lastUpdatedNS
    }
}

public final class PanoramaMapStatusStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PanoramaMapStatus?

    public init() {}

    public func update(_ value: PanoramaMapStatus) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    public func snapshot() -> PanoramaMapStatus? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
