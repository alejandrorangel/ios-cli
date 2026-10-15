import Foundation

public struct Diagnostic: Codable, Equatable, Sendable {
    public let severity: String
    public let message: String
    public let file: String?
    public let line: Int?
    public let column: Int?

    public var summary: String {
        guard let file else { return "\(severity): \(message)" }
        guard let line else { return "\(file): \(severity): \(message)" }
        return "\(file):\(line):\(column ?? 0): \(severity): \(message)"
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
    /// The team passed with --team (nil: the project's own signing settings).
    public let team: String?
    /// What to do about a signing failure, when the errors show one.
    public let hint: String?
}

public struct BuildRequest: Sendable {
    public let container: Container
    public let scheme: String
    public let configuration: String?
    public let destination: Destination
    public let derivedDataPath: String?
    public let team: String?

    public init(container: Container, scheme: String, configuration: String?, destination: Destination,
                derivedDataPath: String?, team: String? = nil) {
        self.container = container
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
        self.derivedDataPath = derivedDataPath
        self.team = team
    }

    public var xcodebuildArguments: [String] {
        var arguments = ["xcodebuild", "build"] + container.xcodebuildArguments
        arguments += ["-scheme", scheme, "-destination", destination.xcodebuildValue]
        if let configuration { arguments += ["-configuration", configuration] }
        if let derivedDataPath { arguments += ["-derivedDataPath", derivedDataPath] }
        return arguments + Signing.arguments(team: team, destination: destination)
    }
}

/// Signing for app builds. ios-cli never picks a team for an app: the project's settings are used
/// unless --team is passed, because automatic signing registers the app's bundle ID in that team.
public enum Signing {
    /// Build settings for an explicit team, for this build only (the project isn't edited).
    /// Simulator builds don't sign with a team, so nothing is added for them.
    public static func arguments(team: String?, destination: Destination) -> [String] {
        guard let team, destination.sdk == "iphoneos" else { return [] }
        return ["DEVELOPMENT_TEAM=\(team)", "CODE_SIGN_STYLE=Automatic", "-allowProvisioningUpdates"]
    }

    /// A next step for signing errors in a build log's diagnostics.
    public static func hint(for errors: [Diagnostic], team: String?) -> String? {
        let messages = errors.map(\.message)
        if messages.contains(where: { $0.contains("requires a development team") }) {
            return "The project has no signing team for devices. Pass --team <TEAM_ID> (your team ID: Xcode → Settings → "
                + "Accounts, or developer.apple.com → Membership). It's used for this build only, and Xcode registers the "
                + "app's bundle ID in that team, so choose the team that should own the app."
        }
        if let message = messages.first(where: { $0.hasPrefix("No Account for Team") }) {
            return "Xcode isn't signed in to the team" + (team.map { " \($0)" } ?? "") + " (\(message.prefix { $0 != "." }))."
                + " Check the team ID, or add the account in Xcode → Settings → Accounts."
        }
        return nil
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
            log: log.path,
            team: Signing.arguments(team: request.team, destination: request.destination).isEmpty ? nil : request.team,
            hint: status == 0 ? nil : Signing.hint(for: errors, team: request.team)
        )
    }

    public static var defaultLogDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ios-cli/logs")
    }

    nonisolated(unsafe) private static let located = /^(.+?):(\d+):(\d+): (error|warning): (.+)$/
    /// Project-level problems, e.g. "/x/App.xcodeproj: error: Signing for "App" requires a development team."
    nonisolated(unsafe) private static let fileOnly = /^(\/.+?): (error|warning): (.+)$/
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
            } else if let m = try? fileOnly.wholeMatch(in: line) {
                diagnostic = Diagnostic(severity: String(m.2), message: String(m.3), file: String(m.1), line: nil, column: nil)
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
