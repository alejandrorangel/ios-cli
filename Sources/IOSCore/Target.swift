import Foundation

/// A simulator or physical device that a command acts on.
public enum Target: Equatable, Sendable {
    case simulator(Simulator)
    case device(PhysicalDevice)

    public var udid: String {
        switch self {
        case let .simulator(s): s.udid
        case let .device(d): d.udid
        }
    }

    public var isSimulator: Bool {
        if case .simulator = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case let .simulator(s): "\(s.name) (simulator, iOS \(s.osVersion ?? "?"), \(s.udid))"
        case let .device(d): "\(d.name) (device, iOS \(d.osVersion ?? "?"), \(d.udid))"
        }
    }
}

public enum TargetResolver {
    public static func resolve(_ query: String?) throws -> Target {
        try resolve(query, simulators: SimulatorList.load(), devices: DeviceList.load())
    }

    /// Like `resolve`, but with no query it never picks a physical device (tests install and run
    /// there, which disturbs whoever is using it): the booted simulator, else the first iPhone on
    /// the newest iOS runtime, which xcodebuild boots.
    public static func resolveSimulatorFirst(_ query: String?) throws -> Target {
        guard query == nil else { return try resolve(query) }
        return try defaultSimulator(SimulatorList.load())
    }

    public static func defaultSimulator(_ simulators: [Simulator]) throws -> Target {
        let booted = simulators.filter(\.isBooted)
        if booted.count == 1 { return .simulator(booted[0]) }
        if booted.count > 1 { throw IOSError.ambiguousDevice(query: nil, candidates: booted.map { Target.simulator($0).label }) }
        let iPhones = simulators.filter { $0.runtime.contains("iOS") && $0.name.hasPrefix("iPhone") }
        let newest = iPhones.max { versionParts($0.osVersion) .lexicographicallyPrecedes(versionParts($1.osVersion)) }
        guard let newest else { throw IOSError.ambiguousDevice(query: nil, candidates: simulators.map { Target.simulator($0).label }) }
        let pick = iPhones.filter { $0.osVersion == newest.osVersion }.min { $0.name < $1.name }!
        return .simulator(pick)
    }

    private static func versionParts(_ version: String?) -> [Int] {
        (version ?? "").split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Resolution order: exact UDID, then case-insensitive name. With no query, the single
    /// booted simulator or connected device is used; anything else is ambiguous.
    public static func resolve(_ query: String?, simulators: [Simulator], devices: [PhysicalDevice]) throws -> Target {
        let all = devices.map(Target.device) + simulators.map(Target.simulator)

        guard let query else {
            let active = devices.filter(\.isConnected).map(Target.device)
                + simulators.filter(\.isBooted).map(Target.simulator)
            if active.count == 1 { return active[0] }
            throw IOSError.ambiguousDevice(query: nil, candidates: active.map(\.label))
        }

        if let match = all.first(where: { $0.udid.caseInsensitiveCompare(query) == .orderedSame }) {
            return match
        }
        let byName = all.filter { target in
            switch target {
            case let .simulator(s): s.name.caseInsensitiveCompare(query) == .orderedSame
            case let .device(d): d.name.caseInsensitiveCompare(query) == .orderedSame
            }
        }
        switch byName.count {
        case 1: return byName[0]
        case 0: throw IOSError.deviceNotFound(query: query, candidates: all.map(\.label))
        default:
            // Several simulators often share a name across runtimes; prefer the booted one.
            let booted = byName.filter { if case let .simulator(s) = $0 { s.isBooted } else { false } }
            if booted.count == 1 { return booted[0] }
            throw IOSError.ambiguousDevice(query: query, candidates: byName.map(\.label))
        }
    }
}
