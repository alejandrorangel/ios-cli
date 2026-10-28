import ArgumentParser
import IOSCore

struct TestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run a scheme's unit and UI tests and summarize the failures.",
        discussion: """
        Runs on --device, else the booted simulator, else an iPhone simulator on the newest iOS; a \
        physical device is only used when named with --device. Failures are listed with the file and line \
        of each failed expectation; passing tests are only counted. Each failure's id \
        can be passed back to --only to rerun just that test. --env sets a variable in the test process \
        (for tests gated on ProcessInfo's environment). Attachments (Attachment.record, XCTAttachment) are \
        exported with readable names and listed for passing tests too, with the text of small text files. \
        Swift Testing runs suites in parallel even when each is .serialized; the output names suites that \
        overlapped, and --no-parallel runs one at a time (for tests sharing audio, the camera…). What a test \
        prints is shown under its failures (--show-output: for every test); when tests ran in parallel their \
        lines may be mixed, and the output says so. The full log and the .xcresult bundle \
        (open it in Xcode for attachments and screenshots) are written to files whose paths are in the \
        output. Exits non-zero when a test fails or the tests don't build.
        """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var project: ProjectOptions
    @OptionGroup var target: TargetOptions
    @OptionGroup var signing: SigningOptions

    @Option(help: "Run only this test target, suite or test, e.g. AppTests/LoginTests/testEmpty (repeatable).")
    var only: [String] = []

    @Option(help: "Skip this test target, suite or test (repeatable).")
    var skip: [String] = []

    @Option(help: "Test plan to run instead of the scheme's default.")
    var testPlan: String?

    @Flag(help: "Run the tests from the last build without building (after `ios test` or Xcode's Build for Testing).")
    var noBuild = false

    @Option(help: "Rerun a failing test up to this many times; it passes if any attempt passes.")
    var retries: Int?

    @Option(name: .customLong("env"), help: ArgumentHelp(
        "Set an environment variable in the test process (repeatable). Passed as TEST_RUNNER_<NAME>.",
        valueName: "NAME=VALUE"))
    var environment: [String] = []

    @Flag(help: "Run one test and one suite at a time, including Swift Testing suites (-parallel-testing-enabled NO).")
    var noParallel = false

    @Option(help: ArgumentHelp("Export attachments to this directory (default: next to the result bundle).",
                               valueName: "dir"))
    var attachments: String?

    @Flag(help: "Show what every test printed, not only failed tests.")
    var showOutput = false

    func run() throws {
        let environment = try TestRequest.parseEnvironment(environment)
        let container = try project.container()
        let resolved = try TargetResolver.resolveSimulatorFirst(target.device)
        let (listing, _) = try Describer.listing(container)
        let scheme = try Describer.resolveScheme(project.scheme, in: listing)

        Docs.progress("Testing \(scheme) on \(resolved.label)…")
        let result = try TestRunner.run(TestRequest(
            container: container, scheme: scheme, configuration: project.configuration,
            destination: .target(resolved), derivedDataPath: project.derivedDataPath,
            only: only, skip: skip, testPlan: testPlan, withoutBuilding: noBuild, retries: retries, team: signing.team,
            environment: environment, serial: noParallel, attachmentsDirectory: attachments
        ))
        try Output.emit(result, json: global.json) { result.textSummary(allOutput: showOutput) }
        if !result.succeeded { throw ExitCode.failure }
    }
}

extension TestResult {
    func textSummary(allOutput: Bool = false) -> String {
        var lines: [String] = []
        if !buildErrors.isEmpty {
            lines.append("✗ Tests didn't build in \(duration)s (\(buildErrors.count) errors)")
            lines += buildErrors.prefix(15).map { "  \($0.summary)" }
        } else if passed + failed + skipped + expectedFailures == 0 {
            lines.append("✗ No tests ran (\(duration)s)")
        } else {
            let counts = ["\(passed) passed", "\(failed) failed"] + (skipped > 0 ? ["\(skipped) skipped"] : [])
                + (expectedFailures > 0 ? ["\(expectedFailures) expected failures"] : [])
            let mark = succeeded ? "✓ Tests passed" : "✗ Tests failed"
            lines.append("\(mark) in \(duration)s: \(counts.joined(separator: ", "))")
            for test in failures.prefix(20) {
                lines.append("  ✗ \(test.id)")
                lines += test.failures.prefix(5).map { "      \($0.summary.replacingOccurrences(of: "\n", with: "\n        "))" }
                if test.failures.count > 5 { lines.append("      … \(test.failures.count - 5) more failures") }
                let printed = output.filter { $0.test == test.id }
                let atIssues = printed.filter { $0.beforeIssue != nil }
                for entry in (atIssues.isEmpty ? printed : atIssues).prefix(3) { lines += entry.textLines(limit: 10) }
            }
            if failures.count > 20 { lines.append("  … \(failures.count - 20) more failed tests") }
            for test in skippedTests.prefix(10) {
                lines.append("  – \(test.id) skipped" + (test.skipReason.map { ": \($0)" } ?? ""))
            }
        }
        if !overlappingSuites.isEmpty {
            lines.append("  ! Suites ran at the same time: \(overlappingSuites.joined(separator: ", ")). "
                         + "Pass --no-parallel to run them one at a time.")
        }
        let failedIDs = Set(failures.prefix(20).map(\.id))
        let otherOutput = allOutput ? output.filter { !failedIDs.contains($0.test) } : []
        if !otherOutput.isEmpty {
            lines.append("Output:")
            for printed in otherOutput {
                lines.append("  \(printed.test)")
                lines += printed.textLines(limit: 20)
            }
        }
        if !attachments.isEmpty {
            lines.append("Attachments:")
            for attachment in attachments.prefix(20) {
                lines.append("  \(attachment.test)" + (attachment.argument.map { " [\($0)]" } ?? "") + ": \(attachment.path)")
                if let text = attachment.text {
                    let textLines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    lines += textLines.prefix(10).map { "      \($0)" }
                    if textLines.count > 10 { lines.append("      … \(textLines.count - 10) more lines") }
                }
            }
            if attachments.count > 20 { lines.append("  … \(attachments.count - 20) more attachments") }
        }
        lines += issues.map { "  \($0)" }
        if !environment.isEmpty {
            lines.append("Environment: " + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        if let hint { lines.append("Hint: \(hint)") }
        lines.append("Log: \(log)")
        if let resultBundle { lines.append("Result bundle: \(resultBundle)") }
        return lines.joined(separator: "\n")
    }
}

extension TestOutput {
    /// The lines before the first failed expectation when there is one, else the last `limit` lines,
    /// under a header with the log line to read the rest from.
    func textLines(limit: Int) -> [String] {
        let all = (beforeIssue ?? text).split(separator: "\n", omittingEmptySubsequences: false)
        let note = (argument.map { ", \($0)" } ?? "") + (beforeIssue != nil ? ", before the first issue" : "")
            + (interleaved ? ", mixed with tests that ran at the same time" : "")
        var lines = ["      output (log line \(logLine)\(note)):"]
        if all.count > limit { lines.append("        … \(all.count - limit) earlier lines") }
        return lines + all.suffix(limit).map { "        \($0)" }
    }
}
