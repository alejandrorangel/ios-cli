import ArgumentParser
import Foundation
import IOSCore

/// Calls one of Xcode's tools with the project in the current directory (when there is one) and
/// prints its answer: the text Xcode returns, or its JSON with --json.
func callXcodeTool(_ tool: String, _ arguments: [String: Any], workspace: String?, project: String?, json: Bool) throws {
    let bridge = try XcodeBridge()
    var arguments = arguments
    if let container = try? ProjectLocator.locate(workspace: workspace, project: project, directory: FileManager.default.currentDirectoryPath) {
        arguments["workspaceIdentifier"] = try bridge.openWorkspace(container.path)
    }
    let result = try bridge.call(tool, arguments)
    if result["success"] as? Bool == false {
        throw IOSError.bridgeFailed(tool: tool, message: result["message"] as? String ?? "failed")
    }
    if json || result["text"] == nil {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(result["text"] as? String ?? "")
    }
}

struct SignalsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "signals",
        abstract: "Crashes and performance problems your users hit, from Apple's crash and field reports (App Store and TestFlight).",
        discussion: """
        Asks Xcode (the Organizer's data; sign in to your developer account in Xcode first). Run it in the \
        project's folder, or pass --bundle-id. `ios crashes` reads crash reports on a simulator or device instead.
        """,
        subcommands: [Crashes.self, Crash.self, Performance.self, PerformanceIssue.self]
    )

    struct Source: ParsableArguments {
        @Option(help: "The app's bundle identifier (default: the active scheme's app).") var bundleId: String?
        @Option(help: "Only this app version, e.g. 8.1.0.") var appVersion: String?
        @Flag(help: "TestFlight data only.") var beta = false
        @Flag(help: "App Store data only.") var appStore = false
        @Option(help: "Path to an .xcworkspace (default: the one in the current directory).") var workspace: String?
        @Option(help: "Path to an .xcodeproj.") var project: String?

        func validate() throws {
            if beta && appStore { throw ValidationError("Pass --beta or --app-store, not both.") }
        }

        var arguments: [String: Any] {
            var out: [String: Any] = ["platform": "iOS"]
            if let bundleId { out["bundle_id"] = bundleId }
            if let appVersion { out["app_version"] = appVersion }
            if beta || appStore { out["is_beta"] = beta }
            return out
        }
    }

    struct Crashes: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Top crash signatures of the last 14 days, by devices affected.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var source: Source
        @Option(help: "How many signatures.") var count = 5

        func run() throws {
            var arguments = source.arguments
            arguments["count"] = count
            try callXcodeTool("GetTopCrashIssues", arguments, workspace: source.workspace, project: source.project, json: global.json)
        }
    }

    struct Crash: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Crash logs and triage notes for one signature from `ios signals crashes`.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var source: Source
        @Argument(help: "The signature name, as `ios signals crashes` printed it.") var signature: String

        func run() throws {
            var arguments = source.arguments
            arguments["signature_name"] = signature
            try callXcodeTool("GetCrashIssueLogs", arguments, workspace: source.workspace, project: source.project, json: global.json)
        }
    }

    static let diagnosticTypes = ["launches", "hangs", "diskwrites", "energy"]

    struct Performance: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Top field performance issues: launches, hangs, disk writes or energy.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var source: Source
        @Option(help: "launches, hangs, diskwrites or energy.") var type: String

        func validate() throws {
            guard SignalsCommand.diagnosticTypes.contains(type) else { throw ValidationError("--type must be launches, hangs, diskwrites or energy.") }
        }

        func run() throws {
            var arguments = source.arguments
            arguments["diagnostic_type"] = type
            try callXcodeTool("GetTopFieldPerformanceIssues", arguments, workspace: source.workspace, project: source.project, json: global.json)
        }
    }

    struct PerformanceIssue: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "performance-issue",
                                                        abstract: "Logs and triage notes for one issue from `ios signals performance`.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var source: Source
        @Option(help: "launches, hangs, diskwrites or energy.") var type: String
        @Argument(help: "The signature name, as `ios signals performance` printed it.") var signature: String

        func validate() throws {
            guard SignalsCommand.diagnosticTypes.contains(type) else { throw ValidationError("--type must be launches, hangs, diskwrites or energy.") }
            if source.appVersion == nil { throw ValidationError("Pass --app-version (from `ios signals performance`).") }
        }

        func run() throws {
            var arguments = source.arguments
            arguments["diagnostic_type"] = type
            arguments["signature_name"] = signature
            try callXcodeTool("GetFieldPerformanceIssueLogs", arguments, workspace: source.workspace, project: source.project, json: global.json)
        }
    }
}
