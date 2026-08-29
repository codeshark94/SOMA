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

public struct AcousticOnsetEvidence: Sendable {
    public let triggered: Bool
    public let confidence: Double
    public let thresholdDB: Double
    public let transient: Bool
    public let estimatedLookbackNS: UInt64

    public init(
        triggered: Bool,
        confidence: Double,
        thresholdDB: Double,
        transient: Bool,
        estimatedLookbackNS: UInt64 = 0
    ) {
        self.triggered = triggered
        self.confidence = confidence
        self.thresholdDB = thresholdDB
        self.transient = transient
        self.estimatedLookbackNS = estimatedLookbackNS
    }
}

/// Detects a new acoustic event independently of speech classification.
///
/// Voice activity intentionally rejects clicks, claps, and many environmental
/// sounds. Auditory orienting needs the opposite behavior: a sharp transient
/// must be noticed immediately, while a quieter sustained sound should still
/// be admitted after a few audio packets. The adaptive floor is settled only
/// after the USB microphone leaves digital silence so device startup cannot be
/// mistaken for an event.
public final class AcousticOnsetGate: @unchecked Sendable {
    private let lock = NSLock()
    private var noiseFloorDB = -Double.infinity
    private var settlingUntilNS: UInt64 = 0
    private var sustainedAboveThresholdNS: UInt64 = 0
    private var cooldownUntilNS: UInt64 = 0
    private var previousLevelDB = -Double.infinity

    private let settlingDurationNS: UInt64
    private let sustainedDurationNS: UInt64
    private let cooldownDurationNS: UInt64

    public init(
        settlingMilliseconds: UInt64 = 500,
        sustainedMilliseconds: UInt64 = 30,
        cooldownMilliseconds: UInt64 = 1_200
    ) {
        precondition(settlingMilliseconds > 0)
        precondition(sustainedMilliseconds > 0)
        precondition(cooldownMilliseconds > 0)
        settlingDurationNS = settlingMilliseconds * 1_000_000
        sustainedDurationNS = sustainedMilliseconds * 1_000_000
        cooldownDurationNS = cooldownMilliseconds * 1_000_000
    }

    public func ingest(
        levelDB: Double,
        durationNS: UInt64,
        continuous: Bool,
        at monotonicNS: UInt64
    ) -> AcousticOnsetEvidence {
        lock.lock()
        defer { lock.unlock() }

        guard levelDB.isFinite, durationNS > 0 else {
            return AcousticOnsetEvidence(
                triggered: false,
                confidence: 0,
                thresholdDB: -34,
                transient: false
            )
        }

        if !continuous {
            sustainedAboveThresholdNS = 0
        }

        // UAC devices commonly emit digital silence while their processing
        // pipeline starts. Wait for the first physical noise floor before
        // beginning the settling interval.
        if levelDB <= -90 {
            previousLevelDB = levelDB
            return AcousticOnsetEvidence(
                triggered: false,
                confidence: 0,
                thresholdDB: -34,
                transient: false
            )
        }
        if !noiseFloorDB.isFinite {
            noiseFloorDB = levelDB
            previousLevelDB = levelDB
            settlingUntilNS = monotonicNS + settlingDurationNS
            return AcousticOnsetEvidence(
                triggered: false,
                confidence: 0,
                thresholdDB: min(levelDB + 7, -18),
                transient: false
            )
        }

        let thresholdDB = min(noiseFloorDB + 7, -18)
        if monotonicNS < settlingUntilNS {
            noiseFloorDB = noiseFloorDB * 0.92 + levelDB * 0.08
            previousLevelDB = levelDB
            sustainedAboveThresholdNS = 0
            return AcousticOnsetEvidence(
                triggered: false,
                confidence: 0,
                thresholdDB: thresholdDB,
                transient: false
            )
        }

        let levelRiseDB = previousLevelDB.isFinite ? levelDB - previousLevelDB : 0
        let transientThresholdDB = min(noiseFloorDB + 12, -13)
        let isTransient = levelDB >= transientThresholdDB && levelRiseDB >= 8
        if levelDB >= thresholdDB {
            sustainedAboveThresholdNS = min(
                sustainedDurationNS,
                sustainedAboveThresholdNS + durationNS
            )
        } else {
            sustainedAboveThresholdNS = 0
            // Follow slow room-noise changes, but never learn a candidate
            // event into the baseline that is meant to detect it.
            noiseFloorDB = noiseFloorDB * 0.985 + levelDB * 0.015
        }
        let isSustained = sustainedAboveThresholdNS >= sustainedDurationNS
        let canTrigger = monotonicNS >= cooldownUntilNS
        let triggered = canTrigger && (isTransient || isSustained)
        if triggered {
            cooldownUntilNS = monotonicNS + cooldownDurationNS
            sustainedAboveThresholdNS = 0
        }
        previousLevelDB = levelDB

        return AcousticOnsetEvidence(
            triggered: triggered,
            confidence: clamp((levelDB - thresholdDB + 6) / 18),
            thresholdDB: thresholdDB,
            transient: triggered && isTransient,
            estimatedLookbackNS: triggered
                ? (isTransient ? durationNS : sustainedDurationNS)
                : 0
        )
    }
}

private func clamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
}
