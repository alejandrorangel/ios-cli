import Foundation

public enum IOSError: Error, CustomStringConvertible, Equatable {
    case toolFailed(command: String, status: Int32, stderr: String)
    case invalidOutput(tool: String, reason: String)
    case deviceNotFound(query: String, candidates: [String])
    case ambiguousDevice(query: String?, candidates: [String])
    case notImplemented(command: String, plan: String)
    case projectNotFound(directory: String)
    case ambiguousProject(directory: String, candidates: [String])
    case schemeRequired(schemes: [String])
    case schemeNotFound(scheme: String, schemes: [String])
    case noAppProduct(scheme: String)
    case buildFailed(log: String, errors: [String])
    case logsNeedBundleID
    case deviceLogsNeedLaunch
    case appNotInstalled(bundleID: String, udid: String)
    case notAnApp(path: String)
    case database(path: String, message: String)
    case download(url: String, message: String)
    case docNotFound(path: String)
    case symbolModuleUnavailable(module: String, detail: String)
    case runnerUnreachable(host: String, port: UInt16, reason: String)
    case runnerCommandFailed(command: String, message: String)
    case runnerNoReply(command: String, seconds: Int)
    case runnerStartFailed(log: String, detail: String)
    case runnerBuildFailed(log: String, errors: [String])
    case runnerTeamRequired(candidates: [String])
    case elementNotFound(query: String)
    case noAppSelected
    case appNotRunning(bundleID: String)
    case swiftUIDumpFailed(reason: String)
    case bridgeNotApproved(detail: String)
    case bridgeFailed(tool: String, message: String)
    case previewNotFound(name: String, available: [String], ambiguous: Bool)
    case skillNotFound(name: String, available: [String])
    case skillExists(path: String)
    case skillNotInstalled(name: String, directory: String)

    public var description: String {
        switch self {
        case let .previewNotFound(name, available, ambiguous):
            return (ambiguous ? "Several previews match '\(name)'; use a more specific name or --index."
                              : "No preview named '\(name)' in this file.") + Self.list(available, heading: "Previews")
        case let .skillNotFound(name, available):
            return "No skill named '\(name)'." + Self.list(available, heading: "Available")
        case let .skillExists(path):
            return "\(path) exists and wasn't installed by `ios skills`; pass --force to replace or remove it."
        case let .skillNotInstalled(name, directory):
            return "\(name) isn't installed in \(directory)."
        case let .bridgeNotApproved(detail):
            return """
                Xcode hasn't approved `ios` to use its tools yet. Opening or creating a project (`ios preview …`, \
                `ios create …`) makes Xcode ask; approve the dialog (or use Xcode's menu-bar extra, or \
                `sudo xcrun mcp-server approve --for-24-hours`), then retry.
                (\(detail.trimmingCharacters(in: .whitespacesAndNewlines)))
                """
        case let .bridgeFailed(tool, message):
            return "Xcode's \(tool) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .appNotRunning(bundleID):
            return "\(bundleID) isn't running. Start it with `ios layout --swiftui --relaunch --bundle-id \(bundleID)`."
        case let .swiftUIDumpFailed(reason):
            return "Couldn't read the SwiftUI tree (the app must be a debug build you can attach to): \(reason.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .runnerUnreachable(host, port, reason):
            return "Can't reach the UI automation runner at \(host):\(port): \(reason)"
        case let .runnerNoReply(command, seconds):
            return "`\(command.split(separator: " ").first ?? "")` was sent but the runner didn't reply within \(seconds) s, "
                + "so it may or may not have happened. Check with `ios layout`."
        case let .runnerCommandFailed(command, message):
            return "`\(command.split(separator: " ").first ?? "")` failed: \(message)"
        case let .runnerStartFailed(log, detail):
            return "The UI automation runner didn't start.\n\(detail)\nLog: \(log)"
        case let .runnerBuildFailed(log, errors):
            return "Building the UI automation runner failed." + Self.list(errors, heading: "Errors") + "\nLog: \(log)"
        case let .runnerTeamRequired(candidates):
            let base = "A physical device needs the runner signed by your development team; pass --team <TEAM_ID> or set IOS_CLI_TEAM."
            return base + (candidates.isEmpty ? "" : "\nTeams with a wildcard development profile for this device:" + Self.list(candidates))
        case let .elementNotFound(query):
            return "No visible element matches \(query). Run `ios layout` to see what's on screen."
        case .noAppSelected:
            return "No app selected for UI automation yet; pass --bundle-id."
        case let .database(path, message):
            return "Database error\(path.isEmpty ? "" : " (\(path))"): \(message)"
        case let .download(url, message):
            return "Download failed for \(url): \(message)"
        case let .docNotFound(path):
            return "No documentation page at \(path). Use `ios docs search` to find the right path."
        case let .symbolModuleUnavailable(module, detail):
            return "Couldn't read the SDK's symbols for module '\(module)' (module names are case-sensitive, e.g. SwiftUI)."
                + (detail.isEmpty ? "" : "\n\(detail)")
        case .logsNeedBundleID:
            return "Pass --bundle-id (or --process for simulator log streams) to choose whose logs to show."
        case .deviceLogsNeedLaunch:
            return "Reading a device's unified log needs root (`sudo log collect --device-udid …`). "
                + "Use --launch to relaunch the app with its console attached instead."
        case let .appNotInstalled(bundleID, udid):
            return "\(bundleID) isn't installed on \(udid)."
        case let .notAnApp(path):
            return "\(path) isn't an app bundle (no Info.plist with CFBundleIdentifier)."
        case let .projectNotFound(directory):
            return "No .xcworkspace, .xcodeproj or Package.swift in \(directory). Pass --workspace or --project."
        case let .ambiguousProject(directory, candidates):
            return "Several Xcode containers in \(directory); pass --workspace or --project." + Self.list(candidates)
        case let .schemeRequired(schemes):
            return "This project has several schemes; pass --scheme." + Self.list(schemes)
        case let .schemeNotFound(scheme, schemes):
            return "No scheme named '\(scheme)'." + Self.list(schemes)
        case let .noAppProduct(scheme):
            return "Scheme '\(scheme)' doesn't build an app, so there's nothing to install or launch."
        case let .buildFailed(log, errors):
            let shown = errors.prefix(10).map { "  \($0)" }.joined(separator: "\n")
            return "Build failed." + (shown.isEmpty ? "" : "\n\(shown)") + "\nFull log: \(log)"
        case let .toolFailed(command, status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(command)` exited with status \(status)" + (detail.isEmpty ? "" : ":\n\(detail)")
        case let .invalidOutput(tool, reason):
            return "Unexpected output from \(tool): \(reason)"
        case let .deviceNotFound(query, candidates):
            return "No simulator or device matches '\(query)'." + Self.list(candidates)
        case let .ambiguousDevice(query, candidates):
            let what = query.map { "'\($0)' matches" } ?? "No --device given and there are"
            return "\(what) several targets; pass --device <udid>." + Self.list(candidates)
        case let .notImplemented(command, plan):
            return "`ios \(command)` is not implemented yet (\(plan) in PLAN.md)."
        }
    }

    private static func list(_ items: [String], heading: String = "Candidates") -> String {
        items.isEmpty ? "" : "\n\(heading):\n" + items.map { "  \($0)" }.joined(separator: "\n")
    }
}
