import Foundation
import Testing
@testable import IOSCore

// A trimmed snapshot of a sign-in screen, in the runner's JSON format.
private let snapshotJSON = #"""
{"type": 2, "label": "Sample App", "frame": [0, 0, 402, 874], "children": [
  {"type": 4, "frame": [0, 0, 402, 874], "children": [
    {"type": 9, "id": "closeButton", "label": "close", "frame": [350, 72, 40, 40]},
    {"type": 48, "id": "headingLabel", "label": "Welcome back", "frame": [100, 130, 202, 32]},
    {"type": 49, "id": "EmailAddressTextField", "label": "Email Address", "value": "test@example.com",
     "frame": [20, 220, 362, 40], "focused": true},
    {"type": 9, "id": "submitButton", "label": "Sign in", "frame": [20, 410, 362, 44], "enabled": false},
    {"type": 48, "label": "Sign in", "frame": [180, 420, 48, 24]},
    {"type": 1, "frame": [0, 500, 402, 100]},
    {"type": 9, "label": "Offscreen", "frame": [0, 1200, 100, 40]},
    {"type": 9, "label": "Half visible", "frame": [-50, 800, 100, 100]},
    {"type": 19, "frame": [0, 600, 402, 274], "children": [
      {"type": 20, "label": "q", "frame": [5, 610, 30, 40]}
    ]}
  ]}
]}
"""#

private func tree() throws -> UIElementNode {
    try Layout.parse(try JSONSerialization.jsonObject(with: Data(snapshotJSON.utf8)))
}

@Test func mapsElementTypeNames() throws {
    let root = try tree()
    #expect(root.type == "Application")
    #expect(root.children[0].type == "Window")
    #expect(root.children[0].children[2].type == "TextField")
    #expect(Layout.typeNames.count == 83) // Any … StatusItem in Xcode 27
    #expect(Layout.typeNames[45] == "SearchField")
}

@Test func flattensToVisibleMeaningfulElements() throws {
    let elements = Layout.flatten(try tree())
    let labels = elements.map { $0.id ?? $0.label ?? "?" }
    #expect(labels == ["closeButton", "headingLabel", "EmailAddressTextField", "submitButton", "Sign in", "Half visible"])
    // Unlabeled containers, off-screen elements and keyboard keys are left out.
    #expect(!labels.contains("Offscreen"))
    #expect(!labels.contains("q"))
    #expect(elements.map(\.index) == Array(1...elements.count))
}

@Test func tapPointIsCenterOfVisiblePart() throws {
    let elements = Layout.flatten(try tree())
    let close = try #require(elements.first { $0.id == "closeButton" })
    #expect(close.center == Point(x: 370, y: 92))
    let half = try #require(elements.first { $0.label == "Half visible" })
    #expect(half.center == Point(x: 25, y: 837)) // clipped to the screen: x 0…50, y 800…874
}

@Test func findsElementsByIdentifierAndLabel() throws {
    let elements = Layout.flatten(try tree())
    #expect(Layout.find(in: elements, id: "submitButton")?.type == "Button")
    // "Sign in" is both a Button and a StaticText; the interactive one wins.
    #expect(Layout.find(in: elements, label: "Sign in")?.id == "submitButton")
    #expect(Layout.find(in: elements, label: "welcome")?.id == "headingLabel") // contains, case-insensitive
    #expect(Layout.find(in: elements, id: "nope") == nil)
}

@Test func describesElementsForText() throws {
    let elements = Layout.flatten(try tree())
    let email = try #require(elements.first { $0.id == "EmailAddressTextField" })
    #expect(email.textLine == #"[3] TextField id=EmailAddressTextField "Email Address" value="test@example.com" focused @(201,240)"#)
    let submit = try #require(elements.first { $0.id == "submitButton" })
    #expect(submit.textLine.contains("disabled"))
}

@Test func computesSwipePoints() throws {
    let screen = Rect(x: 0, y: 0, width: 400, height: 800)
    let up = try #require(Layout.swipePoints(direction: "up", screen: screen))
    #expect(up.0 == Point(x: 200, y: 600) && up.1 == Point(x: 200, y: 200))
    let left = try #require(Layout.swipePoints(direction: "left", screen: screen))
    #expect(left.0.x > left.1.x)
    #expect(Layout.swipePoints(direction: "sideways", screen: screen) == nil)
}

@Test func simulatorsGetStableDistinctPorts() {
    func sim(_ udid: String) -> Target {
        .simulator(Simulator(udid: udid, name: "iPhone", state: "Booted", runtime: "iOS", osVersion: "27.0", deviceType: nil))
    }
    let a = RunnerSessions.port(for: sim("C3F07A81-1DFF-4C17-87B6-CDBB54C2D7CC"))
    #expect(a == RunnerSessions.port(for: sim("C3F07A81-1DFF-4C17-87B6-CDBB54C2D7CC"))) // stable across calls
    #expect(a != RunnerSessions.port(for: sim("FAEF2067-EC21-4C9E-8CCC-829C32B9A086")))
    #expect((8101...8900).contains(a))
    let device = Target.device(PhysicalDevice(udid: "D", name: "iPad", model: nil, osVersion: nil, connectionState: "connected",
                                              transport: "wired", tunnelAddress: "fd00::1", developerMode: nil))
    #expect(RunnerSessions.port(for: device) == 8100)
}

@Test func keepsSheetsOutsideTheFirstWindow() throws {
    // iPad form sheet: the first window is a centred card, a second sheet sits at the bottom of the
    // screen outside it. The application frame is the screen, so both must be kept.
    let json = #"""
    {"type": 2, "frame": [0, 0, 1024, 1366], "children": [
      {"type": 4, "frame": [112, 200, 800, 900], "children": [
        {"type": 9, "id": "transport-play", "label": "Play", "frame": [480, 1000, 64, 44]}
      ]},
      {"type": 4, "frame": [0, 0, 1024, 1366], "children": [
        {"type": 40, "id": "count-in", "label": "Count In", "frame": [150, 1180, 700, 44]},
        {"type": 33, "id": "guitar-volume", "label": "Guitar", "frame": [150, 1240, 700, 44]}
      ]}
    ]}
    """#
    let elements = Layout.flatten(try Layout.parse(try JSONSerialization.jsonObject(with: Data(json.utf8))))
    #expect(elements.compactMap(\.id) == ["transport-play", "count-in", "guitar-volume"])
}

@Test func marksElementsCoveredByAFullScreenPresentation() throws {
    // Window layers: the root screen, a full-screen cover, then a sheet container (full-screen with
    // a dimming region). Only the sheet is on top; the other layers are covered.
    let json = #"""
    {"type": 2, "frame": [0, 0, 402, 874], "children": [
      {"type": 4, "frame": [0, 0, 402, 874], "children": [
        {"type": 1, "frame": [0, 0, 402, 874], "children": [
          {"type": 9, "id": "open-practice", "label": "Practice Session", "frame": [138, 441, 126, 20]}]},
        {"type": 1, "frame": [0, 0, 402, 874], "children": [
          {"type": 9, "id": "open-settings", "label": "Track Settings", "frame": [146, 461, 109, 20]}]},
        {"type": 1, "frame": [0, 0, 402, 874], "children": [
          {"type": 40, "id": "count-in", "label": "Count In", "frame": [23, 588, 355, 27]},
          {"type": 9, "label": "Track Settings", "frame": [146, 700, 109, 20]}]}
      ]}
    ]}
    """#
    let elements = Layout.flatten(try Layout.parse(try JSONSerialization.jsonObject(with: Data(json.utf8))))
    let covered = Dictionary(uniqueKeysWithValues: elements.map { ($0.id ?? "sheet-\($0.label ?? "")", $0.covered) })
    #expect(covered == ["open-practice": true, "open-settings": true, "count-in": false, "sheet-Track Settings": false])
    // A label on both a covered layer and the top layer resolves to the one on top.
    #expect(Layout.find(in: elements, label: "Track Settings")?.center.y == 710)
    #expect(elements.first { $0.id == "open-practice" }?.textLine.contains("covered") == true)
}

@Test func aimsAtTheControlOfALabeledToggle() throws {
    let json = #"""
    {"type": 2, "frame": [0, 0, 402, 874], "children": [{"type": 4, "frame": [0, 0, 402, 874], "children": [
      {"type": 40, "id": "count-in", "label": "Count In", "frame": [23, 588, 355, 27], "children": [
        {"type": 48, "label": "Count In", "frame": [23, 592, 62, 20]},
        {"type": 40, "frame": [320, 588, 60, 27]}]}
    ]}]}
    """#
    let elements = Layout.flatten(try Layout.parse(try JSONSerialization.jsonObject(with: Data(json.utf8))))
    #expect(Layout.find(in: elements, id: "count-in")?.center == Point(x: 350, y: 601.5))
}
