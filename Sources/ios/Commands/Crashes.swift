import ArgumentParser
import Foundation
import IOSCore

struct CrashesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crashes",
        abstract: "List and read crash reports from a simulator or device, symbolicated where possible.",
        discussion: """
        Simulator reports come from ~/Library/Logs/DiagnosticReports; device reports are copied off the device \
        (cached in ~/Library/Caches/ios-cli/crashes). App frames are symbolicated with the build's dSYM (found \
        by UUID) or, for simulator builds, the app binary in DerivedData.
        """,
        subcommands: [List.self, Show.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List recent crashes, newest first.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions
        @Option(help: "Only this app's crashes.") var bundleId: String?
        @Option(help: "Only this process (executable name).") var process: String?
        @Option(help: "How far back to look, in hours.") var hours: Double = 72
        @Option(help: "Most reports to list.") var limit = 20

        func run() throws {
            let resolved = try TargetResolver.ensureReachable(TargetResolver.resolve(target.device))
            if !resolved.isSimulator { Docs.progress("Reading crash reports from the device…") }
            let reports = try Crashes.list(on: resolved, bundleID: bundleId, process: process, hours: hours, limit: limit)
            try Output.emit(reports, json: global.json) {
                guard !reports.isEmpty else { return "No crashes in the last \(Int(hours)) h on \(resolved.label)." }
                return reports.map { report in
                    var line = "\(report.time ?? "?")  \(report.process)"
                    if let bundleID = report.bundleID { line += " (\(bundleID)" + (report.version.map { " \($0)" } ?? "") + ")" }
                    line += "  \(report.exception ?? "?")" + (report.signal.map { "/\($0)" } ?? "")
                    if let reason = report.reason { line += "\n    \(reason)" }
                    return line + "\n    \(report.path)"
                }.joined(separator: "\n")
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a crash: exception, reason and the crashed thread's frames.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "An .ips file (from `ios crashes list`).") var path: String
        @Option(help: "Frames to show.") var frames = 25

        func run() throws {
            let report = try Crashes.details(path, maxFrames: frames)
            try Output.emit(report, json: global.json) {
                var lines = ["\(report.process)" + (report.bundleID.map { " (\($0)" + (report.version.map { " \($0)" } ?? "") + ")" } ?? "")
                             + " crashed at \(report.time ?? "?") on " + (report.simulator ? "a simulator" : report.osVersion ?? "?")]
                lines.append("Exception: \(report.exception ?? "?")" + (report.signal.map { " (\($0))" } ?? ""))
                if let reason = report.reason { lines.append("Reason: \(reason)") }
                func render(_ title: String, _ frames: [CrashReport.Frame]) {
                    lines.append("")
                    lines.append(title)
                    lines += frames.enumerated().map { i, frame in
                        "  \(i)".padding(toLength: 5, withPad: " ", startingAt: 0) + frame.image.padding(toLength: 28, withPad: " ", startingAt: 0)
                            + " " + (frame.symbol ?? frame.address ?? "?") + (frame.location.map { "  \($0)" } ?? "")
                    }
                }
                if let thrown = report.exceptionFrames { render("Thrown at:", thrown) }
                render("Crashed thread:", report.frames ?? [])
                if report.symbolicated ?? 0 > 0 { lines.append("\n(\(report.symbolicated!) frames symbolicated locally)") }
                return lines.joined(separator: "\n")
            }
        }
    }
}
