import Foundation

public struct Simulator: Codable, Equatable, Sendable {
    public let udid: String
    public let name: String
    public let state: String
    public let runtime: String
    public let osVersion: String?
    public let deviceType: String?

    public var isBooted: Bool { state == "Booted" }
}

public enum SimulatorList {
    public static func load() throws -> [Simulator] {
        let result = try Shell.checked("/usr/bin/xcrun", ["simctl", "list", "-j", "devices", "runtimes", "available"])
        return try parse(result.stdout)
    }

    /// Parses `simctl list -j devices runtimes`: devices are keyed by runtime identifier,
    /// and the runtimes array maps those identifiers to versions.
    public static func parse(_ data: Data) throws -> [Simulator] {
        struct Listing: Decodable {
            struct Runtime: Decodable { let identifier: String; let version: String?; let name: String? }
            struct Device: Decodable {
                let udid: String
                let name: String
                let state: String
                let isAvailable: Bool?
                let deviceTypeIdentifier: String?
            }
            let devices: [String: [Device]]
            let runtimes: [Runtime]?
        }

        let listing: Listing
        do {
            listing = try JSONDecoder().decode(Listing.self, from: data)
        } catch {
            throw IOSError.invalidOutput(tool: "simctl list -j", reason: "\(error)")
        }
        let versions = Dictionary(
            (listing.runtimes ?? []).map { ($0.identifier, $0.version) },
            uniquingKeysWith: { first, _ in first }
        )
        return listing.devices
            .flatMap { runtime, devices in
                devices.filter { $0.isAvailable ?? true }.map {
                    Simulator(
                        udid: $0.udid,
                        name: $0.name,
                        state: $0.state,
                        runtime: runtime,
                        osVersion: versions[runtime] ?? nil,
                        deviceType: $0.deviceTypeIdentifier
                    )
                }
            }
            .sorted { ($0.osVersion ?? "", $0.name) > ($1.osVersion ?? "", $1.name) }
    }
}
