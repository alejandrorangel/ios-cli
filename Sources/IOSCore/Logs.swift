import Foundation

public struct LogEntry: Codable, Equatable, Sendable {
    public let timestamp: String?
    /// Unified-log message type (Default, Info, Debug, Error, Fault); nil for console lines.
    public let level: String?
    public let subsystem: String?
    public let category: String?
    public let process: String?
    public let pid: Int?
    public let message: String
    /// "unifiedLog" or "console".
    public let source: String

    public var textLine: String {
        guard source == "unifiedLog" else { return message }
        let time = timestamp.map { String($0.dropFirst(11).prefix(12)) } ?? "" // HH:mm:ss.SSS
        let origin = [subsystem, category].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "/")
        return "\(time) [\(level ?? "?")] \(origin.isEmpty ? "" : origin + ": ")\(message)"
    }
}

public struct LogRequest: Sendable {
    public enum Mode: Sendable {
        /// Follow the unified log (simulator only without root).
        case stream
        /// Unified-log history, e.g. "5m" (simulator only).
        case history(String)
        /// Relaunch the app with its stdout/stderr attached (simulator or device).
        case launch
    }

    public let target: Target
    public let bundleIdentifier: String?
    public let process: String?
    public let mode: Mode
    public let level: String?
    public let subsystem: String?
    public let duration: Double?

    public init(target: Target, bundleIdentifier: String?, process: String?, mode: Mode,
                level: String?, subsystem: String?, duration: Double?) {
        self.target = target
        self.bundleIdentifier = bundleIdentifier
        self.process = process
        self.mode = mode
        self.level = level
        self.subsystem = subsystem
        self.duration = duration
    }
}

public enum Logs {
    /// Runs the request and calls `onEntry` for each log entry until it ends or times out.
    public static func run(_ request: LogRequest, onEntry: (LogEntry) -> Void) throws {
        switch (request.mode, request.target) {
        case let (.launch, target):
            guard let bundleID = request.bundleIdentifier else { throw IOSError.logsNeedBundleID }
            try launchWithConsole(bundleID, on: target, duration: request.duration, onEntry: onEntry)

        case (.stream, .device), (.history, .device):
            throw IOSError.deviceLogsNeedLaunch

        case let (mode, .simulator(sim)):
            let process = try request.process ?? request.bundleIdentifier.map { try executableName(of: $0, on: sim) }
            guard let process else { throw IOSError.logsNeedBundleID }
            var predicate = "process == \"\(process)\""
            if let subsystem = request.subsystem { predicate += " AND subsystem == \"\(subsystem)\"" }

            var arguments = ["simctl", "spawn", sim.udid, "log"]
            if case let .history(window) = mode {
                arguments += ["show", "--last", window]
            } else {
                arguments += ["stream"]
            }
            arguments += ["--style", "ndjson", "--predicate", predicate]
            if let level = request.level { arguments += ["--level", level] }

            try Shell.stream("/usr/bin/xcrun", arguments, duration: request.duration) { line in
                if let entry = parseUnifiedLogLine(line) { onEntry(entry) }
            }
        }
    }

    /// Relaunches the app attached to its console. OS_ACTIVITY_DT_MODE makes os_log/Logger
    /// messages appear on stderr too, the way Xcode's console shows them.
    static func launchWithConsole(_ bundleID: String, on target: Target, duration: Double?, onEntry: (LogEntry) -> Void) throws {
        func forward(_ raw: String) {
            // Consoles attached through a PTY end lines with \r\n.
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard !line.isEmpty else { return }
            onEntry(LogEntry(timestamp: nil, level: nil, subsystem: nil, category: nil,
                             process: nil, pid: nil, message: line, source: "console"))
        }
        switch target {
        case let .simulator(s):
            try Launcher.prepare(target)
            try Shell.stream(
                "/usr/bin/xcrun",
                ["simctl", "launch", "--console-pty", "--terminate-running-process", s.udid, bundleID],
                environment: ["SIMCTL_CHILD_OS_ACTIVITY_DT_MODE": "1"],
                includeStderr: true, duration: duration, onLine: forward
            )
        case let .device(d):
            try Shell.stream(
                "/usr/bin/xcrun",
                ["devicectl", "device", "process", "launch", "--device", d.udid, "--terminate-existing",
                 "--console", "--environment-variables", #"{"OS_ACTIVITY_DT_MODE":"1"}"#, bundleID],
                includeStderr: true, duration: duration
            ) { line in
                if !isDevicectlStatus(line) { forward(line) }
            }
        }
    }

    /// devicectl's own progress lines, mixed into the app's console output.
    static func isDevicectlStatus(_ line: String) -> Bool {
        line.hasPrefix("Launched application with ") || line.hasPrefix("Waiting for the application to terminate")
    }

    /// The process name to filter on: the app's CFBundleExecutable.
    static func executableName(of bundleID: String, on sim: Simulator) throws -> String {
        let info = try Shell.checked("/usr/bin/xcrun", ["simctl", "appinfo", sim.udid, bundleID]).stdoutString
        guard let name = parseExecutableName(info) else {
            throw IOSError.appNotInstalled(bundleID: bundleID, udid: sim.udid)
        }
        return name
    }

    /// Reads CFBundleExecutable from `simctl appinfo` (old-style plist text).
    static func parseExecutableName(_ appinfo: String) -> String? {
        guard let match = appinfo.firstMatch(of: /CFBundleExecutable = "?([^";]+)"?;/) else { return nil }
        return String(match.1)
    }

    /// Converts one `log --style ndjson` line; skips preamble and summary lines.
    public static func parseUnifiedLogLine(_ line: String) -> LogEntry? {
        guard
            line.hasPrefix("{"),
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let message = object["eventMessage"] as? String
        else { return nil }
        let image = object["processImagePath"] as? String
        return LogEntry(
            timestamp: object["timestamp"] as? String,
            level: object["messageType"] as? String,
            subsystem: object["subsystem"] as? String,
            category: object["category"] as? String,
            process: image.map { ($0 as NSString).lastPathComponent },
            pid: object["processID"] as? Int,
            message: message,
            source: "unifiedLog"
        )
    }
}
