import Foundation

/// Updates the running `ios` in place from the latest GitHub release, the way scripts/get.sh installs it.
public enum Updater {
    public static let defaultRepository = "alejandrorangel/ios-cli"
    static let asset = "ios-cli-macos-arm64.tar.gz"

    public struct Result: Codable, Sendable {
        public let current: String
        public let latest: String
        /// "updated", "upToDate" or "available" (with --check).
        public let status: String
        public let path: String
        public let signed: Bool
    }

    static var repository: String { ProcessInfo.processInfo.environment["IOS_CLI_REPO"] ?? defaultRepository }

    /// The install folder holding the real executable and its resource bundle (…/share/ios-cli).
    public static func installDirectory() throws -> URL {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let directory = executable.deletingLastPathComponent()
        if executable.path.contains("/.build/") {
            throw IOSError.failed("This `ios` was built from source (\(executable.path)); update the checkout and run scripts/install.sh instead.")
        }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("ios-cli_IOSCore.bundle").path) else {
            throw IOSError.failed("\(executable.path) isn't an installed copy (no ios-cli_IOSCore.bundle beside it); install with get.sh first.")
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw IOSError.failed("Can't write to \(directory.path).")
        }
        return directory
    }

    /// The latest release's version, without the leading "v".
    public static func latestVersion() throws -> String {
        let api = "https://api.github.com/repos/\(repository)/releases/latest"
        if let result = try? Shell.run("/usr/bin/curl", ["-fsSL", api]), result.status == 0,
           let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
           let tag = object["tag_name"] as? String {
            return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        }
        // Private forks: the GitHub CLI's login can read what anonymous curl can't.
        if let result = try? Shell.run("/usr/bin/env", ["gh", "release", "view", "--repo", repository, "--json", "tagName", "-q", ".tagName"]),
           result.status == 0 {
            let tag = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty { return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
        }
        throw IOSError.download(url: api, message: "couldn't read the latest release (offline, rate-limited, or a private repository without `gh auth login`)")
    }

    /// Whether `latest` is newer than `current`, comparing dotted numbers.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = latest.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    public static func update(current: String, check: Bool, force: Bool, progress: (String) -> Void) throws -> Result {
        let directory = try installDirectory()
        let latest = try latestVersion()
        let identity = ProcessInfo.processInfo.environment["IOS_CLI_SIGN_IDENTITY"].flatMap { $0.isEmpty ? nil : $0 }
        let executable = directory.appendingPathComponent("ios")
        guard force || isNewer(latest, than: current) else {
            return Result(current: current, latest: latest, status: "upToDate", path: executable.path, signed: false)
        }
        if check { return Result(current: current, latest: latest, status: "available", path: executable.path, signed: false) }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let base = "https://github.com/\(repository)/releases/download/v\(latest)"
        progress("Downloading ios \(latest)…")
        for name in [asset, asset + ".sha256"] {
            let result = try Shell.run("/usr/bin/curl", ["-fsSL", "\(base)/\(name)", "-o", scratch.appendingPathComponent(name).path])
            if result.status != 0 {
                let gh = try? Shell.run("/usr/bin/env", ["gh", "release", "download", "v\(latest)", "--repo", repository,
                                                         "--pattern", name, "--dir", scratch.path, "--clobber"])
                guard gh?.status == 0 else { throw IOSError.download(url: "\(base)/\(name)", message: result.stderr) }
            }
        }
        let verify = try Shell.run("/usr/bin/shasum", ["-a", "256", "-c", asset + ".sha256"], in: scratch.path)
        guard verify.status == 0 else { throw IOSError.failed("The download's checksum doesn't match; nothing was changed.") }
        try Shell.checked("/usr/bin/tar", ["-xzf", asset, "-C", scratch.path], in: scratch.path)
        let unpacked = scratch.appendingPathComponent("ios-cli")

        // Stage the new binary beside the old one, sign it, then swap: the running copy is replaced in one rename.
        let staged = directory.appendingPathComponent("ios.new")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: unpacked.appendingPathComponent("ios"), to: staged)
        if let identity {
            // Keeps Xcode's tool-service approval: it's tied to the signature, not to one build.
            try Shell.checked("/usr/bin/codesign", ["--force", "--sign", identity, "--identifier", "io.github.alejandrorangel.ios-cli", staged.path])
        }
        let bundle = directory.appendingPathComponent("ios-cli_IOSCore.bundle")
        try? FileManager.default.removeItem(at: bundle)
        try FileManager.default.copyItem(at: unpacked.appendingPathComponent("ios-cli_IOSCore.bundle"), to: bundle)
        _ = try FileManager.default.replaceItemAt(executable, withItemAt: staged)
        return Result(current: current, latest: latest, status: "updated", path: executable.path, signed: identity != nil)
    }
}
