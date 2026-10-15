import Foundation

/// An agent skill `ios skills` can install: a folder with SKILL.md (plus optional references).
public struct SkillInfo: Codable, Sendable {
    public let name: String
    public let description: String
    /// "ios-cli" (bundled with this tool) or "xcode" (exported from the installed Xcode).
    public let source: String
    public let installed: Bool
    /// True when installed by `ios skills` (so update/remove may touch it).
    public let managed: Bool
    public let path: String?
}

public enum SkillManager {
    static let markerName = ".ios-cli-skill.json"

    /// ~/.claude/skills, where Claude Code looks for personal skills.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")
    }

    struct Source {
        let name: String
        let description: String
        let origin: String
        let folder: URL
    }

    /// Skills available to install, bundled first, then Xcode's.
    static func sources(progress: (String) -> Void = { _ in }) throws -> [Source] {
        var out: [Source] = []
        let bundled = try BundledResources.directory("Skills", containing: "ios-cli/SKILL.md")
        out += try skills(in: bundled, origin: "ios-cli")
        if let xcode = try? xcodeSkillsDirectory(progress: progress) {
            out += try skills(in: xcode, origin: "xcode").filter { s in !out.contains { $0.name == s.name } }
        }
        return out
    }

    /// Xcode's skills, exported once per Xcode build into the cache.
    static func xcodeSkillsDirectory(progress: (String) -> Void) throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ios-cli/xcode-skills/\(Describer.cachedXcodeBuildForSymbols)")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path), !entries.isEmpty { return dir }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = try Shell.run("/usr/bin/xcrun", ["mcpbridge", "run-agent", "skills", "export", dir.path])
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard result.status == 0, !entries.isEmpty else {
            try? FileManager.default.removeItem(at: dir)
            throw IOSError.toolFailed(command: "xcrun mcpbridge run-agent skills export", status: result.status,
                                      stderr: result.stderr + result.stdoutString)
        }
        return dir
    }

    static func skills(in dir: URL, origin: String) throws -> [Source] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let file = folder.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let meta = frontMatter(text)
            return Source(name: meta["name"] ?? folder.lastPathComponent, description: meta["description"] ?? "",
                          origin: origin, folder: folder)
        }.sorted { $0.name < $1.name }
    }

    /// Top-level keys from a SKILL.md's YAML front matter: plain or quoted single-line values, and
    /// block values (`key: |` or `key: >` followed by indented lines, joined with spaces).
    static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var blockKey: String?
        var blockLines: [String] = []
        func finishBlock() {
            if let key = blockKey { out[key] = blockLines.joined(separator: " ") }
            blockKey = nil
            blockLines = []
        }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if blockKey != nil, line.first == " " || line.first == "\t" || line.trimmingCharacters(in: .whitespaces).isEmpty {
                let content = line.trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { blockLines.append(content) }
                continue
            }
            finishBlock()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if ["|", ">", "|-", ">-", "|+", ">+"].contains(value) {
                blockKey = key
                continue
            }
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            out[key] = value
        }
        finishBlock()
        return out
    }

    // MARK: Commands

    public static func list(in target: URL, progress: (String) -> Void = { _ in }) throws -> [SkillInfo] {
        try sources(progress: progress).map { source in
            let installedAt = target.appendingPathComponent(source.name)
            let installed = FileManager.default.fileExists(atPath: installedAt.appendingPathComponent("SKILL.md").path)
            return SkillInfo(name: source.name, description: source.description, source: source.origin, installed: installed,
                             managed: isManaged(installedAt), path: installed ? installedAt.path : nil)
        }
    }

    /// Installs skills by name. Refuses to overwrite a skill `ios` didn't install unless `force`.
    @discardableResult
    public static func add(_ names: [String], into target: URL, force: Bool, progress: (String) -> Void = { _ in }) throws -> [SkillInfo] {
        let available = try sources(progress: progress)
        return try names.map { name in
            guard let source = available.first(where: { $0.name == name }) else {
                throw IOSError.skillNotFound(name: name, available: available.map(\.name))
            }
            let destination = target.appendingPathComponent(source.name)
            if FileManager.default.fileExists(atPath: destination.path), !isManaged(destination), !force {
                throw IOSError.skillExists(path: destination.path)
            }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source.folder, to: destination)
            let marker: [String: String] = ["source": source.origin, "xcodeBuild": Describer.cachedXcodeBuildForSymbols,
                                            "installedAt": ISO8601DateFormatter().string(from: Date())]
            try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]).write(to: destination.appendingPathComponent(markerName))
            return SkillInfo(name: source.name, description: source.description, source: source.origin,
                             installed: true, managed: true, path: destination.path)
        }
    }

    /// Removes skills installed by `ios skills` (others are left alone unless `force`).
    public static func remove(_ names: [String], from target: URL, force: Bool) throws -> [String] {
        try names.map { name in
            let folder = target.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: folder.path) else { throw IOSError.skillNotInstalled(name: name, directory: target.path) }
            guard isManaged(folder) || force else { throw IOSError.skillExists(path: folder.path) }
            try FileManager.default.removeItem(at: folder)
            return name
        }
    }

    /// Reinstalls every skill `ios skills` installed in `target`, refreshing Xcode's export first.
    public static func update(in target: URL, progress: (String) -> Void = { _ in }) throws -> [SkillInfo] {
        let xcodeCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ios-cli/xcode-skills/\(Describer.cachedXcodeBuildForSymbols)")
        try? FileManager.default.removeItem(at: xcodeCache)
        let managed = try list(in: target, progress: progress).filter { $0.installed && $0.managed }.map(\.name)
        return try add(managed, into: target, force: false, progress: progress)
    }

    static func isManaged(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(markerName).path)
    }
}
