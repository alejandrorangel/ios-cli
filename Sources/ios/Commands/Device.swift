import ArgumentParser
import IOSCore

struct Device: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Physical devices.",
        subcommands: [List.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List paired physical devices.")

        @OptionGroup var global: GlobalOptions

        func run() throws {
            let devices = try DeviceList.load()
            try Output.emit(devices, json: global.json) {
                Output.table([["NAME", "MODEL", "OS", "STATE", "TRANSPORT", "UDID"]] + devices.map {
                    [$0.name, $0.model ?? "?", $0.osVersion ?? "?", $0.connectionState ?? "?", $0.transport ?? "-", $0.udid]
                })
            }
        }
    }
}
