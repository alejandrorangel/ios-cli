import Testing
@testable import IOSCore

private func sim(_ udid: String, _ name: String, booted: Bool = false) -> Simulator {
    Simulator(udid: udid, name: name, state: booted ? "Booted" : "Shutdown",
              runtime: "iOS", osVersion: "27.0", deviceType: nil)
}

private func sim(_ udid: String, _ name: String, os: String) -> Simulator {
    Simulator(udid: udid, name: name, state: "Shutdown", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-\(os)",
              osVersion: os, deviceType: nil)
}

private func device(_ udid: String, _ name: String, connected: Bool = true) -> PhysicalDevice {
    PhysicalDevice(udid: udid, name: name, model: nil, osVersion: "27.0.1",
                   connectionState: connected ? "connected" : "unavailable",
                   transport: "wired", tunnelAddress: nil, developerMode: "enabled")
}

@Test func resolvesByUDIDThenName() throws {
    let sims = [sim("SIM-A", "iPhone 17"), sim("SIM-B", "iPhone 18 Pro")]
    let devices = [device("DEV-1", "Test iPad")]
    #expect(try TargetResolver.resolve("sim-b", simulators: sims, devices: devices).udid == "SIM-B")
    #expect(try TargetResolver.resolve("test ipad", simulators: sims, devices: devices).udid == "DEV-1")
}

@Test func defaultsToTheOnlyActiveTarget() throws {
    let sims = [sim("SIM-A", "iPhone 17", booted: true), sim("SIM-B", "iPhone 18 Pro")]
    let devices = [device("DEV-1", "Test iPad", connected: false)]
    #expect(try TargetResolver.resolve(nil, simulators: sims, devices: devices).udid == "SIM-A")
}

@Test func ambiguousWithoutQueryWhenSeveralActive() {
    let sims = [sim("SIM-A", "iPhone 17", booted: true)]
    let devices = [device("DEV-1", "Test iPad")]
    #expect(throws: IOSError.self) { try TargetResolver.resolve(nil, simulators: sims, devices: devices) }
}

@Test func prefersBootedSimulatorWhenNamesRepeat() throws {
    // Same model name on two runtimes is common.
    let sims = [sim("SIM-26", "iPhone 17"), sim("SIM-27", "iPhone 17", booted: true)]
    #expect(try TargetResolver.resolve("iPhone 17", simulators: sims, devices: []).udid == "SIM-27")
}

@Test func unknownQueryListsCandidates() {
    #expect(throws: IOSError.self) {
        try TargetResolver.resolve("nope", simulators: [sim("SIM-A", "iPhone 17")], devices: [])
    }
}

@Test func testsDefaultToASimulatorNeverADevice() throws {
    // Booted simulator wins.
    #expect(try TargetResolver.defaultSimulator([sim("SIM-A", "iPhone 17", booted: true), sim("SIM-B", "iPhone 18")]).udid == "SIM-A")
    // None booted: first iPhone (by name) on the newest iOS; 27 sorts above 9 numerically.
    let sims = [sim("OLD", "iPhone 8", os: "9.3"), sim("PRO", "iPhone 17 Pro", os: "27.0"),
                sim("BASE", "iPhone 17", os: "27.0"), sim("IPAD", "iPad Air", os: "27.0"), sim("MID", "iPhone 16", os: "26.5")]
    #expect(try TargetResolver.defaultSimulator(sims).udid == "BASE")
    #expect(throws: IOSError.self) { try TargetResolver.defaultSimulator([]) }
}
