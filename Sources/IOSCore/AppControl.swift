import Foundation

public struct InstalledApp: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let name: String?
    public let version: String?
    /// "user" (installed by you or the App Store) or "system".
    public let kind: String
}

/// Installed-app control on simulators (`simctl`) and devices (`devicectl`).
public enum AppControl {
    public static func list(on target: Target, includeSystem: Bool) throws -> [InstalledApp] {
        let apps: [InstalledApp]
        switch target {
        case let .simulator(s):
            try requireBooted(s)
            apps = try parseSimctlApps(Shell.checked("/usr/bin/xcrun", ["simctl", "listapps", s.udid]).stdout)
        case let .device(d):
            var arguments = ["devicectl", "device", "info", "apps", "--device", d.udid, "-j", "-"]
            if includeSystem { arguments += ["--include-all-apps"] }
            apps = try parseDevicectlApps(Shell.checked("/usr/bin/xcrun", arguments).stdout)
        }
        // ios-cli's own UI automation runner isn't one of the user's apps.
        return apps.filter { (includeSystem || $0.kind == "user") && !$0.bundleIdentifier.hasPrefix(RunnerBuild.bundleIdentifier) }.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    /// Stops the app. Returns false when it wasn't running.
    @discardableResult
    public static func terminate(_ bundleID: String, on target: Target) throws -> Bool {
        switch target {
        case let .simulator(s):
            try requireBooted(s)
            let result = try Shell.run("/usr/bin/xcrun", ["simctl", "terminate", s.udid, bundleID])
            if result.status == 0 { return true }
            if result.stderr.contains("found nothing to terminate") { return false }
            throw IOSError.toolFailed(command: "simctl terminate \(bundleID)", status: result.status, stderr: result.stderr)
        case let .device(d):
            guard let pid = try devicePID(of: bundleID, on: d) else { return false }
            try Shell.checked("/usr/bin/xcrun", ["devicectl", "device", "process", "terminate", "--device", d.udid, "--pid", String(pid)])
            return true
        }
    }

    public static func uninstall(_ bundleID: String, on target: Target) throws {
        switch target {
        case let .simulator(s):
            try requireBooted(s)
            try Shell.checked("/usr/bin/xcrun", ["simctl", "uninstall", s.udid, bundleID])
        case let .device(d):
            try Shell.checked("/usr/bin/xcrun", ["devicectl", "device", "uninstall", "app", "--device", d.udid, bundleID])
        }
    }

    /// Opens a URL as if tapped: a deep link or universal link goes to the app that claims it.
    public static func openURL(_ url: String, on target: Target) throws {
        switch target {
        case let .simulator(s):
            try requireBooted(s)
            try Shell.checked("/usr/bin/xcrun", ["simctl", "openurl", s.udid, url])
        case let .device(d):
            try Shell.checked("/usr/bin/xcrun", ["devicectl", "device", "process", "openURL", "--device", d.udid, url])
        }
    }

    static func requireBooted(_ simulator: Simulator) throws {
        guard simulator.isBooted else { throw IOSError.simulatorNotBooted(name: simulator.name, udid: simulator.udid) }
    }

    /// devicectl has no "terminate by bundle ID": find where the app is installed, then the running
    /// process whose executable sits directly in that .app (extensions live deeper, in PlugIns/).
    static func devicePID(of bundleID: String, on device: PhysicalDevice) throws -> Int? {
        let apps = try Shell.checked("/usr/bin/xcrun", [
            "devicectl", "device", "info", "apps", "--device", device.udid, "--bundle-id", bundleID, "-j", "-",
        ]).stdout
        guard let appURL = appURL(fromDevicectlApps: apps) else {
            throw IOSError.appNotInstalled(bundleID: bundleID, udid: device.udid)
        }
        let processes = try Shell.checked("/usr/bin/xcrun", [
            "devicectl", "device", "info", "processes", "--device", device.udid, "-j", "-",
        ]).stdout
        return pid(inApp: appURL, processes: processes)
    }

    static func appURL(fromDevicectlApps data: Data) -> String? {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let apps = (root?["result"] as? [String: Any])?["apps"] as? [[String: Any]]
        return apps?.first?["url"] as? String
    }

    static func pid(inApp appURL: String, processes data: Data) -> Int? {
        let prefix = appURL.hasSuffix("/") ? appURL : appURL + "/"
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let running = (root?["result"] as? [String: Any])?["runningProcesses"] as? [[String: Any]] ?? []
        return running.first { process in
            guard let executable = process["executable"] as? String, executable.hasPrefix(prefix) else { return false }
            return !executable.dropFirst(prefix.count).contains("/")
        }?["processIdentifier"] as? Int
    }

    /// `simctl listapps` prints an old-style (OpenStep) property list keyed by bundle ID.
    static func parseSimctlApps(_ data: Data) throws -> [InstalledApp] {
        guard let apps = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else {
            throw IOSError.invalidOutput(tool: "simctl listapps", reason: "not a property list")
        }
        return apps.map { id, info in
            InstalledApp(
                bundleIdentifier: id,
                name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String,
                version: info["CFBundleShortVersionString"] as? String,
                kind: (info["ApplicationType"] as? String) == "User" ? "user" : "system"
            )
        }
    }

    static func parseDevicectlApps(_ data: Data) throws -> [InstalledApp] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = (root["result"] as? [String: Any])?["apps"] as? [[String: Any]] else {
            throw IOSError.invalidOutput(tool: "devicectl device info apps", reason: "no result.apps")
        }
        return apps.compactMap { app in
            guard let id = app["bundleIdentifier"] as? String else { return nil }
            let system = (app["defaultApp"] as? Bool) == true || (app["internalApp"] as? Bool) == true
                || (app["removable"] as? Bool) == false
            return InstalledApp(bundleIdentifier: id, name: app["name"] as? String, version: app["version"] as? String,
                                kind: system ? "system" : "user")
        }
    }
}
