import Foundation

/// What xcodebuild builds for: a specific simulator/device, or a generic platform.
public enum Destination: Equatable, Sendable {
    case target(Target)
    case genericSimulator
    case genericDevice

    public var sdk: String {
        switch self {
        case .target(.simulator), .genericSimulator: "iphonesimulator"
        case .target(.device), .genericDevice: "iphoneos"
        }
    }

    public var xcodebuildValue: String {
        switch self {
        case let .target(.simulator(s)): "platform=iOS Simulator,id=\(s.udid)"
        case let .target(.device(d)): "platform=iOS,id=\(d.udid)"
        case .genericSimulator: "generic/platform=iOS Simulator"
        case .genericDevice: "generic/platform=iOS"
        }
    }
}
