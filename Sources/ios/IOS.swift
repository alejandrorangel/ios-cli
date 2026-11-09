import ArgumentParser
import IOSCore

@main
struct IOS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "iOS development from the command line, for people and AI agents.",
        discussion: "Pass --json to any command for machine-readable output. See PLAN.md for the roadmap.",
        version: "0.6.0",
        subcommands: [
            Info.self,
            DoctorCommand.self,
            Sim.self,
            Device.self,
            ScreenCommand.self,
            Describe.self,
            AnalyzeCommand.self,
            Build.self,
            Install.self,
            Run.self,
            TestCommand.self,
            AppCommand.self,
            LogsCommand.self,
            CrashesCommand.self,
            SignalsCommand.self,
            Docs.self,
            LayoutCommand.self,
            Input.self,
            JourneyCommand.self,
            RunnerCommand.self,
            Check.self,
            Preview.self,
            ProfileCommand.self,
            Create.self,
            XcodeCommand.self,
            Skills.self,
            UpdateCommand.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Flag(help: "Print machine-readable JSON instead of text.")
    var json = false
}

/// What the launched app receives: `-- -Flag YES` style arguments and --env variables.
struct LaunchOptions: ParsableArguments {
    @Option(name: .customLong("launch-env"), help: ArgumentHelp("Environment variable for the app as NAME=VALUE (repeatable).", valueName: "name=value"))
    var environment: [String] = []

    @Argument(parsing: .postTerminator, help: ArgumentHelp("Arguments for the app after --, e.g. -- -ShowOnboarding NO (sets that UserDefaults key for this launch).", valueName: "app-arguments"))
    var arguments: [String] = []

    func environmentValues() throws -> [String: String] {
        var values: [String: String] = [:]
        for pair in environment {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { throw ValidationError("--launch-env takes NAME=VALUE, got '\(pair)'.") }
            values[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        return values
    }
}

struct TargetOptions: ParsableArguments {
    @Option(name: .long, help: "Simulator or device UDID or name. Defaults to the only booted simulator or connected device.")
    var device: String?
}
