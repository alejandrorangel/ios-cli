import ArgumentParser
import Foundation
import IOSCore

struct ScreenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "Capture the screen of a simulator or device.",
        subcommands: [Capture.self]
    )

    struct Capture: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a PNG screenshot.")

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Option(name: .shortAndLong, help: "Output file.")
        var output = "screenshot.png"

        struct Result: Encodable {
            let path: String
            let udid: String
        }

        func run() throws {
            let resolved = try TargetResolver.resolve(target.device)
            let path = URL(fileURLWithPath: output).standardizedFileURL.path
            try Screen.capture(resolved, to: path)
            try Output.emit(Result(path: path, udid: resolved.udid), json: global.json) {
                "Saved \(path) from \(resolved.label)"
            }
        }
    }
}
