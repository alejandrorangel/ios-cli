import ArgumentParser
import IOSCore

struct Sim: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage simulators.",
        subcommands: [List.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List available simulators.")

        @OptionGroup var global: GlobalOptions

        @Flag(help: "Only show booted simulators.")
        var booted = false

        func run() throws {
            let simulators = try SimulatorList.load().filter { !booted || $0.isBooted }
            try Output.emit(simulators, json: global.json) {
                Output.table([["NAME", "OS", "STATE", "UDID"]] + simulators.map {
                    [$0.name, $0.osVersion ?? "?", $0.state, $0.udid]
                })
            }
        }
    }
}
