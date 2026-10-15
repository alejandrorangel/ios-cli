import ArgumentParser
import Foundation
import IOSCore

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show compiler errors and warnings for Swift files without a full build (~0.2–0.5 s per file).",
        discussion: """
        Asks Xcode 27's tool service (no Xcode window needed) to type-check each file as it is on disk, \
        so use it right after editing. Xcode asks you to approve `ios` the first time. Lines are reported, \
        columns aren't. Use `ios build` for the whole project. Exits non-zero when a file has errors.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "Path to an .xcworkspace. Defaults to the one in the current directory.")
    var workspace: String?

    @Option(help: "Path to an .xcodeproj.")
    var project: String?

    @Argument(help: "Swift files to check (they must be part of the project).")
    var files: [String]

    func validate() throws {
        if files.isEmpty { throw ValidationError("Pass one or more Swift files.") }
        for file in files where !FileManager.default.fileExists(atPath: file) {
            throw ValidationError("\(file) doesn't exist.")
        }
    }

    func run() throws {
        let container = try ProjectLocator.locate(workspace: workspace, project: project,
                                                  directory: FileManager.default.currentDirectoryPath)
        let start = Date()
        let results = try CodeIssues.check(container, files: files)
        let seconds = (Date().timeIntervalSince(start) * 10).rounded() / 10
        try Output.emit(results, json: global.json) {
            var lines: [String] = []
            for result in results {
                let counts = "\(result.errors) error\(result.errors == 1 ? "" : "s"), \(result.warnings) warning\(result.warnings == 1 ? "" : "s")"
                lines.append("\(result.errors > 0 ? "✗" : "✓") \(counts) in \(result.projectPath)")
                lines += result.diagnostics.map { "  \($0.summary.replacingOccurrences(of: "\n", with: "\n    "))" }
            }
            lines.append("(\(seconds)s)")
            return lines.joined(separator: "\n")
        }
        if results.contains(where: { $0.errors > 0 }) { throw ExitCode.failure }
    }
}
