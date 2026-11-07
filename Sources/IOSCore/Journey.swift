import Foundation

/// A journey: a user flow written as plain-language steps, in the same XML as the Android CLI's
/// journeys, so one file can describe a flow for both apps. An agent carries out the steps with
/// `ios layout` / `ios input` / `ios screen`; ios-cli finds and parses the files, applies the
/// optional iOS `<setup>`, and turns the agent's result JSON into the Android-style report.
///
///     <journey name="Loop a section">
///       <description>Practice Mode loops the selected bars</description>
///       <setup platform="ios">
///         <launch bundle-id="com.example.app">
///           <argument>-SkipOnboarding</argument><argument>YES</argument>
///           <env name="API_ENV" value="staging"/>
///         </launch>
///         <open-url>example://practice/42</open-url>
///       </setup>
///       <actions>
///         <action>Tap "Loop"</action>
///         <action>Verify that bars 1–4 are highlighted</action>
///       </actions>
///     </journey>
public struct Journey: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public let index: Int
        public let text: String
        /// "check" for steps starting with check/verify (inspect only, don't interact), else "action".
        public let kind: String
    }

    public struct Setup: Codable, Equatable, Sendable {
        public let bundleID: String?
        public let arguments: [String]
        public let environment: [String: String]
        public let urls: [String]
    }

    public let name: String
    public let description: String?
    public let file: String
    public let setup: Setup?
    public let steps: [Step]
}

public enum Journeys {
    public static let fileSuffix = ".journey.xml"

    public static func parse(file: String) throws -> Journey {
        let url = URL(fileURLWithPath: file).standardizedFileURL
        guard let data = try? Data(contentsOf: url) else { throw IOSError.failed("Can't read \(url.path).") }
        return try parse(data, file: url.path)
    }

    public static func parse(_ data: Data, file: String) throws -> Journey {
        let document: XMLDocument
        do { document = try XMLDocument(data: data) } catch {
            throw IOSError.failed("\(file) isn't valid XML: \(error.localizedDescription)")
        }
        guard let root = document.rootElement(), root.name == "journey" else {
            throw IOSError.failed("\(file): the root element must be <journey>.")
        }
        func text(_ node: XMLNode?) -> String? {
            let value = node?.stringValue?.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            return value?.isEmpty == false ? value : nil
        }
        let actions = root.elements(forName: "actions").first?.elements(forName: "action") ?? []
        guard !actions.isEmpty else { throw IOSError.failed("\(file): <actions> has no <action> steps.") }
        let steps = try actions.enumerated().map { offset, element in
            guard let value = text(element) else { throw IOSError.failed("\(file): action \(offset + 1) is empty.") }
            return Journey.Step(index: offset + 1, text: value, kind: isCheck(value) ? "check" : "action")
        }
        // <setup platform="ios"> wins over a <setup> with no platform; other platforms' setups are ignored.
        let setups = root.elements(forName: "setup")
        let setupElement = setups.first { $0.attribute(forName: "platform")?.stringValue == "ios" }
            ?? setups.first { $0.attribute(forName: "platform") == nil }
        let setup = setupElement.map { element -> Journey.Setup in
            let launch = element.elements(forName: "launch").first
            var environment: [String: String] = [:]
            for env in launch?.elements(forName: "env") ?? [] {
                if let name = env.attribute(forName: "name")?.stringValue {
                    environment[name] = env.attribute(forName: "value")?.stringValue ?? ""
                }
            }
            return Journey.Setup(
                bundleID: launch?.attribute(forName: "bundle-id")?.stringValue,
                arguments: (launch?.elements(forName: "argument") ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) },
                environment: environment,
                urls: element.elements(forName: "open-url").compactMap { text($0) }
            )
        }
        return Journey(name: root.attribute(forName: "name")?.stringValue ?? URL(fileURLWithPath: file).lastPathComponent,
                       description: text(root.elements(forName: "description").first), file: file, setup: setup, steps: steps)
    }

    static func isCheck(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("check") || lower.hasPrefix("verify")
    }

    /// Journey files under `directory` (skipping build output and dependencies), sorted by path.
    public static func find(in directory: String) -> [String] {
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        let skipped: Set<String> = [".build", "build", "DerivedData", "Pods", "Carthage", "node_modules", ".git", ".swiftpm"]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var files: [String] = []
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if url.lastPathComponent.hasSuffix(fileSuffix) { files.append(url.path) }
        }
        return files.sorted()
    }

    // MARK: Results

    /// What the agent records while running a journey; `ios journey report` checks it and writes the report.
    public struct Result: Codable, Sendable {
        public struct StepResult: Codable, Sendable {
            public let index: Int
            public let text: String?
            /// "passed", "failed" or "notRun" (after an earlier failure).
            public let result: String
            public let commands: [String]?
            public let screenshot: String?
            public let comment: String?
        }

        public let journey: String
        public let file: String?
        public let device: String?
        public let app: String?
        public let startedAt: String?
        public let finishedAt: String?
        /// "passed", "failed" or "malformed" (a step that isn't a UI action or check).
        public let result: String
        public let steps: [StepResult]
        public let summary: String?
    }

    static let stepResults: Set<String> = ["passed", "failed", "notRun"]
    static let journeyResults: Set<String> = ["passed", "failed", "malformed"]

    /// Reads a result file, checking it against its journey when the journey file is known.
    public static func readResult(_ path: String) throws -> (Result, Journey?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw IOSError.failed("Can't read \(path).") }
        let result: Result
        do { result = try JSONDecoder().decode(Result.self, from: data) } catch {
            throw IOSError.failed("\(path) isn't a journey result: \(error). See `ios help journey report` for the format.")
        }
        var problems: [String] = []
        if !journeyResults.contains(result.result) { problems.append("result must be passed, failed or malformed, not '\(result.result)'") }
        for step in result.steps where !stepResults.contains(step.result) {
            problems.append("step \(step.index): result must be passed, failed or notRun, not '\(step.result)'")
        }
        if result.result == "passed", let failed = result.steps.first(where: { $0.result != "passed" }) {
            problems.append("the journey is marked passed but step \(failed.index) is \(failed.result)")
        }
        var journey: Journey?
        if let file = result.file {
            let resolved = file.hasPrefix("/") ? file : URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(file).path
            journey = try? parse(file: FileManager.default.fileExists(atPath: resolved) ? resolved : file)
            if let journey, journey.steps.count != result.steps.count {
                problems.append("the journey has \(journey.steps.count) steps but the result lists \(result.steps.count)")
            }
        }
        guard problems.isEmpty else { throw IOSError.failed("\(path): " + problems.joined(separator: "; ") + ".") }
        return (result, journey)
    }

    /// The Markdown report, in the Android CLI's journey report layout.
    public static func markdown(_ result: Result, journey: Journey?) -> String {
        var lines = ["# Journey: \(result.journey)", ""]
        var facts: [String] = []
        if let device = result.device { facts.append("**Device**: \(device)") }
        if let app = result.app { facts.append("**App**: \(app)") }
        if let started = result.startedAt { facts.append("**Started**: \(started)") }
        facts.append("**Result**: \(result.result == "passed" ? "✅ passed" : result.result == "malformed" ? "⚠️ malformed" : "❌ failed")")
        lines += facts.map { "- \($0)" } + ["", "## Results", ""]
        for step in result.steps {
            let text = step.text ?? journey?.steps.first { $0.index == step.index }?.text ?? "Step \(step.index)"
            let mark = step.result == "passed" ? " ✅" : step.result == "failed" ? " ❌" : ""
            lines.append("### Action: \(text)\(mark)")
            if let commands = step.commands, !commands.isEmpty {
                lines.append("- **Commands**:")
                lines += commands.map { "  - `\($0)`" }
            }
            if let screenshot = step.screenshot {
                lines.append("- **Screenshot**: [\(URL(fileURLWithPath: screenshot).lastPathComponent)](\(screenshot))")
            }
            if let comment = step.comment { lines.append("- **Comment**: \(comment)") }
            lines.append("")
        }
        if let summary = result.summary { lines += ["## Summary", "", summary, ""] }
        return lines.joined(separator: "\n")
    }
}
