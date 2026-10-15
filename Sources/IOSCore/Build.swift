import Foundation

public struct Diagnostic: Codable, Equatable, Sendable {
    public let severity: String
    public let message: String
    public let file: String?
    public let line: Int?
    public let column: Int?

    public var summary: String {
        guard let file else { return "\(severity): \(message)" }
        return "\(file):\(line ?? 0):\(column ?? 0): \(severity): \(message)"
    }
}

public struct BuildResult: Codable, Sendable {
    public let succeeded: Bool
    public let scheme: String
    public let destination: String
    public let duration: Double
    public let errors: [Diagnostic]
    public let warningCount: Int
    /// First warnings only, to keep agent context small; the full list is in the log.
    public let warnings: [Diagnostic]
    public let log: String
}

public struct BuildRequest: Sendable {
    public let container: Container
    public let scheme: String
    public let configuration: String?
    public let destination: Destination
    public let derivedDataPath: String?

    public init(container: Container, scheme: String, configuration: String?, destination: Destination, derivedDataPath: String?) {
        self.container = container
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
        self.derivedDataPath = derivedDataPath
    }

    public var xcodebuildArguments: [String] {
        var arguments = ["xcodebuild", "build"] + container.xcodebuildArguments
        arguments += ["-scheme", scheme, "-destination", destination.xcodebuildValue]
        if let configuration { arguments += ["-configuration", configuration] }
        if let derivedDataPath { arguments += ["-derivedDataPath", derivedDataPath] }
        return arguments
    }
}

public enum Builder {
    static let maxWarnings = 20

    /// Runs `xcodebuild build` with output in a log file, and summarizes the result.
    public static func build(_ request: BuildRequest, logDirectory: URL = defaultLogDirectory) throws -> BuildResult {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let log = logDirectory.appendingPathComponent("build-\(stamp)-\(suffix).log")
        let start = Date()
        let status = try Shell.run("/usr/bin/xcrun", request.xcodebuildArguments, log: log, in: request.container.workingDirectory)
        let duration = Date().timeIntervalSince(start)

        let diagnostics = parseDiagnostics((try? String(contentsOf: log, encoding: .utf8)) ?? "")
        let errors = diagnostics.filter { $0.severity == "error" }
        let warnings = diagnostics.filter { $0.severity == "warning" }
        return BuildResult(
            succeeded: status == 0,
            scheme: request.scheme,
            destination: request.destination.xcodebuildValue,
            duration: (duration * 10).rounded() / 10,
            errors: errors,
            warningCount: warnings.count,
            warnings: Array(warnings.prefix(maxWarnings)),
            log: log.path
        )
    }

    public static var defaultLogDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ios-cli/logs")
    }

    nonisolated(unsafe) private static let located = /^(.+?):(\d+):(\d+): (error|warning): (.+)$/
    nonisolated(unsafe) private static let bare = /^(?:xcodebuild: )?(error|warning): (.+)$/

    /// Extracts compiler/tool diagnostics from an xcodebuild log, de-duplicated
    /// (xcodebuild repeats each diagnostic in its summary).
    public static func parseDiagnostics(_ log: String) -> [Diagnostic] {
        var seen = Set<String>()
        var result: [Diagnostic] = []
        for raw in log.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let diagnostic: Diagnostic
            if let m = try? located.wholeMatch(in: line) {
                diagnostic = Diagnostic(severity: String(m.4), message: String(m.5), file: String(m.1),
                                        line: Int(m.2), column: Int(m.3))
            } else if let m = try? bare.wholeMatch(in: line) {
                diagnostic = Diagnostic(severity: String(m.1), message: String(m.2), file: nil, line: nil, column: nil)
            } else {
                continue
            }
            if seen.insert(diagnostic.summary).inserted { result.append(diagnostic) }
        }
        return result
    }
}
