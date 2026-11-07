import Foundation

/// Records an Instruments trace with `xctrace` and summarizes the Time Profiler samples:
/// where the time went, by function, for the app's own code and overall.
public enum Profiler {
    public struct Request: Sendable {
        public var target: Target
        public var template: String
        /// An .app to install and launch under the profiler (no admin authorization needed).
        public var app: String?
        /// Or a running process to attach to (pid or name); attaching needs Developer Tools access.
        public var attach: String?
        public var seconds: Double
        public var output: String
        public var arguments: [String]
        public var environment: [String: String] = [:]

        public init(target: Target, template: String, app: String?, attach: String?, seconds: Double, output: String, arguments: [String]) {
            self.target = target
            self.template = template
            self.app = app
            self.attach = attach
            self.seconds = seconds
            self.output = output
            self.arguments = arguments
        }
    }

    public struct FunctionTime: Codable, Sendable {
        public let function: String
        public let binary: String
        /// Milliseconds of samples with this function on top of the stack.
        public let selfMs: Double
        /// Milliseconds of samples with this function anywhere on the stack.
        public let totalMs: Double
    }

    public struct Summary: Codable, Sendable {
        public let trace: String
        public let template: String
        public let process: String?
        /// Milliseconds of running samples in the process.
        public let sampledMs: Double
        public let threads: [ThreadTime]
        /// Functions in the app's own binaries (the .app and its frameworks), heaviest first.
        public let appFunctions: [FunctionTime]
        /// All functions by self time, heaviest first.
        public let topSelf: [FunctionTime]
        public let tables: [String]

        public struct ThreadTime: Codable, Sendable {
            public let thread: String
            public let ms: Double
        }
    }

    public static let defaultTemplate = "Time Profiler"

    /// Simulator attach needs the developer tools to be allowed to inspect processes; without it,
    /// xctrace waits for an admin password nobody sees.
    public static func attachAllowed() -> Bool {
        let status = (try? Shell.run("/usr/sbin/DevToolsSecurity", ["-status"]))?.stdoutString ?? ""
        return status.contains("enabled")
    }

    public static func record(_ request: Request, progress: (String) -> Void) throws {
        let output = URL(fileURLWithPath: request.output).standardizedFileURL
        try? FileManager.default.removeItem(at: output)
        var arguments = ["xctrace", "record", "--template", request.template, "--device", request.target.udid,
                         "--time-limit", "\(Int(request.seconds.rounded(.up)))s", "--output", output.path, "--no-prompt"]
        if let attach = request.attach {
            if request.target.isSimulator, !attachAllowed() {
                throw IOSError.failed("""
                    Attaching to a simulator process needs Developer Tools access, which is off on this Mac \
                    (xctrace would wait for an admin password). Either run `sudo DevToolsSecurity -enable` once, \
                    or profile from launch with --app <path to the .app>.
                    """)
            }
            arguments += ["--attach", attach]
        } else if let app = request.app {
            arguments += request.environment.keys.sorted().flatMap { ["--env", "\($0)=\(request.environment[$0]!)"] }
            arguments += ["--launch", "--", URL(fileURLWithPath: app).standardizedFileURL.path] + request.arguments
        }
        progress("Recording \(request.template) for \(Int(request.seconds)) s…")
        let log = output.deletingPathExtension().appendingPathExtension("log")
        let status = try Shell.run("/usr/bin/xcrun", arguments, log: log)
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard FileManager.default.fileExists(atPath: output.path), !text.contains("Recording failed") else {
            throw IOSError.failed("xctrace couldn't record (exit \(status)): "
                + (text.split(separator: "\n").last { !$0.isEmpty }.map(String.init) ?? "no output") + "\nLog: \(log.path)")
        }
        try? FileManager.default.removeItem(at: log)
    }

    /// The trace's table names (what can be exported).
    public static func tables(_ trace: String) throws -> [String] {
        let toc = try Shell.checked("/usr/bin/xcrun", ["xctrace", "export", "--input", trace, "--toc"]).stdoutString
        let names = toc.matches(of: /<table [^>]*?schema="([^"]+)"/).map { String($0.1) }
        return Array(Set(names)).sorted()
    }

    public static func summarize(_ trace: String, template: String, appBinaries: Set<String>, limit: Int = 15) throws -> Summary {
        let tables = try tables(trace)
        var summary = Summary(trace: trace, template: template, process: nil, sampledMs: 0, threads: [], appFunctions: [], topSelf: [], tables: tables)
        guard tables.contains("time-profile") else { return summary }
        let xml = try Shell.checked("/usr/bin/xcrun", [
            "xctrace", "export", "--input", trace, "--xpath", #"/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]"#,
        ]).stdout
        let samples = TimeProfileParser.parse(xml)
        summary = aggregate(samples, trace: trace, template: template, tables: tables, appBinaries: appBinaries, limit: limit)
        return summary
    }

    struct Sample {
        let thread: String
        let process: String
        let running: Bool
        let weightNs: Double
        /// Leaf first.
        let frames: [(name: String, binary: String)]
    }

    static func aggregate(_ samples: [Sample], trace: String, template: String, tables: [String], appBinaries: Set<String>, limit: Int) -> Summary {
        let running = samples.filter(\.running)
        // The launched or attached app is the busiest process in its own recording.
        let byProcess = Dictionary(grouping: running, by: \.process).mapValues { $0.reduce(0) { $0 + $1.weightNs } }
        let process = byProcess.max { $0.value < $1.value }?.key
        let mine = running.filter { $0.process == process }
        var selfTime: [String: (binary: String, ns: Double)] = [:]
        var totalTime: [String: Double] = [:]
        var threads: [String: Double] = [:]
        for sample in mine {
            // "Main Thread (0x44f414d) (SampleApp, pid: 2850)": the process is already named once.
            threads[sample.thread.replacing(/\s\([^()]*, pid: \d+\)$/, with: ""), default: 0] += sample.weightNs
            if let leaf = sample.frames.first { selfTime[leaf.name, default: (leaf.binary, 0)].ns += sample.weightNs }
            // Count each function once per sample, however deep its recursion.
            var seen = Set<String>()
            for frame in sample.frames where seen.insert(frame.name).inserted {
                totalTime[frame.name, default: 0] += sample.weightNs
                if selfTime[frame.name] == nil { selfTime[frame.name] = (frame.binary, 0) }
            }
        }
        let functions = selfTime.map { name, value in
            FunctionTime(function: name, binary: value.binary, selfMs: value.ns / 1e6, totalMs: (totalTime[name] ?? value.ns) / 1e6)
        }
        let appFunctions = functions.filter { appBinaries.contains($0.binary) }
            .sorted { $0.totalMs != $1.totalMs ? $0.totalMs > $1.totalMs : $0.selfMs > $1.selfMs }
        return Summary(
            trace: trace, template: template, process: process, sampledMs: mine.reduce(0) { $0 + $1.weightNs } / 1e6,
            threads: threads.map { Summary.ThreadTime(thread: $0.key, ms: $0.value / 1e6) }.sorted { $0.ms > $1.ms }.prefix(8).map { $0 },
            appFunctions: Array(appFunctions.prefix(limit)),
            topSelf: Array(functions.filter { $0.selfMs > 0 }.sorted { $0.selfMs > $1.selfMs }.prefix(limit)),
            tables: tables
        )
    }

    /// The executable and framework names inside an .app, to tell the app's code from the system's.
    public static func binaries(inApp path: String) -> Set<String> {
        let app = URL(fileURLWithPath: path)
        var names: Set<String> = [app.deletingPathExtension().lastPathComponent]
        if let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let executable = info["CFBundleExecutable"] as? String {
            names.insert(executable)
            names.insert(executable + ".debug.dylib")
        }
        for item in (try? FileManager.default.contentsOfDirectory(atPath: app.appendingPathComponent("Frameworks").path)) ?? [] {
            names.insert(item.replacingOccurrences(of: ".framework", with: ""))
            names.insert(item)
        }
        return names
    }
}

/// Streams `xctrace export` time-profile XML. Values appear once with an id and later as ref="id",
/// so every element with an id is remembered.
final class TimeProfileParser: NSObject, XMLParserDelegate {
    private var formatted: [String: String] = [:] // id → fmt (thread, process, thread-state…)
    private var values: [String: String] = [:]    // id → text (weight…)
    private var frames: [String: (String, String)] = [:]
    private var binaries: [String: String] = [:]
    private var backtraces: [String: [(String, String)]] = [:]
    private var samples: [Profiler.Sample] = []

    private var row: [String: String] = [:]     // column → id
    private var inRow = false
    private var text = ""
    private var stack: [(name: String, id: String?)] = []
    private var backtrace: [(String, String)]?
    private var backtraceID: String?
    private var frame: (id: String?, name: String, binary: String)?

    static func parse(_ data: Data) -> [Profiler.Sample] {
        let delegate = TimeProfileParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.samples
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        let id = attributes["id"], ref = attributes["ref"]
        if let id, let fmt = attributes["fmt"] { formatted[id] = fmt }
        switch name {
        case "row":
            inRow = true
            row = [:]
        case "tagged-backtrace", "backtrace":
            if let ref { row["backtrace"] = ref } else { backtrace = []; backtraceID = id; row["backtrace"] = id }
        case "frame":
            if let ref, let known = frames[ref] { backtrace?.append(known) } else {
                frame = (id, attributes["name"] ?? attributes["addr"] ?? "???", "")
            }
        case "binary":
            if let ref { frame?.binary = binaries[ref] ?? "" } else {
                let binaryName = attributes["name"] ?? ""
                if let id { binaries[id] = binaryName }
                frame?.binary = binaryName
            }
        default:
            // Top-level columns of the row (thread, process, weight…), by id or ref.
            if inRow, stack.last?.name == "row" { row[name] = ref ?? id }
        }
        stack.append((name, id))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let current = stack.popLast()
        if let id = current?.id, !text.isEmpty { values[id] = text }
        switch name {
        case "frame":
            if let made = frame {
                if let id = made.id { frames[id] = (made.name, made.binary) }
                backtrace?.append((made.name, made.binary))
                frame = nil
            }
        case "tagged-backtrace", "backtrace":
            if let id = backtraceID, let made = backtrace { backtraces[id] = made }
            backtrace = nil
            backtraceID = nil
        case "row":
            inRow = false
            let weight = row["weight"].flatMap { values[$0] }.flatMap(Double.init) ?? 1_000_000
            let state = row["thread-state"].flatMap { formatted[$0] ?? values[$0] } ?? "Running"
            let frames = row["backtrace"].flatMap { backtraces[$0] } ?? []
            samples.append(Profiler.Sample(
                thread: row["thread"].flatMap { formatted[$0] } ?? "?",
                process: row["process"].flatMap { formatted[$0] } ?? "?",
                running: state == "Running", weightNs: weight,
                frames: frames.map { (name: $0.0, binary: $0.1) }
            ))
        default:
            break
        }
        text = ""
    }
}
