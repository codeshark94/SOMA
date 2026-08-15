import Foundation

public struct LiveVoiceLaunchGate: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case inactive
        case starting
        case active
    }

    public private(set) var phase: Phase = .inactive
    public private(set) var retryAfterNS: UInt64 = 0

    public init() {}

    public mutating func beginLaunch(at monotonicNS: UInt64) -> Bool {
        guard phase == .inactive, monotonicNS >= retryAfterNS else { return false }
        phase = .starting
        return true
    }

    public mutating func observeActive() {
        phase = .active
        retryAfterNS = 0
    }

    public mutating func observeEnded() {
        phase = .inactive
        retryAfterNS = 0
    }

    public mutating func fail(
        at monotonicNS: UInt64,
        retryMilliseconds: UInt64 = 5_000
    ) {
        phase = .inactive
        let delta = retryMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        if delta.overflow {
            retryAfterNS = UInt64.max
            return
        }
        let deadline = monotonicNS.addingReportingOverflow(delta.partialValue)
        retryAfterNS = deadline.overflow ? UInt64.max : deadline.partialValue
    }
}

/// Owns the local lifetime of one active Live voice session. Only confirmed
/// user activity renews this lease; assistant speech must not keep an idle
/// microphone session alive indefinitely.
public struct LiveVoiceSessionInactivityGate: Equatable, Sendable {
    public let timeoutMilliseconds: UInt64
    public private(set) var deadlineNS: UInt64?

    public init(timeoutMilliseconds: UInt64 = 60_000) {
        precondition(timeoutMilliseconds > 0)
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    @discardableResult
    public mutating func activate(at monotonicNS: UInt64) -> UInt64 {
        renew(at: monotonicNS)
    }

    @discardableResult
    public mutating func recordUserActivity(at monotonicNS: UInt64) -> UInt64? {
        guard deadlineNS != nil else { return nil }
        return renew(at: monotonicNS)
    }

    public func shouldClose(at monotonicNS: UInt64) -> Bool {
        guard let deadlineNS else { return false }
        return monotonicNS >= deadlineNS
    }

    public mutating func close() {
        deadlineNS = nil
    }

    @discardableResult
    private mutating func renew(at monotonicNS: UInt64) -> UInt64 {
        let delta = timeoutMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        let result = monotonicNS.addingReportingOverflow(delta.partialValue)
        let deadline = delta.overflow || result.overflow ? UInt64.max : result.partialValue
        deadlineNS = deadline
        return deadline
    }
}
