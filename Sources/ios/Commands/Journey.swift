import ArgumentParser
import Foundation
import IOSCore

struct JourneyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "journey",
        abstract: "Find, set up and report journeys: user flows written as plain-language steps an agent carries out.",
        discussion: """
        A journey is a *.journey.xml file in the Android CLI's format (<journey name> → <description>, \
        <actions> → <action>…), so one file can cover a flow on both platforms. An optional \
        <setup platform="ios"> launches the app with arguments and environment and opens URLs. The agent \
        runs each step with `ios layout`, `ios input` and `ios screen`, records a result JSON, and \
        `ios journey report` checks it and writes the Markdown report. The ios-cli skill has the rules.
        """,
        subcommands: [List.self, Show.self, Setup.self, Report.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the *.journey.xml files under a folder, with their step counts.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Folder to search (default: the current one).") var directory = "."

        struct Entry: Encodable {
            let file: String
            let name: String?
            let steps: Int?
            let error: String?
        }

        func run() throws {
            let entries = Journeys.find(in: directory).map { file -> Entry in
                do {
                    let journey = try Journeys.parse(file: file)
                    return Entry(file: file, name: journey.name, steps: journey.steps.count, error: nil)
                } catch {
                    // The parser's messages start with the path, which the listing already shows.
                    let message = "\(error)"
                    return Entry(file: file, name: nil, steps: nil, error: message.components(separatedBy: ": ").dropFirst().joined(separator: ": "))
                }
            }
            try Output.emit(entries, json: global.json) {
                guard !entries.isEmpty else { return "No *\(Journeys.fileSuffix) files under \(directory)." }
                return Output.table(entries.map { entry in
                    [entry.name ?? "⚠ invalid", entry.steps.map { "\($0) steps" } ?? (entry.error ?? ""), entry.file]
                })
            }
            if entries.contains(where: { $0.error != nil }) { throw ExitCode.failure }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a journey's setup and numbered steps (checks marked).")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The .journey.xml file.") var file: String

        func run() throws {
            let journey = try Journeys.parse(file: file)
            try Output.emit(journey, json: global.json) {
                var lines = ["Journey: \(journey.name)"]
                if let description = journey.description { lines.append(description) }
                if let setup = journey.setup {
                    lines.append("Setup:")
                    if let bundleID = setup.bundleID {
                        lines.append("  launch \(bundleID)" + (setup.arguments.isEmpty ? "" : " -- " + setup.arguments.joined(separator: " ")))
                    }
                    lines += setup.environment.keys.sorted().map { "  env \($0)=\(setup.environment[$0]!)" }
                    lines += setup.urls.map { "  open \($0)" }
                }
                lines += journey.steps.map { "\($0.index). " + ($0.kind == "check" ? "[check] " : "") + $0.text }
                return lines.joined(separator: "\n")
            }
        }
    }

    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Apply a journey's <setup>: relaunch the app with its arguments and environment, then open its URLs.",
            discussion: "Run it before the first step. A journey without <setup> needs the app already on the right screen."
        )
        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions
        @Argument(help: "The .journey.xml file.") var file: String

        struct Result: Encodable {
            let journey: String
            let launch: LaunchResult?
            let opened: [String]
        }

        func run() throws {
            let journey = try Journeys.parse(file: file)
            guard let setup = journey.setup else {
                throw IOSError.failed("\(journey.name) has no <setup platform=\"ios\"> (or platform-less <setup>); start the app yourself.")
            }
            let resolved = try TargetResolver.resolve(target.device)
            try Launcher.prepare(resolved)
            var launch: LaunchResult?
            if let bundleID = setup.bundleID {
                launch = try Launcher.launch(bundleID, on: resolved, arguments: setup.arguments, environment: setup.environment)
            }
            for url in setup.urls {
                // Give a freshly launched app a moment to set up its URL handling.
                if launch != nil { Thread.sleep(forTimeInterval: 1.5) }
                try AppControl.openURL(url, on: resolved)
            }
            try Output.emit(Result(journey: journey.name, launch: launch, opened: setup.urls), json: global.json) {
                var lines: [String] = []
                if let launch {
                    lines.append("Launched \(launch.bundleIdentifier) on \(resolved.label)" + (launch.pid.map { " (pid \($0))" } ?? ""))
                }
                lines += setup.urls.map { "Opened \($0)" }
                return lines.joined(separator: "\n")
            }
        }
    }

    struct Report: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check a journey result JSON and write its Markdown report (the Android CLI's layout).",
            discussion: """
            The result JSON: {"journey", "file", "device", "app", "startedAt", "finishedAt", "result": \
            passed|failed|malformed, "steps": [{"index", "text", "result": passed|failed|notRun, \
            "commands": [...], "screenshot", "comment"}], "summary"}. Only journey, result and steps (with \
            index and result) are required. Exits 1 when the journey didn't pass.
            """
        )
        @OptionGroup var global: GlobalOptions
        @Argument(help: "The result JSON file.") var result: String
        @Option(name: .shortAndLong, help: "Markdown file to write (default: the result's path with .md).") var output: String?

        struct Written: Encodable {
            let report: String
            let result: String
        }

        func run() throws {
            let (parsed, journey) = try Journeys.readResult(result)
            let path = URL(fileURLWithPath: output ?? (result.hasSuffix(".json") ? String(result.dropLast(5)) : result) + (output == nil ? ".md" : ""))
                .standardizedFileURL
            try Journeys.markdown(parsed, journey: journey).write(to: path, atomically: true, encoding: .utf8)
            try Output.emit(Written(report: path.path, result: parsed.result), json: global.json) {
                let failed = parsed.steps.first { $0.result == "failed" }
                return "\(parsed.journey): \(parsed.result)" + (failed.map { " at step \($0.index)" } ?? "") + " — wrote \(path.path)"
            }
            if parsed.result != "passed" { throw ExitCode.failure }
        }
    }
}
