import Foundation

/// A spherical viewing direction chosen because it has not recently been
/// covered by the camera field of view. This is L0 spatial novelty, not an
/// object identity claim.
public struct SpatialCoverageDirection: Sendable {
    public let bearing: GimbalRelativeBearing
    public let probability: Double
    public let panoramaQuality: Double
    public let placeFamiliarity: Double
    public let expectedInformationGain: Double

    public init(
        bearing: GimbalRelativeBearing,
        probability: Double,
        panoramaQuality: Double = 0,
        placeFamiliarity: Double = 0,
        expectedInformationGain: Double = 1
    ) {
        self.bearing = bearing
        self.probability = min(max(probability, 0), 1)
        self.panoramaQuality = min(max(panoramaQuality, 0), 1)
        self.placeFamiliarity = min(max(placeFamiliarity, 0), 1)
        self.expectedInformationGain = min(max(expectedInformationGain, 0), 1)
    }
}

public struct SphericalPlaceRecognition: Codable, Equatable, Sendable {
    public let bearing: GimbalRelativeBearing
    public let familiarity: Double
    public let novelty: Double
    public let isRevisit: Bool
    public let observationCount: Int

    public init(
        bearing: GimbalRelativeBearing,
        familiarity: Double,
        novelty: Double,
        isRevisit: Bool,
        observationCount: Int
    ) {
        self.bearing = bearing
        self.familiarity = min(max(familiarity, 0), 1)
        self.novelty = min(max(novelty, 0), 1)
        self.isRevisit = isRevisit
        self.observationCount = max(1, observationCount)
    }
}

public enum GimbalObservationPreference: Sendable {
    case nearestVisible
    case centered
}

/// Acceleration-limited velocity state for continuous no-target exploration.
/// A new spatial waypoint changes the desired velocity, but never steps the
/// physical command directly from one direction to the other.
public struct SmoothExplorationVelocity: Equatable, Sendable {
    public let pitchDegreesPerSecond: Double
    public let panDegreesPerSecond: Double
}

public struct GimbalVisibilityRoutePlan: Codable, Equatable, Sendable {
    public let target: GimbalRelativeBearing
    public let observationPose: GimbalRelativeBearing
    public let requiresMotion: Bool
    public let panClearanceDegrees: Double
    public let pitchClearanceDegrees: Double
}

/// Plans the shortest direct route in finite pan/pitch joint space to a camera
/// pose whose FOV contains the requested world bearing. The admissible joint
/// envelope is convex, so this route never wraps through a mechanical limit.
public enum GimbalVisibilityRoutePlanner {
    public static func plan(
        to target: GimbalRelativeBearing,
        from pose: GimbalPose,
        horizontalFieldOfViewDegrees: Double = 86,
        aspectRatio: Double = 16.0 / 9.0,
        kinematicEnvelope: GimbalKinematicEnvelope = .obsbotTiny2Lite,
        horizontalViewMarginDegrees: Double = 8,
        verticalViewMarginDegrees: Double = 6,
        observationPreference: GimbalObservationPreference = .nearestVisible
    ) -> GimbalVisibilityRoutePlan? {
        let visibleHalf = usableHalfView(
            horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
            aspectRatio: aspectRatio,
            horizontalViewMarginDegrees: horizontalViewMarginDegrees,
            verticalViewMarginDegrees: verticalViewMarginDegrees
        )
        guard visibleHalf.horizontal > 0, visibleHalf.vertical > 0,
              let pan = visibleAxisPosition(
                target: target.azimuthDegrees,
                current: pose.panDegrees,
                visibleHalfWidth: visibleHalf.horizontal,
                limit: kinematicEnvelope.maximumAutonomousPanDegrees,
                preference: observationPreference
              ),
              let pitch = visibleAxisPosition(
                target: target.elevationDegrees,
                current: pose.pitchDegrees,
                visibleHalfWidth: visibleHalf.vertical,
                limit: kinematicEnvelope.maximumAutonomousPitchDegrees,
                preference: observationPreference
              ) else {
            return nil
        }
        let observationPose = GimbalRelativeBearing(
            azimuthDegrees: pan,
            elevationDegrees: pitch
        )
        return GimbalVisibilityRoutePlan(
            target: target,
            observationPose: observationPose,
            requiresMotion: hypot(pan - pose.panDegrees, pitch - pose.pitchDegrees) > 0.5,
            panClearanceDegrees: max(0, kinematicEnvelope.maximumAutonomousPanDegrees - abs(pan)),
            pitchClearanceDegrees: max(0, kinematicEnvelope.maximumAutonomousPitchDegrees - abs(pitch))
        )
    }

    public static func guide(
        to target: GimbalRelativeBearing,
        from pose: GimbalPose,
        horizontalFieldOfViewDegrees: Double = 86,
        aspectRatio: Double = 16.0 / 9.0,
        kinematicEnvelope: GimbalKinematicEnvelope = .obsbotTiny2Lite,
        horizontalViewMarginDegrees: Double = 8,
        verticalViewMarginDegrees: Double = 6,
        observationPreference: GimbalObservationPreference = .nearestVisible
    ) -> GimbalRelativeBearing? {
        plan(
            to: target,
            from: pose,
            horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
            aspectRatio: aspectRatio,
            kinematicEnvelope: kinematicEnvelope,
            horizontalViewMarginDegrees: horizontalViewMarginDegrees,
            verticalViewMarginDegrees: verticalViewMarginDegrees,
            observationPreference: observationPreference
        )?.observationPose
    }

    static func usableHalfView(
        horizontalFieldOfViewDegrees: Double,
        aspectRatio: Double,
        horizontalViewMarginDegrees: Double,
        verticalViewMarginDegrees: Double
    ) -> (horizontal: Double, vertical: Double) {
        let horizontalHalf = max(1, min(horizontalFieldOfViewDegrees, 170)) / 2
        let horizontalHalfRadians = horizontalHalf * .pi / 180
        let verticalHalf = atan(tan(horizontalHalfRadians) / max(aspectRatio, 0.1)) * 180 / .pi
        return (
            horizontalHalf - max(0, horizontalViewMarginDegrees),
            verticalHalf - max(0, verticalViewMarginDegrees)
        )
    }

    private static func visibleAxisPosition(
        target: Double,
        current: Double,
        visibleHalfWidth: Double,
        limit: Double,
        preference: GimbalObservationPreference
    ) -> Double? {
        let lower = max(-abs(limit), target - visibleHalfWidth)
        let upper = min(abs(limit), target + visibleHalfWidth)
        guard lower <= upper else { return nil }
        switch preference {
        case .nearestVisible:
            return min(max(current, lower), upper)
        case .centered:
            return min(max(target, lower), upper)
        }
    }
}

public struct SmoothExplorationDynamics: Sendable {
    private var velocity = SmoothExplorationVelocity(
        pitchDegreesPerSecond: 0,
        panDegreesPerSecond: 0
    )
    private var lastNS: UInt64?

    public init() {}

    public static func stoppingVelocity(
        errorDegrees: Double,
        maximumDegreesPerSecond: Double,
        accelerationDegreesPerSecondSquared: Double,
        deadbandDegrees: Double = 2
    ) -> Double {
        let remaining = max(0, abs(errorDegrees) - deadbandDegrees)
        guard remaining > 0 else { return 0 }
        let stoppingSpeed = sqrt(2 * accelerationDegreesPerSecondSquared * remaining)
        let magnitude = min(maximumDegreesPerSecond, stoppingSpeed)
        return errorDegrees < 0 ? -magnitude : magnitude
    }

    public static func waypointTimeoutSeconds(
        panErrorDegrees: Double,
        pitchErrorDegrees: Double,
        maximumPanDegreesPerSecond: Double = 60,
        maximumPitchDegreesPerSecond: Double = 30,
        minimumRealizedSpeedFraction: Double = 0.45
    ) -> Double {
        let panTravel = abs(panErrorDegrees) / maximumPanDegreesPerSecond
        let pitchTravel = abs(pitchErrorDegrees) / maximumPitchDegreesPerSecond
        let realizedFraction = min(max(minimumRealizedSpeedFraction, 0.25), 1)
        return max(3.5, max(panTravel, pitchTravel) / realizedFraction + 1.5)
    }

    /// Coverage waypoints are look-ahead guides, not fixation points. Hand the
    /// controller to the next guide before both axes brake to zero at the
    /// exact cell centre.
    public static func shouldBlendToNextWaypoint(
        panErrorDegrees: Double,
        pitchErrorDegrees: Double,
        lookAheadRadiusDegrees: Double = 10
    ) -> Bool {
        hypot(panErrorDegrees, pitchErrorDegrees) <= lookAheadRadiusDegrees
    }

    public mutating func advance(
        towardPitch desiredPitch: Double,
        pan desiredPan: Double,
        at monotonicNS: UInt64,
        maximumPitchAcceleration: Double = 80,
        maximumPanAcceleration: Double = 120
    ) -> SmoothExplorationVelocity {
        let elapsed: Double
        if let lastNS, monotonicNS > lastNS {
            elapsed = min(max(Double(monotonicNS - lastNS) / 1_000_000_000, 0.01), 0.10)
        } else {
            elapsed = 0.05
        }
        velocity = SmoothExplorationVelocity(
            pitchDegreesPerSecond: slew(
                from: velocity.pitchDegreesPerSecond,
                to: desiredPitch,
                maximumChange: max(0, maximumPitchAcceleration) * elapsed
            ),
            panDegreesPerSecond: slew(
                from: velocity.panDegreesPerSecond,
                to: desiredPan,
                maximumChange: max(0, maximumPanAcceleration) * elapsed
            )
        )
        lastNS = monotonicNS
        return velocity
    }

    public mutating func reset() {
        velocity = SmoothExplorationVelocity(
            pitchDegreesPerSecond: 0,
            panDegreesPerSecond: 0
        )
        lastNS = nil
    }

    private func slew(from current: Double, to desired: Double, maximumChange: Double) -> Double {
        max(current - maximumChange, min(current + maximumChange, desired))
    }
}

/// Tracks whether a physical pan axis has stopped responding during
/// exploration. One failed direction reverses the next waypoint; failure in both
/// directions means the controller must re-home instead of oscillating at the
/// same mechanical limit.
public enum PanStallRecoveryAction: Equatable, Sendable {
    case none
    case reverse
    case recenter
}

public struct PanStallRecovery: Sendable {
    private var failedDirections: Set<Int> = []

    public init() {}

    public mutating func record(requestedPanDegreesPerSecond: Double, observedMotionDegrees: Double) -> PanStallRecoveryAction {
        guard abs(requestedPanDegreesPerSecond) >= 12 else { return .none }
        guard observedMotionDegrees < 1.5 else {
            failedDirections.removeAll()
            return .none
        }
        failedDirections.insert(requestedPanDegreesPerSecond < 0 ? -1 : 1)
        if failedDirections.count == 2 {
            failedDirections.removeAll()
            return .recenter
        }
        return .reverse
    }
}

/// Retains when each gimbal-relative direction was last visible. The grid is
/// deliberately coarser than detector boxes: it drives exploration between
/// known scene hypotheses instead of making a second object tracker.
public struct SpatialCoverageField: Sendable {
    private struct Cell: Sendable {
        let bearing: GimbalRelativeBearing
        var lastObservedNS: UInt64?
        var observationCount: Int
        var unproductiveVisits: Int
        var lastUnproductiveNS: UInt64?
        var panoramaQuality: Double
        var panoramaLastUpdatedNS: UInt64?
        var placeEmbedding: PanoramaPlaceEmbedding?
        var placeFamiliarity: Double
        var placeConflict: Double
        var placeObservationCount: Int
        var placeLastUpdatedNS: UInt64?
    }

    /// A recent self-directed look is weak negative evidence for looking
    /// immediately beside the same place again. This is separate from image
    /// coverage: it remains useful while the camera is moving or a frame is
    /// temporarily unavailable.
    private struct ExplorationVisit: Sendable {
        let bearing: GimbalRelativeBearing
        let monotonicNS: UInt64
    }

    private var cells: [Cell]
    private let kinematicEnvelope: GimbalKinematicEnvelope
    private var recentExplorationVisits: [ExplorationVisit] = []

    public init(
        kinematicEnvelope: GimbalKinematicEnvelope = .obsbotTiny2Lite,
        horizontalFieldOfViewDegrees: Double = 86,
        aspectRatio: Double = 16.0 / 9.0
    ) {
        self.kinematicEnvelope = kinematicEnvelope
        var initial: [Cell] = []
        let usableHalf = GimbalVisibilityRoutePlanner.usableHalfView(
            horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
            aspectRatio: aspectRatio,
            horizontalViewMarginDegrees: 8,
            verticalViewMarginDegrees: 6
        )
        // The atlas covers every direction that can be observed from a valid
        // autonomous camera centre, including directions visible only near a
        // frame edge. It does not confuse wrapped spherical distance with a
        // mechanically reachable pan route.
        let maximumMappedAzimuth = min(
            180,
            floor((kinematicEnvelope.maximumAutonomousPanDegrees + usableHalf.horizontal) / 18) * 18
        )
        let maximumMappedElevation = min(
            90,
            floor((kinematicEnvelope.maximumAutonomousPitchDegrees + usableHalf.vertical) / 13) * 13
        )
        for elevation in stride(from: -maximumMappedElevation, through: maximumMappedElevation, by: 13.0) {
            for azimuth in stride(from: -maximumMappedAzimuth, through: maximumMappedAzimuth, by: 18.0) {
                initial.append(Cell(
                    bearing: GimbalRelativeBearing(
                        azimuthDegrees: azimuth,
                        elevationDegrees: elevation
                    ),
                    lastObservedNS: nil,
                    observationCount: 0,
                    unproductiveVisits: 0,
                    lastUnproductiveNS: nil,
                    panoramaQuality: 0,
                    panoramaLastUpdatedNS: nil,
                    placeEmbedding: nil,
                    placeFamiliarity: 0,
                    placeConflict: 0,
                    placeObservationCount: 0,
                    placeLastUpdatedNS: nil
                ))
            }
        }
        cells = initial
    }

    public mutating func observePanorama(
        pose: GimbalPose,
        horizontalFieldOfViewDegrees: Double,
        frameQuality: Double,
        dynamicVisionRects: [NormalizedRect],
        poseProjection: GimbalPoseProjection,
        cameraProjectionModel: CameraProjectionModel? = nil,
        at monotonicNS: UInt64,
        aspectRatio: Double = 16.0 / 9.0
    ) {
        let boundedFrameQuality = min(max(frameQuality, 0), 1)
        guard boundedFrameQuality > 0 else { return }
        for index in cells.indices {
            guard let coordinate = SphericalPanoramaProjection.sourceCoordinate(
                for: canonicalBearing(
                    cells[index].bearing,
                    poseProjection: poseProjection
                ),
                cameraPose: pose,
                horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                aspectRatio: aspectRatio,
                poseProjection: poseProjection,
                cameraProjectionModel: cameraProjectionModel
            ), !SphericalPanoramaProjection.isDynamicallyMasked(
                sourceCoordinate: coordinate,
                visionRects: dynamicVisionRects
            ) else { continue }
            let incomingQuality = boundedFrameQuality * coordinate.viewWeight
            guard PanoramaObservationQuality.shouldReplace(
                existingQuality: cells[index].panoramaQuality,
                incomingQuality: incomingQuality
            ) else { continue }
            // Comparable observations may refresh scene appearance, but the
            // confidence floor must never ratchet downward over many revisits.
            cells[index].panoramaQuality = max(cells[index].panoramaQuality, incomingQuality)
            cells[index].panoramaLastUpdatedNS = monotonicNS
        }
    }

    public mutating func observe(
        pose: GimbalPose,
        horizontalFieldOfViewDegrees: Double,
        poseProjection: GimbalPoseProjection = .identity,
        cameraProjectionModel: CameraProjectionModel? = nil,
        at monotonicNS: UInt64,
        aspectRatio: Double = 16.0 / 9.0
    ) {
        for index in cells.indices {
            guard SphericalPanoramaProjection.sourceCoordinate(
                for: canonicalBearing(
                    cells[index].bearing,
                    poseProjection: poseProjection
                ),
                cameraPose: pose,
                horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                aspectRatio: aspectRatio,
                poseProjection: poseProjection,
                cameraProjectionModel: cameraProjectionModel
            ) != nil else { continue }
            cells[index].lastObservedNS = monotonicNS
            cells[index].observationCount += 1
        }
    }

    /// Associates one stable, human-free learned embedding with the nearest
    /// fixed spherical cell. Revisits update that cell instead of creating a
    /// second location, which is the appropriate loop-closure model for a
    /// fixed-base pan/tilt camera.
    public mutating func observePlace(
        embedding: PanoramaPlaceEmbedding,
        pose: GimbalPose,
        observationQuality: Double,
        at monotonicNS: UInt64
    ) -> SphericalPlaceRecognition? {
        guard let index = cells.indices.min(by: {
                  sphericalDistanceDegrees(cells[$0].bearing, pose: pose)
                      < sphericalDistanceDegrees(cells[$1].bearing, pose: pose)
              }) else { return nil }
        let quality = min(max(observationQuality, 0), 1)
        let wasRevisit = cells[index].placeEmbedding?.isCompatible(with: embedding) == true
        let familiarity: Double
        if let current = cells[index].placeEmbedding,
           let compatibleFamiliarity = current.similarity(to: embedding) {
            familiarity = compatibleFamiliarity
            let adaptation = (0.08 + 0.27 * quality) * (0.25 + 0.75 * familiarity)
            cells[index].placeEmbedding = current.blended(with: embedding, weight: adaptation)
            cells[index].placeFamiliarity = cells[index].placeObservationCount <= 1
                ? familiarity
                : 0.7 * cells[index].placeFamiliarity + 0.3 * familiarity
            cells[index].placeConflict = cells[index].placeObservationCount <= 1
                ? 1 - familiarity
                : 0.7 * cells[index].placeConflict + 0.3 * (1 - familiarity)
        } else {
            familiarity = 0
            cells[index].placeEmbedding = embedding
            cells[index].placeFamiliarity = 0
            cells[index].placeConflict = 0
            cells[index].placeObservationCount = 0
        }
        cells[index].placeObservationCount += 1
        cells[index].placeLastUpdatedNS = monotonicNS
        return SphericalPlaceRecognition(
            bearing: cells[index].bearing,
            familiarity: familiarity,
            novelty: wasRevisit ? 1 - familiarity : 1,
            isRevisit: wasRevisit,
            observationCount: cells[index].placeObservationCount
        )
    }

    /// Normalizes recently-unseen directions against an explicit no-exploration
    /// alternative. Nearby unseen directions win first, then long-unseen space
    /// gradually becomes attractive again after coverage ages.
    public func nextDirection(from pose: GimbalPose, at monotonicNS: UInt64) -> SpatialCoverageDirection? {
        let distribution = directionDistribution(from: pose, at: monotonicNS, temperature: 1)
        guard let index = distribution.probabilities.indices.max(by: { distribution.probabilities[$0] < distribution.probabilities[$1] }),
              distribution.probabilities[index] > distribution.noExplorationProbability else {
            return nil
        }
        return SpatialCoverageDirection(
            bearing: cells[index].bearing,
            probability: distribution.probabilities[index],
            panoramaQuality: cells[index].panoramaQuality,
            placeFamiliarity: cells[index].placeFamiliarity,
            expectedInformationGain: expectedInformationGain(for: cells[index], at: monotonicNS)
        )
    }

    /// Samples a direction from a tempered posterior. This is used only at an
    /// idle exploration transition, never for per-frame visual fixation.
    public func sampleNextDirection(
        from pose: GimbalPose,
        at monotonicNS: UInt64,
        temperature: Double,
        uniform: Double
    ) -> SpatialCoverageDirection? {
        let distribution = directionDistribution(from: pose, at: monotonicNS, temperature: temperature)
        let draw = min(max(uniform, 0), 1.0.nextDown)
        var cumulative = 0.0
        for index in cells.indices {
            cumulative += distribution.probabilities[index]
            if draw < cumulative {
                return SpatialCoverageDirection(
                    bearing: cells[index].bearing,
                    probability: distribution.probabilities[index],
                    panoramaQuality: cells[index].panoramaQuality,
                    placeFamiliarity: cells[index].placeFamiliarity,
                    expectedInformationGain: expectedInformationGain(for: cells[index], at: monotonicNS)
                )
            }
        }
        return nil // explicit no-exploration alternative
    }

    /// Internal observability for deterministic policy checks. Production
    /// callers select through `sampleNextDirection` instead of treating this
    /// posterior mass as a directive.
    func explorationProbability(
        for bearing: GimbalRelativeBearing,
        from pose: GimbalPose,
        at monotonicNS: UInt64,
        temperature: Double
    ) -> Double? {
        guard let index = cells.indices.first(where: { cells[$0].bearing == bearing }) else {
            return nil
        }
        return directionDistribution(
            from: pose,
            at: monotonicNS,
            temperature: temperature
        ).probabilities[index]
    }

    /// A full look at a selected direction without an acquired target is
    /// evidence against immediately spending another exploration pulse there.
    public mutating func recordUnproductiveVisit(
        to direction: SpatialCoverageDirection,
        at monotonicNS: UInt64? = nil
    ) {
        guard let index = cells.indices.first(where: { cells[$0].bearing == direction.bearing }) else { return }
        let visitNS = monotonicNS
            ?? cells[index].lastObservedNS
            ?? cells[index].lastUnproductiveNS
            ?? 0
        cells[index].unproductiveVisits += 1
        cells[index].lastUnproductiveNS = visitNS
        // Keep only the short-lived spatial context needed for inhibition of
        // return. The longer-lived information value is already represented
        // by the coverage and place-memory fields above.
        recentExplorationVisits.removeAll {
            visitNS >= $0.monotonicNS && visitNS - $0.monotonicNS > 75_000_000_000
        }
        recentExplorationVisits.append(
            ExplorationVisit(bearing: direction.bearing, monotonicNS: visitNS)
        )
        if recentExplorationVisits.count > 8 {
            recentExplorationVisits.removeFirst(recentExplorationVisits.count - 8)
        }
    }

    private func directionDistribution(
        from pose: GimbalPose,
        at monotonicNS: UInt64,
        temperature: Double
    ) -> (probabilities: [Double], noExplorationProbability: Double) {
        let revisitNS = 90_000_000_000.0
        let inverseTemperature = 1 / min(max(temperature, 0.35), 2.5)
        let likelihoods = cells.map { cell -> Double in
            guard let route = GimbalVisibilityRoutePlanner.plan(
                to: cell.bearing,
                from: pose,
                kinematicEnvelope: kinematicEnvelope
            ) else { return 0 }
            let novelty: Double
            if let lastObservedNS = cell.lastObservedNS, monotonicNS >= lastObservedNS {
                novelty = min(1, Double(monotonicNS - lastObservedNS) / revisitNS)
            } else {
                novelty = 1
            }
            let observationNeed = expectedInformationGain(
                for: cell,
                at: monotonicNS,
                novelty: novelty
            )
            let routeDistance = sphericalDistanceDegrees(route.observationPose, pose: pose)
            let failureAgeSeconds = cell.lastUnproductiveNS.map {
                monotonicNS >= $0 ? Double(monotonicNS - $0) / 1_000_000_000 : 0
            } ?? 0
            let effectiveFailures = Double(cell.unproductiveVisits) * exp(-failureAgeSeconds / 300)
            let failurePenalty = exp(-0.7 * effectiveFailures)
            let returnInhibition = recentExplorationInhibition(
                for: cell.bearing,
                at: monotonicNS
            )
            // Prefer a natural eye-level scan. With a weak divisor the
            // exploration regularly dives to a low cell and sweeps nose-down,
            // which reads as "tucking the head and turning". A stronger
            // horizontal preference keeps the sweep near eye level while still
            // allowing gentle up/down coverage.
            let elevationComfort = exp(-abs(cell.bearing.elevationDegrees) / 10)
            let boundaryClearance = min(route.panClearanceDegrees / 20, route.pitchClearanceDegrees / 12)
            let boundaryComfort = 0.55 + 0.45 * min(max(boundaryClearance, 0), 1)
            return pow(
                max(
                    0.001,
                    observationNeed * exp(-routeDistance / 120) * failurePenalty
                        * (1 - 0.85 * returnInhibition) * elevationComfort * boundaryComfort
                ),
                inverseTemperature
            )
        }
        let noExplorationLikelihood = pow(0.03, inverseTemperature)
        let total = likelihoods.reduce(noExplorationLikelihood, +)
        let probabilities = likelihoods.map { $0 / total }
        return (probabilities, noExplorationLikelihood / total)
    }

    private func expectedInformationGain(
        for cell: Cell,
        at monotonicNS: UInt64,
        novelty suppliedNovelty: Double? = nil
    ) -> Double {
        let novelty: Double
        if let suppliedNovelty {
            novelty = suppliedNovelty
        } else if let lastObservedNS = cell.lastObservedNS, monotonicNS >= lastObservedNS {
            novelty = min(1, Double(monotonicNS - lastObservedNS) / 90_000_000_000)
        } else {
            novelty = 1
        }
        let panoramaNeed = 1 - cell.panoramaQuality
        let placeNeed: Double
        if cell.placeEmbedding == nil {
            placeNeed = 1
        } else {
            let evidenceNeed = 1 / sqrt(Double(max(1, cell.placeObservationCount)))
            placeNeed = max(evidenceNeed, cell.placeConflict)
        }
        return min(max(0.20 * novelty + 0.45 * panoramaNeed + 0.35 * placeNeed, 0), 1)
    }

    /// Inhibition of return is local on the viewing sphere and decays over
    /// time. It makes a no-target scan leave a just-examined region while
    /// allowing that region to become useful again once the room may have
    /// changed.
    private func recentExplorationInhibition(
        for bearing: GimbalRelativeBearing,
        at monotonicNS: UInt64
    ) -> Double {
        recentExplorationVisits.reduce(0) { strongest, visit in
            let ageSeconds: Double
            if monotonicNS >= visit.monotonicNS {
                ageSeconds = Double(monotonicNS - visit.monotonicNS) / 1_000_000_000
            } else {
                ageSeconds = 0
            }
            let temporalDecay = exp(-ageSeconds / 35)
            let distance = sphericalDistanceDegrees(bearing, visit.bearing)
            let spatialFalloff = exp(-0.5 * pow(distance / 30, 2))
            return max(strongest, temporalDecay * spatialFalloff)
        }
    }

    public func snapshot(at monotonicNS: UInt64) -> [SphericalAtlasCell] {
        cells.map { cell in
            SphericalAtlasCell(
                bearing: cell.bearing,
                lastObservedMilliseconds: cell.lastObservedNS.map {
                    monotonicNS >= $0 ? Double(monotonicNS - $0) / 1_000_000 : 0
                },
                observationCount: cell.observationCount,
                unproductiveVisits: cell.unproductiveVisits,
                panoramaQuality: cell.panoramaQuality,
                panoramaLastUpdatedMilliseconds: cell.panoramaLastUpdatedNS.map {
                    monotonicNS >= $0 ? Double(monotonicNS - $0) / 1_000_000 : 0
                },
                placeFamiliarity: cell.placeFamiliarity,
                placeConflict: cell.placeConflict,
                placeObservationCount: cell.placeObservationCount,
                placeLastUpdatedMilliseconds: cell.placeLastUpdatedNS.map {
                    monotonicNS >= $0 ? Double(monotonicNS - $0) / 1_000_000 : 0
                },
                expectedInformationGain: expectedInformationGain(for: cell, at: monotonicNS)
            )
        }
    }

    public mutating func restorePlaceMemory(
        _ snapshot: SphericalPlaceMemorySnapshot,
        expectedEncoder: String,
        expectedRevision: Int
    ) -> Int {
        guard let validated = try? snapshot.validated(
            expectedEncoder: expectedEncoder,
            expectedRevision: expectedRevision
        ) else { return 0 }
        var restored = 0
        for remembered in validated.cells {
            guard let index = cells.firstIndex(where: { $0.bearing == remembered.bearing }) else {
                continue
            }
            cells[index].placeEmbedding = remembered.embedding
            cells[index].placeFamiliarity = remembered.familiarity
            cells[index].placeConflict = remembered.conflict
            cells[index].placeObservationCount = remembered.observationCount
            cells[index].placeLastUpdatedNS = nil
            restored += 1
        }
        return restored
    }

    public func placeMemorySnapshot(
        generatedAtUnixMilliseconds: UInt64
    ) -> SphericalPlaceMemorySnapshot {
        SphericalPlaceMemorySnapshot(
            generatedAtUnixMilliseconds: generatedAtUnixMilliseconds,
            cells: cells.compactMap { cell in
                guard let embedding = cell.placeEmbedding else { return nil }
                return SphericalPlaceMemoryCell(
                    bearing: cell.bearing,
                    embedding: embedding,
                    familiarity: cell.placeFamiliarity,
                    conflict: cell.placeConflict,
                    observationCount: cell.placeObservationCount
                )
            }
        )
    }

    public var placeEmbeddingIdentity: (encoder: String, revision: Int)? {
        cells.lazy.compactMap(\.placeEmbedding).first.map { ($0.encoder, $0.revision) }
    }

    public var placeMemoryCount: Int {
        cells.reduce(0) { $0 + ($1.placeEmbedding == nil ? 0 : 1) }
    }

    private func angularDifference(_ targetDegrees: Double, _ currentDegrees: Double) -> Double {
        var difference = (targetDegrees - currentDegrees).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference <= -180 { difference += 360 }
        return difference
    }

    /// Coverage cells live in SDK motor coordinates because the route planner
    /// consumes them directly. Image projection lives in a conventional
    /// right/up visual sphere, so convert the stored bearing exactly once.
    private func canonicalBearing(
        _ bearing: GimbalRelativeBearing,
        poseProjection: GimbalPoseProjection
    ) -> GimbalRelativeBearing {
        GimbalRelativeBearing(
            azimuthDegrees: bearing.azimuthDegrees * (poseProjection.panImageSign >= 0 ? 1 : -1),
            elevationDegrees: bearing.elevationDegrees * (poseProjection.pitchImageSign >= 0 ? 1 : -1)
        )
    }

    private func sphericalDistanceDegrees(_ bearing: GimbalRelativeBearing, pose: GimbalPose) -> Double {
        sphericalDistanceDegrees(
            bearing,
            GimbalRelativeBearing(
                azimuthDegrees: pose.panDegrees,
                elevationDegrees: pose.pitchDegrees
            )
        )
    }

    private func sphericalDistanceDegrees(
        _ lhs: GimbalRelativeBearing,
        _ rhs: GimbalRelativeBearing
    ) -> Double {
        let azimuthDelta = angularDifference(lhs.azimuthDegrees, rhs.azimuthDegrees) * .pi / 180
        let lhsElevation = lhs.elevationDegrees * .pi / 180
        let rhsElevation = rhs.elevationDegrees * .pi / 180
        let cosine = sin(lhsElevation) * sin(rhsElevation)
            + cos(lhsElevation) * cos(rhsElevation) * cos(azimuthDelta)
        return acos(min(1, max(-1, cosine))) * 180 / .pi
    }
}

public struct SphericalAtlasCell: Codable, Equatable, Sendable {
    public let bearing: GimbalRelativeBearing
    public let lastObservedMilliseconds: Double?
    public let observationCount: Int
    public let unproductiveVisits: Int
    public let panoramaQuality: Double
    public let panoramaLastUpdatedMilliseconds: Double?
    public let placeFamiliarity: Double
    public let placeConflict: Double
    public let placeObservationCount: Int
    public let placeLastUpdatedMilliseconds: Double?
    public let expectedInformationGain: Double
}

public struct SphericalSceneAtlasSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let monotonicNS: UInt64
    public let kinematicEnvelope: GimbalKinematicEnvelope
    public let placeEmbeddingEncoder: String?
    public let placeEmbeddingRevision: Int?
    public let restoredPlaceCount: Int
    public let persistedPlaceCount: Int
    public let cells: [SphericalAtlasCell]
    public let entities: [EmbodimentSceneEntity]

    public var observedCellCount: Int {
        cells.reduce(0) { $0 + ($1.observationCount > 0 ? 1 : 0) }
    }
}

/// Thread-safe shared allocentric map for L0 motor planning and the cognitive
/// embodiment endpoint. Panorama quality may bias no-target exploration, but
/// pixels never become object or social motor evidence.
public final class SphericalSceneAtlasStore: @unchecked Sendable {
    private let lock = NSLock()
    private let kinematicEnvelope: GimbalKinematicEnvelope
    private var coverage: SpatialCoverageField
    private var entities: [String: EmbodimentSceneEntity] = [:]
    private var restoredPlaceCount = 0
    private let maximumEntities = 256

    public init(kinematicEnvelope: GimbalKinematicEnvelope = .obsbotTiny2Lite) {
        self.kinematicEnvelope = kinematicEnvelope
        coverage = SpatialCoverageField(kinematicEnvelope: kinematicEnvelope)
    }

    public func observe(
        pose: GimbalPose,
        horizontalFieldOfViewDegrees: Double,
        poseProjection: GimbalPoseProjection = .identity,
        cameraProjectionModel: CameraProjectionModel? = nil,
        at monotonicNS: UInt64
    ) {
        lock.lock()
        coverage.observe(
            pose: pose,
            horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
            poseProjection: poseProjection,
            cameraProjectionModel: cameraProjectionModel,
            at: monotonicNS
        )
        lock.unlock()
    }

    public func updateScene(_ newEntities: [EmbodimentSceneEntity]) {
        lock.lock()
        for entity in newEntities {
            if let current = entities[entity.sceneID],
               !entity.observedThisFrame,
               current.observedThisFrame,
               entity.lastSeenMilliseconds <= current.lastSeenMilliseconds {
                continue
            }
            entities[entity.sceneID] = entity
        }
        if entities.count > maximumEntities {
            let retained = entities.values.sorted { lhs, rhs in
                if lhs.observedThisFrame != rhs.observedThisFrame {
                    return lhs.observedThisFrame && !rhs.observedThisFrame
                }
                if lhs.lastSeenMilliseconds != rhs.lastSeenMilliseconds {
                    return lhs.lastSeenMilliseconds < rhs.lastSeenMilliseconds
                }
                return lhs.sceneID < rhs.sceneID
            }.prefix(maximumEntities)
            entities = Dictionary(uniqueKeysWithValues: retained.map { ($0.sceneID, $0) })
        }
        lock.unlock()
    }

    public func observePanorama(
        pose: GimbalPose,
        horizontalFieldOfViewDegrees: Double,
        frameQuality: Double,
        dynamicVisionRects: [NormalizedRect],
        poseProjection: GimbalPoseProjection,
        cameraProjectionModel: CameraProjectionModel? = nil,
        at monotonicNS: UInt64
    ) {
        lock.lock()
        coverage.observePanorama(
            pose: pose,
            horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
            frameQuality: frameQuality,
            dynamicVisionRects: dynamicVisionRects,
            poseProjection: poseProjection,
            cameraProjectionModel: cameraProjectionModel,
            at: monotonicNS
        )
        lock.unlock()
    }

    public func observePlace(
        embedding: PanoramaPlaceEmbedding,
        pose: GimbalPose,
        observationQuality: Double,
        at monotonicNS: UInt64
    ) -> SphericalPlaceRecognition? {
        lock.lock()
        defer { lock.unlock() }
        return coverage.observePlace(
            embedding: embedding,
            pose: pose,
            observationQuality: observationQuality,
            at: monotonicNS
        )
    }

    @discardableResult
    public func restorePlaceMemory(
        _ snapshot: SphericalPlaceMemorySnapshot,
        expectedEncoder: String,
        expectedRevision: Int
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = coverage.restorePlaceMemory(
            snapshot,
            expectedEncoder: expectedEncoder,
            expectedRevision: expectedRevision
        )
        restoredPlaceCount = count
        return count
    }

    public func placeMemorySnapshot(
        generatedAtUnixMilliseconds: UInt64
    ) -> SphericalPlaceMemorySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return coverage.placeMemorySnapshot(
            generatedAtUnixMilliseconds: generatedAtUnixMilliseconds
        )
    }

    public func sampleNextDirection(
        from pose: GimbalPose,
        at monotonicNS: UInt64,
        temperature: Double,
        uniform: Double
    ) -> SpatialCoverageDirection? {
        lock.lock()
        defer { lock.unlock() }
        return coverage.sampleNextDirection(
            from: pose,
            at: monotonicNS,
            temperature: temperature,
            uniform: uniform
        )
    }

    public func recordUnproductiveVisit(
        to direction: SpatialCoverageDirection,
        at monotonicNS: UInt64
    ) {
        lock.lock()
        coverage.recordUnproductiveVisit(to: direction, at: monotonicNS)
        lock.unlock()
    }

    public func snapshot(at monotonicNS: UInt64) -> SphericalSceneAtlasSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let embeddingIdentity = coverage.placeEmbeddingIdentity
        return SphericalSceneAtlasSnapshot(
            schemaVersion: 4,
            monotonicNS: monotonicNS,
            kinematicEnvelope: kinematicEnvelope,
            placeEmbeddingEncoder: embeddingIdentity?.encoder,
            placeEmbeddingRevision: embeddingIdentity?.revision,
            restoredPlaceCount: restoredPlaceCount,
            persistedPlaceCount: coverage.placeMemoryCount,
            cells: coverage.snapshot(at: monotonicNS),
            entities: entities.values.sorted { lhs, rhs in
                if lhs.observedThisFrame != rhs.observedThisFrame {
                    return lhs.observedThisFrame && !rhs.observedThisFrame
                }
                if lhs.lastSeenMilliseconds != rhs.lastSeenMilliseconds {
                    return lhs.lastSeenMilliseconds < rhs.lastSeenMilliseconds
                }
                return lhs.sceneID < rhs.sceneID
            }
        )
    }
}
