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

    public var isConnected: Bool { connectionState == "connected" }
}

public enum DeviceList {
    public static func load() throws -> [PhysicalDevice] {
        // `-j -` writes the JSON document to stdout and moves progress output to stderr.
        let result = try Shell.checked("/usr/bin/xcrun", ["devicectl", "list", "devices", "-j", "-"])
        return try parse(result.stdout)
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
        guard hardware["reality"] as? String == "physical", let udid = hardware["udid"] as? String else { return nil }
        return PhysicalDevice(
            udid: udid,
            name: state["name"] as? String ?? udid,
            model: hardware["marketingName"] as? String,
            osVersion: (software["osVersionNumber"] as? [String: Any])?["stringValue"] as? String,
            connectionState: connection["state"] as? String,
            transport: connection["transportType"] as? String,
            tunnelAddress: connection["tunnelIPAddressString"] as? String,
            // v5 encodes the status as a single-key object, e.g. {"enabled": {"mode": 1}}.
            developerMode: (state["developerModeStatus"] as? [String: Any])?.keys.first
        )
    }

    private static func fromLegacy(_ d: [String: Any]) -> PhysicalDevice? {
        let hardware = d["hardwareProperties"] as? [String: Any] ?? [:]
        let device = d["deviceProperties"] as? [String: Any] ?? [:]
        let connection = d["connectionProperties"] as? [String: Any] ?? [:]
        guard hardware["reality"] as? String == "physical", let udid = hardware["udid"] as? String else { return nil }
        return PhysicalDevice(
            udid: udid,
            name: device["name"] as? String ?? udid,
            model: hardware["marketingName"] as? String,
            osVersion: device["osVersionNumber"] as? String,
            connectionState: connection["tunnelState"] as? String,
            transport: connection["transportType"] as? String,
            tunnelAddress: connection["tunnelIPAddress"] as? String,
            developerMode: device["developerModeStatus"] as? String
        )
    }
}
