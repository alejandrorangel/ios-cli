import ArgumentParser
import IOSCore

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the active Xcode, booted simulators and connected devices."
    )

    @OptionGroup var global: GlobalOptions

    struct Report: Encodable {
        let xcode: XcodeInfo
        let bootedSimulators: [Simulator]
        let connectedDevices: [PhysicalDevice]
    }

    func run() throws {
        let report = Report(
            xcode: try XcodeInfo.load(),
            bootedSimulators: try SimulatorList.load().filter(\.isBooted),
            connectedDevices: try DeviceList.load().filter(\.isConnected)
        )
        try Output.emit(report, json: global.json) {
            var lines = [
                "Xcode \(report.xcode.version) (\(report.xcode.build))",
                "  \(report.xcode.developerDirectory)",
                "",
                "Booted simulators: \(report.bootedSimulators.count)",
            ]
            lines += report.bootedSimulators.map { "  \($0.name)  iOS \($0.osVersion ?? "?")  \($0.udid)" }
            lines += ["", "Connected devices: \(report.connectedDevices.count)"]
            lines += report.connectedDevices.map {
                "  \($0.name)  iOS \($0.osVersion ?? "?")  \($0.transport ?? "")  \($0.udid)"
            }
            return lines.joined(separator: "\n")
        }
    }
}
