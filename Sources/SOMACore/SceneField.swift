import Foundation

public enum CameraFieldOfView {
    /// Converts a physical diagonal field of view to the horizontal field of
    /// view required by projection, tracking boundaries, and spherical coverage.
    /// Device-specific mode labels must first be resolved to physical optics.
    public static func horizontalDegrees(
        diagonalDegrees: Double,
        aspectRatio: Double
    ) -> Double? {
        guard diagonalDegrees.isFinite,
              diagonalDegrees > 0,
              diagonalDegrees < 180,
              aspectRatio.isFinite,
              aspectRatio > 0 else { return nil }
        let diagonalHalf = diagonalDegrees * .pi / 360
        let tangentScale = sqrt(1 + 1 / (aspectRatio * aspectRatio))
        return atan(tan(diagonalHalf) / tangentScale) * 360 / .pi
    }

    public static func verticalDegrees(
        diagonalDegrees: Double,
        aspectRatio: Double
    ) -> Double? {
        guard let horizontal = horizontalDegrees(
            diagonalDegrees: diagonalDegrees,
            aspectRatio: aspectRatio
        ) else { return nil }
        return atan(tan(horizontal * .pi / 360) / aspectRatio) * 360 / .pi
    }
}

public enum OBSBOTTiny2LiteOptics {
    public static let wideHorizontalDegrees = 67.2
    public static let nominalWideModeDegrees = 86.0

    /// libdev exposes generic 86/78/65 mode names, while Tiny 2 Lite's optical
    /// specification gives the wide horizontal angle as 67.2 degrees. Preserve
    /// the generic modes' tangent-space crop ratios without treating their
    /// labels as this camera's physical angles.
    public static func horizontalDegrees(forFOVMode modeDegrees: Double) -> Double? {
        guard [65.0, 78.0, 86.0].contains(modeDegrees) else { return nil }
        let nominalRatio = tan(modeDegrees * .pi / 360)
            / tan(nominalWideModeDegrees * .pi / 360)
        return atan(tan(wideHorizontalDegrees * .pi / 360) * nominalRatio) * 360 / .pi
    }
}

public enum OBSBOTTiny3LiteOptics {
    public static let wideHorizontalDegrees = 72.0

    public static func horizontalDegrees(forFOVMode modeDegrees: Double) -> Double? {
        OBSBOTDeviceProfile.tiny3Lite.horizontalFieldOfViewDegrees(forSDKMode: modeDegrees)
    }
}

/// A gimbal-relative direction, in degrees, anchored at the camera's home
/// orientation rather than at a geographic reference frame.
public struct GimbalRelativeBearing: Codable, Equatable, Sendable {
    public let azimuthDegrees: Double
    public let elevationDegrees: Double

    public init(azimuthDegrees: Double, elevationDegrees: Double) {
        self.azimuthDegrees = Self.normalizeAzimuth(azimuthDegrees)
        self.elevationDegrees = min(max(elevationDegrees, -90), 90)
    }

    private static func normalizeAzimuth(_ value: Double) -> Double {
        var normalized = value.truncatingRemainder(dividingBy: 360)
        if normalized > 180 { normalized -= 360 }
        if normalized <= -180 { normalized += 360 }
        return normalized
    }
}

/// A measured physical Tiny 2 Lite attitude, in the SDK's pitch/pan axes.
public struct GimbalPose: Codable, Equatable, Sendable {
    public let pitchDegrees: Double
    public let panDegrees: Double
    public let monotonicNS: UInt64

    public init(pitchDegrees: Double, panDegrees: Double, monotonicNS: UInt64) {
        self.pitchDegrees = pitchDegrees
        self.panDegrees = panDegrees
        self.monotonicNS = monotonicNS
    }

    public func isFresh(for timestampNS: UInt64, maximumAgeNS: UInt64) -> Bool {
        timestampNS >= monotonicNS && timestampNS - monotonicNS <= maximumAgeNS
    }
}

/// One source of truth for the camera's finite joint space.  Scene evidence
/// may exist outside the autonomous centre envelope when it is visible near a
/// frame edge, but every planned camera centre must remain inside that
/// envelope.  The wider tracking envelope is reserved for live visual servo
/// corrections and never used to generate exploratory waypoints.
public struct GimbalKinematicEnvelope: Codable, Equatable, Sendable {
    public let maximumTrackingPanDegrees: Double
    public let maximumTrackingPitchDegrees: Double
    public let maximumAutonomousPanDegrees: Double
    public let maximumAutonomousPitchDegrees: Double

    public init(
        maximumTrackingPanDegrees: Double,
        maximumTrackingPitchDegrees: Double,
        maximumAutonomousPanDegrees: Double,
        maximumAutonomousPitchDegrees: Double
    ) {
        self.maximumTrackingPanDegrees = abs(maximumTrackingPanDegrees)
        self.maximumTrackingPitchDegrees = abs(maximumTrackingPitchDegrees)
        self.maximumAutonomousPanDegrees = min(
            abs(maximumAutonomousPanDegrees),
            self.maximumTrackingPanDegrees
        )
        self.maximumAutonomousPitchDegrees = min(
            abs(maximumAutonomousPitchDegrees),
            self.maximumTrackingPitchDegrees
        )
    }

    public static let obsbotTiny2Lite = GimbalKinematicEnvelope(
        maximumTrackingPanDegrees: 126,
        maximumTrackingPitchDegrees: 34,
        maximumAutonomousPanDegrees: 110,
        maximumAutonomousPitchDegrees: 24
    )

    /// Tiny 3 Lite's controllable tilt is asymmetric (-60°...32°). Keep the
    /// autonomous envelope inside the common central range until a route has
    /// a measured product-specific calibration.
    public static let obsbotTiny3Lite = GimbalKinematicEnvelope(
        maximumTrackingPanDegrees: 126,
        maximumTrackingPitchDegrees: 28,
        maximumAutonomousPanDegrees: 110,
        maximumAutonomousPitchDegrees: 20
    )

    public func containsTrackingCenter(_ bearing: GimbalRelativeBearing) -> Bool {
        abs(bearing.azimuthDegrees) <= maximumTrackingPanDegrees
            && abs(bearing.elevationDegrees) <= maximumTrackingPitchDegrees
    }

    public func containsAutonomousCenter(_ bearing: GimbalRelativeBearing) -> Bool {
        abs(bearing.azimuthDegrees) <= maximumAutonomousPanDegrees
            && abs(bearing.elevationDegrees) <= maximumAutonomousPitchDegrees
    }
}

/// Maps image offsets into the SDK attitude coordinates. This is separate
/// from a velocity-command calibration: a positive SDK speed need not increase
/// the SDK-reported angle on the same axis.
public struct GimbalPoseProjection: Sendable {
    public let panImageSign: Double
    public let pitchImageSign: Double

    public init(panImageSign: Double, pitchImageSign: Double) {
        self.panImageSign = panImageSign
        self.pitchImageSign = pitchImageSign
    }

    public static let identity = GimbalPoseProjection(panImageSign: 1, pitchImageSign: 1)
    public static let obsbotTiny2Lite = GimbalPoseProjection(panImageSign: -1, pitchImageSign: -1)
}

/// The image-space motor envelope for one physical gimbal attitude. Detections
/// outside it remain scene evidence, but cannot ask the camera to turn farther
/// toward a frame edge or a known joint limit.
public struct TrackingBoundary: Equatable, Sendable {
    public let isPoseAligned: Bool
    public let minimumCenterX: Double
    public let maximumCenterX: Double
    public let minimumCenterY: Double
    public let maximumCenterY: Double
    private let physicalMinimumCenterX: Double
    private let physicalMaximumCenterX: Double
    private let physicalMinimumCenterY: Double
    private let physicalMaximumCenterY: Double

    public init(
        cameraPose: GimbalPose?,
        horizontalFieldOfViewDegrees: Double = 70,
        aspectRatio: Double = 16.0 / 9.0,
        kinematicEnvelope: GimbalKinematicEnvelope = .obsbotTiny2Lite
    ) {
        let baseMinimumX = 0.18
        let baseMaximumX = 0.82
        let baseMinimumY = 0.20
        let baseMaximumY = 0.80
        guard let cameraPose else {
            isPoseAligned = false
            minimumCenterX = baseMinimumX
            maximumCenterX = baseMaximumX
            minimumCenterY = baseMinimumY
            maximumCenterY = baseMaximumY
            physicalMinimumCenterX = baseMinimumX
            physicalMaximumCenterX = baseMaximumX
            physicalMinimumCenterY = baseMinimumY
            physicalMaximumCenterY = baseMaximumY
            return
        }
        isPoseAligned = true

        let horizontalHalfRadians = max(1, min(horizontalFieldOfViewDegrees, 170)) * .pi / 360
        let verticalHalfRadians = atan(tan(horizontalHalfRadians) / max(aspectRatio, 0.1))
        let horizontalHalfDegrees = horizontalHalfRadians * 180 / .pi
        let verticalHalfDegrees = verticalHalfRadians * 180 / .pi
        func imageCenter(forHorizontalOffset degrees: Double) -> Double {
            if degrees <= -horizontalHalfDegrees { return -.infinity }
            if degrees >= horizontalHalfDegrees { return .infinity }
            return 0.5 + tan(degrees * .pi / 180) / (2 * tan(horizontalHalfRadians))
        }
        func imageCenter(forVerticalOffset degrees: Double) -> Double {
            if degrees <= -verticalHalfDegrees { return -.infinity }
            if degrees >= verticalHalfDegrees { return .infinity }
            return 0.5 + tan(degrees * .pi / 180) / (2 * tan(verticalHalfRadians))
        }

        physicalMinimumCenterX = imageCenter(
            forHorizontalOffset: -kinematicEnvelope.maximumTrackingPanDegrees - cameraPose.panDegrees
        )
        physicalMaximumCenterX = imageCenter(
            forHorizontalOffset: kinematicEnvelope.maximumTrackingPanDegrees - cameraPose.panDegrees
        )
        physicalMinimumCenterY = imageCenter(
            forVerticalOffset: -kinematicEnvelope.maximumTrackingPitchDegrees - cameraPose.pitchDegrees
        )
        physicalMaximumCenterY = imageCenter(
            forVerticalOffset: kinematicEnvelope.maximumTrackingPitchDegrees - cameraPose.pitchDegrees
        )
        minimumCenterX = max(baseMinimumX, physicalMinimumCenterX)
        maximumCenterX = min(baseMaximumX, physicalMaximumCenterX)
        minimumCenterY = max(baseMinimumY, physicalMinimumCenterY)
        maximumCenterY = min(baseMaximumY, physicalMaximumCenterY)
    }

    public func contains(_ rect: NormalizedRect) -> Bool {
        minimumCenterX <= maximumCenterX
            && minimumCenterY <= maximumCenterY
            && rect.centerX >= minimumCenterX
            && rect.centerX <= maximumCenterX
            && rect.centerY >= minimumCenterY
            && rect.centerY <= maximumCenterY
    }

    public func allowsMotorTarget(_ rect: NormalizedRect) -> Bool {
        isPoseAligned && contains(rect)
    }

    /// A freshly confirmed face near the conservative framing boundary can
    /// receive a short re-entry correction. Objects keep the strict envelope;
    /// the face path never crosses the attitude-derived physical joint range.
    public func allowsFaceReentry(_ rect: NormalizedRect) -> Bool {
        guard isPoseAligned,
              physicalMinimumCenterX <= physicalMaximumCenterX,
              physicalMinimumCenterY <= physicalMaximumCenterY else {
            return false
        }
        let minimumX = max(0.08, physicalMinimumCenterX)
        let maximumX = min(0.92, physicalMaximumCenterX)
        let minimumY = max(0.08, physicalMinimumCenterY)
        let maximumY = min(0.94, physicalMaximumCenterY)
        return minimumX <= maximumX
            && minimumY <= maximumY
            && rect.centerX >= minimumX
            && rect.centerX <= maximumX
            && rect.centerY >= minimumY
            && rect.centerY <= maximumY
    }

    /// The social fovea in the runtime's top-left image coordinate system. A
    /// seated face normally appears high in the camera image (small y);
    /// desk/floor texture appears low (large y).
    public static func allowsFaceLockAcquisition(_ rect: NormalizedRect) -> Bool {
        rect.centerX >= 0.22 && rect.centerX <= 0.78
            && rect.centerY >= 0.08 && rect.centerY <= 0.92
    }

}

/// A persistent local scene candidate. It records detector evidence without
/// asserting that a class label is true in the outside world.
public struct SceneCandidate: Sendable {
    public let id: String
    public let observation: VisualObservation
    public let observedThisFrame: Bool
    public let observationCount: Int
    public let stabilityMilliseconds: Double
    public let sourceCount: Int
    public let isActionEligible: Bool
    /// A face-activity observation may acquire a new L0 face lock. Once a
    /// lock exists, its fresh face frames remain motor-eligible even when the
    /// person becomes still; activity is an acquisition filter, not a lease.
    public let faceActivityEligible: Bool
    /// Current System Vision validation that can promote a provisional face
    /// lock without waiting for a deliberate movement.
    public let faceVerificationEligible: Bool
    /// Current interaction liveness for a verified face. Independent face
    /// geometry may own motor tracking, but it cannot by itself authorize eye
    /// contact or a new spoken interaction because static faces and displays
    /// can satisfy landmark detection. Two coherent world-space motion samples
    /// establish this state, which persists while the face remains continuously
    /// observed.
    public let faceInteractionLivenessEligible: Bool
    /// Current directed-contact evidence. It never persists as motor authority
    /// and is consumed only while this candidate is observed in the frame.
    public let eyeContactEligible: Bool
    public let trackingBoundary: TrackingBoundary
    /// The unsmoothed bearing from this completed camera frame. Persistent
    /// scene bearings are intentionally filtered for map continuity, while the
    /// motor servo needs the current measurement to react to rapid movement.
    public let observedBearing: GimbalRelativeBearing?
    public let bearing: GimbalRelativeBearing?
    public let spatialConfidence: Double
    public let lastSeenMilliseconds: Double

    public func attentionObservation() -> VisualObservation {
        VisualObservation(
            rect: observation.rect,
            confidence: observation.confidence,
            source: observation.source,
            kind: observation.kind,
            label: observation.label,
            attentionWeight: observation.attentionWeight,
            posteriorProbability: observation.posteriorProbability,
            sceneID: id,
            stabilityMilliseconds: stabilityMilliseconds,
            isActionEligible: isActionEligible,
            isFaceVerified: faceVerificationEligible,
            isEyeContactEligible: eyeContactEligible,
            gazeEvidence: observation.gazeEvidence
        )
    }
}

/// Keeps all contemporaneous visual hypotheses alive independently of which
/// one attention currently selects. A detector label is evidence, not identity.
public struct SceneField: Sendable {
    private struct FaceMotionSample: Sendable {
        let azimuthDelta: Double
        let elevationDelta: Double
        let monotonicNS: UInt64
    }

    private struct Track: Sendable {
        var id: String
        var rect: NormalizedRect
        var confidence: Double
        var source: VisualObservationSource
        var kind: AttentionTargetKind
        var label: String?
        var attentionWeight: Double
        var faceMotorEvidence: Bool
        var faceVerified: Bool
        var eyeContactEligible: Bool
        var gazeEvidence: VisualGazeEvidence
        var firstSeenNS: UInt64
        var lastSeenNS: UInt64
        var observationCount: Int
        var sources: Set<VisualObservationSource>
        var observedThisFrame: Bool
        var observedBearing: GimbalRelativeBearing?
        var bearing: GimbalRelativeBearing?
        var trackingBoundary: TrackingBoundary
        var lastFaceActivityNS: UInt64?
        var pendingFaceMotion: FaceMotionSample?
        var faceInteractionLivenessValidated: Bool
    }

    private var tracks: [Track] = []
    private var nextID = 1
    private let requiresFaceActivity: Bool
    private let faceActivityLeaseNS: UInt64 = 1_500_000_000
    private let faceInteractionContinuityNS: UInt64 = 750_000_000
    private let unverifiedFaceTrackGapNS: UInt64 = 250_000_000

    public init(requiresFaceActivity: Bool = false) {
        self.requiresFaceActivity = requiresFaceActivity
    }

    /// Removes a face-shaped track that exhausted its independent-verification
    /// window. Session spatial memory still retains real, verified faces and
    /// every non-face object; only this explicitly rejected false hypothesis
    /// is discarded.
    public mutating func invalidateUnverifiedFaceTracks(matching rects: [NormalizedRect]) {
        guard !rects.isEmpty else { return }
        tracks.removeAll { track in
            guard track.kind == .human,
                  track.label == "face",
                  !track.faceVerified else {
                return false
            }
            return rects.contains { rect in
                let centreDistance = hypot(
                    track.rect.centerX - rect.centerX,
                    track.rect.centerY - rect.centerY
                )
                let areaRatio = (rect.width * rect.height)
                    / max(track.rect.width * track.rect.height, 0.000_001)
                return centreDistance <= 0.20 && areaRatio >= 0.35 && areaRatio <= 2.8
            }
        }
    }

    public mutating func ingest(
        _ observations: [VisualObservation],
        at monotonicNS: UInt64,
        cameraPose: GimbalPose? = nil,
        horizontalFieldOfViewDegrees: Double = 70,
        aspectRatio: Double = 16.0 / 9.0,
        cameraSettled: Bool = false,
        poseProjection: GimbalPoseProjection = .identity,
        cameraProjectionModel: CameraProjectionModel? = nil
    ) -> [SceneCandidate] {
        for index in tracks.indices {
            tracks[index].observedThisFrame = false
            tracks[index].observedBearing = nil
        }
        var claimedSources: [Int: Set<VisualObservationSource>] = [:]
        let trackingBoundary = TrackingBoundary(
            cameraPose: cameraPose,
            horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
            aspectRatio: aspectRatio
        )

        for observation in observations {
            let bearing = cameraPose.map {
                self.bearing(
                    for: observation.rect,
                    cameraPose: $0,
                    horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                    aspectRatio: aspectRatio,
                    poseProjection: poseProjection,
                    cameraProjectionModel: cameraProjectionModel
                )
            }
            if let index = bestMatch(for: observation, bearing: bearing, excluding: claimedSources) {
                claimedSources[index, default: []].insert(observation.source)
                updateTrack(
                    at: index,
                    with: observation,
                    bearing: bearing,
                    trackingBoundary: trackingBoundary,
                    cameraSettled: cameraSettled,
                    at: monotonicNS
                )
            } else {
                let newIndex = tracks.count
                tracks.append(Track(
                    id: "scene-\(nextID)",
                    rect: observation.rect,
                    confidence: observation.confidence,
                    source: observation.source,
                    kind: observation.kind,
                    label: observation.label,
                    attentionWeight: observation.attentionWeight,
                    faceMotorEvidence: observation.isActionEligible,
                    faceVerified: observation.isFaceVerified,
                    eyeContactEligible: observation.isEyeContactEligible,
                    gazeEvidence: observation.gazeEvidence,
                    firstSeenNS: monotonicNS,
                    lastSeenNS: monotonicNS,
                    observationCount: 1,
                    sources: [observation.source],
                    observedThisFrame: true,
                    observedBearing: bearing,
                    bearing: bearing,
                    trackingBoundary: trackingBoundary,
                    lastFaceActivityNS: nil,
                    pendingFaceMotion: nil,
                    faceInteractionLivenessValidated: false
                ))
                claimedSources[newIndex, default: []].insert(observation.source)
                nextID += 1
            }
        }

        // The global field retains objects and independently verified faces
        // for re-observation. A raw face-shaped hypothesis is different: if
        // it is absent from this visual update, it has no evidence left and
        // must not linger as a remembered person for the session.
        tracks.removeAll { track in
            guard track.kind == .human,
                  track.label == "face",
                  !track.faceVerified,
                  !track.observedThisFrame,
                  monotonicNS >= track.lastSeenNS else {
                return false
            }
            // Face inference may miss one or two frames while the gimbal is
            // moving. Preserve only geometric track continuity across that
            // short gap; candidate(from:) keeps it non-actionable while it is
            // not observed. Explicit verifier rejection still removes it via
            // invalidateUnverifiedFaceTracks immediately.
            return monotonicNS - track.lastSeenNS > unverifiedFaceTrackGapNS
        }

        // The spatial field is session memory, not a 15-second cache. Stale
        // candidates remain available for re-observation and map continuity.
        return tracks.map { track in candidate(from: track, at: monotonicNS) }
    }

    private mutating func updateTrack(
        at index: Int,
        with observation: VisualObservation,
        bearing: GimbalRelativeBearing?,
        trackingBoundary: TrackingBoundary,
        cameraSettled: Bool,
        at monotonicNS: UInt64
    ) {
        var track = tracks[index]
        if track.kind == .human,
           track.label == "face",
           monotonicNS >= track.lastSeenNS,
           monotonicNS - track.lastSeenNS > faceInteractionContinuityNS {
            track.faceInteractionLivenessValidated = false
            track.pendingFaceMotion = nil
        }
        if requiresFaceActivity,
           track.kind == .human,
           track.label == "face",
           observation.isActionEligible,
           cameraSettled,
           let priorBearing = track.bearing,
           let bearing,
           monotonicNS >= track.lastSeenNS,
           monotonicNS - track.lastSeenNS <= 250_000_000 {
            let imageMotion = hypot(
                observation.rect.centerX - track.rect.centerX,
                observation.rect.centerY - track.rect.centerY
            )
            let worldMotion = angularDistance(priorBearing, bearing)
            // Camera motion is removed in bearing space. A small detector
            // jitter cannot activate a static face-shaped object; natural
            // head/body movement can.
            if imageMotion >= 0.012, worldMotion >= 0.5, worldMotion <= 12.0 {
                let sample = FaceMotionSample(
                    azimuthDelta: signedAzimuthDelta(from: priorBearing, to: bearing),
                    elevationDelta: bearing.elevationDegrees - priorBearing.elevationDegrees,
                    monotonicNS: monotonicNS
                )
                if let pending = track.pendingFaceMotion,
                   monotonicNS > pending.monotonicNS,
                   monotonicNS - pending.monotonicNS <= 160_000_000,
                   pending.azimuthDelta * sample.azimuthDelta
                        + pending.elevationDelta * sample.elevationDelta > 0 {
                    // One detector-box twitch is not a reason to motor-lock
                    // onto a static face-shaped object. A second, directionally
                    // consistent motion sample is a low-latency acquisition
                    // cue; once locked, later stillness is allowed.
                    track.lastFaceActivityNS = monotonicNS
                    track.faceInteractionLivenessValidated = true
                    track.pendingFaceMotion = nil
                } else {
                    track.pendingFaceMotion = sample
                }
            } else {
                track.pendingFaceMotion = nil
            }
        } else if requiresFaceActivity,
                  track.kind == .human,
                  track.label == "face" {
            track.pendingFaceMotion = nil
        }
        track.rect = track.rect.blended(toward: observation.rect, weight: 0.45)
        track.confidence = track.confidence * 0.55 + observation.confidence * 0.45
        if observation.kind != .unknown { track.kind = observation.kind }
        if observation.kind != .unknown || track.kind == .unknown {
            track.source = observation.source
            if let label = observation.label { track.label = label }
        }
        track.attentionWeight = observation.attentionWeight
        if track.kind == .human, track.label == "face" {
            // Scene persistence must not manufacture motor authority. A face
            // becomes actionable only when FacePersonFusion has a current
            // independent person corroboration.
            track.faceMotorEvidence = observation.isActionEligible
            track.faceVerified = observation.isFaceVerified
            track.eyeContactEligible = observation.isEyeContactEligible
            track.gazeEvidence = observation.gazeEvidence
        }
        track.lastSeenNS = monotonicNS
        track.observationCount += 1
        track.sources.insert(observation.source)
        track.observedThisFrame = true
        track.observedBearing = bearing
        track.trackingBoundary = trackingBoundary
        if let bearing {
            track.bearing = blendedBearing(track.bearing, toward: bearing)
        }
        tracks[index] = track
    }

    private func bestMatch(
        for observation: VisualObservation,
        bearing: GimbalRelativeBearing?,
        excluding claimedSources: [Int: Set<VisualObservationSource>]
    ) -> Int? {
        let imageMatch = tracks.indices
            .filter {
                !(claimedSources[$0]?.contains(observation.source) ?? false)
                    && compatible(tracks[$0], observation)
            }
            .max { imageMatchScore(tracks[$0], observation) < imageMatchScore(tracks[$1], observation) }
        if let imageMatch {
            if let bearing, let trackedBearing = tracks[imageMatch].bearing,
               angularDistance(trackedBearing, bearing) > 12 {
                // The same class can appear at the same image rectangle after
                // a pan, yet occupy a different gimbal-relative direction.
                // Keep separate world hypotheses in that case.
            } else {
                return imageMatch
            }
        }
        guard let bearing else { return nil }
        return tracks.indices
            .filter {
                !(claimedSources[$0]?.contains(observation.source) ?? false)
                    && spatiallyCompatible(tracks[$0], observation, bearing: bearing)
            }
            .min {
                angularDistance(tracks[$0].bearing!, bearing) < angularDistance(tracks[$1].bearing!, bearing)
            }
    }

    private func compatible(_ track: Track, _ observation: VisualObservation) -> Bool {
        guard track.kind == observation.kind || track.kind == .unknown || observation.kind == .unknown else { return false }
        guard let trackedLabel = track.label, let observationLabel = observation.label else { return true }
        guard trackedLabel == observationLabel else { return false }
        let overlap = intersectionOverUnion(track.rect, observation.rect)
        guard trackedLabel == "face", track.kind == .human, observation.kind == .human else {
            return overlap >= 0.30
        }
        if overlap >= 0.12 { return true }
        let centreDistance = hypot(
            track.rect.centerX - observation.rect.centerX,
            track.rect.centerY - observation.rect.centerY
        )
        let areaRatio = (observation.rect.width * observation.rect.height)
            / max(track.rect.width * track.rect.height, 0.000_001)
        // This is geometric continuity, not identity: it merely keeps a face
        // measurement from changing scene ID when the gimbal moves it between
        // adjacent detector frames. A distant or radically re-scaled face
        // remains a separate scene hypothesis.
        return centreDistance <= 0.18 && areaRatio >= 0.45 && areaRatio <= 2.25
    }

    private func imageMatchScore(_ track: Track, _ observation: VisualObservation) -> Double {
        let overlap = intersectionOverUnion(track.rect, observation.rect)
        guard track.kind == .human,
              observation.kind == .human,
              track.label == "face",
              observation.label == "face" else {
            return overlap
        }
        let centreDistance = hypot(
            track.rect.centerX - observation.rect.centerX,
            track.rect.centerY - observation.rect.centerY
        )
        return overlap + max(0, 0.18 - centreDistance)
    }

    private func spatiallyCompatible(
        _ track: Track,
        _ observation: VisualObservation,
        bearing: GimbalRelativeBearing
    ) -> Bool {
        // Objectness saliency is anonymous background evidence, not an
        // object identity. Merge nearby bearings so repeated saliency frames
        // do not create an unbounded number of permanent map records.
        if track.kind == .unknown,
           observation.kind == .unknown,
           track.source == .systemSaliency,
           observation.source == .systemSaliency,
           let trackedBearing = track.bearing {
            return angularDistance(trackedBearing, bearing) <= 10
        }
        guard let trackedBearing = track.bearing,
              let trackedLabel = track.label,
              let observationLabel = observation.label,
              track.kind == observation.kind,
              trackedLabel == observationLabel else {
            return false
        }
        return angularDistance(trackedBearing, bearing) <= 12
    }

    private func candidate(from track: Track, at monotonicNS: UInt64) -> SceneCandidate {
        let stabilityMilliseconds = monotonicNS >= track.firstSeenNS
            ? Double(monotonicNS - track.firstSeenNS) / 1_000_000
            : 0
        let isFace = track.kind == .human && track.label == "face"
        let actionEligible = isActionEligible(track)
            // Spatial memory persists for the session, but it never preserves
            // motor authority. A face may drive only while it is in this
            // completed visual frame; the face lock itself decides whether an
            // ANE-only first acquisition remains a short provisional response
            // or is promoted by independent confirmation/activity.
            && (!isFace || (
                track.observedThisFrame
                    // Do not discard the very observation that opens the
                    // provisional lock. Requiring person corroboration here
                    // made the downstream lock unreachable for real faces.
            ))
        // A verified face is a real person's face (the verifier rules out
        // static face-shaped objects), so it is motor-eligible even while the
        // person is still — the motion-based activity lease is only needed to
        // reject unverified face-shaped distractors. Otherwise a person sitting
        // still in front of the camera would never stop the coverage scan.
        let faceActivityEligible = isFace
            && actionEligible
            && (!requiresFaceActivity || track.faceVerified || hasFreshFaceActivity(track, at: monotonicNS))
        let faceVerificationEligible = isFace
            && actionEligible
            && track.faceVerified
        let faceInteractionLivenessEligible = isFace
            && actionEligible
            && track.observedThisFrame
            && track.faceInteractionLivenessValidated
        let lastSeenMilliseconds = monotonicNS >= track.lastSeenNS
            ? Double(monotonicNS - track.lastSeenNS) / 1_000_000
            : 0
        let observation = VisualObservation(
            rect: track.rect,
            confidence: track.confidence,
            source: track.source,
            kind: track.kind,
            label: track.label,
            attentionWeight: track.attentionWeight,
            gazeEvidence: track.gazeEvidence
        )
        let spatialConfidence = track.kind == .human
            ? track.confidence
            : track.confidence * exp(-lastSeenMilliseconds / 12_000)
        return SceneCandidate(
            id: track.id,
            observation: observation,
            observedThisFrame: track.observedThisFrame,
            observationCount: track.observationCount,
            stabilityMilliseconds: stabilityMilliseconds,
            sourceCount: track.sources.count,
            isActionEligible: actionEligible,
            faceActivityEligible: faceActivityEligible,
            faceVerificationEligible: faceVerificationEligible,
            faceInteractionLivenessEligible: faceInteractionLivenessEligible,
            eyeContactEligible: track.observedThisFrame && track.eyeContactEligible,
            trackingBoundary: track.trackingBoundary,
            observedBearing: track.observedThisFrame ? track.observedBearing : nil,
            bearing: track.bearing,
            spatialConfidence: spatialConfidence,
            lastSeenMilliseconds: lastSeenMilliseconds
        )
    }

    private func bearing(
        for rect: NormalizedRect,
        cameraPose: GimbalPose,
        horizontalFieldOfViewDegrees: Double,
        aspectRatio: Double,
        poseProjection: GimbalPoseProjection,
        cameraProjectionModel: CameraProjectionModel?
    ) -> GimbalRelativeBearing {
        if let cameraProjectionModel, cameraProjectionModel.isValid {
            let actualRay = (
                (rect.centerX - cameraProjectionModel.principalXNormalized)
                    / cameraProjectionModel.focalXNormalized,
                ((1 - rect.centerY) - cameraProjectionModel.principalYNormalized)
                    / cameraProjectionModel.focalYNormalized,
                1.0
            )
            let idealRay = cameraProjectionModel.actualToIdeal(actualRay)
            let panSign = poseProjection.panImageSign >= 0 ? 1.0 : -1.0
            let pitchSign = poseProjection.pitchImageSign >= 0 ? 1.0 : -1.0
            // `panImageSign` measures how an image point moves when the SDK
            // attitude increases. Camera yaw has the inverse horizontal
            // relation: panning the camera right moves a fixed world point
            // left in its image. Bearings remain in SDK-attitude coordinates
            // because motor routing consumes them directly.
            let cameraAzimuth = -cameraPose.panDegrees * panSign * .pi / 180
            let cameraElevation = cameraPose.pitchDegrees * pitchSign * .pi / 180
            let forward = (
                cos(cameraElevation) * sin(cameraAzimuth),
                sin(cameraElevation),
                cos(cameraElevation) * cos(cameraAzimuth)
            )
            let right = (cos(cameraAzimuth), 0.0, -sin(cameraAzimuth))
            let up = (
                -sin(cameraElevation) * sin(cameraAzimuth),
                cos(cameraElevation),
                -sin(cameraElevation) * cos(cameraAzimuth)
            )
            let world = (
                right.0 * idealRay.0 + up.0 * idealRay.1 + forward.0 * idealRay.2,
                right.1 * idealRay.0 + up.1 * idealRay.1 + forward.1 * idealRay.2,
                right.2 * idealRay.0 + up.2 * idealRay.1 + forward.2 * idealRay.2
            )
            let canonicalAzimuth = atan2(world.0, world.2) * 180 / .pi
            let canonicalElevation = atan2(world.1, hypot(world.0, world.2)) * 180 / .pi
            return GimbalRelativeBearing(
                azimuthDegrees: -canonicalAzimuth / panSign,
                elevationDegrees: canonicalElevation / pitchSign
            )
        }
        let horizontalHalfRadians = max(1, min(horizontalFieldOfViewDegrees, 170)) * .pi / 360
        let verticalHalfRadians = atan(tan(horizontalHalfRadians) / max(aspectRatio, 0.1))
        let horizontalOffset = atan((rect.centerX - 0.5) * 2 * tan(horizontalHalfRadians)) * 180 / .pi
        let verticalOffset = atan((rect.centerY - 0.5) * 2 * tan(verticalHalfRadians)) * 180 / .pi
        return GimbalRelativeBearing(
            azimuthDegrees: cameraPose.panDegrees - poseProjection.panImageSign * horizontalOffset,
            elevationDegrees: cameraPose.pitchDegrees - poseProjection.pitchImageSign * verticalOffset
        )
    }

    private func blendedBearing(
        _ current: GimbalRelativeBearing?,
        toward next: GimbalRelativeBearing
    ) -> GimbalRelativeBearing {
        guard let current else { return next }
        let currentRadians = current.azimuthDegrees * .pi / 180
        let nextRadians = next.azimuthDegrees * .pi / 180
        let azimuth = atan2(
            sin(currentRadians) * 0.55 + sin(nextRadians) * 0.45,
            cos(currentRadians) * 0.55 + cos(nextRadians) * 0.45
        ) * 180 / .pi
        return GimbalRelativeBearing(
            azimuthDegrees: azimuth,
            elevationDegrees: current.elevationDegrees * 0.55 + next.elevationDegrees * 0.45
        )
    }

    private func angularDistance(_ lhs: GimbalRelativeBearing, _ rhs: GimbalRelativeBearing) -> Double {
        let azimuthDelta = abs(lhs.azimuthDegrees - rhs.azimuthDegrees).truncatingRemainder(dividingBy: 360)
        let wrappedAzimuthDelta = azimuthDelta > 180 ? 360 - azimuthDelta : azimuthDelta
        return hypot(wrappedAzimuthDelta, lhs.elevationDegrees - rhs.elevationDegrees)
    }

    private func signedAzimuthDelta(from lhs: GimbalRelativeBearing, to rhs: GimbalRelativeBearing) -> Double {
        var delta = (rhs.azimuthDegrees - lhs.azimuthDegrees).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta <= -180 { delta += 360 }
        return delta
    }

    private func isActionEligible(_ track: Track) -> Bool {
        let area = track.rect.width * track.rect.height
        guard area >= 0.006 else {
            return false
        }
        // A current human rectangle is sufficient for image-space closed-loop
        // tracking during a brief SDK-attitude reporting gap. The physical
        // boundary still applies whenever a fresh pose is available. Retained
        // offscreen records remain session-map evidence only at L0.
        if track.kind == .human && !track.trackingBoundary.isPoseAligned {
            return true
        }
        if track.kind == .human, track.label == "face" {
            return track.trackingBoundary.allowsFaceReentry(track.rect)
        }
        guard track.trackingBoundary.allowsMotorTarget(track.rect) else { return false }
        // A saliency mask spanning most of the frame is background structure,
        // not a local thing to turn toward. A normal saliency region must also
        // persist briefly before it gains motor authority because it carries no
        // class label. All rejected regions remain scene evidence.
        if track.source == .systemSaliency {
            return area < 0.55 && track.lastSeenNS >= track.firstSeenNS
                && track.lastSeenNS - track.firstSeenNS >= 200_000_000
        }
        return true
    }

    private func hasFreshFaceActivity(_ track: Track, at monotonicNS: UInt64) -> Bool {
        guard let lastFaceActivityNS = track.lastFaceActivityNS,
              monotonicNS >= lastFaceActivityNS else {
            return false
        }
        return monotonicNS - lastFaceActivityNS <= faceActivityLeaseNS
    }

    private func intersectionOverUnion(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let x1 = max(lhs.x, rhs.x)
        let y1 = max(lhs.y, rhs.y)
        let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }
}
