import ArgumentParser
import Foundation
import IOSCore

struct ScreenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "Capture the screen of a simulator or device, or record a simulator's screen.",
        subcommands: [Capture.self, Resolve.self, Record.self]
    )

    struct Capture: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a PNG screenshot.",
            discussion: """
            --annotate draws a numbered box around each element `ios layout` lists, with the same [N], and \
            prints the list. Use it to find an element by how it looks (an icon with no label), then \
            `ios input tap --index N`, or `ios screen resolve` to turn "#N" into coordinates later.
            """
        )

        @OptionGroup var global: GlobalOptions
        @OptionGroup var automation: AutomationOptions

        @Option(name: .shortAndLong, help: "Output file.")
        var output = "screenshot.png"

        @Flag(name: .shortAndLong, help: "Draw numbered boxes around the elements `ios layout` lists (uses the UI automation runner).")
        var annotate = false

        struct Result: Encodable {
            let path: String
            let udid: String
            let elements: [LayoutElement]?
        }

        func run() throws {
            let resolved = try TargetResolver.resolve(automation.device)
            let path = URL(fileURLWithPath: output).standardizedFileURL.path
            var elements: [LayoutElement]?
            if annotate {
                // Read the elements first: starting the runner can bring the app forward.
                let tree = try snapshot(automation.session())
                elements = Layout.flatten(tree)
                try Screen.capture(resolved, to: path)
                try Annotate.draw(elements ?? [], screen: Layout.screen(of: tree), png: path)
            } else {
                try Screen.capture(resolved, to: path)
            }
            try Output.emit(Result(path: path, udid: resolved.udid, elements: elements), json: global.json) {
                var lines = ["Saved \(path) from \(resolved.label)"]
                if let elements {
                    lines += elements.isEmpty ? ["No visible elements to number (the app may still be loading)."] : elements.map(\.textLine)
                }
                return lines.joined(separator: "\n")
            }
        }
    }

    struct Resolve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replace each #N in a string with element N's tap point from an annotated screenshot.",
            discussion: """
            `ios screen resolve --screenshot shot.png "#3"` prints "x y". The points are the ones saved \
            when the screenshot was taken, so they're only right while the screen hasn't changed: \
            `ios input tap $(ios screen resolve --screenshot shot.png "#12")`.
            """
        )

        @OptionGroup var global: GlobalOptions

        @Option(help: "A PNG saved by `ios screen capture --annotate`.")
        var screenshot: String

        @Argument(help: "Text containing #N references, e.g. \"#3\" or \"#3 #7\".")
        var string: String

        struct Result: Encodable {
            let resolved: String
        }

        func run() throws {
            let resolved = try Annotate.resolve(string, marks: Annotate.marks(in: screenshot))
            try Output.emit(Result(resolved: resolved), json: global.json) { resolved }
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
