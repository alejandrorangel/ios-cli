import ArgumentParser
import Foundation
import IOSCore

struct AppCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Control installed apps on a simulator or device: list, launch, terminate, uninstall, open URLs.",
        subcommands: [List.self, Launch.self, Terminate.self, Uninstall.self, OpenURL.self]
    )

    struct Result: Encodable {
        let bundleIdentifier: String?
        let udid: String
        let message: String
    }

    static func emit(_ message: String, bundleID: String?, target: Target, json: Bool) throws {
        try Output.emit(Result(bundleIdentifier: bundleID, udid: target.udid, message: message), json: json) {
            "\(message) on \(target.label)"
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List installed apps (yours by default).")

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Flag(help: "Include system apps.")
        var all = false

        func run() throws {
            let resolved = try TargetResolver.resolve(target.device)
            let apps = try AppControl.list(on: resolved, includeSystem: all)
            try Output.emit(apps, json: global.json) {
                apps.isEmpty ? "No apps installed on \(resolved.label)." : Output.table(
                    [["BUNDLE ID", "NAME", "VERSION"] + (all ? ["KIND"] : [])]
                        + apps.map { [$0.bundleIdentifier, $0.name ?? "", $0.version ?? ""] + (all ? [$0.kind] : []) }
                )
            }
        }
    }

    struct Launch: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Launch an installed app (restarting it if running).")

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Option(help: "The app's bundle identifier.")
        var bundleID: String

        func run() throws {
            let resolved = try TargetResolver.resolve(target.device)
            try Launcher.prepare(resolved)
            let launch = try Launcher.launch(bundleID, on: resolved)
            try Output.emit(launch, json: global.json) {
                "Launched \(bundleID) on \(resolved.label)" + (launch.pid.map { " (pid \($0))" } ?? "")
            }
        }
    }

    struct Terminate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a running app.")

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Option(help: "The app's bundle identifier.")
        var bundleID: String

        func run() throws {
            let resolved = try TargetResolver.resolve(target.device)
            let stopped = try AppControl.terminate(bundleID, on: resolved)
            try AppCommand.emit(stopped ? "Terminated \(bundleID)" : "\(bundleID) wasn't running", bundleID: bundleID,
                                target: resolved, json: global.json)
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Uninstall an app and its data.")

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Option(help: "The app's bundle identifier.")
        var bundleID: String

        func run() throws {
            let resolved = try TargetResolver.resolve(target.device)
            try AppControl.uninstall(bundleID, on: resolved)
            try AppCommand.emit("Uninstalled \(bundleID)", bundleID: bundleID, target: resolved, json: global.json)
        }
    }

    struct OpenURL: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "open-url",
            abstract: "Open a URL as if tapped: deep links (myapp://…) and universal links go to the app that handles them."
        )

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Argument(help: "The URL, e.g. myapp://settings or https://example.com/item/42.")
        var url: String

        func validate() throws {
            guard let parsed = URL(string: url), parsed.scheme != nil else { throw ValidationError("'\(url)' isn't a URL with a scheme.") }
        }

        func run() throws {
            let resolved = try TargetResolver.resolve(target.device)
            try AppControl.openURL(url, on: resolved)
            try AppCommand.emit("Opened \(url)", bundleID: nil, target: resolved, json: global.json)
        }
    }
}
