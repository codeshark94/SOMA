import Foundation

public struct VoiceActivityEvidence: Sendable {
    public let active: Bool
    public let confidence: Double
    public let thresholdDB: Double
    public let changed: Bool
}

public final class VoiceActivityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var noiseFloorDB = -60.0
    private var sustainedAboveThresholdNS: UInt64 = 0
    private var holdUntilNS: UInt64 = 0

    public init() {}

    public func ingest(levelDB: Double, durationNS: UInt64, continuous: Bool, at monotonicNS: UInt64) -> VoiceActivityEvidence {
        lock.lock()
        defer { lock.unlock() }

        if !active {
            noiseFloorDB = noiseFloorDB * 0.985 + levelDB * 0.015
        }
        let thresholdDB = max(noiseFloorDB + 16, -34)
        let previous = active

        if !continuous {
            active = false
            sustainedAboveThresholdNS = 0
            holdUntilNS = 0
        }

        if levelDB >= thresholdDB {
            if active {
                holdUntilNS = monotonicNS + 520_000_000
            } else {
                sustainedAboveThresholdNS = min(96_000_000, sustainedAboveThresholdNS + durationNS)
                if sustainedAboveThresholdNS >= 96_000_000 {
                    active = true
                    holdUntilNS = monotonicNS + 520_000_000
                }
            }
        } else {
            sustainedAboveThresholdNS = 0
            if active, monotonicNS >= holdUntilNS {
                active = false
            }
        }

        let confidence = clamp((levelDB - thresholdDB + 10) / 22)
        return VoiceActivityEvidence(
            active: active,
            confidence: confidence,
            thresholdDB: thresholdDB,
            changed: active != previous
        )
    }
}

private func clamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
}
