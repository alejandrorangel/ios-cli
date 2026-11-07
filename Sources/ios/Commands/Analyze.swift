import ArgumentParser
import Foundation
import IOSCore

struct AnalyzeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Show what's in a built app: identity, size by part, signing, entitlements, privacy manifests.",
        discussion: """
        Takes an .app, an .ipa or an .xcarchive (`ios describe --scheme S` prints where a build's .app is). \
        Everything is read locally. Notes point out debug or simulator builds, expired profiles and \
        missing privacy manifests.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Path to an .app, .ipa or .xcarchive.")
    var path: String

    func run() throws {
        let analysis = try Analyze.run(path)
        try Output.emit(analysis, json: global.json) { text(analysis) }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func text(_ a: AppAnalysis) -> String {
        let id = a.identity
        var lines = ["\(id.name ?? "?") \(id.bundleID ?? "")  \(id.version ?? "?") (\(id.build ?? "?"))"]
        lines.append("  \(id.platform ?? "?") · minimum iOS \(id.minimumOS ?? "?") · \(id.deviceFamilies.joined(separator: ", "))"
            + " · \(id.architectures.joined(separator: ", ")) · SDK \(id.sdk ?? "?") · Xcode \(id.xcode ?? "?")")
        lines.append("  \(a.app)")
        lines.append("")
        lines.append("Size: \(size(a.bytes)) installed" + (a.downloadBytes.map { ", \(size($0)) .ipa" } ?? ""))
        let shown = a.parts.prefix(15)
        lines.append(Output.table(shown.map { part in
            ["  " + size(part.bytes), part.kind, part.path + (part.privacyManifest == false ? "  (no privacy manifest)" : "")]
        }))
        if a.parts.count > shown.count { lines.append("  … \(a.parts.count - shown.count) more (--json lists all)") }
        lines.append("")
        lines.append("Largest files:")
        lines.append(Output.table(a.largestFiles.prefix(5).map { ["  " + size($0.bytes), $0.path] }))
        lines.append("")
        let s = a.signing
        var signing = "Signing: \(s.kind)"
        if let authority = s.authority { signing += " — \(authority)" }
        lines.append(signing)
        if let profile = s.profile {
            var line = "  Profile: \(profile.name ?? "?")"
            if let expires = profile.expires { line += ", expires \(expires.formatted(date: .abbreviated, time: .omitted))" }
            if profile.allDevices { line += ", any device" } else if let devices = profile.devices { line += ", \(devices) devices" }
            lines.append(line)
        }
        if !s.entitlements.isEmpty {
            lines.append("  Entitlements:")
            lines += s.entitlements.keys.sorted().map { "    \($0) = \(s.entitlements[$0]!)" }
        }
        lines.append("Privacy manifest: \(a.privacyManifest ? "yes" : "no")")
        if !a.embeddedLibraries.isEmpty { lines.append("Embedded libraries: \(a.embeddedLibraries.joined(separator: ", "))") }
        if let dSYMs = a.dSYMs { lines.append("dSYMs: \(dSYMs.isEmpty ? "none" : dSYMs.joined(separator: ", "))") }
        if !a.notes.isEmpty {
            lines.append("")
            lines += a.notes.map { "⚠ \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}
