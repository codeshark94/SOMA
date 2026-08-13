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
    public let correlation: Double

    public init(sampleRateHz: Double, lagSamples: Int, correlation: Double) {
        self.sampleRateHz = sampleRateHz
        self.lagSamples = lagSamples
        self.correlation = correlation
    }
}

public struct StereoDirectionCalibration: Codable, Equatable, Sendable {
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
            .filter { abs($0.sampleRateHz - sampleRateHz) / sampleRateHz <= 0.05 && $0.correlation >= 0.45 }
            .map { Double($0.lagSamples) }
            .sorted()
        guard values.count >= 3 else { return nil }
        return values[values.count / 2]
    }
}

public struct AudioDirectionEvidence: Codable, Equatable, Sendable {
    public let direction: AudioDirection
    public let confidence: Double
    public let lagSamples: Int?
    public let delayMilliseconds: Double?
    public let correlation: Double?

    public init(
        direction: AudioDirection,
        confidence: Double,
        lagSamples: Int? = nil,
        delayMilliseconds: Double? = nil,
        correlation: Double? = nil
    ) {
        self.direction = direction
        self.confidence = min(max(confidence, 0), 1)
        self.lagSamples = lagSamples
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
        let position = min(max((Double(measurement.lagSamples) - calibration.centerLagSamples) / halfSpan, -1), 1)
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
            delayMilliseconds: Double(measurement.lagSamples) / sampleRateHz * 1_000,
            correlation: measurement.correlation
        )
    }

    public static func measure(left: [Float], right: [Float], sampleRateHz: Double) -> StereoTDOAMeasurement? {
        guard sampleRateHz > 0, left.count == right.count, left.count >= 64 else { return nil }
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
        guard let best = candidates.max(by: { $0.correlation < $1.correlation }) else { return nil }
        let competingCorrelation = candidates
            .filter { abs($0.lag - best.lag) > 1 }
            .map(\.correlation)
            .max() ?? 0
        guard best.correlation > 0, best.correlation - competingCorrelation >= 0.015 else { return nil }
        return StereoTDOAMeasurement(sampleRateHz: sampleRateHz, lagSamples: best.lag, correlation: best.correlation)
    }
}
