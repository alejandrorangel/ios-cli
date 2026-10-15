import Foundation

/// Minimal MCP client for Xcode 27's tool service over `xcrun mcpbridge` (JSON-RPC on stdio).
/// The tools run in the background "Xcode Service", so no Xcode window is needed.
///
/// Xcode asks the user to approve each client binary (and each project folder) once; until then
/// calls fail with "isn't approved", which becomes `IOSError.bridgeNotApproved`.
public final class XcodeBridge {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1

    public init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["mcpbridge"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        _ = try request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
            "clientInfo": ["name": "ios-cli", "version": "0.5.1"],
        ])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    /// Calls a tool and returns its structured result; tool errors are thrown.
    @discardableResult
    public func call(_ tool: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let result = try request("tools/call", ["name": tool, "arguments": arguments])
        let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        if result["isError"] as? Bool == true {
            throw Self.toolError(tool, text: text)
        }
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        // Some tools answer with JSON text instead of structuredContent.
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return ["text": text]
    }

    /// Opens (or finds the already open) workspace or project; returns its workspace identifier,
    /// which other tools need (passing the path instead doesn't work, despite the schema).
    public func openWorkspace(_ path: String) throws -> String {
        let result = try call("XcodeOpenWorkspace", ["path": path])
        guard let identifier = result["workspaceIdentifier"] as? String else {
            throw IOSError.bridgeFailed(tool: "XcodeOpenWorkspace", message: result["message"] as? String ?? "no workspace identifier")
        }
        return identifier
    }

    static func toolError(_ tool: String, text: String) -> IOSError {
        // Errors arrive as plain text or as {"type":"error","data":"…"}.
        var message = text
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = object["data"] as? String {
            message = detail
        }
        if message.contains("isn't approved") || message.contains("not approved") {
            return .bridgeNotApproved(detail: message)
        }
        return .bridgeFailed(tool: tool, message: message)
    }

    // MARK: JSON-RPC

    private func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            let message = try readMessage()
            guard message["id"] as? Int == id else { continue } // skip notifications
            if let error = message["error"] as? [String: Any] {
                throw IOSError.bridgeFailed(tool: method, message: error["message"] as? String ?? "\(error)")
            }
            return message["result"] as? [String: Any] ?? [:]
        }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readMessage() throws -> [String: Any] {
        let handle = output.fileHandleForReading
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return object }
                continue
            }
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                throw IOSError.bridgeFailed(tool: "mcpbridge", message: "the bridge exited (is Xcode 27 installed and selected with xcode-select?)")
            }
            buffer.append(chunk)
        }
    }
}
