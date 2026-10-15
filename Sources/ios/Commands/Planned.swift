import ArgumentParser
import IOSCore

// Commands from the plan that aren't implemented yet. Each one fails with a pointer to
// its phase so agents and people get a clear answer instead of an unknown-command error.
// The spikes/ folder has working prototypes for most of them.

struct Preview: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render a SwiftUI preview (planned).")
    func run() throws { throw IOSError.notImplemented(command: "preview", plan: "Phase 3, §4") }
}

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a project from an Xcode template (planned).")
    func run() throws { throw IOSError.notImplemented(command: "create", plan: "Phase 3, §4") }
}

struct Skills: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage agent skills (planned).")
    func run() throws { throw IOSError.notImplemented(command: "skills", plan: "Phase 4") }
}
