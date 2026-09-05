import Foundation

/// Normalizes App Server's protocol status and an MCP tool's structured
/// result. A JSON-RPC item may be protocol-complete while the tool itself
/// reports `ok: false`, so diagnostics must preserve both layers.
public struct MCPToolCompletionDiagnostic: Equatable, Sendable {
    public let itemID: String?
    public let tool: String
    public let protocolStatus: String
    public let effectiveStatus: String
    public let error: String

    public static func parse(
        _ item: [String: Any],
        serverName: String = "soma_embodiment"
    ) -> Self? {
        guard item["type"] as? String == "mcpToolCall",
              item["server"] as? String == serverName,
              let tool = item["tool"] as? String,
              let status = item["status"] as? String else { return nil }
        let result = item["result"] as? [String: Any]
        let structured = result?["structuredContent"] as? [String: Any]
        let structuredOK = structured?["ok"] as? Bool
        let protocolError = ((item["error"] as? [String: Any])?["message"] as? String) ?? ""
        let toolError = (structured?["error"] as? String) ?? ""
        let error = protocolError.isEmpty ? toolError : protocolError
        return Self(
            itemID: item["id"] as? String,
            tool: String(tool.prefix(96)),
            protocolStatus: String(status.prefix(48)),
            effectiveStatus: structuredOK == false ? "failed" : String(status.prefix(48)),
            error: String(error.prefix(512))
        )
    }
}
