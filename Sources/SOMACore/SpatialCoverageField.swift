import Foundation

/// A spherical viewing direction chosen because it has not recently been
/// covered by the camera field of view. This is L0 spatial novelty, not an
/// object identity claim.
public struct SpatialCoverageDirection: Sendable {
    public let bearing: GimbalRelativeBearing
    public let probability: Double

    public init(bearing: GimbalRelativeBearing, probability: Double) {
        self.bearing = bearing
        self.probability = min(max(probability, 0), 1)
    }
}

/// Acceleration-limited velocity state for continuous no-target exploration.
/// A new spatial waypoint changes the desired velocity, but never steps the
/// physical command directly from one direction to the other.
public struct SmoothExplorationVelocity: Equatable, Sendable {
    public let pitchDegreesPerSecond: Double
    public let panDegreesPerSecond: Double
}

/// Plans the shortest direct route in finite pan/pitch joint space to a camera
/// pose whose FOV contains the requested world bearing. The admissible joint
/// envelope is convex, so this route never wraps through a mechanical limit.
public enum GimbalVisibilityRoutePlanner {
    public static func guide(
        to target: GimbalRelativeBearing,
        from pose: GimbalPose,
        horizontalFieldOfViewDegrees: Double = 86,
        aspectRatio: Double = 16.0 / 9.0,
        maximumPanCenterDegrees: Double = 110,
        maximumPitchCenterDegrees: Double = 24,
        horizontalViewMarginDegrees: Double = 8,
        verticalViewMarginDegrees: Double = 6
    ) -> GimbalRelativeBearing? {
        let horizontalHalf = max(1, min(horizontalFieldOfViewDegrees, 170)) / 2
        let horizontalHalfRadians = horizontalHalf * .pi / 180
        let verticalHalf = atan(tan(horizontalHalfRadians) / max(aspectRatio, 0.1)) * 180 / .pi
        let usableHorizontalHalf = horizontalHalf - max(0, horizontalViewMarginDegrees)
        let usableVerticalHalf = verticalHalf - max(0, verticalViewMarginDegrees)
        guard usableHorizontalHalf > 0, usableVerticalHalf > 0,
              let pan = nearestVisibleAxisPosition(
                target: target.azimuthDegrees,
                current: pose.panDegrees,
                visibleHalfWidth: usableHorizontalHalf,
                limit: maximumPanCenterDegrees
              ),
              let pitch = nearestVisibleAxisPosition(
                target: target.elevationDegrees,
                current: pose.pitchDegrees,
                visibleHalfWidth: usableVerticalHalf,
                limit: maximumPitchCenterDegrees
              ) else {
            return nil
        }
        return GimbalRelativeBearing(azimuthDegrees: pan, elevationDegrees: pitch)
    }

    private static func nearestVisibleAxisPosition(
        target: Double,
        current: Double,
        visibleHalfWidth: Double,
        limit: Double
    ) -> Double? {
        let lower = max(-abs(limit), target - visibleHalfWidth)
        let upper = min(abs(limit), target + visibleHalfWidth)
        guard lower <= upper else { return nil }
        return min(max(current, lower), upper)
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
        maximumPitchDegreesPerSecond: Double = 30
    ) -> Double {
        let panTravel = abs(panErrorDegrees) / maximumPanDegreesPerSecond
        let pitchTravel = abs(pitchErrorDegrees) / maximumPitchDegreesPerSecond
        return min(8, max(3.5, max(panTravel, pitchTravel) + 1.5))
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
        at monotonicNS: UInt64
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
                maximumChange: 80 * elapsed
            ),
            panDegreesPerSecond: slew(
                from: velocity.panDegreesPerSecond,
                to: desiredPan,
                maximumChange: 120 * elapsed
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
        var unproductiveVisits: Int
    }

    private var cells: [Cell]

    public init() {
        var initial: [Cell] = []
        // Explore a comfort-bounded spherical field. The former eye-level-only
        // row made every yaw look like a new place while repeatedly viewing
        // the same horizontal band. Five elevation layers cover above/below
        // the current FOV without permitting ceiling/floor extremes.
        for elevation in stride(from: -30.0, through: 30.0, by: 15.0) {
            for azimuth in stride(from: -108.0, through: 108.0, by: 18.0) {
                initial.append(Cell(
                    bearing: GimbalRelativeBearing(
                        azimuthDegrees: azimuth,
                        elevationDegrees: elevation
                    ),
                    lastObservedNS: nil,
                    unproductiveVisits: 0
                ))
            }
        }
        cells = initial
    }

    public mutating func observe(
        pose: GimbalPose,
        horizontalFieldOfViewDegrees: Double,
        at monotonicNS: UInt64,
        aspectRatio: Double = 16.0 / 9.0
    ) {
        let horizontalHalf = max(1, min(horizontalFieldOfViewDegrees, 170)) / 2
        let horizontalHalfRadians = horizontalHalf * .pi / 180
        let verticalHalf = atan(tan(horizontalHalfRadians) / max(aspectRatio, 0.1)) * 180 / .pi
        for index in cells.indices {
            let cell = cells[index].bearing
            guard abs(angularDifference(cell.azimuthDegrees, pose.panDegrees)) <= horizontalHalf,
                  abs(cell.elevationDegrees - pose.pitchDegrees) <= verticalHalf else {
                continue
            }
            cells[index].lastObservedNS = monotonicNS
        }
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
        return SpatialCoverageDirection(bearing: cells[index].bearing, probability: distribution.probabilities[index])
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
                return SpatialCoverageDirection(bearing: cells[index].bearing, probability: distribution.probabilities[index])
            }
        }
        return nil // explicit no-exploration alternative
    }

    /// A full look at a selected direction without an acquired target is
    /// evidence against immediately spending another exploration pulse there.
    public mutating func recordUnproductiveVisit(to direction: SpatialCoverageDirection) {
        guard let index = cells.indices.first(where: { cells[$0].bearing == direction.bearing }) else { return }
        cells[index].unproductiveVisits += 1
    }

    private func directionDistribution(
        from pose: GimbalPose,
        at monotonicNS: UInt64,
        temperature: Double
    ) -> (probabilities: [Double], noExplorationProbability: Double) {
        let revisitNS = 90_000_000_000.0
        let inverseTemperature = 1 / min(max(temperature, 0.35), 2.5)
        let likelihoods = cells.map { cell -> Double in
            let novelty: Double
            if let lastObservedNS = cell.lastObservedNS, monotonicNS >= lastObservedNS {
                novelty = min(1, Double(monotonicNS - lastObservedNS) / revisitNS)
            } else {
                novelty = 1
            }
            let distance = sphericalDistanceDegrees(cell.bearing, pose: pose)
            let failurePenalty = exp(-0.7 * Double(cell.unproductiveVisits))
            let elevationComfort = exp(-abs(cell.bearing.elevationDegrees) / 75)
            return pow(
                max(0.001, novelty * exp(-distance / 120) * failurePenalty * elevationComfort),
                inverseTemperature
            )
        }
        let noExplorationLikelihood = pow(0.03, inverseTemperature)
        let total = likelihoods.reduce(noExplorationLikelihood, +)
        let probabilities = likelihoods.map { $0 / total }
        return (probabilities, noExplorationLikelihood / total)
    }

    private func angularDifference(_ targetDegrees: Double, _ currentDegrees: Double) -> Double {
        var difference = (targetDegrees - currentDegrees).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference <= -180 { difference += 360 }
        return difference
    }

    private func sphericalDistanceDegrees(_ bearing: GimbalRelativeBearing, pose: GimbalPose) -> Double {
        let azimuthDelta = angularDifference(bearing.azimuthDegrees, pose.panDegrees) * .pi / 180
        let bearingElevation = bearing.elevationDegrees * .pi / 180
        let poseElevation = pose.pitchDegrees * .pi / 180
        let cosine = sin(bearingElevation) * sin(poseElevation)
            + cos(bearingElevation) * cos(poseElevation) * cos(azimuthDelta)
        return acos(min(1, max(-1, cosine))) * 180 / .pi
    }
}
