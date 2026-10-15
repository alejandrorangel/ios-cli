import ArgumentParser
import Foundation
import IOSCore

struct Sim: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage simulators: create, boot, erase, and set appearance, location, permissions and more.",
        discussion: """
        Commands act on --device (a simulator name or UDID), else the only booted simulator. \
        `boot` without --device boots the default iPhone (newest iOS).
        """,
        subcommands: [
            List.self, Create.self, Boot.self, Shutdown.self, Erase.self, Delete.self,
            Appearance.self, ContentSize.self, Location.self, Privacy.self, Push.self, StatusBar.self,
        ]
    )

    /// What lifecycle and settings commands print.
    struct Result: Encodable {
        let udid: String
        let name: String
        let message: String
        var value: String?
    }

    static func emit(_ simulator: Simulator, _ message: String, value: String? = nil, json: Bool) throws {
        let result = Result(udid: simulator.udid, name: simulator.name, message: message, value: value)
        try Output.emit(result, json: json) { "\(message) — \(simulator.name) (\(simulator.udid))" }
    }

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

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a simulator.",
            discussion: "Device types: `xcrun simctl list devicetypes`. Runtimes: `ios sim list` shows the OS versions in use."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Name for the new simulator.")
        var name: String

        @Option(help: "Device type name or identifier, e.g. \"iPhone 17 Pro\".")
        var type = "iPhone 17"

        @Option(help: "iOS version, e.g. 27.0. Defaults to the newest installed runtime.")
        var os: String?

        @Flag(help: "Boot it after creating it.")
        var boot = false

        func run() throws {
            var simulator = try SimControl.create(name: name, type: type, os: os)
            if boot {
                try SimControl.boot(simulator, show: false)
                simulator = try SimControl.simulator(simulator.udid, command: "sim create")
            }
            try Output.emit(simulator, json: global.json) {
                "Created \(simulator.name) (iOS \(simulator.osVersion ?? "?"), \(simulator.state)) \(simulator.udid)"
            }
        }
    }

    struct Boot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Boot a simulator and wait until it's ready.")

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Flag(help: "Also open the Simulator app showing it.")
        var show = false

        func run() throws {
            let simulator = try SimControl.simulator(target.device, command: "sim boot", orDefault: true)
            let wasBooted = simulator.isBooted
            try SimControl.boot(simulator, show: show)
            try Sim.emit(simulator, wasBooted ? "Already booted" : "Booted", json: global.json)
        }
    }

    struct Shutdown: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shut down a simulator (or all of them).")

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Flag(help: "Shut down every booted simulator.")
        var all = false

        func run() throws {
            let simulators = all ? try SimulatorList.load().filter(\.isBooted)
                                 : [try SimControl.simulator(target.device, command: "sim shutdown")]
            for simulator in simulators { try SimControl.shutdown(simulator) }
            let results = simulators.map { Result(udid: $0.udid, name: $0.name, message: $0.isBooted ? "Shut down" : "Already shut down") }
            try Output.emit(results, json: global.json) {
                results.isEmpty ? "No simulators were booted." : results.map { "\($0.message) — \($0.name) (\($0.udid))" }.joined(separator: "\n")
            }
        }
    }

    struct Erase: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Erase a simulator's contents and settings (apps, data, permissions).",
            discussion: "A booted simulator is shut down, erased and booted again."
        )

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        func run() throws {
            let simulator = try SimControl.simulator(target.device, command: "sim erase")
            RunnerSessions.stop(.simulator(simulator)) // erasing removes the runner app anyway
            let rebooted = try SimControl.erase(simulator)
            try Sim.emit(simulator, rebooted ? "Erased and rebooted" : "Erased", json: global.json)
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a simulator.")

        @OptionGroup var global: GlobalOptions

        @Option(name: .long, help: "Simulator name or UDID (required).")
        var device: String

        func run() throws {
            let simulator = try SimControl.simulator(device, command: "sim delete")
            RunnerSessions.stop(.simulator(simulator))
            try SimControl.delete(simulator)
            try Sim.emit(simulator, "Deleted", json: global.json)
        }
    }

    struct Appearance: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show or set light/dark appearance.")

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Argument(help: "light or dark. Omit to print the current appearance.")
        var mode: String?

        func validate() throws {
            if let mode, !SimControl.appearances.contains(mode) { throw ValidationError("Appearance must be light or dark.") }
        }

        func run() throws {
            let simulator = try SimControl.simulator(target.device, command: "sim appearance")
            let value = try SimControl.ui(simulator, option: "appearance", value: mode)
            try Sim.emit(simulator, "Appearance: \(value)", value: value, json: global.json)
        }
    }

    struct ContentSize: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "content-size",
            abstract: "Show or set the Dynamic Type text size.",
            discussion: "Sizes: \(SimControl.contentSizes.joined(separator: ", ")), or increment / decrement."
        )

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Argument(help: "Size name, increment or decrement. Omit to print the current size.")
        var size: String?

        func validate() throws {
            if let size, !(SimControl.contentSizes + ["increment", "decrement"]).contains(size) {
                throw ValidationError("Unknown size '\(size)'. Sizes: \(SimControl.contentSizes.joined(separator: ", ")), increment, decrement.")
            }
        }

        func run() throws {
            let simulator = try SimControl.simulator(target.device, command: "sim content-size")
            let value = try SimControl.ui(simulator, option: "content_size", value: size)
            try Sim.emit(simulator, "Content size: \(value)", value: value, json: global.json)
        }
    }

    struct Location: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set or clear the simulated location.")

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Argument(help: "latitude,longitude (e.g. 37.3349,-122.0090), or clear.")
        var location: String

        func validate() throws {
            if location != "clear" && SimControl.parseCoordinate(location) == nil {
                throw ValidationError("Pass latitude,longitude with '.' decimals (e.g. 37.3349,-122.0090), or clear.")
            }
        }

        func run() throws {
            let simulator = try SimControl.simulator(target.device, command: "sim location")
            if let point = SimControl.parseCoordinate(location) {
                try SimControl.setLocation(simulator, latitude: point.latitude, longitude: point.longitude)
                try Sim.emit(simulator, "Location set to \(point.latitude),\(point.longitude)", value: location, json: global.json)
            } else {
                try SimControl.clearLocation(simulator)
                try Sim.emit(simulator, "Location cleared", json: global.json)
            }
        }
    }

    struct Privacy: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Grant, revoke or reset an app's permission (so prompts can be tested again).",
            discussion: """
            Services: \(SimControl.privacyServices.joined(separator: ", ")). `reset` makes the app ask again \
            on next use; it also works without --bundle-id (all apps). Some changes terminate the app. \
            Notification permission isn't covered by simctl; erase the simulator or reinstall the app to reset it.
            """
        )

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Argument(help: "grant, revoke or reset.")
        var action: String

        @Argument(help: "Service, e.g. photos, location, microphone, or all.")
        var service: String

        @Option(help: "The app's bundle identifier (required for grant and revoke).")
        var bundleID: String?

        func validate() throws {
            guard SimControl.privacyActions.contains(action) else { throw ValidationError("Action must be grant, revoke or reset.") }
            guard SimControl.privacyServices.contains(service) else {
                throw ValidationError("Unknown service '\(service)'. Services: \(SimControl.privacyServices.joined(separator: ", ")).")
            }
            if action != "reset" && bundleID == nil { throw ValidationError("\(action) needs --bundle-id.") }
        }

        func run() throws {
            let simulator = try SimControl.simulator(target.device, command: "sim privacy")
            try SimControl.privacy(simulator, action: action, service: service, bundleID: bundleID)
            let verb = ["grant": "Granted", "revoke": "Revoked", "reset": "Reset"][action]!
            try Sim.emit(simulator, "\(verb) \(service) for \(bundleID ?? "all apps")", json: global.json)
        }
    }

    struct Push: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a simulated push notification to an app.",
            discussion: """
            Pass an APNs JSON payload (with an "aps" key) as a file or - for stdin, or build a simple alert \
            with --title / --body / --badge. The app needs notification permission to show it.
            """
        )

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Option(help: "The app's bundle identifier.")
        var bundleID: String

        @Argument(help: "APNs payload JSON file, or - for stdin.")
        var payload: String?

        @Option(help: "Alert title.")
        var title: String?

        @Option(help: "Alert body.")
        var body: String?

        @Option(help: "Badge count.")
        var badge: Int?

        @Flag(help: "Play the default sound.")
        var sound = false

        func validate() throws {
            let built = title != nil || body != nil || badge != nil
            if payload == nil && !built { throw ValidationError("Pass a payload file, or --title / --body / --badge.") }
            if payload != nil && built { throw ValidationError("Pass a payload file or --title/--body/--badge, not both.") }
        }

        func run() throws {
            let simulator = try SimControl.simulator(target.device, command: "sim push")
            let data: Data
            if let payload {
                data = payload == "-" ? FileHandle.standardInput.readDataToEndOfFile()
                                      : try Data(contentsOf: URL(fileURLWithPath: payload))
            } else {
                data = try JSONSerialization.data(withJSONObject: SimControl.pushPayload(title: title, body: body, badge: badge, sound: sound))
            }
            try SimControl.push(simulator, bundleID: bundleID, payload: data)
            try Sim.emit(simulator, "Sent push to \(bundleID)", json: global.json)
        }
    }

    struct StatusBar: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status-bar",
            abstract: "Override the status bar (time, battery, signal) for screenshots, or clear the overrides.",
            discussion: "--clean sets 9:41, full battery, full Wi-Fi and cellular; other options adjust it."
        )

        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        @Flag(help: "Apple's screenshot look: 9:41, 100% charged, full signal.")
        var clean = false

        @Flag(help: "Remove all overrides.")
        var clear = false

        @Option(help: "Time to show, e.g. 9:41 (or an ISO date).")
        var time: String?

        @Option(help: "Battery level 0–100.")
        var battery: Int?

        @Option(help: "charging, charged or discharging.")
        var batteryState: String?

        @Option(help: "Wi-Fi bars 0–3.")
        var wifiBars: Int?

        @Option(help: "Cellular bars 0–4.")
        var cellularBars: Int?

        @Option(help: "hide, wifi, 3g, 4g, lte, lte-a, lte+, 5g, 5g+, 5g-uwb or 5g-uc.")
        var network: String?

        @Option(help: "Carrier name ('' to hide it).")
        var carrier: String?

        var overrides: SimControl.StatusBar {
            (clean ? .clean : SimControl.StatusBar()).merging(SimControl.StatusBar(
                time: time, batteryLevel: battery, batteryState: batteryState, wifiBars: wifiBars,
                cellularBars: cellularBars, dataNetwork: network, operatorName: carrier
            ))
        }

        func validate() throws {
            if clear && (clean || !overrides.isEmpty) { throw ValidationError("--clear can't be combined with overrides.") }
            if !clear && overrides.isEmpty { throw ValidationError("Pass --clean, an override such as --time 9:41, or --clear.") }
            if let battery, !(0...100).contains(battery) { throw ValidationError("--battery must be 0–100.") }
            if let wifiBars, !(0...3).contains(wifiBars) { throw ValidationError("--wifi-bars must be 0–3.") }
            if let cellularBars, !(0...4).contains(cellularBars) { throw ValidationError("--cellular-bars must be 0–4.") }
        }

        func run() throws {
            let simulator = try SimControl.simulator(target.device, command: "sim status-bar")
            if clear {
                try SimControl.clearStatusBar(simulator)
                try Sim.emit(simulator, "Status bar overrides cleared", json: global.json)
            } else {
                try SimControl.overrideStatusBar(simulator, overrides)
                try Sim.emit(simulator, "Status bar: \(overrides.summary)", json: global.json)
            }
        }
    }
}
