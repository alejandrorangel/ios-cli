import Foundation

public enum Screen {
    /// Saves a PNG screenshot of the target to `path`.
    public static func capture(_ target: Target, to path: String) throws {
        switch target {
        case let .simulator(s):
            try Shell.checked("/usr/bin/xcrun", ["simctl", "io", s.udid, "screenshot", "--type=png", path])
        case let .device(d):
            try Shell.checked("/usr/bin/xcrun", [
                "devicectl", "device", "capture", "screenshot", "--device", d.udid, "--destination", path,
            ])
        }
    }
}
