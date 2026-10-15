import ArgumentParser
import Foundation
import IOSCore

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check Xcode, simulators, devices, signing, Xcode approval, docs, skills and the install; print fixes.",
        discussion: """
        Read-only: nothing is changed. Run it on a new machine, after an Xcode update, or when a command \
        fails for an unclear reason. Exits non-zero when something blocks most commands (✗); warnings (⚠) \
        affect only some commands.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Skip contacting Xcode's tool service (it can take a few seconds to start).")
    var skipXcodeService = false

    @Flag(help: "Skip checking GitHub for a newer release.")
    var offline = false

    func run() throws {
        let checks = Doctor.run(version: IOS.configuration.version, skillsDirectory: SkillManager.defaultDirectory,
                                checkBridge: !skipXcodeService, checkLatest: !offline, progress: Docs.progress)
        try Output.emit(checks, json: global.json) {
            var lines = checks.map { check -> String in
                let mark = ["ok": "✓", "warn": "⚠", "fail": "✗"][check.status] ?? "•"
                return "\(mark) \(check.summary)" + (check.fix.map { "\n    fix: \($0)" } ?? "")
            }
            let warnings = checks.filter { $0.status == "warn" }.count, failures = checks.filter { $0.status == "fail" }.count
            lines.append(failures + warnings == 0 ? "\nAll good." : "\n\(failures) problem\(failures == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s").")
            return lines.joined(separator: "\n")
        }
        if checks.contains(where: { $0.status == "fail" }) { throw ExitCode.failure }
    }
}
