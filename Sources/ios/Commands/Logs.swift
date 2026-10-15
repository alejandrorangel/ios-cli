import ArgumentParser
import Foundation
import IOSCore

struct LogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show an app's logs from a simulator or device.",
        discussion: """
        Simulators: follows the app's unified log (os_log / Logger / NSLog), or shows recent history with --last.
        --launch relaunches the app with its console attached, which also captures print(). On devices --launch is \
        required, because reading a device's unified log needs root.
        With --json, prints one JSON object per line (NDJSON) as entries arrive.
        """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var target: TargetOptions

    @Option(help: "App bundle identifier, e.g. from `ios run` or `ios describe`.")
    var bundleId: String?

    @Option(help: "Process name to filter on (simulator log streams), instead of --bundle-id.")
    var process: String?

    @Flag(help: "Relaunch the app with its console attached (captures print(); required on devices).")
    var launch = false

    @Option(help: "Show history instead of following, e.g. 30s, 5m, 1h (simulator only).")
    var last: String?

    @Option(help: "Stop after this many seconds. Recommended for agents.")
    var duration: Double?

    @Option(help: "Lowest level to include: default, info or debug.")
    var level: String?

    @Option(help: "Only messages from this subsystem.")
    var subsystem: String?

    func validate() throws {
        if launch && last != nil { throw ValidationError("--last can't be combined with --launch.") }
        if bundleId == nil && process == nil { throw ValidationError("Pass --bundle-id or --process.") }
        if let level, !["default", "info", "debug"].contains(level) {
            throw ValidationError("--level must be default, info or debug.")
        }
    }

    func run() throws {
        // Line-buffer stdout so each entry reaches a pipe (an agent) immediately.
        setvbuf(stdout, nil, _IOLBF, 0)
        let mode: LogRequest.Mode = launch ? .launch : last.map { .history($0) } ?? .stream
        let request = LogRequest(
            target: try TargetResolver.resolve(target.device), bundleIdentifier: bundleId, process: process,
            mode: mode, level: level, subsystem: subsystem, duration: duration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Logs.run(request) { entry in
            if global.json, let data = try? encoder.encode(entry) {
                print(String(decoding: data, as: UTF8.self))
            } else {
                print(entry.textLine)
            }
        }
    }
}
