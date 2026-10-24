import Foundation

/// Minimal MCP server over newline-delimited JSON-RPC. stdout carries JSON-RPC lines only.
public final class MCPServer {
    private let tools: CompanyTools
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Runs before every tool call (the redactor reload in `brahma mcp`).
    /// Runs before every tool call (`brahma mcp` reloads secrets here: `Store.prepareForToolCall`); a throw refuses the call
    /// with the error's text as the tool error.
    private let beforeCall: @Sendable () throws -> Void

    public init(tools: CompanyTools, beforeCall: @escaping @Sendable () throws -> Void = {}) {
        self.tools = tools; self.beforeCall = beforeCall
    }

    /// One JSON-RPC response line, or nil for notifications (and blank lines).
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              let request = message.objectValue else {
            return respond(id: .null, error: (-32700, "Parse error"))
        }
        // No id means notification: never answered.
        guard let id = request["id"] else { return nil }
        guard let method = request["method"]?.stringValue else {
            return respond(id: id, error: (-32600, "Invalid Request"))
        }
        let params = request["params"]?.objectValue ?? [:]
        switch method {
        case "initialize":
            let version = params["protocolVersion"]?.stringValue ?? "2025-06-18"
            return respond(id: id, result: .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("brahma"), "version": .string("0.1.0")]),
            ]))
        case "ping":
            return respond(id: id, result: .object([:]))
        case "tools/list":
            let specs = tools.specs().compactMap { spec -> JSONValue? in
                guard let data = try? encoder.encode(spec) else { return nil }
                return try? JSONDecoder().decode(JSONValue.self, from: data)
            }
            return respond(id: id, result: .object(["tools": .array(specs)]))
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return respond(id: id, error: (-32602, "Invalid params: missing tool name"))
            }
            let args = params["arguments"]?.objectValue ?? [:]
            let text: String, isError: Bool
            do { try beforeCall(); text = try tools.call(name: name, arguments: args); isError = false }
            catch let e as ToolError { text = e.message; isError = true }
            catch { text = "\(error)"; isError = true }
            return respond(id: id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "isError": .bool(isError),
            ]))
        default:
            return respond(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    /// Reads lines until EOF, writing each response immediately.
    public func serve(input: FileHandle, output: FileHandle) {
        var buffer = Data()
        func emit(_ line: String) -> Bool {
            guard let response = handle(line: line) else { return true }
            do { try output.write(contentsOf: Data((response + "\n").utf8)); return true }
            catch { return false }
        }
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if !emit(String(decoding: lineData, as: UTF8.self)) { return }
            }
        }
        if !buffer.isEmpty { _ = emit(String(decoding: buffer, as: UTF8.self)) }
    }

    private func respond(id: JSONValue, result: JSONValue) -> String {
        encode(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func respond(id: JSONValue, error: (Int, String)) -> String {
        encode(["jsonrpc": .string("2.0"), "id": id,
                "error": .object(["code": .number(Double(error.0)), "message": .string(error.1)])])
    }

    private func encode(_ v: [String: JSONValue]) -> String {
        let data = (try? encoder.encode(JSONValue.object(v))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
