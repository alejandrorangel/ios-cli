import ArgumentParser
import Foundation
import IOSCore

struct Skills: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install agent skills: ios-cli's own and the ones that ship with Xcode.",
        discussion: """
        Skills go to ~/.claude/skills (Claude Code's personal skills) by default; --project uses ./.claude/skills \
        and --dir any folder (for other agents). Xcode's skills (swiftui-specialist, uikit-app-modernization, …) \
        are exported from the installed Xcode, so they match its version.
        """,
        subcommands: [List.self, Add.self, Remove.self, Update.self]
    )

    struct Location: ParsableArguments {
        @Flag(help: "Use ./.claude/skills in the current project instead of ~/.claude/skills.")
        var project = false

        @Option(help: "Skills folder to use instead.")
        var dir: String?

        var url: URL {
            if let dir { return URL(fileURLWithPath: dir).standardizedFileURL }
            if project { return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills") }
            return SkillManager.defaultDirectory
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List available skills and whether they're installed.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var location: Location

        func run() throws {
            let skills = try SkillManager.list(in: location.url, progress: Docs.progress)
            try Output.emit(skills, json: global.json) {
                skills.map { s in
                    let state = s.installed ? (s.managed ? "installed" : "installed (not by ios)") : "-"
                    let summary = s.description.count > 90 ? String(s.description.prefix(89)) + "…" : s.description
                    return "\(s.name.padding(toLength: 46, withPad: " ", startingAt: 0)) \(s.source.padding(toLength: 8, withPad: " ", startingAt: 0)) \(state)\n    \(summary)"
                }.joined(separator: "\n") + "\n\nFolder: \(location.url.path)"
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install skills by name.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var location: Location
        @Argument(help: "Skill names (see `ios skills list`).") var names: [String] = []
        @Flag(help: "Install every available skill.") var all = false
        @Flag(help: "Replace a same-named skill that wasn't installed by `ios skills`.") var force = false

        func run() throws {
            var wanted = names
            if all { wanted = try SkillManager.list(in: location.url).map(\.name) }
            guard !wanted.isEmpty else { throw ValidationError("Pass skill names or --all.") }
            let added = try SkillManager.add(wanted, into: location.url, force: force, progress: Docs.progress)
            try Output.emit(added, json: global.json) {
                added.map { "Installed \($0.name) (\($0.source)) → \($0.path ?? "")" }.joined(separator: "\n")
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove skills installed by `ios skills`.")
        @OptionGroup var location: Location
        @Argument(help: "Skill names.") var names: [String]
        @Flag(help: "Also remove a same-named skill that wasn't installed by `ios skills`.") var force = false

        func run() throws {
            for name in try SkillManager.remove(names, from: location.url, force: force) { print("Removed \(name)") }
        }
    }

    struct Update: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reinstall skills installed by `ios skills` (e.g. after updating ios or Xcode).")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var location: Location

        func run() throws {
            let updated = try SkillManager.update(in: location.url, progress: Docs.progress)
            try Output.emit(updated, json: global.json) {
                updated.isEmpty ? "No skills installed by `ios skills` in \(location.url.path)."
                    : updated.map { "Updated \($0.name) (\($0.source))" }.joined(separator: "\n")
            }
        }
    }
}
