import Foundation

/// Signing for the on-device runner. Simulators use ad-hoc signing and need nothing.
public struct RunnerSigning: Sendable {
    public let team: String?
    /// Lets xcodebuild create profiles in the developer account (`-allowProvisioningUpdates`).
    /// Off by default so nothing changes in the account; a local wildcard profile is enough.
    public let allowProvisioningUpdates: Bool

    public init(team: String?, allowProvisioningUpdates: Bool) {
        self.team = team ?? ProcessInfo.processInfo.environment["IOS_CLI_TEAM"]
        self.allowProvisioningUpdates = allowProvisioningUpdates
    }
}

public enum RunnerBuild {
    static let bundleIdentifier = "dev.ioscli.runner"

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ios-cli/runner")
    }

    /// Builds the runner for the target's platform (cached per Xcode build, platform, team and
    /// runner source) and returns its .xctestrun file.
    public static func xctestrun(for target: Target, signing: RunnerSigning, progress: (String) -> Void) throws -> URL {
        let source = try sourceDirectory()
        var team: String?
        if case let .device(device) = target {
            team = try signing.team ?? teamFromLocalProfiles(device: device.udid)
        }
        let platform = target.isSimulator ? "iphonesimulator" : "iphoneos"
        let key = [Describer.cachedXcodeBuildForSymbols, platform, team ?? "adhoc", try sourceHash(source)].joined(separator: "-")
        let dir = directory.appendingPathComponent("builds/\(key)")
        if let existing = findXCTestRun(in: dir) { return existing }

        progress("Building the UI automation runner for \(platform) (first use)…")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = dir.appendingPathComponent("src")
        try FileManager.default.copyItem(at: source, to: project)

        var arguments = [
            "xcodebuild", "build-for-testing", "-project", project.appendingPathComponent("Runner.xcodeproj").path,
            "-scheme", "Runner", "-derivedDataPath", dir.appendingPathComponent("dd").path,
            "-destination", target.isSimulator ? "generic/platform=iOS Simulator" : "generic/platform=iOS",
        ]
        if let team {
            arguments += ["CODE_SIGN_STYLE=Automatic", "DEVELOPMENT_TEAM=\(team)", "CODE_SIGN_IDENTITY=Apple Development",
                          "PRODUCT_BUNDLE_IDENTIFIER=\(bundleIdentifier)"]
            if signing.allowProvisioningUpdates { arguments.append("-allowProvisioningUpdates") }
        }
        let log = dir.appendingPathComponent("build.log")
        let status = try Shell.run("/usr/bin/xcrun", arguments, log: log)
        guard status == 0, let built = findXCTestRun(in: dir) else {
            let errors = Builder.parseDiagnostics((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .filter { $0.severity == "error" }.map(\.summary)
            throw IOSError.runnerBuildFailed(log: log.path, errors: errors)
        }
        return built
    }

    static func findXCTestRun(in dir: URL) -> URL? {
        let products = dir.appendingPathComponent("dd/Build/Products")
        let files = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension == "xctestrun" }
    }

    /// The runner project shipped as a package resource. Looked up next to the real executable
    /// (following the ~/.local/bin symlink) rather than through Bundle.module, whose fallback is
    /// the original build folder and which crashes when the bundle is missing.
    static func sourceDirectory() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["IOS_CLI_RESOURCES"] {
            candidates.append(URL(fileURLWithPath: override).appendingPathComponent("Runner"))
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let bundle = executable.deletingLastPathComponent().appendingPathComponent("ios-cli_IOSCore.bundle")
            candidates.append(bundle.appendingPathComponent("Contents/Resources/Runner")) // macOS bundle layout
            candidates.append(bundle.appendingPathComponent("Runner"))
        }
        if let found = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("Runner.xcodeproj").path) }) {
            return found
        }
        throw IOSError.invalidOutput(tool: "ios", reason: "runner resources missing from the installation (looked in "
            + candidates.map(\.path).joined(separator: ", ") + "); reinstall with scripts/install.sh")
    }

    static func sourceHash(_ dir: URL) throws -> String {
        var combined = ""
        for name in ["Runner.xcodeproj/project.pbxproj", "RunnerUITests/RunnerUITests.swift"] {
            combined += (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        return String(MetadataCache.sha256(combined).prefix(10))
    }

    /// Teams that have a local Xcode-managed wildcard development profile covering the device.
    /// Using one means the runner can be signed without changing anything in the developer account.
    static func teamFromLocalProfiles(device udid: String) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"]
            .map { home.appendingPathComponent($0) }
        var teams = Set<String>()
        for dir in dirs {
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "mobileprovision" {
                guard
                    let decoded = try? Shell.run("/usr/bin/security", ["cms", "-D", "-i", file.path]), decoded.status == 0,
                    let plist = try? PropertyListSerialization.propertyList(from: decoded.stdout, format: nil) as? [String: Any],
                    let entitlements = plist["Entitlements"] as? [String: Any],
                    let appID = entitlements["application-identifier"] as? String, appID.hasSuffix(".*"),
                    entitlements["get-task-allow"] as? Bool == true,
                    let expiry = plist["ExpirationDate"] as? Date, expiry > Date(),
                    (plist["ProvisionedDevices"] as? [String] ?? []).contains(udid),
                    let team = (plist["TeamIdentifier"] as? [String])?.first
                else { continue }
                teams.insert(team)
            }
        }
        guard teams.count == 1, let team = teams.first else {
            throw IOSError.runnerTeamRequired(candidates: teams.sorted())
        }
        return team
    }
}
