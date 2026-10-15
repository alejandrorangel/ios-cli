import CryptoKit
import Foundation

/// JSON cache for slow xcodebuild metadata, invalidated when project files change.
public struct MetadataCache: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let override = ProcessInfo.processInfo.environment["IOS_CLI_CACHE_DIR"] {
            self.directory = URL(fileURLWithPath: override)
        } else {
            self.directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ios-cli/describe")
        }
    }

    private struct Entry<Value: Codable>: Codable {
        let fingerprint: String
        let value: Value
    }

    public func read<Value: Codable>(_ type: Value.Type, key: String, fingerprint: String) -> Value? {
        guard
            let data = try? Data(contentsOf: file(for: key)),
            let entry = try? JSONDecoder().decode(Entry<Value>.self, from: data),
            entry.fingerprint == fingerprint
        else { return nil }
        return entry.value
    }

    public func write<Value: Codable>(_ value: Value, key: String, fingerprint: String) {
        // A failed cache write only costs speed on the next run, so it isn't an error.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Entry(fingerprint: fingerprint, value: value)) {
            try? data.write(to: file(for: key), options: .atomic)
        }
    }

    private func file(for key: String) -> URL {
        directory.appendingPathComponent(Self.sha256(key) + ".json")
    }

    static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ProjectFingerprint {
    /// Files whose changes can alter schemes, targets or build settings.
    static func isRelevant(_ name: String) -> Bool {
        name == "project.pbxproj" || name == "contents.xcworkspacedata"
            || name == "Package.swift" || name == "Package.resolved"
            || name.hasSuffix(".xcscheme") || name.hasSuffix(".xcconfig")
    }

    /// Directories that never hold project definitions. Hidden directories are skipped too,
    /// which also keeps out agent worktrees (e.g. .claude/worktrees) and .git.
    static let skippedDirectories: Set<String> = ["DerivedData", "build", "node_modules", "Carthage"]

    /// Hash of path + modification time + size for every relevant file under `root`.
    public static func compute(root: String, extra: [String] = []) -> String {
        let rootURL = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        var lines = extra
        if let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard isRelevant(url.lastPathComponent) else { continue }
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                lines.append("\(url.path)|\(mtime)|\(values?.fileSize ?? 0)")
            }
        }
        return MetadataCache.sha256(lines.sorted().joined(separator: "\n"))
    }
}
