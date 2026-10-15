import ArgumentParser
import IOSCore

@main
struct IOS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "iOS development from the command line, for people and AI agents.",
        discussion: "Pass --json to any command for machine-readable output. See PLAN.md for the roadmap.",
        version: "0.1.0",
        subcommands: [
            Info.self,
            Sim.self,
            Device.self,
            ScreenCommand.self,
            Describe.self,
            Build.self,
            Install.self,
            Run.self,
            LogsCommand.self,
            Docs.self,
            LayoutCommand.self,
            Input.self,
            RunnerCommand.self,
            // Not implemented yet; each names its phase in PLAN.md.
            Preview.self,
            Create.self,
            Skills.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Flag(help: "Print machine-readable JSON instead of text.")
    var json = false
}

struct TargetOptions: ParsableArguments {
    @Option(name: .long, help: "Simulator or device UDID or name. Defaults to the only booted simulator or connected device.")
    var device: String?
}
