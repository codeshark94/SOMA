import Foundation
import SOMACore

/// Thread-safe holder for the language detected from the participant's most
/// recent speech. L1 and L2 both read this so a person who speaks first in a
/// language is answered in that same language, even when they have no stored
/// preferred language.
final class L1ActiveLanguage: @unchecked Sendable {
    private let lock = NSLock()
    private var detected: String?
    private var lastDetectedAtNS: UInt64 = 0

    /// Detect the language of a finalized participant transcript and remember it
    /// if it is confident. Returns the detected tag, if any.
    @discardableResult
    func detectAndSet(from text: String) -> String? {
        guard let tag = LanguageDetector.detectTag(from: text) else { return nil }
        lock.lock()
        detected = tag
        lastDetectedAtNS = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        return tag
    }

    /// The currently detected language, or nil if none has been detected yet.
    func current() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return detected
    }

    /// The detected language if it was detected recently (within `windowNS`),
    /// otherwise nil. Lets a stale detection decay so a later quiet period does
    /// not keep forcing an old language.
    func recent(within windowNS: UInt64 = 30 * 60 * 1_000_000_000) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        guard let detected, now - lastDetectedAtNS <= windowNS else { return nil }
        return detected
    }
}
