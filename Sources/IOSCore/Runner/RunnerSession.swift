import Foundation

/// A running UI automation server for one simulator or device.
public struct RunnerSession: Codable, Sendable {
    public let udid: String
    public let host: String
    public let port: UInt16
    public let pid: Int32
    public let log: String
    public let startedAt: Date
    /// Hash of the runner source it was built from; a changed runner is restarted.
    public let runnerVersion: String

    public struct Reply {
        public let result: Any?
        public let elapsed: Double
    }

    /// Sends one command and returns its result; throws the runner's error message.
    public func send(_ command: String, timeout: TimeInterval = 60) throws -> Reply {
        let data = try TCPClient.request(host: host, port: port, line: command, timeout: timeout)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IOSError.runnerUnreachable(host: host, port: port, reason: "no reply (the runner may have stopped; see \(log))")
        }
        guard object["ok"] as? Bool == true else {
            throw IOSError.runnerCommandFailed(command: command, message: object["error"] as? String ?? "unknown error")
        }
        return Reply(result: object["result"], elapsed: object["elapsed"] as? Double ?? 0)
    }
}

public enum RunnerSessions {
    static var stateDirectory: URL { RunnerBuild.directory.appendingPathComponent("sessions") }

    static func stateFile(_ udid: String) -> URL { stateDirectory.appendingPathComponent("\(udid).json") }

    /// The target's live session, starting the runner if needed (~5–15 s, plus a one-time build).
    public static func ensure(_ target: Target, signing: RunnerSigning, progress: (String) -> Void) throws -> RunnerSession {
        let version = try RunnerBuild.sourceHash(RunnerBuild.sourceDirectory())
        if let session = current(target) {
            if session.runnerVersion == version { return session }
            progress("Restarting the UI automation runner (it was built from older code)…")
        }
        // Clear anything left over (older state formats, a runner that stopped answering, or
        // another runner on our port), so the new one can bind the port.
        stop(target)
        _ = try? TCPClient.request(host: try address(of: target), port: port(for: target), line: "quit", timeout: 2)

        try Launcher.prepare(target)
        let xctestrun = try RunnerBuild.xctestrun(for: target, signing: signing, progress: progress)
        let host = try address(of: target)
        let port = port(for: target)
        let log = RunnerBuild.directory.appendingPathComponent("logs/\(target.udid).log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)

        progress("Starting the UI automation runner on \(target.label)…")
        // nohup + background so the runner outlives this command; it's the long-lived server.
        // TEST_RUNNER_-prefixed variables reach the test process without the prefix.
        let script = "nohup /usr/bin/xcrun xcodebuild test-without-building -xctestrun \"$1\" -destination \"id=$2\" "
            + "-destination-timeout 60 > \"$3\" 2>&1 & echo $!"
        let started = try Shell.run("/bin/sh", ["-c", script, "sh", xctestrun.path, target.udid, log.path],
                                    environment: ["TEST_RUNNER_IOS_CLI_PORT": String(port)])
        guard let pid = Int32(started.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw IOSError.runnerStartFailed(log: log.path, detail: started.stderr)
        }

        let session = RunnerSession(udid: target.udid, host: host, port: port, pid: pid, log: log.path,
                                    startedAt: Date(), runnerVersion: version)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if (try? session.send("ping", timeout: 2)) != nil {
                try save(session)
                return session
            }
            if kill(pid, 0) != 0 { // xcodebuild exited: build/launch failure
                throw IOSError.runnerStartFailed(log: log.path, detail: tail(of: log))
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        kill(pid, SIGTERM)
        throw IOSError.runnerStartFailed(log: log.path, detail: "timed out waiting for the runner\n" + tail(of: log))
    }

    /// The saved session if its runner still answers.
    public static func current(_ target: Target) -> RunnerSession? {
        guard
            let data = try? Data(contentsOf: stateFile(target.udid)),
            let session = try? JSONDecoder().decode(RunnerSession.self, from: data),
            (try? session.send("ping", timeout: 3)) != nil
        else { return nil }
        return session
    }

    /// Stops the target's runner. Returns false if none was running.
    @discardableResult
    public static func stop(_ target: Target) -> Bool {
        guard let data = try? Data(contentsOf: stateFile(target.udid)) else { return false }
        if let session = try? JSONDecoder().decode(RunnerSession.self, from: data) {
            _ = try? session.send("quit", timeout: 3)
        }
        // Read the PID leniently so state files from older versions still get cleaned up.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0, kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: stateFile(target.udid))
        return true
    }

    /// The last app driven on a target, kept across runner restarts.
    public static func lastApp(for target: Target) -> String? {
        (try? String(contentsOf: stateDirectory.appendingPathComponent("\(target.udid).app"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func rememberApp(_ bundleIdentifier: String, for target: Target) {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try? bundleIdentifier.write(to: stateDirectory.appendingPathComponent("\(target.udid).app"), atomically: true, encoding: .utf8)
    }

    static func save(_ session: RunnerSession) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: stateFile(session.udid), options: .atomic)
    }

    /// Simulators share the Mac's network stack; devices are reached through their CoreDevice tunnel.
    static func address(of target: Target) throws -> String {
        switch target {
        case .simulator: return "127.0.0.1"
        case let .device(device):
            let fresh = try DeviceList.load().first { $0.udid == device.udid } ?? device
            guard let address = fresh.tunnelAddress, fresh.isConnected else {
                throw IOSError.runnerUnreachable(host: device.name, port: 0, reason: "the device isn't connected (is it locked or asleep?)")
            }
            return address
        }
    }

    /// Simulators share one port space, so each gets its own port derived from its UDID.
    static func port(for target: Target) -> UInt16 {
        guard target.isSimulator else { return 8100 }
        var hash: UInt32 = 2_166_136_261 // FNV-1a: stable across runs, unlike hashValue
        for byte in target.udid.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return 8101 + UInt16(hash % 800)
    }

    static func tail(of log: URL, lines: Int = 15) -> String {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
