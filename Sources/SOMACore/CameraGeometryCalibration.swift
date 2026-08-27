import Foundation

/// A normalized pinhole model plus the rigid camera-to-gimbal rotation.
/// Intrinsics are normalized by the active image width/height, so the same
/// calibration remains valid across resolutions with the same optical crop.
public struct CameraProjectionModel: Codable, Equatable, Sendable {
    public let focalXNormalized: Double
    public let focalYNormalized: Double
    public let principalXNormalized: Double
    public let principalYNormalized: Double
    /// Row-major rotation mapping an actual camera ray into the ideal camera
    /// frame implied by the SDK yaw/pitch axes.
    public let cameraToIdealRotation: [Double]
    /// Brown-Conrady radial terms in normalized camera coordinates. Optional
    /// preserves compatibility with schema-1 pinhole calibrations.
    public let radialK1: Double?
    public let radialK2: Double?

    public init(
        focalXNormalized: Double,
        focalYNormalized: Double,
        principalXNormalized: Double = 0.5,
        principalYNormalized: Double = 0.5,
        cameraToIdealRotation: [Double] = [
            1, 0, 0,
            0, 1, 0,
            0, 0, 1,
        ],
        radialK1: Double = 0,
        radialK2: Double = 0
    ) {
        self.focalXNormalized = focalXNormalized
        self.focalYNormalized = focalYNormalized
        self.principalXNormalized = principalXNormalized
        self.principalYNormalized = principalYNormalized
        self.cameraToIdealRotation = cameraToIdealRotation
        self.radialK1 = radialK1
        self.radialK2 = radialK2
    }

    public static func pinhole(
        horizontalFieldOfViewDegrees: Double,
        aspectRatio: Double = 16.0 / 9.0
    ) -> CameraProjectionModel {
        let horizontalHalf = min(max(horizontalFieldOfViewDegrees, 1), 170) * .pi / 360
        let focalX = 0.5 / tan(horizontalHalf)
        return CameraProjectionModel(
            focalXNormalized: focalX,
            focalYNormalized: focalX * max(aspectRatio, 0.1)
        )
    }

    public var horizontalFieldOfViewDegrees: Double {
        (atan(principalXNormalized / focalXNormalized)
            + atan((1 - principalXNormalized) / focalXNormalized)) * 180 / .pi
    }

    public var verticalFieldOfViewDegrees: Double {
        (atan(principalYNormalized / focalYNormalized)
            + atan((1 - principalYNormalized) / focalYNormalized)) * 180 / .pi
    }

    /// Models the camera's centered digital/optical crop in the same
    /// normalized-image coordinate system.  Scaling focal length keeps the
    /// calibrated principal point, lens distortion, and camera-to-gimbal
    /// extrinsics intact while narrowing the visual ray field.
    public func withOpticalZoom(_ factor: Double) -> CameraProjectionModel? {
        guard factor.isFinite, factor >= 1, factor <= 2 else { return nil }
        let zoomed = CameraProjectionModel(
            focalXNormalized: focalXNormalized * factor,
            focalYNormalized: focalYNormalized * factor,
            principalXNormalized: principalXNormalized,
            principalYNormalized: principalYNormalized,
            cameraToIdealRotation: cameraToIdealRotation,
            radialK1: radialK1 ?? 0,
            radialK2: radialK2 ?? 0
        )
        return zoomed.isValid ? zoomed : nil
    }

    public var isValid: Bool {
        guard focalXNormalized.isFinite,
              focalYNormalized.isFinite,
              principalXNormalized.isFinite,
              principalYNormalized.isFinite,
              (radialK1 ?? 0).isFinite,
              (radialK2 ?? 0).isFinite,
              focalXNormalized >= 0.35, focalXNormalized <= 1.5,
              focalYNormalized >= 0.6, focalYNormalized <= 2.5,
              principalXNormalized >= 0.40, principalXNormalized <= 0.60,
              principalYNormalized >= 0.40, principalYNormalized <= 0.60,
              abs(radialK1 ?? 0) <= 0.8,
              abs(radialK2 ?? 0) <= 0.8,
              cameraToIdealRotation.count == 9 else {
            return false
        }
        let r = cameraToIdealRotation
        guard r[0].isFinite, r[1].isFinite, r[2].isFinite,
              r[3].isFinite, r[4].isFinite, r[5].isFinite,
              r[6].isFinite, r[7].isFinite, r[8].isFinite else {
            return false
        }
        let row0Length = r[0] * r[0] + r[1] * r[1] + r[2] * r[2]
        let row1Length = r[3] * r[3] + r[4] * r[4] + r[5] * r[5]
        let row2Length = r[6] * r[6] + r[7] * r[7] + r[8] * r[8]
        let row01 = r[0] * r[3] + r[1] * r[4] + r[2] * r[5]
        let row02 = r[0] * r[6] + r[1] * r[7] + r[2] * r[8]
        let row12 = r[3] * r[6] + r[4] * r[7] + r[5] * r[8]
        let determinant = r[0] * (r[4] * r[8] - r[5] * r[7])
            - r[1] * (r[3] * r[8] - r[5] * r[6])
            + r[2] * (r[3] * r[7] - r[4] * r[6])
        return abs(row0Length - 1) <= 0.02
            && abs(row1Length - 1) <= 0.02
            && abs(row2Length - 1) <= 0.02
            && abs(row01) <= 0.02
            && abs(row02) <= 0.02
            && abs(row12) <= 0.02
            && abs(determinant - 1) <= 0.02
    }

    public func actualToIdeal(_ vector: (Double, Double, Double)) -> (Double, Double, Double) {
        guard abs(vector.2) > 1e-9 else { return vector }
        let distortedX = vector.0 / vector.2
        let distortedY = vector.1 / vector.2
        var undistortedX = distortedX
        var undistortedY = distortedY
        for _ in 0..<8 {
            let radius2 = undistortedX * undistortedX + undistortedY * undistortedY
            let radial = 1 + (radialK1 ?? 0) * radius2 + (radialK2 ?? 0) * radius2 * radius2
            guard abs(radial) > 0.25 else { break }
            undistortedX = distortedX / radial
            undistortedY = distortedY / radial
        }
        let r = cameraToIdealRotation
        let undistorted = (
            undistortedX * vector.2,
            undistortedY * vector.2,
            vector.2
        )
        return (
            r[0] * undistorted.0 + r[1] * undistorted.1 + r[2] * undistorted.2,
            r[3] * undistorted.0 + r[4] * undistorted.1 + r[5] * undistorted.2,
            r[6] * undistorted.0 + r[7] * undistorted.1 + r[8] * undistorted.2
        )
    }

    public func idealToActual(_ vector: (Double, Double, Double)) -> (Double, Double, Double) {
        let r = cameraToIdealRotation
        let undistorted = (
            r[0] * vector.0 + r[3] * vector.1 + r[6] * vector.2,
            r[1] * vector.0 + r[4] * vector.1 + r[7] * vector.2,
            r[2] * vector.0 + r[5] * vector.1 + r[8] * vector.2
        )
        guard abs(undistorted.2) > 1e-9 else { return undistorted }
        let x = undistorted.0 / undistorted.2
        let y = undistorted.1 / undistorted.2
        let radius2 = x * x + y * y
        let radial = 1 + (radialK1 ?? 0) * radius2 + (radialK2 ?? 0) * radius2 * radius2
        return (x * radial * undistorted.2, y * radial * undistorted.2, undistorted.2)
    }

    /// Returns the camera attitude that places a world-fixed target at the
    /// requested Vision-normalized composition point. The target and result
    /// remain in the gimbal's reported coordinate system; the image-axis
    /// convention is applied exactly once through `poseProjection`.
    public func cameraBearing(
        placing target: GimbalRelativeBearing,
        at framing: NormalizedRect,
        poseProjection: GimbalPoseProjection
    ) -> GimbalRelativeBearing? {
        guard isValid,
              framing.x.isFinite, framing.y.isFinite,
              framing.width.isFinite, framing.height.isFinite,
              framing.x >= 0, framing.y >= 0,
              framing.width > 0, framing.height > 0,
              framing.x + framing.width <= 1,
              framing.y + framing.height <= 1 else {
            return nil
        }
        let actualRay = (
            (framing.centerX - principalXNormalized) / focalXNormalized,
            ((1 - framing.centerY) - principalYNormalized) / focalYNormalized,
            1.0
        )
        let idealRay = actualToIdeal(actualRay)
        guard idealRay.2.isFinite, idealRay.2 > 0 else { return nil }
        let panOffset = atan2(idealRay.0, idealRay.2) * 180 / .pi
        // The runtime normalizes all detections to a top-left image origin.
        // Positive ideal y is an upward visual ray, so placing a fixed target
        // there requires a lower camera elevation.
        let elevationOffset = -atan2(idealRay.1, hypot(idealRay.0, idealRay.2)) * 180 / .pi
        let panSign = poseProjection.panImageSign >= 0 ? 1.0 : -1.0
        let pitchSign = poseProjection.pitchImageSign >= 0 ? 1.0 : -1.0
        return GimbalRelativeBearing(
            azimuthDegrees: target.azimuthDegrees + panSign * panOffset,
            elevationDegrees: target.elevationDegrees + pitchSign * elevationOffset
        )
    }
}

public struct CameraGeometryCalibration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceProfile: String
    public let fovMode: Int
    public let imageWidth: Int
    public let imageHeight: Int
    public let projection: CameraProjectionModel
    public let capturedFrames: Int
    public let fittedPairs: Int
    public let fittedMatches: Int
    public let validationPairs: Int
    public let validationMatches: Int
    public let initialRMSEPixels: Double
    public let calibratedRMSEPixels: Double
    public let calibratedP90Pixels: Double
    public let generatedAt: String

    public init(
        schemaVersion: Int = 1,
        deviceProfile: String,
        fovMode: Int,
        imageWidth: Int,
        imageHeight: Int,
        projection: CameraProjectionModel,
        capturedFrames: Int,
        fittedPairs: Int,
        fittedMatches: Int,
        validationPairs: Int,
        validationMatches: Int,
        initialRMSEPixels: Double,
        calibratedRMSEPixels: Double,
        calibratedP90Pixels: Double,
        generatedAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.deviceProfile = deviceProfile
        self.fovMode = fovMode
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.projection = projection
        self.capturedFrames = capturedFrames
        self.fittedPairs = fittedPairs
        self.fittedMatches = fittedMatches
        self.validationPairs = validationPairs
        self.validationMatches = validationMatches
        self.initialRMSEPixels = initialRMSEPixels
        self.calibratedRMSEPixels = calibratedRMSEPixels
        self.calibratedP90Pixels = calibratedP90Pixels
        self.generatedAt = generatedAt
    }

    public var isValid: Bool {
        schemaVersion == 1
            && resolvedDeviceProfile != nil
            && [65, 78, 86].contains(fovMode)
            && imageWidth >= 640 && imageHeight >= 360
            && projection.isValid
            && capturedFrames >= 8
            && fittedPairs >= 6
            && fittedMatches >= 120
            && validationPairs >= 3
            && validationMatches >= 72
            && initialRMSEPixels.isFinite
            && calibratedRMSEPixels.isFinite
            && calibratedP90Pixels.isFinite
            && calibratedRMSEPixels > 0
            && calibratedRMSEPixels < initialRMSEPixels
            && calibratedRMSEPixels <= initialRMSEPixels * 0.8
            && calibratedP90Pixels <= 12
    }

    public var resolvedDeviceProfile: OBSBOTDeviceProfile? {
        switch deviceProfile {
        case "obsbot_tiny_2_lite": .tiny2Lite
        case "obsbot_tiny_3_lite": .tiny3Lite
        default: OBSBOTDeviceProfile(rawValue: deviceProfile)
        }
    }

    public func applies(to profile: OBSBOTDeviceProfile) -> Bool {
        resolvedDeviceProfile == profile
    }
}
