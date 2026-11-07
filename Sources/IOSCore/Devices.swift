import Foundation

public struct PhysicalDevice: Codable, Equatable, Sendable {
    public let udid: String
    public let name: String
    public let model: String?
    public let osVersion: String?
    public let connectionState: String?
    public let transport: String?
    /// Address of the CoreDevice tunnel; on-device servers (e.g. the XCUITest runner) are reached here.
    public let tunnelAddress: String?
    public let developerMode: String?
    /// What `devicectl list devices` shows in its State column: "connected", "available (paired)",
    /// "unavailable"… The JSON only has the tunnel state, which stays "disconnected" until a tool opens
    /// the tunnel, even while the device is awake and reachable.
    public var availability: String?

    /// Reachable now: the tunnel is up, or devicectl sees the device and will open it on use.
    public var isConnected: Bool {
        connectionState == "connected" || availability == "connected" || availability?.hasPrefix("available") == true
    }

    /// Paired but out of reach (locked, asleep, unplugged, or on another network).
    public var isUnavailable: Bool { !isConnected && availability != nil }

    /// The state to show people.
    public var displayState: String { connectionState == "connected" ? "connected" : availability ?? connectionState ?? "?" }
}

public enum DeviceList {
    public static func load() throws -> [PhysicalDevice] {
        // `-j -` writes the JSON document to stdout and moves progress output to stderr.
        let result = try Shell.checked("/usr/bin/xcrun", ["devicectl", "list", "devices", "-j", "-"])
        var devices = try parse(result.stdout)
        guard !devices.isEmpty, let table = try? Shell.run("/usr/bin/xcrun", ["devicectl", "list", "devices"]) else { return devices }
        let states = availability(table: table.stdoutString)
        for i in devices.indices { devices[i].availability = states[devices[i].udid] }
        return devices
    }

    /// UDID → State column of `devicectl list devices`' table, found by the header's column positions.
    static func availability(table: String) -> [String: String] {
        let lines = table.split(separator: "\n").map(String.init)
        guard let header = lines.first(where: { $0.hasPrefix("Name") && $0.contains("State") }),
              let stateStart = header.range(of: "State")?.lowerBound,
              let identifierStart = header.range(of: "Identifier")?.lowerBound else { return [:] }
        let stateColumn = header.distance(from: header.startIndex, to: stateStart)
        let identifierColumn = header.distance(from: header.startIndex, to: identifierStart)
        var out: [String: String] = [:]
        for line in lines where line.count > stateColumn {
            let characters = Array(line)
            // Names can't be relied on for width ("Alejandro’s"), but the header and rows share columns.
            let rest = String(characters[stateColumn...])
            let state = rest.components(separatedBy: "   ").first?.trimmingCharacters(in: .whitespaces) ?? ""
            let identifier = String(characters[identifierColumn..<min(stateColumn, characters.count)])
                .split(separator: " ").first.map(String.init) ?? ""
            if !identifier.isEmpty, !state.isEmpty { out[identifier] = state }
        }
        return out
    }

    /// Parses `devicectl list devices -j -`. Reads the JSON v5 `properties` dictionary and
    /// falls back to the older `*Properties` fields, which v5 still emits but deprecates.
    public static func parse(_ data: Data) throws -> [PhysicalDevice] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let devices = result["devices"] as? [[String: Any]]
        else {
            throw IOSError.invalidOutput(tool: "devicectl list devices", reason: "missing result.devices")
        }
        return devices.compactMap { device in
            if let properties = device["properties"] as? [String: Any] {
                return fromV5(properties)
            }
            return fromLegacy(device)
        }
    }

    private static func fromV5(_ p: [String: Any]) -> PhysicalDevice? {
        let hardware = p["hardware"] as? [String: Any] ?? [:]
        let software = p["software"] as? [String: Any] ?? [:]
        let connection = p["connection"] as? [String: Any] ?? [:]
        let state = p["state"] as? [String: Any] ?? [:]
        // A device that just woke can be listed before its hardware details are filled in; anything
        // that isn't a simulator (reality "simulated", transport "sameMachine") counts.
        guard hardware["reality"] as? String != "simulated", connection["transportType"] as? String != "sameMachine",
              let udid = hardware["udid"] as? String ?? p["udid"] as? String else { return nil }
        return PhysicalDevice(
            udid: udid,
            name: state["name"] as? String ?? udid,
            model: hardware["marketingName"] as? String,
            osVersion: (software["osVersionNumber"] as? [String: Any])?["stringValue"] as? String,
            connectionState: connection["state"] as? String,
            transport: connection["transportType"] as? String,
            tunnelAddress: connection["tunnelIPAddressString"] as? String,
            // v5 encodes the status as a single-key object, e.g. {"enabled": {"mode": 1}}.
            developerMode: (state["developerModeStatus"] as? [String: Any])?.keys.first,
            availability: nil
        )
    }

    private static func fromLegacy(_ d: [String: Any]) -> PhysicalDevice? {
        let hardware = d["hardwareProperties"] as? [String: Any] ?? [:]
        let device = d["deviceProperties"] as? [String: Any] ?? [:]
        let connection = d["connectionProperties"] as? [String: Any] ?? [:]
        guard hardware["reality"] as? String != "simulated", connection["transportType"] as? String != "sameMachine",
              let udid = hardware["udid"] as? String else { return nil }
        return PhysicalDevice(
            udid: udid,
            name: device["name"] as? String ?? udid,
            model: hardware["marketingName"] as? String,
            osVersion: device["osVersionNumber"] as? String,
            connectionState: connection["tunnelState"] as? String,
            transport: connection["transportType"] as? String,
            tunnelAddress: connection["tunnelIPAddress"] as? String,
            developerMode: device["developerModeStatus"] as? String,
            availability: nil
        )
    }
}
