import Foundation

public struct XcodeInfo: Codable, Equatable, Sendable {
    public let developerDirectory: String
    public let version: String
    public let build: String

    public init(developerDirectory: String, version: String, build: String) {
        self.developerDirectory = developerDirectory
        self.version = version
        self.build = build
    }

    public static func load() throws -> XcodeInfo {
        let dir = try Shell.checked("/usr/bin/xcode-select", ["-p"]).stdoutString
        let versionOutput = try Shell.checked("/usr/bin/xcrun", ["xcodebuild", "-version"]).stdoutString
        let (version, build) = try parseVersion(versionOutput)
        return XcodeInfo(
            developerDirectory: dir.trimmingCharacters(in: .whitespacesAndNewlines),
            version: version,
            build: build
        )
    }

    /// The active Xcode's build (e.g. 27A266a), read from its version.plist: much faster than
    /// `xcodebuild -version` (~0.25 s), which matters for commands that only need a cache key.
    public static func currentBuild() -> String? {
        guard let dir = try? Shell.run("/usr/bin/xcode-select", ["-p"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty else { return nil }
        let plist = URL(fileURLWithPath: dir).deletingLastPathComponent().appendingPathComponent("version.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["ProductBuildVersion"] as? String
    }

    /// Parses `xcodebuild -version`, e.g. "Xcode 27.0\nBuild version 27A266a".
    public static func parseVersion(_ output: String) throws -> (version: String, build: String) {
        var version: String?
        var build: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Xcode ") { version = String(line.dropFirst("Xcode ".count)) }
            if line.hasPrefix("Build version ") { build = String(line.dropFirst("Build version ".count)) }
        }
        guard let version, let build else {
            throw IOSError.invalidOutput(tool: "xcodebuild -version", reason: output)
        }
        return (version, build)
    }
}
