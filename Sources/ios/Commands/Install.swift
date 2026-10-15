import ArgumentParser
import Foundation
import IOSCore

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install an .app bundle on a simulator or device.",
        discussion: "Boots the simulator first if it's shut down. Use `ios describe --scheme S` to find a built app's path."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var target: TargetOptions

    @Argument(help: "Path to the .app bundle.")
    var app: String

    @Flag(help: "Launch the app after installing (restarting it if running).")
    var launch = false

    struct Result: Encodable {
        let bundleIdentifier: String
        let path: String
        let udid: String
        let launch: LaunchResult?
    }

    func run() throws {
        let path = URL(fileURLWithPath: app).standardizedFileURL.path
        let bundleID = try Launcher.bundleIdentifier(ofApp: path)
        let resolved = try TargetResolver.resolve(target.device)
        try Launcher.prepare(resolved)
        try Launcher.install(path, on: resolved)
        let launched = launch ? try Launcher.launch(bundleID, on: resolved) : nil

        try Output.emit(Result(bundleIdentifier: bundleID, path: path, udid: resolved.udid, launch: launched), json: global.json) {
            var text = "Installed \(bundleID) on \(resolved.label)"
            if let launched { text += "\nLaunched" + (launched.pid.map { " (pid \($0))" } ?? "") }
            return text
        }
    }
}
