import ArgumentParser
import Foundation
import IOSCore

struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Record an Instruments trace and summarize where the app spends its time.",
        discussion: """
        Launches the app under the profiler for --seconds (or attaches with --attach), saves the .trace \
        (open it in Instruments for the full picture), and prints the heaviest functions in the app's own \
        code and overall, from Time Profiler samples. Other templates (--template "SwiftUI", "Allocations", \
        "Leaks"…) are recorded too; the summary then lists the tables to export with `xcrun xctrace export`.
        Example: `ios profile --app "$(ios describe --scheme App --json | jq -r '.apps[0].path')" --seconds 15`.
        """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var target: TargetOptions

    @Option(help: "The .app to launch under the profiler.")
    var app: String?

    @Option(help: "An installed app to launch under the profiler (simulator: its installed copy).")
    var bundleId: String?

    @Option(help: "A running process (pid or name) to attach to instead of launching.")
    var attach: String?

    @Option(help: "Instruments template.")
    var template = Profiler.defaultTemplate

    @Option(help: "Seconds to record.")
    var seconds: Double = 10

    @Option(name: .shortAndLong, help: "Trace file to write.")
    var output = "profile.trace"

    @Option(help: "Functions to list.")
    var top = 15

    @OptionGroup var launchOptions: LaunchOptions

    func validate() throws {
        let sources = [app, bundleId, attach].compactMap { $0 }.count
        guard sources == 1 else { throw ValidationError("Pass one of --app, --bundle-id or --attach.") }
        guard seconds > 0, seconds <= 600 else { throw ValidationError("--seconds must be between 0 and 600.") }
    }

    func run() throws {
        let resolved = try TargetResolver.ensureReachable(TargetResolver.resolve(target.device))
        var appPath = app
        if let bundleId {
            if case let .simulator(s) = resolved {
                appPath = try Shell.checked("/usr/bin/xcrun", ["simctl", "get_app_container", s.udid, bundleId, "app"])
                    .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                appPath = bundleId // xctrace launches an installed device app by its identifier
            }
        }
        var request = Profiler.Request(target: resolved, template: template, app: appPath, attach: attach, seconds: seconds,
                                       output: output, arguments: launchOptions.arguments)
        request.environment = try launchOptions.environmentValues()
        try Profiler.record(request, progress: Docs.progress)
        let trace = URL(fileURLWithPath: output).standardizedFileURL.path
        let binaries = appPath.map { $0.hasSuffix(".app") ? Profiler.binaries(inApp: $0) : [] } ?? []
        Docs.progress("Summarizing…")
        let summary = try Profiler.summarize(trace, template: template, appBinaries: binaries, limit: top)
        try Output.emit(summary, json: global.json) { text(summary) }
    }

    private func ms(_ value: Double) -> String { value >= 1000 ? String(format: "%.2f s", value / 1000) : String(format: "%.0f ms", value) }

    private func text(_ s: Profiler.Summary) -> String {
        var lines = ["Saved \(s.trace) (\(s.template))"]
        guard s.sampledMs > 0 else {
            lines.append("No Time Profiler samples to summarize. Tables in the trace: \(s.tables.joined(separator: ", "))")
            lines.append("Export one with: xcrun xctrace export --input \(s.trace) --xpath '/trace-toc/run[@number=\"1\"]/data/table[@schema=\"NAME\"]'")
            return lines.joined(separator: "\n")
        }
        lines.append("\(s.process ?? "?"): \(ms(s.sampledMs)) of CPU sampled")
        lines.append("")
        lines.append("Threads:")
        lines.append(Output.table(s.threads.map { ["  " + ms($0.ms), $0.thread] }))
        if !s.appFunctions.isEmpty {
            lines.append("")
            lines.append("App code (total = time with it on the stack, self = time in it):")
            lines.append(Output.table([["  TOTAL", "SELF", "FUNCTION"]] + s.appFunctions.map { ["  " + ms($0.totalMs), ms($0.selfMs), $0.function] }))
        }
        lines.append("")
        lines.append("Heaviest functions (self time):")
        lines.append(Output.table(s.topSelf.map { ["  " + ms($0.selfMs), $0.binary, $0.function] }))
        return lines.joined(separator: "\n")
    }
}
