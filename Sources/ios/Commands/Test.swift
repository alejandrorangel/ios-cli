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
        can be passed back to --only to rerun just that test. The full log and the .xcresult bundle \
        (open it in Xcode for attachments and screenshots) are written to files whose paths are in the \
        output. Exits non-zero when a test fails or the tests don't build.
        """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var project: ProjectOptions
    @OptionGroup var target: TargetOptions

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

    func run() throws {
        let container = try project.container()
        let resolved = try TargetResolver.resolveSimulatorFirst(target.device)
        let (listing, _) = try Describer.listing(container)
        let scheme = try Describer.resolveScheme(project.scheme, in: listing)

        Docs.progress("Testing \(scheme) on \(resolved.label)…")
        let result = try TestRunner.run(TestRequest(
            container: container, scheme: scheme, configuration: project.configuration,
            destination: .target(resolved), derivedDataPath: project.derivedDataPath,
            only: only, skip: skip, testPlan: testPlan, withoutBuilding: noBuild, retries: retries
        ))
        try Output.emit(result, json: global.json) { result.textSummary }
        if !result.succeeded { throw ExitCode.failure }
    }
}

extension TestResult {
    var textSummary: String {
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
            }
            if failures.count > 20 { lines.append("  … \(failures.count - 20) more failed tests") }
            for test in skippedTests.prefix(10) {
                lines.append("  – \(test.id) skipped" + (test.skipReason.map { ": \($0)" } ?? ""))
            }
        }
        lines += issues.map { "  \($0)" }
        lines.append("Log: \(log)")
        if let resultBundle { lines.append("Result bundle: \(resultBundle)") }
        return lines.joined(separator: "\n")
    }
}
