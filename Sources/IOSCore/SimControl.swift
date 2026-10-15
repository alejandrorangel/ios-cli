import Foundation

/// Simulator lifecycle and settings, through `simctl`.
public enum SimControl {
    // MARK: Choosing a simulator

    /// The simulator a command acts on. With a query: that simulator (a device is an error).
    /// Without: the only booted simulator; `orDefault` falls back to the default iPhone (for `boot`).
    public static func simulator(_ query: String?, command: String, orDefault: Bool = false) throws -> Simulator {
        let simulators = try SimulatorList.load()
        if let query {
            switch try TargetResolver.resolve(query, simulators: simulators, devices: (try? DeviceList.load()) ?? []) {
            case let .simulator(s): return s
            case .device: throw IOSError.simulatorOnly(command: command)
            }
        }
        if orDefault, case let .simulator(s) = try TargetResolver.defaultSimulator(simulators) { return s }
        let booted = simulators.filter(\.isBooted)
        if booted.count == 1 { return booted[0] }
        throw IOSError.ambiguousDevice(query: nil, candidates: (booted.isEmpty ? simulators : booted).map { Target.simulator($0).label })
    }

    // MARK: Lifecycle

    /// Creates a simulator and returns it. `type` is a device type name ("iPhone 17") or identifier;
    /// `os` a version ("27.0") or runtime identifier; the newest compatible runtime when nil.
    public static func create(name: String, type: String, os: String?) throws -> Simulator {
        var arguments = ["simctl", "create", name, type]
        if let os { arguments.append(os.hasPrefix("com.apple.") ? os : "iOS \(os)") }
        let udid = try Shell.checked("/usr/bin/xcrun", arguments).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let created = try SimulatorList.load().first(where: { $0.udid == udid }) else {
            throw IOSError.invalidOutput(tool: "simctl create", reason: "created \(udid) but it isn't listed")
        }
        return created
    }

    /// Boots and waits until the simulator is usable; `show` also brings up Simulator.app.
    public static func boot(_ simulator: Simulator, show: Bool) throws {
        if !simulator.isBooted { try Launcher.prepare(.simulator(simulator)) }
        if show { try Shell.checked("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", simulator.udid]) }
    }

    public static func shutdown(_ simulator: Simulator) throws {
        guard simulator.isBooted else { return }
        try simctl(["shutdown", simulator.udid])
    }

    /// Erases contents and settings. simctl only erases shut-down simulators, so a booted one is
    /// shut down first and booted again afterwards. Returns whether it was rebooted.
    @discardableResult
    public static func erase(_ simulator: Simulator) throws -> Bool {
        try shutdown(simulator)
        try simctl(["erase", simulator.udid])
        guard simulator.isBooted else { return false }
        try simctl(["boot", simulator.udid])
        try simctl(["bootstatus", simulator.udid, "-b"])
        return true
    }

    public static func delete(_ simulator: Simulator) throws {
        try shutdown(simulator)
        try simctl(["delete", simulator.udid])
    }

    // MARK: Settings

    public static let appearances = ["light", "dark"]
    public static let contentSizes = [
        "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
        "accessibility-medium", "accessibility-large", "accessibility-extra-large",
        "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large",
    ]

    /// Reads (value nil) or sets a `simctl ui` option and returns the current value.
    public static func ui(_ simulator: Simulator, option: String, value: String?) throws -> String {
        if let value { try simctl(["ui", simulator.udid, option, value]) }
        return try simctl(["ui", simulator.udid, option]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func setLocation(_ simulator: Simulator, latitude: Double, longitude: Double) throws {
        try simctl(["location", simulator.udid, "set", "\(latitude),\(longitude)"])
    }

    public static func clearLocation(_ simulator: Simulator) throws {
        try simctl(["location", simulator.udid, "clear"])
    }

    /// "37.33,-122.01" → (37.33, -122.01); nil unless both are valid coordinates.
    public static func parseCoordinate(_ text: String) -> (latitude: Double, longitude: Double)? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return (lat, lon)
    }

    public static let privacyActions = ["grant", "revoke", "reset"]
    public static let privacyServices = [
        "all", "calendar", "contacts-limited", "contacts", "location", "location-always", "photos-add", "photos",
        "media-library", "microphone", "motion", "reminders", "siri",
    ]

    /// Grants, revokes or resets a permission. Some changes terminate the app if it's running.
    public static func privacy(_ simulator: Simulator, action: String, service: String, bundleID: String?) throws {
        try simctl(["privacy", simulator.udid, action, service] + (bundleID.map { [$0] } ?? []))
    }

    /// A minimal APNs payload with an alert, for pushes without a JSON file.
    public static func pushPayload(title: String?, body: String?, badge: Int?, sound: Bool) -> [String: Any] {
        var alert: [String: Any] = [:]
        if let title { alert["title"] = title }
        if let body { alert["body"] = body }
        var aps: [String: Any] = [:]
        if !alert.isEmpty { aps["alert"] = alert }
        if let badge { aps["badge"] = badge }
        if sound { aps["sound"] = "default" }
        return ["aps": aps]
    }

    /// Sends a simulated remote notification; `payload` is APNs JSON with an "aps" key.
    public static func push(_ simulator: Simulator, bundleID: String, payload: Data) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-push-\(UUID().uuidString).json")
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try simctl(["push", simulator.udid, bundleID, file.path])
    }

    /// Status bar overrides as `simctl status_bar override` flags.
    public struct StatusBar: Codable, Sendable {
        public var time: String?
        public var batteryLevel: Int?
        public var batteryState: String?
        public var wifiBars: Int?
        public var cellularBars: Int?
        public var dataNetwork: String?
        public var operatorName: String?

        public init(time: String? = nil, batteryLevel: Int? = nil, batteryState: String? = nil, wifiBars: Int? = nil,
                    cellularBars: Int? = nil, dataNetwork: String? = nil, operatorName: String? = nil) {
            self.time = time
            self.batteryLevel = batteryLevel
            self.batteryState = batteryState
            self.wifiBars = wifiBars
            self.cellularBars = cellularBars
            self.dataNetwork = dataNetwork
            self.operatorName = operatorName
        }

        /// The look of Apple's marketing screenshots: 9:41, full battery and signal.
        public static let clean = StatusBar(time: "9:41", batteryLevel: 100, batteryState: "charged", wifiBars: 3,
                                            cellularBars: 4, dataNetwork: "wifi", operatorName: "")

        /// Fields set in `other` replace these.
        public func merging(_ other: StatusBar) -> StatusBar {
            StatusBar(time: other.time ?? time, batteryLevel: other.batteryLevel ?? batteryLevel,
                      batteryState: other.batteryState ?? batteryState, wifiBars: other.wifiBars ?? wifiBars,
                      cellularBars: other.cellularBars ?? cellularBars, dataNetwork: other.dataNetwork ?? dataNetwork,
                      operatorName: other.operatorName ?? operatorName)
        }

        public var isEmpty: Bool { arguments.isEmpty }

        /// "9:41, battery 100% charged, Wi-Fi 3 bars, …" for output.
        public var summary: String {
            var parts: [String] = []
            if let time { parts.append(time) }
            if let batteryLevel { parts.append("battery \(batteryLevel)%" + (batteryState.map { " \($0)" } ?? "")) }
            else if let batteryState { parts.append("battery \(batteryState)") }
            if let wifiBars { parts.append("Wi-Fi \(wifiBars) bars") }
            if let cellularBars { parts.append("cellular \(cellularBars) bars") }
            if let dataNetwork { parts.append("network \(dataNetwork)") }
            if let operatorName { parts.append(operatorName.isEmpty ? "no carrier" : "carrier \(operatorName)") }
            return parts.joined(separator: ", ")
        }

        public var arguments: [String] {
            var out: [String] = []
            if let time { out += ["--time", time] }
            if let batteryLevel { out += ["--batteryLevel", String(batteryLevel)] }
            if let batteryState { out += ["--batteryState", batteryState] }
            if let wifiBars { out += ["--wifiMode", "active", "--wifiBars", String(wifiBars)] }
            if let cellularBars { out += ["--cellularMode", "active", "--cellularBars", String(cellularBars)] }
            if let dataNetwork { out += ["--dataNetwork", dataNetwork] }
            if let operatorName { out += ["--operatorName", operatorName] }
            return out
        }
    }

    public static func overrideStatusBar(_ simulator: Simulator, _ statusBar: StatusBar) throws {
        try simctl(["status_bar", simulator.udid, "override"] + statusBar.arguments)
    }

    public static func clearStatusBar(_ simulator: Simulator) throws {
        try simctl(["status_bar", simulator.udid, "clear"])
    }

    // MARK: Recording

    /// Records the screen to a QuickTime movie for `seconds`, stopping the way simctl expects
    /// (SIGINT, then waiting while it finalizes the file).
    public static func record(_ simulator: Simulator, to path: String, seconds: Double) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", simulator.udid, "recordVideo", "--codec=h264", "--force", path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()

        // Count the duration from "Recording started" (the first frame), not from launch.
        let started = DispatchSemaphore(value: 0)
        let box = ProcessBox(process)
        let collected = LockedText()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            if collected.append(chunk).contains("Recording started") { started.signal() }
        }
        if started.wait(timeout: .now() + 15) == .timedOut, !box.process.isRunning {
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw IOSError.toolFailed(command: "simctl io recordVideo", status: process.terminationStatus, stderr: collected.text)
        }
        Thread.sleep(forTimeInterval: seconds)
        process.interrupt()
        process.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil
        guard FileManager.default.fileExists(atPath: path) else {
            throw IOSError.toolFailed(command: "simctl io recordVideo", status: process.terminationStatus, stderr: collected.text)
        }
    }

    @discardableResult
    static func simctl(_ arguments: [String]) throws -> String {
        try Shell.checked("/usr/bin/xcrun", ["simctl"] + arguments).stdoutString
    }
}

/// Text appended from a pipe's handler thread and read from the caller's.
final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    /// Appends and returns everything so far.
    func append(_ chunk: String) -> String {
        lock.lock(); defer { lock.unlock() }
        value += chunk
        return value
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
