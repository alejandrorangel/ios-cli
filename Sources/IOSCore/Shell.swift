import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}

/// Lets the timeout closure stop a process; Process itself isn't Sendable.
final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

public enum Shell {
    /// Runs a developer tool through `xcrun`, so the Xcode chosen by `xcode-select` is used.
    @discardableResult
    public static func xcrun(_ arguments: [String]) throws -> CommandResult {
        try run("/usr/bin/xcrun", arguments)
    }

    /// Runs a tool and fails with `IOSError.toolFailed` on a non-zero exit.
    @discardableResult
    public static func checked(_ path: String, _ arguments: [String], in directory: String? = nil) throws -> CommandResult {
        let result = try run(path, arguments, in: directory)
        guard result.status == 0 else {
            throw IOSError.toolFailed(
                command: ([path] + arguments).joined(separator: " "),
                status: result.status,
                stderr: result.stderr
            )
        }
        return result
    }

    /// Runs a tool with stdout and stderr written to `log`, for long, verbose tools like
    /// `xcodebuild build`. Returns the exit status; callers parse the log afterwards.
    public static func run(_ path: String, _ arguments: [String], log: URL, in directory: String? = nil) throws -> Int32 {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs a long-lived tool (log stream, app console) and calls `onLine` for each output line.
    /// Stops the tool after `duration` seconds when given. stderr is merged into the stream
    /// when `includeStderr` is set (app consoles write most output there).
    @discardableResult
    public static func stream(
        _ path: String, _ arguments: [String], environment: [String: String] = [:],
        includeStderr: Bool = false, duration: Double? = nil, onLine: (String) -> Void
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = includeStderr ? pipe : FileHandle.nullDevice
        try process.run()

        if let duration {
            let box = ProcessBox(process)
            DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
                if box.process.isRunning { box.process.terminate() }
            }
        }

        // availableData blocks until output arrives and returns empty at EOF (tool exited).
        var buffer = Data()
        let handle = pipe.fileHandleForReading
        while case let chunk = handle.availableData, !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                onLine(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
        process.waitUntilExit()
        return process.terminationStatus
    }

    public static func run(_ path: String, _ arguments: [String], in directory: String? = nil,
                           environment: [String: String] = [:]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        // stderr goes to a temp file: reading two pipes one after the other can deadlock
        // when the unread one fills its buffer (devicectl and xcodebuild are chatty there).
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-cli-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        let errHandle = try FileHandle(forWritingTo: errURL)

        let out = Pipe()
        process.standardOutput = out
        process.standardError = errHandle
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try errHandle.close()

        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
