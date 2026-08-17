import Foundation

/// The Codex app-server sandbox level used for L2 live-voice sessions. This
/// controls what the conversation agent may do to the local filesystem:
/// read-only is the safest, workspace-write allows edits inside the project,
/// and danger-full-access allows arbitrary file operations.
public enum SOMACodexSandbox: String, CaseIterable, Codable, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    public var label: String {
        switch self {
        case .readOnly: "Read-only"
        case .workspaceWrite: "Workspace write"
        case .dangerFullAccess: "Full access"
        }
    }
}
