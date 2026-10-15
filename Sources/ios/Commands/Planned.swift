import ArgumentParser
import IOSCore

// Commands from the plan that aren't implemented yet. Each one fails with a pointer to
// its phase so agents and people get a clear answer instead of an unknown-command error.

struct Skills: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage agent skills (planned).")
    func run() throws { throw IOSError.notImplemented(command: "skills", plan: "Phase 4") }
}
