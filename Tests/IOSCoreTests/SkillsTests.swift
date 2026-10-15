import Foundation
import Testing
@testable import IOSCore

@Test func parsesPlainQuotedAndBlockFrontMatter() {
    let plain = "---\nname: ios-cli\ndescription: Builds, runs and inspects iOS apps.\n---\n# Body"
    #expect(SkillManager.frontMatter(plain) == ["name": "ios-cli", "description": "Builds, runs and inspects iOS apps."])

    let quoted = "---\ndescription: \"Authoritative \\\"SwiftUI\\\" guidance: use it.\"\nname: swiftui-specialist\n---\n"
    #expect(SkillManager.frontMatter(quoted)["description"] == "Authoritative \"SwiftUI\" guidance: use it.")

    let block = "---\nname: adopt-c-bounds-safety\ndescription: |\n  Adopt -fbounds-safety in C code.\n  Use when hardening parsers.\nmetadata: x\n---\n"
    let parsed = SkillManager.frontMatter(block)
    #expect(parsed["description"] == "Adopt -fbounds-safety in C code. Use when hardening parsers.")
    #expect(parsed["metadata"] == "x")

    #expect(SkillManager.frontMatter("# No front matter").isEmpty)
}

@Test func installsUpdatesAndProtectsSkills() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-skills-\(UUID().uuidString)")
    let target = root.appendingPathComponent("target")
    defer { try? FileManager.default.removeItem(at: root) }

    // A skill folder the user made by hand is never replaced or removed without force.
    let manual = target.appendingPathComponent("manual")
    try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
    try Data("---\nname: manual\n---\n".utf8).write(to: manual.appendingPathComponent("SKILL.md"))
    #expect(!SkillManager.isManaged(manual))
    #expect(throws: IOSError.self) { try SkillManager.remove(["manual"], from: target, force: false) }
    #expect(try SkillManager.remove(["manual"], from: target, force: true) == ["manual"])
    #expect(throws: IOSError.self) { try SkillManager.remove(["missing"], from: target, force: false) }
}

@Test func detectsOutdatedInstalledSkills() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-skills-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source/demo"), installed = root.appendingPathComponent("target/demo")
    for folder in [source, installed] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\nname: demo\n---\nv1\n".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
    }
    let sources = [SkillManager.Source(name: "demo", description: "", origin: "ios-cli", folder: source)]
    let target = root.appendingPathComponent("target")
    #expect(SkillManager.outdated(in: target, sources: sources).isEmpty)              // not managed: left alone
    try Data("{}".utf8).write(to: installed.appendingPathComponent(SkillManager.markerName))
    #expect(SkillManager.outdated(in: target, sources: sources).isEmpty)              // managed and identical
    try Data("---\nname: demo\n---\nv2\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
    #expect(SkillManager.outdated(in: target, sources: sources) == ["demo"])          // this build ships a newer one
}
