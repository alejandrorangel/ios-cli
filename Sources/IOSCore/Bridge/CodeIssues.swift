import Foundation

/// One file's compiler diagnostics, as Xcode currently sees them.
public struct FileCheck: Codable, Sendable {
    /// The path as given (on disk).
    public let file: String
    /// The path in Xcode's project navigator.
    public let projectPath: String
    public let errors: Int
    public let warnings: Int
    /// Errors, warnings and notes; `file` is the on-disk path. Xcode reports lines but not columns.
    public let diagnostics: [Diagnostic]
}

public enum CodeIssues {
    /// Type-checks each file through Xcode's tool service (no full build): about 0.2–0.5 s per file.
    public static func check(_ container: Container, files: [String]) throws -> [FileCheck] {
        let bridge = try XcodeBridge()
        let workspace = try bridge.openWorkspace(container.path)
        return try files.map { file in
            let path = URL(fileURLWithPath: file).standardizedFileURL.path
            let navigatorPath = try Previews.projectPath(of: path, in: workspace, bridge: bridge)
            let result = try bridge.call("XcodeRefreshCodeIssuesInFile", ["workspaceIdentifier": workspace, "filePath": navigatorPath])
            guard result["success"] as? Bool != false, let content = result["content"] as? String else {
                throw IOSError.bridgeFailed(tool: "XcodeRefreshCodeIssuesInFile", message: result["content"] as? String ?? "no diagnostics returned")
            }
            let diagnostics = parse(content, file: path)
            return FileCheck(
                file: path, projectPath: navigatorPath,
                errors: diagnostics.filter { $0.severity == "error" }.count,
                warnings: diagnostics.filter { $0.severity == "warning" }.count,
                diagnostics: diagnostics
            )
        }
    }

    nonisolated(unsafe) private static let item = /^\d+\. \[(\w+)\] (?:\[Line: (\d+)\] )?(.*)$/

    /// Parses the tool's text: "Current issues in 'App/File.swift' (2 total):" then one numbered
    /// "N. [Error] [Line: 65] message" per issue; lines that don't start an item continue the last message.
    static func parse(_ content: String, file: String) -> [Diagnostic] {
        var items: [(severity: String, line: Int?, message: String)] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(raw)
            if let m = try? item.wholeMatch(in: text) {
                items.append((String(m.1).lowercased(), m.2.flatMap { Int($0) }, String(m.3)))
            } else if !items.isEmpty, !text.hasPrefix("Current issues in"), !text.hasPrefix("No issues found") {
                items[items.count - 1].message += "\n" + text.trimmingCharacters(in: .whitespaces)
            }
        }
        return items.map { Diagnostic(severity: $0.severity, message: $0.message, file: file, line: $0.line, column: nil) }
    }
}
