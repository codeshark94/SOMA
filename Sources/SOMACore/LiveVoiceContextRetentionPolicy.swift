import Foundation

/// Bounds the backing reasoning context in a Live Voice session without
/// weakening the stable instruction prefix that carries persona, authority,
/// and the initial mental context.
public enum LiveVoiceContextRetentionPolicy {
    /// Backing Codex history after its carried instruction prefix. Compaction
    /// happens at turn boundaries and leaves enough recent dialogue for a
    /// natural spoken exchange.
    public static let backingAutoCompactTokenLimit = 12_000
    public static let backingAutoCompactTokenLimitScope = "body_after_prefix"

    public static let backingCompactionPrompt = """
    Compact this live spoken interaction into a terse working-memory handoff. Preserve the participant's current goal, unresolved questions, explicit constraints and corrections, commitments already made, relevant successful or failed tool results, delegated task identifiers and status, newly stated person facts or preferences, and the immediate conversational thread needed for a natural next reply. Preserve uncertainty and distinguish observations from inferences. Drop transcript wording, repetitions, acknowledgements, filler, stale camera descriptions, obsolete tool advice, completed micro-steps, and superseded plans. Do not turn private developer context into participant speech. The stable system and developer prefix remains authoritative for SOMA's persona, language, permissions, embodiment contract, and durable-memory access.
    """
}
