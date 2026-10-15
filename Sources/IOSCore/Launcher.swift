import Foundation

public struct LaunchResult: Codable, Sendable {
    public let bundleIdentifier: String
    public let pid: Int?
    public let udid: String
}

public enum Launcher {
    /// Boots a shut-down simulator and waits until it's usable. No-op for devices.
    public static func prepare(_ target: Target) throws {
        guard case let .simulator(s) = target, !s.isBooted else { return }
        try Shell.checked("/usr/bin/xcrun", ["simctl", "boot", s.udid])
        try Shell.checked("/usr/bin/xcrun", ["simctl", "bootstatus", s.udid, "-b"])
    }

    /// CFBundleIdentifier from an .app bundle's Info.plist.
    public static func bundleIdentifier(ofApp appPath: String) throws -> String {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let identifier = info["CFBundleIdentifier"] as? String
        else { throw IOSError.notAnApp(path: appPath) }
        return identifier
    }

    public static func install(_ appPath: String, on target: Target) throws {
        switch target {
        case let .simulator(s):
            try Shell.checked("/usr/bin/xcrun", ["simctl", "install", s.udid, appPath])
        case let .device(d):
            try Shell.checked("/usr/bin/xcrun", ["devicectl", "device", "install", "app", "--device", d.udid, appPath])
        }
    }

    /// Launches (restarting it if running) and returns the new process ID when the tool reports it.
    public static func launch(_ bundleIdentifier: String, on target: Target) throws -> LaunchResult {
        switch target {
        case let .simulator(s):
            let out = try Shell.checked("/usr/bin/xcrun", [
                "simctl", "launch", "--terminate-running-process", s.udid, bundleIdentifier,
            ]).stdoutString
            return LaunchResult(bundleIdentifier: bundleIdentifier, pid: parseSimctlPid(out), udid: s.udid)
        case let .device(d):
            let out = try Shell.checked("/usr/bin/xcrun", [
                "devicectl", "device", "process", "launch", "--device", d.udid,
                "--terminate-existing", bundleIdentifier, "-j", "-",
            ]).stdout
            return LaunchResult(bundleIdentifier: bundleIdentifier, pid: parseDevicectlPid(out), udid: d.udid)
        }
    }

    /// `simctl launch` prints "com.example.app: 12345".
    static func parseSimctlPid(_ output: String) -> Int? {
        output.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func parseDevicectlPid(_ data: Data) -> Int? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let process = result["process"] as? [String: Any]
        else { return nil }
        return process["processIdentifier"] as? Int
    }
}
