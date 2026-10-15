import Foundation
import Testing
@testable import IOSCore

// Samples trimmed from real Xcode 27 output, with identifying values replaced.

private let simctlSample = """
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
      {"udid": "SIM-27-A", "name": "iPhone 17", "state": "Booted", "isAvailable": true,
       "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
      {"udid": "SIM-27-B", "name": "iPhone 18 Pro", "state": "Shutdown", "isAvailable": true}
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
      {"udid": "SIM-26-A", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true},
      {"udid": "SIM-26-X", "name": "Broken", "state": "Shutdown", "isAvailable": false}
    ]
  },
  "runtimes": [
    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "name": "iOS 27.0"},
    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version": "26.5", "name": "iOS 26.5"}
  ]
}
"""

// devicectl JSON v5: the new `properties` dictionary next to the deprecated fields.
private let devicectlV5Sample = """
{
  "info": {"jsonVersion": 5},
  "result": {"devices": [
    {
      "identifier": "CORE-1",
      "hardwareProperties": {"reality": "physical", "udid": "DEVICE-1"},
      "properties": {
        "connection": {"state": "connected", "transportType": "wired", "tunnelIPAddressString": "fd00::1"},
        "hardware": {"reality": "physical", "udid": "DEVICE-1", "marketingName": "iPad Pro (12.9-inch) (5th generation)"},
        "software": {"osVersionNumber": {"stringValue": "27.0.1"}},
        "state": {"name": "Test iPad", "developerModeStatus": {"enabled": {"mode": 1}}}
      }
    },
    {
      "identifier": "CORE-2",
      "properties": {
        "hardware": {"reality": "simulated", "udid": "SIM-27-A"},
        "state": {"name": "iPhone 17"}
      }
    }
  ]}
}
"""

private let devicectlLegacySample = """
{
  "result": {"devices": [
    {
      "hardwareProperties": {"reality": "physical", "udid": "DEVICE-2", "marketingName": "iPhone"},
      "deviceProperties": {"name": "Old iPhone", "osVersionNumber": "26.5", "developerModeStatus": "enabled"},
      "connectionProperties": {"tunnelState": "connected", "transportType": "wired", "tunnelIPAddress": "fd00::2"}
    }
  ]}
}
"""

@Test func parsesSimulatorsWithRuntimeVersions() throws {
    let sims = try SimulatorList.parse(Data(simctlSample.utf8))
    #expect(sims.count == 3) // unavailable simulator dropped
    let booted = try #require(sims.first { $0.udid == "SIM-27-A" })
    #expect(booted.isBooted)
    #expect(booted.osVersion == "27.0")
    #expect(booted.deviceType == "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
    #expect(sims.first?.osVersion == "27.0") // newest runtime first
}

@Test func parsesDevicectlV5Properties() throws {
    let devices = try DeviceList.parse(Data(devicectlV5Sample.utf8))
    #expect(devices.count == 1) // simulators in devicectl output are ignored
    let iPad = try #require(devices.first)
    #expect(iPad.name == "Test iPad")
    #expect(iPad.osVersion == "27.0.1")
    #expect(iPad.isConnected)
    #expect(iPad.tunnelAddress == "fd00::1")
    #expect(iPad.developerMode == "enabled")
}

@Test func fallsBackToLegacyDevicectlFields() throws {
    let device = try #require(try DeviceList.parse(Data(devicectlLegacySample.utf8)).first)
    #expect(device.name == "Old iPhone")
    #expect(device.osVersion == "26.5")
    #expect(device.isConnected)
    #expect(device.tunnelAddress == "fd00::2")
}

@Test func rejectsUnexpectedDevicectlOutput() {
    #expect(throws: IOSError.self) { try DeviceList.parse(Data("{}".utf8)) }
}

@Test func parsesXcodeVersion() throws {
    let (version, build) = try XcodeInfo.parseVersion("Xcode 27.0\nBuild version 27A266a\n")
    #expect(version == "27.0")
    #expect(build == "27A266a")
}
