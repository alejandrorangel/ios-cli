import ArgumentParser
import Foundation
import IOSCore

struct ScreenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "Capture the screen of a simulator or device, or record a simulator's screen.",
        subcommands: [Capture.self, Record.self]
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

    struct Record: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Record a simulator's screen to an H.264 .mp4/.mov for a number of seconds.")

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Option(name: .shortAndLong, help: "Output file.")
        var output = "recording.mp4"

        @Option(help: "Seconds to record, counted from the first frame.")
        var duration: Double = 10

        struct Result: Encodable {
            let path: String
            let udid: String
            let seconds: Double
        }

        func validate() throws {
            if duration <= 0 || duration > 600 { throw ValidationError("--duration must be between 0 and 600 seconds.") }
        }

        func run() throws {
            let simulator = try SimControl.simulator(target.device, command: "screen record")
            let path = URL(fileURLWithPath: output).standardizedFileURL.path
            Docs.progress("Recording \(simulator.name) for \(duration) s…")
            try SimControl.record(simulator, to: path, seconds: duration)
            try Output.emit(Result(path: path, udid: simulator.udid, seconds: duration), json: global.json) {
                "Saved \(path) (\(duration) s) from \(simulator.name)"
            }
        }
    }
}
