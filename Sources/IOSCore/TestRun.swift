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

    public init(container: Container, scheme: String, configuration: String?, destination: Destination,
                derivedDataPath: String?, only: [String], skip: [String], testPlan: String?,
                withoutBuilding: Bool, retries: Int?, team: String? = nil) {
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
                                   log: log, in: request.container.workingDirectory)
        let duration = (Date().timeIntervalSince(start) * 10).rounded() / 10
        let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""

        var cases: [TestCaseResult] = []
        var hasBundle = FileManager.default.fileExists(atPath: bundle.path)
        if hasBundle {
            let tree = try? Shell.run("/usr/bin/xcrun", ["xcresulttool", "get", "test-results", "tests", "--path", bundle.path])
            if let tree, tree.status == 0 { cases = (try? parseTestTree(tree.stdout)) ?? [] } else { hasBundle = false }
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
            hint: Signing.hint(for: buildErrors, team: request.team)
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
            for arguments in children where arguments.nodeType == "Arguments" {
                failures += failureMessages(arguments.children ?? [], arguments: arguments.name)
            }
            cases.append(TestCaseResult(
                id: testID(url: node.nodeIdentifierURL) ?? node.nodeIdentifier ?? node.name,
                name: node.name,
                result: normalized(node.result),
                duration: node.durationInSeconds.map { ($0 * 1000).rounded() / 1000 },
                failures: failures,
                skipReason: children.first { $0.nodeType == "Skip Message" }.map { skipReason($0.name) }
            ))
        }
        tree.testNodes.forEach(visit)
        return cases
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
