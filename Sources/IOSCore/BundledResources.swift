import Foundation

/// Files shipped next to the `ios` binary in ios-cli_IOSCore.bundle.
///
/// Looked up next to the real executable (following the ~/.local/bin symlink) rather than through
/// Bundle.module, whose fallback is the original build folder and which crashes when the bundle
/// is missing.
enum BundledResources {
    static func directory(_ name: String, containing marker: String) throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["IOS_CLI_RESOURCES"] {
            candidates.append(URL(fileURLWithPath: override).appendingPathComponent(name))
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let bundle = executable.deletingLastPathComponent().appendingPathComponent("ios-cli_IOSCore.bundle")
            candidates.append(bundle.appendingPathComponent("Contents/Resources/\(name)")) // macOS bundle layout
            candidates.append(bundle.appendingPathComponent(name))
        }
        if let found = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent(marker).path) }) {
            return found
        }
        throw IOSError.invalidOutput(tool: "ios", reason: "\(name) resources missing from the installation (looked in "
            + candidates.map(\.path).joined(separator: ", ") + "); reinstall with scripts/install.sh")
    }
}
