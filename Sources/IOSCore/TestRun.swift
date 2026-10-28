import Foundation

public struct TestRequest: Sendable {
    public let container: Container
    public let scheme: String
    public let configuration: String?
    public let destination: Destination
    public let derivedDataPath: String?
    /// Test identifiers for `-only-testing:` / `-skip-testing:`: Target, Target/Suite or Target/Suite/test.
    public let only: [String]
    public let skip: [String]
    public let testPlan: String?
    /// Run the tests from the last build (`test-without-building`).
    public let withoutBuilding: Bool
    /// Rerun failing tests up to this many times (`-retry-tests-on-failure`).
    public let retries: Int?
    public let team: String?
    /// Variables for the test process, without the `TEST_RUNNER_` prefix.
    public let environment: [String: String]
    /// Run one test (and one Swift Testing suite) at a time (`-parallel-testing-enabled NO`).
    public let serial: Bool
    /// Where to export attachments; nil puts them next to the result bundle.
    public let attachmentsDirectory: String?

    public init(container: Container, scheme: String, configuration: String?, destination: Destination,
                derivedDataPath: String?, only: [String], skip: [String], testPlan: String?,
                withoutBuilding: Bool, retries: Int?, team: String? = nil, environment: [String: String] = [:],
                serial: Bool = false, attachmentsDirectory: String? = nil) {
        self.container = container
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
        self.derivedDataPath = derivedDataPath
        self.only = only
        self.skip = skip
        self.testPlan = testPlan
        self.withoutBuilding = withoutBuilding
        self.retries = retries
        self.team = team
        self.environment = environment
        self.serial = serial
        self.attachmentsDirectory = attachmentsDirectory
    }

    /// xcodebuild passes `TEST_RUNNER_<NAME>` from its own environment to the test process as `<NAME>`.
    public var xcodebuildEnvironment: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.map { ("TEST_RUNNER_" + $0.key, $0.value) })
    }

    /// Parses `NAME=VALUE` (a leading `TEST_RUNNER_` is dropped, since it's added back when running).
    public static func parseEnvironment(_ assignments: [String]) throws -> [String: String] {
        var environment: [String: String] = [:]
        for assignment in assignments {
            guard let equals = assignment.firstIndex(of: "="), equals != assignment.startIndex else {
                throw IOSError.invalidEnvironment(assignment)
            }
            var name = String(assignment[..<equals])
            if name.hasPrefix("TEST_RUNNER_") { name.removeFirst("TEST_RUNNER_".count) }
            environment[name] = String(assignment[assignment.index(after: equals)...])
        }
        return environment
    }

    public func xcodebuildArguments(resultBundle: String) -> [String] {
        var arguments = ["xcodebuild", withoutBuilding ? "test-without-building" : "test"] + container.xcodebuildArguments
        arguments += ["-scheme", scheme, "-destination", destination.xcodebuildValue, "-resultBundlePath", resultBundle]
        if let configuration { arguments += ["-configuration", configuration] }
        if let derivedDataPath { arguments += ["-derivedDataPath", derivedDataPath] }
        if let testPlan { arguments += ["-testPlan", testPlan] }
        arguments += only.map { "-only-testing:\($0)" } + skip.map { "-skip-testing:\($0)" }
        if let retries, retries > 0 {
            arguments += ["-retry-tests-on-failure", "-test-iterations", String(retries + 1)]
        }
        // Also stops Swift Testing from running suites concurrently (`.serialized` only orders a suite's own tests).
        if serial { arguments += ["-parallel-testing-enabled", "NO"] }
        return arguments + Signing.arguments(team: team, destination: destination)
    }
}

public struct TestFailure: Codable, Equatable, Sendable {
    public let message: String
    public let file: String?
    public let line: Int?
    /// The failing argument values of a parameterized test, e.g. "3".
    public let arguments: String?

    public var summary: String {
        let location = file.map { "\($0):\(line ?? 0): " } ?? ""
        let args = arguments.map { "[\($0)] " } ?? ""
        return location + args + message
    }
}

public struct TestCaseResult: Codable, Equatable, Sendable {
    /// What `--only` accepts: Target/Suite/test (XCTest methods without parentheses).
    public let id: String
    public let name: String
    /// "passed", "failed", "skipped" or "expected-failure".
    public let result: String
    public let duration: Double?
    public let failures: [TestFailure]
    public let skipReason: String?
    /// Each argument of a parameterized test; `duration` above is Xcode's figure for the whole test.
    public let arguments: [ArgumentResult]?
}

public struct ArgumentResult: Codable, Equatable, Sendable {
    public let name: String
    public let result: String
    public let duration: Double?
}

public struct TestOutput: Codable, Equatable, Sendable {
    public let test: String
    /// The argument case of a parameterized test, e.g. "speed → .full"; each case gets its own entry.
    public let argument: String?
    /// The log line where the output starts.
    public let logLine: Int
    /// What the test printed (stdout and stderr; in an app-hosted test, the app's too), the end kept when it's long.
    public let text: String
    /// The last lines printed before the test's first failed expectation, which usually explain it.
    public let beforeIssue: String?
    /// Other tests ran at the same time, so some lines may be theirs.
    public let interleaved: Bool
}

public struct TestAttachment: Codable, Equatable, Sendable {
    /// The test that recorded it, as `--only` accepts it.
    public let test: String
    /// The argument case of a parameterized test that recorded it, as in `arguments[].name`.
    public let argument: String?
    public let name: String
    public let path: String
    /// The contents of a small text attachment.
    public let text: String?
}

public struct TestResult: Codable, Sendable {
    public let succeeded: Bool
    public let scheme: String
    public let destination: String
    public let duration: Double
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    public let expectedFailures: Int
    /// Failed tests with their messages; passing tests are left out to keep the output small.
    public let failures: [TestCaseResult]
    public let skippedTests: [TestCaseResult]
    /// Compiler errors when the tests didn't build.
    public let buildErrors: [Diagnostic]
    /// Problems not tied to a test, e.g. "no tests matched" or the runner crashing.
    public let issues: [String]
    public let log: String
    public let resultBundle: String?
    /// What to do about a signing failure, when the build errors show one.
    public let hint: String?
    /// The variables passed to the test process with --env.
    public let environment: [String: String]
    /// Files recorded with `Attachment.record` / `XCTAttachment`, from passing tests too.
    public let attachments: [TestAttachment]
    /// Swift Testing suites (not nested in one another) that ran at the same time.
    public let overlappingSuites: [String]
    /// What each test printed, read from the log.
    public let output: [TestOutput]
}

public enum TestRunner {
    /// Runs `xcodebuild test` with output in a log file and a result bundle, and summarizes the
    /// result bundle's test tree (falling back to the log's errors when nothing ran).
    public static func run(_ request: TestRequest, logDirectory: URL = Builder.defaultLogDirectory) throws -> TestResult {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let log = logDirectory.appendingPathComponent("test-\(stamp)-\(suffix).log")
        let bundle = logDirectory.appendingPathComponent("test-\(stamp)-\(suffix).xcresult")
        let start = Date()
        let status = try Shell.run("/usr/bin/xcrun", request.xcodebuildArguments(resultBundle: bundle.path),
                                   log: log, in: request.container.workingDirectory,
                                   environment: request.xcodebuildEnvironment)
        let duration = (Date().timeIntervalSince(start) * 10).rounded() / 10
        let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""

        var cases: [TestCaseResult] = []
        var index = TreeIndex()
        var attachments: [TestAttachment] = []
        var hasBundle = FileManager.default.fileExists(atPath: bundle.path)
        if hasBundle {
            let tree = try? Shell.run("/usr/bin/xcrun", ["xcresulttool", "get", "test-results", "tests", "--path", bundle.path])
            if let tree, tree.status == 0 {
                cases = (try? parseTestTree(tree.stdout)) ?? []
                index = (try? treeIndex(tree.stdout)) ?? TreeIndex()
                let directory = request.attachmentsDirectory.map { URL(fileURLWithPath: $0) }
                    ?? logDirectory.appendingPathComponent("test-\(stamp)-\(suffix)-attachments")
                let parameterized = Set(cases.filter { $0.arguments != nil }.map(\.id))
                attachments = (try? exportAttachments(bundle: bundle, to: directory, parameterized: parameterized)) ?? []
            } else { hasBundle = false }
        }

        let count = { (result: String) in cases.filter { $0.result == result }.count }
        let buildErrors = cases.isEmpty ? Builder.parseDiagnostics(logText).filter { $0.severity == "error" } : []
        var issues: [String] = []
        if status != 0 && cases.isEmpty && buildErrors.isEmpty {
            issues = logIssues(logText)
            if issues.isEmpty { issues = ["xcodebuild exited with status \(status) without running any tests; see the log."] }
        } else if status == 0 && cases.isEmpty {
            issues = ["No tests ran. Check the scheme's test action, the test plan, or the --only identifiers."]
        }
        return TestResult(
            succeeded: status == 0 && !cases.isEmpty,
            scheme: request.scheme,
            destination: request.destination.xcodebuildValue,
            duration: duration,
            passed: count("passed"), failed: count("failed"), skipped: count("skipped"),
            expectedFailures: count("expected-failure"),
            failures: cases.filter { $0.result == "failed" },
            skippedTests: cases.filter { $0.result == "skipped" },
            buildErrors: buildErrors,
            issues: issues,
            log: log.path,
            resultBundle: hasBundle ? bundle.path : nil,
            hint: Signing.hint(for: buildErrors, team: request.team),
            environment: request.environment,
            attachments: attachments,
            overlappingSuites: overlappingSuites(logText, ancestors: index.ancestors),
            output: testOutput(logText, tests: index.tests)
        )
    }

    private struct Node: Decodable {
        struct Location: Decodable { let filePath: String?; let lineNumber: Int? }
        let name: String
        let nodeType: String
        let nodeIdentifier: String?
        let nodeIdentifierURL: String?
        let result: String?
        let durationInSeconds: Double?
        let sourceLocation: Location?
        let children: [Node]?
    }

    /// Parses `xcresulttool get test-results tests` into one result per test case, in tree order.
    public static func parseTestTree(_ data: Data) throws -> [TestCaseResult] {
        struct Tree: Decodable { let testNodes: [Node] }
        let tree: Tree
        do { tree = try JSONDecoder().decode(Tree.self, from: data) } catch {
            throw IOSError.invalidOutput(tool: "xcresulttool get test-results tests", reason: "\(error)")
        }
        var cases: [TestCaseResult] = []
        func visit(_ node: Node) {
            guard node.nodeType == "Test Case" else { node.children?.forEach(visit); return }
            let children = node.children ?? []
            var failures = failureMessages(children, arguments: nil)
            // Parameterized tests keep each argument's failures under an "Arguments" child.
            let argumentNodes = children.filter { $0.nodeType == "Arguments" }
            for arguments in argumentNodes {
                failures += failureMessages(arguments.children ?? [], arguments: arguments.name)
            }
            cases.append(TestCaseResult(
                id: testID(url: node.nodeIdentifierURL) ?? node.nodeIdentifier ?? node.name,
                name: node.name,
                result: normalized(node.result),
                duration: rounded(node.durationInSeconds),
                failures: failures,
                skipReason: children.first { $0.nodeType == "Skip Message" }.map { skipReason($0.name) },
                arguments: argumentNodes.isEmpty ? nil : argumentNodes.map {
                    ArgumentResult(name: $0.name, result: normalized($0.result), duration: rounded($0.durationInSeconds))
                }
            ))
        }
        tree.testNodes.forEach(visit)
        return cases
    }

    private static func rounded(_ seconds: Double?) -> Double? {
        seconds.map { ($0 * 1000).rounded() / 1000 }
    }

    struct TreeIndex {
        /// Each test suite's name → the names of the suites it's nested in.
        var ancestors: [String: Set<String>] = [:]
        /// Suite name → test name (as the log prints it) → test id.
        var tests: [String: [String: String]] = [:]
    }

    static func treeIndex(_ data: Data) throws -> TreeIndex {
        struct Tree: Decodable { let testNodes: [Node] }
        let tree = try JSONDecoder().decode(Tree.self, from: data)
        var index = TreeIndex()
        func visit(_ node: Node, outer: [String]) {
            var inner = outer
            if node.nodeType == "Test Suite" {
                index.ancestors[node.name, default: []].formUnion(outer)
                inner.append(node.name)
            } else if node.nodeType == "Test Case", let suite = outer.last {
                index.tests[suite, default: [:]][node.name] = testID(url: node.nodeIdentifierURL) ?? node.nodeIdentifier ?? node.name
                return
            }
            node.children?.forEach { visit($0, outer: inner) }
        }
        tree.testNodes.forEach { visit($0, outer: []) }
        return index
    }

    enum Event: Equatable {
        case suiteStarted(String), suiteEnded(String)
        case testStarted(String), testEnded(String)
        /// One argument case of a parameterized test: the test's name and its arguments ("speed → .full").
        case caseStarted(test: String, arguments: String)
        case issue(String)
    }

    private static let name = #"("(?:[^"\\]|\\.)*"|[^ ]+)"#
    nonisolated(unsafe) private static let eventPatterns: [(NSRegularExpression, ([String]) -> Event?)] = [
        (#"^Suite \#(name) started\.$"#, { .suiteStarted($0[0]) }),
        (#"^Suite \#(name) (?:passed|failed|skipped)"#, { .suiteEnded($0[0]) }),
        (#"^Test case passing \d+ arguments? (.+) to \#(name) started\.$"#, { .caseStarted(test: $0[1], arguments: $0[0]) }),
        (#"^Test \#(name) started\.$"#, { $0[0] == "run" ? nil : .testStarted($0[0]) }),
        (#"^Test \#(name)(?: with \d+ test cases?)? (?:passed|failed|skipped)"#, { .testEnded($0[0]) }),
        (#"^Test \#(name) recorded an issue"#, { .issue($0[0]) }),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// The text after a Swift Testing line's symbol ("◇", "✔", "✘", "➜", "↳"), which Xcode
    /// sometimes prefixes with a zero-width space; nil for other lines.
    static func swiftTestingBody(_ line: Substring) -> Substring? {
        let trimmed = line.drop { $0 == "\u{200B}" || $0 == " " }
        guard let first = trimmed.first, "◇✔✘➜↳⚠".contains(first) else { return nil }
        return trimmed.dropFirst().drop { $0 == " " || $0 == "\u{FE0E}" || $0 == "\u{FE0F}" }
    }

    /// A Swift Testing start, end or issue line: "◇ Suite X started.", "✔ Test "Name" passed after…",
    /// "✔ Test f(n:) with 2 test cases passed…", "◇ Test case passing 1 argument n → 1 to f(n:) started."
    static func swiftTestingEvent(_ line: Substring) -> Event? {
        guard let body = swiftTestingBody(line).map(String.init) else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        for (pattern, make) in eventPatterns {
            guard let match = pattern.firstMatch(in: body, range: range) else { continue }
            let groups = (1..<match.numberOfRanges).map { String(body[Range(match.range(at: $0), in: body)!]) }
            return make(groups.map { unquoted(Substring($0)) })
        }
        return nil
    }

    /// Suites that started while another suite (other than one they're nested in) was still running,
    /// from Swift Testing's "◇ Suite X started." / "✔ Suite X passed after…" log lines.
    static func overlappingSuites(_ log: String, ancestors: [String: Set<String>]) -> [String] {
        var running: [String] = []
        var overlapping: [String] = []
        func note(_ name: String) { if !overlapping.contains(name) { overlapping.append(name) } }
        for line in log.split(separator: "\n") {
            switch swiftTestingEvent(line) {
            case let .suiteStarted(name):
                for other in running where !(ancestors[name]?.contains(other) ?? false) && !(ancestors[other]?.contains(name) ?? false) {
                    note(other); note(name)
                }
                running.append(name)
            case let .suiteEnded(name):
                if let index = running.lastIndex(of: name) { running.remove(at: index) }
            default: break
            }
        }
        return overlapping
    }

    /// Assigns the lines between a test's start and end lines in the log to that test (Swift Testing
    /// and XCTest), split per argument case for parameterized tests. Leaves out the test frameworks'
    /// own lines and timestamped unified-log lines (xcodebuild's, or the host app's os_log/NSLog).
    static func testOutput(_ log: String, tests: [String: [String: String]], limit: Int = 4096) -> [TestOutput] {
        struct Running { let name: String; let id: String; var argument: String? }
        struct Collected {
            let test: String; let argument: String?; let line: Int
            var lines: [String] = []; var interleaved = false; var linesBeforeIssue: Int?
        }
        var suites: [String] = []
        var running: [Running] = []
        var collected: [Collected] = []
        var indices: [String: Int] = [:]
        func key(_ test: Running) -> String { test.id + "\u{0}" + (test.argument ?? "") }
        let xctest = try! NSRegularExpression(pattern: #"^Test Case '-\[([^ .\]]+)\.([^ \]]+) ([^\]]+)\]' (started|passed|failed|skipped)"#)
        for (number, line) in log.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            if let match = xctest.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                let part = { (index: Int) in String(text[Range(match.range(at: index), in: text)!]) }
                let id = "\(part(1))/\(part(2))/\(part(3))"
                if part(4) == "started" { running.append(Running(name: id, id: id)) } else { running.removeAll { $0.id == id } }
                continue
            }
            if swiftTestingBody(line) != nil {
                switch swiftTestingEvent(line) {
                case let .suiteStarted(name): suites.append(name)
                case let .suiteEnded(name): if let index = suites.lastIndex(of: name) { suites.remove(at: index) }
                case let .testStarted(name):
                    // In parallel runs a test name can be in several running suites; take one not already running.
                    let candidates = suites.reversed().compactMap { tests[$0]?[name] }
                    let id = candidates.first { id in !running.contains { $0.id == id } } ?? candidates.first ?? name
                    running.append(Running(name: name, id: id))
                case let .testEnded(name):
                    if let index = running.firstIndex(where: { $0.name == name }) { running.remove(at: index) }
                case let .caseStarted(test, arguments):
                    if let index = running.lastIndex(where: { $0.name == test }) { running[index].argument = arguments }
                case let .issue(name):
                    if let test = running.last(where: { $0.name == name }), let index = indices[key(test)],
                       collected[index].linesBeforeIssue == nil {
                        collected[index].linesBeforeIssue = collected[index].lines.count
                    }
                case nil: break
                }
                continue
            }
            guard !running.isEmpty,
                  line.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+([+-]\d{4})? [^ \[]+\[\d+(:[0-9a-fx]+)?\]"#,
                             options: .regularExpression) == nil,
                  !line.contains(": error: -[") else { continue }
            for test in running {
                let index = indices[key(test)] ?? {
                    collected.append(Collected(test: test.id, argument: test.argument, line: number + 1))
                    indices[key(test)] = collected.count - 1
                    return collected.count - 1
                }()
                collected[index].lines.append(text)
                if running.count > 1 { collected[index].interleaved = true }
            }
        }
        return collected.map { entry in
            var text = entry.lines.joined(separator: "\n")
            if text.count > limit { text = "…" + text.suffix(limit) }
            let beforeIssue = entry.linesBeforeIssue.flatMap { count -> String? in
                count == 0 ? nil : entry.lines[..<count].suffix(20).joined(separator: "\n")
            }
            return TestOutput(test: entry.test, argument: entry.argument, logLine: entry.line, text: text,
                              beforeIssue: beforeIssue, interleaved: entry.interleaved)
        }
    }

    private static func unquoted(_ name: Substring) -> String {
        name.count >= 2 && name.hasPrefix("\"") && name.hasSuffix("\"") ? String(name.dropFirst().dropLast()) : String(name)
    }

    struct ManifestEntry: Equatable {
        let test: String
        /// The id `xcresulttool … --test-id` takes ("Suite/test()").
        let testIdentifier: String?
        let file: String
        /// Xcode's name for it, "drift_0_<UUID>.txt", which the activities use too.
        let suggested: String
        let name: String
    }

    /// Parses the manifest.json `xcresulttool export attachments` writes. Names lose the
    /// "_<index>_<UUID>" Xcode appends: "drift_0_E8FD….txt" → "drift.txt".
    static func parseAttachmentManifest(_ data: Data) throws -> [ManifestEntry] {
        struct Test: Decodable { let testIdentifier: String?; let testIdentifierURL: String?; let attachments: [File] }
        struct File: Decodable { let exportedFileName: String; let suggestedHumanReadableName: String? }
        return try JSONDecoder().decode([Test].self, from: data).flatMap { test in
            test.attachments.map { file in
                let suggested = file.suggestedHumanReadableName ?? file.exportedFileName
                let name = suggested.replacingOccurrences(
                    of: #"_\d+_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?=\.[^.]+$|$)"#,
                    with: "", options: .regularExpression)
                return ManifestEntry(test: testID(url: test.testIdentifierURL) ?? test.testIdentifier ?? "",
                                     testIdentifier: test.testIdentifier, file: file.exportedFileName,
                                     suggested: suggested, name: name)
            }
        }
    }

    /// Attachment name → the argument values of the test run that recorded it, from
    /// `xcresulttool get test-results activities`.
    static func attachmentArguments(_ data: Data) throws -> [String: String] {
        struct Activities: Decodable { let testRuns: [Run] }
        struct Run: Decodable { let activities: [Activity]?; let arguments: [Argument]? }
        struct Argument: Decodable { let value: String }
        struct Activity: Decodable { let attachments: [Attachment]?; let childActivities: [Activity]? }
        struct Attachment: Decodable { let name: String }
        var arguments: [String: String] = [:]
        for run in try JSONDecoder().decode(Activities.self, from: data).testRuns {
            guard let values = run.arguments, !values.isEmpty else { continue }
            func visit(_ activity: Activity) {
                activity.attachments?.forEach { arguments[$0.name] = values.map(\.value).joined(separator: ", ") }
                activity.childActivities?.forEach(visit)
            }
            run.activities?.forEach(visit)
        }
        return arguments
    }

    /// A test id as a folder name that needs no quoting: "Target/Suite/drift(speed:)" → "Suite.drift-speed".
    static func folderName(_ test: String) -> String {
        let name = test.split(separator: "/").dropFirst().joined(separator: ".").replacingOccurrences(of: "()", with: "")
        let safe = name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? String($0) : "-" }.joined()
        return safe.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Exports the bundle's attachments to `directory/<Suite.test>/<name>`, keeping the text of small text
    /// files. For `parameterized` tests, reads which argument case recorded each one.
    static func exportAttachments(bundle: URL, to directory: URL, parameterized: Set<String> = []) throws -> [TestAttachment] {
        let fileManager = FileManager.default
        let raw = fileManager.temporaryDirectory.appendingPathComponent("ios-attachments-\(UUID().uuidString)")
        try fileManager.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: raw) }
        let export = try Shell.run("/usr/bin/xcrun", ["xcresulttool", "export", "attachments", "--path", bundle.path,
                                                      "--output-path", raw.path])
        guard export.status == 0,
              let manifest = try? Data(contentsOf: raw.appendingPathComponent("manifest.json")) else { return [] }
        let entries = try parseAttachmentManifest(manifest)
        var arguments: [String: String] = [:]
        for testIdentifier in Set(entries.filter { parameterized.contains($0.test) }.compactMap(\.testIdentifier)) {
            let activities = try? Shell.run("/usr/bin/xcrun", ["xcresulttool", "get", "test-results", "activities",
                                                               "--path", bundle.path, "--test-id", testIdentifier])
            if let activities, activities.status == 0, let found = try? attachmentArguments(activities.stdout) {
                arguments.merge(found) { first, _ in first }
            }
        }
        var attachments: [TestAttachment] = []
        for entry in entries {
            let folder = directory.appendingPathComponent(folderName(entry.test))
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            var destination = folder.appendingPathComponent(entry.name)
            var copy = 2
            while fileManager.fileExists(atPath: destination.path) {
                let base = (entry.name as NSString).deletingPathExtension, ext = (entry.name as NSString).pathExtension
                destination = folder.appendingPathComponent("\(base)-\(copy)" + (ext.isEmpty ? "" : ".\(ext)"))
                copy += 1
            }
            try fileManager.moveItem(at: raw.appendingPathComponent(entry.file), to: destination)
            let data = try? Data(contentsOf: destination)
            let text = data.flatMap { $0.count <= 4096 && !$0.contains(0) ? String(data: $0, encoding: .utf8) : nil }
            attachments.append(TestAttachment(test: entry.test, argument: arguments[entry.suggested],
                                              name: destination.lastPathComponent, path: destination.path, text: text))
        }
        return attachments
    }

    private static func failureMessages(_ nodes: [Node], arguments: String?) -> [TestFailure] {
        nodes.filter { $0.nodeType == "Failure Message" }.map {
            TestFailure(message: $0.name, file: $0.sourceLocation?.filePath, line: $0.sourceLocation?.lineNumber,
                        arguments: arguments)
        }
    }

    /// `test://com.apple.xcode/<Project>/<Target>/<Suite>/<test>` → `<Target>/<Suite>/<test>`, which is
    /// the spelling `-only-testing:` wants (Swift Testing keeps the parentheses, XCTest drops them).
    static func testID(url: String?) -> String? {
        guard let url, let components = URLComponents(string: url), components.scheme == "test" else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/").dropFirst()
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/").removingPercentEncoding
    }

    static func normalized(_ result: String?) -> String {
        switch result {
        case "Passed": "passed"
        case "Failed": "failed"
        case "Skipped": "skipped"
        case "Expected Failure": "expected-failure"
        default: (result ?? "unknown").lowercased()
        }
    }

    static func skipReason(_ message: String) -> String {
        message.hasPrefix("Test skipped: ") ? String(message.dropFirst("Test skipped: ".count)) : message
    }

    /// xcodebuild's own errors, for runs that failed before any test started (no destination,
    /// scheme not configured for testing, test runner failed to launch…).
    static func logIssues(_ log: String) -> [String] {
        var seen = Set<String>()
        var issues: [String] = []
        var inFailureBlock = false
        for raw in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // "Testing failed:" is followed by tab-indented reasons up to a blank line.
            if line == "Testing failed:" { inFailureBlock = true; continue }
            if inFailureBlock && !raw.hasPrefix("\t") { inFailureBlock = false }
            guard inFailureBlock || line.hasPrefix("xcodebuild: error:")
                    || line.contains("Test runner exited") || line.contains("Early unexpected exit") else { continue }
            let text = line.replacingOccurrences(of: "xcodebuild: error: ", with: "")
            if !text.isEmpty, seen.insert(text).inserted { issues.append(text) }
        }
        return issues
    }
}
