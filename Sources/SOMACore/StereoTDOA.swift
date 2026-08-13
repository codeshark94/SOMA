import Foundation

public enum AudioDirection: String, Codable, Sendable {
    case left
    case center
    case right
    case unknown
}

public struct StereoTDOAMeasurement: Codable, Equatable, Sendable {
    public let sampleRateHz: Double
    public let lagSamples: Int
    public let fractionalLagSamples: Double
    public let correlation: Double
    public let zeroLagCorrelation: Double

    public init(
        sampleRateHz: Double,
        lagSamples: Int,
        fractionalLagSamples: Double? = nil,
        correlation: Double,
        zeroLagCorrelation: Double? = nil
    ) {
        self.sampleRateHz = sampleRateHz
        self.lagSamples = lagSamples
        self.fractionalLagSamples = fractionalLagSamples ?? Double(lagSamples)
        self.correlation = correlation
        self.zeroLagCorrelation = zeroLagCorrelation ?? correlation
    }
}

public enum StereoTDOARejection: String, Equatable, Sendable {
    case invalidInput = "invalid_input"
    case lowEnergy = "low_energy"
    case ambiguousPeak = "ambiguous_peak"
}

public enum StereoTDOAMeasurementOutcome: Equatable, Sendable {
    case measurement(StereoTDOAMeasurement)
    case rejected(StereoTDOARejection)
}

public enum TDOACalibrationPosition: String, CaseIterable, Codable, Hashable, Sendable {
    case left
    case center
    case right
}

public struct TDOACalibrationDiagnostic: Equatable, Sendable {
    public let attempts: Int
    public let accepted: Int
    public let eligible: Int
    public let ambiguous: Int
    public let lowEnergy: Int
    public let invalidInput: Int
    public let medianLagSamples: Int?
    public let medianFractionalLagSamples: Double?
    public let medianZeroLagCorrelation: Double?

    public init(
        attempts: Int = 0,
        accepted: Int = 0,
        eligible: Int = 0,
        ambiguous: Int = 0,
        lowEnergy: Int = 0,
        invalidInput: Int = 0,
        medianLagSamples: Int? = nil,
        medianFractionalLagSamples: Double? = nil,
        medianZeroLagCorrelation: Double? = nil
    ) {
        self.attempts = attempts
        self.accepted = accepted
        self.eligible = eligible
        self.ambiguous = ambiguous
        self.lowEnergy = lowEnergy
        self.invalidInput = invalidInput
        self.medianLagSamples = medianLagSamples
        self.medianFractionalLagSamples = medianFractionalLagSamples
        self.medianZeroLagCorrelation = medianZeroLagCorrelation
    }
}

public struct TDOACalibrationDiagnostics: Sendable {
    private var outcomes: [TDOACalibrationPosition: [StereoTDOAMeasurementOutcome]] = [:]

    public init() {}

    public mutating func record(position: TDOACalibrationPosition, outcome: StereoTDOAMeasurementOutcome) {
        outcomes[position, default: []].append(outcome)
    }

    public func diagnostic(for position: TDOACalibrationPosition) -> TDOACalibrationDiagnostic {
        let outcomes = outcomes[position, default: []]
        let accepted = outcomes.compactMap { outcome -> StereoTDOAMeasurement? in
            guard case let .measurement(measurement) = outcome else { return nil }
            return measurement
        }
        let eligibleMeasurements = accepted
            .filter { $0.correlation >= StereoDirectionCalibration.minimumCorrelation }
        let eligibleLags = eligibleMeasurements.map(\.lagSamples).sorted()
        let eligibleFractionalLags = eligibleMeasurements.map(\.fractionalLagSamples).sorted()
        let eligibleZeroLagCorrelations = eligibleMeasurements.map(\.zeroLagCorrelation).sorted()
        return TDOACalibrationDiagnostic(
            attempts: outcomes.count,
            accepted: accepted.count,
            eligible: eligibleMeasurements.count,
            ambiguous: outcomes.count(where: { $0 == .rejected(.ambiguousPeak) }),
            lowEnergy: outcomes.count(where: { $0 == .rejected(.lowEnergy) }),
            invalidInput: outcomes.count(where: { $0 == .rejected(.invalidInput) }),
            medianLagSamples: eligibleLags.isEmpty ? nil : eligibleLags[eligibleLags.count / 2],
            medianFractionalLagSamples: eligibleFractionalLags.isEmpty ? nil : eligibleFractionalLags[eligibleFractionalLags.count / 2],
            medianZeroLagCorrelation: eligibleZeroLagCorrelations.isEmpty ? nil : eligibleZeroLagCorrelations[eligibleZeroLagCorrelations.count / 2]
        )
    }

    public func makeCalibration() -> StereoDirectionCalibration? {
        let allMeasurements = TDOACalibrationPosition.allCases.flatMap { position in
            outcomes[position, default: []].compactMap { outcome -> StereoTDOAMeasurement? in
                guard case let .measurement(measurement) = outcome else { return nil }
                return measurement
            }
        }
        let sampleRates = allMeasurements.map(\.sampleRateHz).sorted()
        guard !sampleRates.isEmpty else { return nil }
        let sampleRateHz = sampleRates[sampleRates.count / 2]
        return StereoDirectionCalibration.make(
            sampleRateHz: sampleRateHz,
            left: measurements(for: .left),
            center: measurements(for: .center),
            right: measurements(for: .right)
        )
    }

    private func measurements(for position: TDOACalibrationPosition) -> [StereoTDOAMeasurement] {
        outcomes[position, default: []].compactMap { outcome in
            guard case let .measurement(measurement) = outcome else { return nil }
            return measurement
        }
    }
}

public struct StereoDirectionCalibration: Codable, Equatable, Sendable {
    public static let minimumCorrelation = 0.45

    public let schemaVersion: Int
    public let sampleRateHz: Double
    public let leftLagSamples: Double
    public let centerLagSamples: Double
    public let rightLagSamples: Double

    public init(sampleRateHz: Double, leftLagSamples: Double, centerLagSamples: Double, rightLagSamples: Double) {
        self.schemaVersion = 1
        self.sampleRateHz = sampleRateHz
        self.leftLagSamples = leftLagSamples
        self.centerLagSamples = centerLagSamples
        self.rightLagSamples = rightLagSamples
    }

    public static func make(
        sampleRateHz: Double,
        left: [StereoTDOAMeasurement],
        center: [StereoTDOAMeasurement],
        right: [StereoTDOAMeasurement]
    ) -> StereoDirectionCalibration? {
        guard sampleRateHz > 0,
              let leftLag = medianLag(left, sampleRateHz: sampleRateHz),
              let centerLag = medianLag(center, sampleRateHz: sampleRateHz),
              let rightLag = medianLag(right, sampleRateHz: sampleRateHz),
              abs(leftLag - rightLag) >= 1 else {
            return nil
        }
        return StereoDirectionCalibration(
            sampleRateHz: sampleRateHz,
            leftLagSamples: leftLag,
            centerLagSamples: centerLag,
            rightLagSamples: rightLag
        )
    }

    private static func medianLag(_ measurements: [StereoTDOAMeasurement], sampleRateHz: Double) -> Double? {
        let values = measurements
            .filter { abs($0.sampleRateHz - sampleRateHz) / sampleRateHz <= 0.05 && $0.correlation >= minimumCorrelation }
            .map(\.fractionalLagSamples)
            .sorted()
        guard values.count >= 3 else { return nil }
        return values[values.count / 2]
    }
}

public struct AudioDirectionEvidence: Codable, Equatable, Sendable {
    public let direction: AudioDirection
    public let confidence: Double
    public let lagSamples: Int?
    public let fractionalLagSamples: Double?
    public let delayMilliseconds: Double?
    public let correlation: Double?

    public init(
        direction: AudioDirection,
        confidence: Double,
        lagSamples: Int? = nil,
        fractionalLagSamples: Double? = nil,
        delayMilliseconds: Double? = nil,
        correlation: Double? = nil
    ) {
        self.direction = direction
        self.confidence = min(max(confidence, 0), 1)
        self.lagSamples = lagSamples
        self.fractionalLagSamples = fractionalLagSamples
        self.delayMilliseconds = delayMilliseconds
        self.correlation = correlation
    }
}

public struct StereoTDOAEstimator: Sendable {
    private let calibration: StereoDirectionCalibration?

    public init(calibration: StereoDirectionCalibration?) {
        self.calibration = calibration
    }

    public func estimate(left: [Float], right: [Float], sampleRateHz: Double) -> AudioDirectionEvidence {
        guard let calibration,
              sampleRateHz > 0,
              abs(sampleRateHz - calibration.sampleRateHz) / calibration.sampleRateHz <= 0.05,
              let measurement = Self.measure(left: left, right: right, sampleRateHz: sampleRateHz),
              measurement.correlation >= 0.45 else {
            return AudioDirectionEvidence(direction: .unknown, confidence: 0)
        }
        let halfSpan = (calibration.rightLagSamples - calibration.leftLagSamples) / 2
        guard abs(halfSpan) >= 0.5 else {
            return AudioDirectionEvidence(direction: .unknown, confidence: 0)
        }
        let position = min(max((measurement.fractionalLagSamples - calibration.centerLagSamples) / halfSpan, -1), 1)
        let direction: AudioDirection
        if position <= -0.25 {
            direction = .left
        } else if position >= 0.25 {
            direction = .right
        } else {
            direction = .center
        }
        let confidence = min(max((measurement.correlation - 0.45) / 0.45, 0), 1)
        return AudioDirectionEvidence(
            direction: direction,
            confidence: confidence,
            lagSamples: measurement.lagSamples,
            fractionalLagSamples: measurement.fractionalLagSamples,
            delayMilliseconds: measurement.fractionalLagSamples / sampleRateHz * 1_000,
            correlation: measurement.correlation
        )
    }

    public static func measure(left: [Float], right: [Float], sampleRateHz: Double) -> StereoTDOAMeasurement? {
        switch assess(left: left, right: right, sampleRateHz: sampleRateHz) {
        case let .measurement(measurement): return measurement
        case .rejected: return nil
        }
    }

    public static func assess(left: [Float], right: [Float], sampleRateHz: Double) -> StereoTDOAMeasurementOutcome {
        guard sampleRateHz > 0, left.count == right.count, left.count >= 64 else {
            return .rejected(.invalidInput)
        }
        let count = left.count
        let meanLeft = left.reduce(0) { $0 + Double($1) } / Double(count)
        let meanRight = right.reduce(0) { $0 + Double($1) } / Double(count)
        let maximumLag = min(count / 4, max(1, Int((sampleRateHz * 0.001).rounded())))
        var candidates: [(lag: Int, correlation: Double)] = []

        for lag in -maximumLag...maximumLag {
            let start = max(0, -lag)
            let end = min(count, count - lag)
            var product = 0.0
            var leftEnergy = 0.0
            var rightEnergy = 0.0
            for index in start..<end {
                let leftSample = Double(left[index]) - meanLeft
                let rightSample = Double(right[index + lag]) - meanRight
                product += leftSample * rightSample
                leftEnergy += leftSample * leftSample
                rightEnergy += rightSample * rightSample
            }
            guard leftEnergy > 0, rightEnergy > 0 else { continue }
            let correlation = abs(product / sqrt(leftEnergy * rightEnergy))
            candidates.append((lag: lag, correlation: correlation))
        }
        guard let bestIndex = candidates.indices.max(by: { candidates[$0].correlation < candidates[$1].correlation }) else {
            return .rejected(.lowEnergy)
        }
        let best = candidates[bestIndex]
        let competingCorrelation = candidates
            .filter { abs($0.lag - best.lag) > 1 }
            .map(\.correlation)
            .max() ?? 0
        guard best.correlation > 0 else { return .rejected(.lowEnergy) }
        guard best.correlation - competingCorrelation >= 0.015 else {
            return .rejected(.ambiguousPeak)
        }
        let fractionalOffset: Double
        if candidates.indices.contains(bestIndex - 1), candidates.indices.contains(bestIndex + 1) {
            let before = candidates[bestIndex - 1].correlation
            let after = candidates[bestIndex + 1].correlation
            let denominator = before - 2 * best.correlation + after
            if denominator < -Double.ulpOfOne {
                fractionalOffset = min(max(0.5 * (before - after) / denominator, -0.5), 0.5)
            } else {
                fractionalOffset = 0
            }
        } else {
            fractionalOffset = 0
        }
        let zeroLagCorrelation = candidates.first(where: { $0.lag == 0 })?.correlation ?? 0
        return .measurement(StereoTDOAMeasurement(
            sampleRateHz: sampleRateHz,
            lagSamples: best.lag,
            fractionalLagSamples: Double(best.lag) + fractionalOffset,
            correlation: best.correlation,
            zeroLagCorrelation: zeroLagCorrelation
        ))
    }
}
