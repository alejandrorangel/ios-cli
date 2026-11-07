import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import IOSCore

// MARK: Annotated screenshots

private func element(_ index: Int, _ type: String, frame: Rect, covered: Bool = false) -> LayoutElement {
    LayoutElement(index: index, type: type, id: nil, label: "e\(index)", value: nil, placeholder: nil, frame: frame,
                  center: Point(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2),
                  enabled: true, selected: false, focused: false, covered: covered)
}

@Test func resolvesMarksInAString() throws {
    let marks = [Annotate.Mark(index: 1, x: 10.4, y: 20.6), Annotate.Mark(index: 12, x: 201, y: 319)]
    #expect(try Annotate.resolve("tap #12", marks: marks) == "tap 201 319")
    #expect(try Annotate.resolve("#1 → #12", marks: marks) == "10 21 → 201 319")
    #expect(try Annotate.resolve("no marks", marks: marks) == "no marks")
    #expect(throws: IOSError.self) { try Annotate.resolve("#3", marks: marks) }
}

@Test func mergesBoxesWithTheSameFrameAndSkipsFullScreenOnes() {
    let screen = Rect(x: 0, y: 0, width: 402, height: 874)
    let row = Rect(x: 16, y: 300, width: 370, height: 52)
    let boxes = Annotate.boxes([
        element(1, "Cell", frame: row), element(2, "Button", frame: Rect(x: 16.5, y: 300, width: 370, height: 52)),
        element(3, "Toolbar", frame: screen), element(4, "Image", frame: Rect(x: 350, y: 315, width: 20, height: 20)),
        element(5, "Button", frame: Rect(x: 0, y: 2000, width: 50, height: 50)), // off screen
    ], screen: screen)
    #expect(boxes.map { $0.elements.map(\.index) } == [[1, 2], [4]])
}

@Test func roundTripsMarksThroughAPNG() throws {
    // A 4×8 px image standing for a 2×4 pt screen.
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("annotate-\(UUID().uuidString).png").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let context = CGContext(data: nil, width: 4, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))

    try Annotate.draw([element(1, "Button", frame: Rect(x: 0, y: 0, width: 1, height: 2))], screen: Rect(x: 0, y: 0, width: 2, height: 4), png: path)
    #expect(try Annotate.marks(in: path) == [Annotate.Mark(index: 1, x: 0.5, y: 1)])
}

// MARK: Journeys

private let journeyXML = """
<journey name="Loop a section">
  <description>
    Practice Mode loops
    the selected bars
  </description>
  <setup platform="android"><launch package="com.example"/></setup>
  <setup platform="ios">
    <launch bundle-id="com.example.app">
      <argument>-Flag</argument><argument>YES</argument>
      <env name="API_ENV" value="staging"/>
    </launch>
    <open-url>example://practice/42</open-url>
  </setup>
  <actions>
    <action>Tap "Loop"</action>
    <action>
      Verify that bars 1–4
      are highlighted
    </action>
  </actions>
</journey>
"""

@Test func parsesAJourneyWithItsIOSSetup() throws {
    let journey = try Journeys.parse(Data(journeyXML.utf8), file: "loop.journey.xml")
    #expect(journey.name == "Loop a section")
    #expect(journey.description == "Practice Mode loops the selected bars")
    #expect(journey.steps.map(\.kind) == ["action", "check"])
    #expect(journey.steps[1].text == "Verify that bars 1–4 are highlighted")
    #expect(journey.setup == Journey.Setup(bundleID: "com.example.app", arguments: ["-Flag", "YES"],
                                           environment: ["API_ENV": "staging"], urls: ["example://practice/42"]))
}

@Test func rejectsJourneysWithoutSteps() {
    #expect(throws: IOSError.self) { try Journeys.parse(Data("<journey name='x'><actions/></journey>".utf8), file: "x") }
    #expect(throws: IOSError.self) { try Journeys.parse(Data("<flow/>".utf8), file: "x") }
    #expect(throws: IOSError.self) { try Journeys.parse(Data("<journey".utf8), file: "x") }
}

@Test func checksResultsAndWritesTheAndroidStyleReport() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journey-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try journeyXML.write(to: folder.appendingPathComponent("loop.journey.xml"), atomically: true, encoding: .utf8)

    func write(_ json: String) throws -> String {
        let url = folder.appendingPathComponent("result-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
    let good = try write("""
        {"journey":"Loop a section","file":"loop.journey.xml","result":"failed","steps":[
          {"index":1,"result":"passed","commands":["ios input tap --label Loop"]},
          {"index":2,"result":"failed","screenshot":"s2.png","comment":"Only bar 1 is highlighted"}]}
        """)
    let (result, journey) = try Journeys.readResult(good)
    let markdown = Journeys.markdown(result, journey: journey)
    #expect(markdown.contains("### Action: Tap \"Loop\" ✅"))
    #expect(markdown.contains("### Action: Verify that bars 1–4 are highlighted ❌"))
    #expect(markdown.contains("  - `ios input tap --label Loop`"))
    #expect(markdown.contains("- **Comment**: Only bar 1 is highlighted"))

    // Marked passed with a failed step, and a step count that doesn't match the journey.
    let contradictory = try write(#"{"journey":"x","result":"passed","steps":[{"index":1,"result":"failed"}]}"#)
    #expect(throws: IOSError.self) { try Journeys.readResult(contradictory) }
    let short = try write(#"{"journey":"x","file":"loop.journey.xml","result":"failed","steps":[{"index":1,"result":"failed"}]}"#)
    #expect(throws: IOSError.self) { try Journeys.readResult(short) }
    let badValue = try write(#"{"journey":"x","result":"ok","steps":[]}"#)
    #expect(throws: IOSError.self) { try Journeys.readResult(badValue) }
}

@Test func findsJourneyFilesButNotInBuildOutput() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journeys-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    for path in ["journeys/a.journey.xml", "journeys/b.xml", ".build/c.journey.xml", "DerivedData/d.journey.xml", "e.journey.xml"] {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: url, atomically: true, encoding: .utf8)
    }
    // Sorted by full path: …/e.journey.xml before …/journeys/a.journey.xml.
    #expect(Journeys.find(in: folder.path).map { URL(fileURLWithPath: $0).lastPathComponent } == ["e.journey.xml", "a.journey.xml"])
}

// MARK: Devices

@Test func readsAvailabilityFromDevicectlsTable() {
    let table = """
    Devices:
    Name                    Hostname   Identifier                                    State                Model                                              Reality
    ---------------------   --------   -------------------------------------------   ------------------   ------------------------------------------------   --------
    Alejandro’s iPad (2)               00008103-000E60D40A79001E (UDID)              available (paired)   iPad Pro (12.9-inch) (5th generation) (iPad13,8)   physical
    Test iPhone             phone.local  00008110-0001 (UDID)                        unavailable          iPhone 15 (iPhone15,4)                             physical
    iPhone 17                          FAEF2067-EC21-4C9E-8CCC-829C32B9A086 (UDID)   connected            iPhone 17 (iPhone18,3)                             simulated
    """
    let states = DeviceList.availability(table: table)
    #expect(states["00008103-000E60D40A79001E"] == "available (paired)")
    #expect(states["00008110-0001"] == "unavailable")
    #expect(states["FAEF2067-EC21-4C9E-8CCC-829C32B9A086"] == "connected")
}

@Test func treatsAvailableDevicesAsUsableAndUnavailableOnesAsNot() {
    var device = PhysicalDevice(udid: "D", name: "iPad", model: nil, osVersion: nil, connectionState: "disconnected",
                                transport: "wired", tunnelAddress: nil, developerMode: nil)
    device.availability = "available (paired)"
    #expect(device.isConnected && !device.isUnavailable && device.displayState == "available (paired)")
    device.availability = "unavailable"
    #expect(!device.isConnected && device.isUnavailable)
    #expect(throws: IOSError.self) { try TargetResolver.ensureReachable(.device(device)) }
}

@Test func keepsDevicesWhoseHardwareDetailsAreMissing() throws {
    let json = #"""
    {"result": {"devices": [
      {"properties": {"hardware": {"udid": "00008103-1"}, "connection": {"state": "disconnected", "transportType": "wired"}, "state": {"name": "iPad"}}},
      {"properties": {"hardware": {"udid": "SIM", "reality": "simulated"}, "connection": {"transportType": "sameMachine"}, "state": {"name": "iPhone 17"}}}
    ]}}
    """#
    #expect(try DeviceList.parse(Data(json.utf8)).map(\.udid) == ["00008103-1"])
}

// MARK: Update

@Test func comparesReleaseVersions() {
    #expect(Updater.isNewer("0.6.0", than: "0.5.3"))
    #expect(Updater.isNewer("0.5.10", than: "0.5.9"))
    #expect(Updater.isNewer("1.0", than: "0.9.9"))
    #expect(!Updater.isNewer("0.5.3", than: "0.5.3"))
    #expect(!Updater.isNewer("0.5.3", than: "0.5.3.1"))
}

// MARK: Analyze

@Test func classifiesAppFilesBySize() {
    let files = [
        Analyze.File(path: "App", bytes: 100), Analyze.File(path: "App.debug.dylib", bytes: 5000),
        Analyze.File(path: "Assets.car", bytes: 800), Analyze.File(path: "Frameworks/Kit.framework/Kit", bytes: 900),
        Analyze.File(path: "Frameworks/Kit.framework/PrivacyInfo.xcprivacy", bytes: 1),
        Analyze.File(path: "Frameworks/Other.framework/Other", bytes: 300), Analyze.File(path: "PlugIns/Widget.appex/Widget", bytes: 200),
        Analyze.File(path: "Res_Res.bundle/Assets.car", bytes: 50), Analyze.File(path: "Info.plist", bytes: 2),
    ]
    let parts = Analyze.breakdown(app: URL(fileURLWithPath: "/x/App.app"), executable: "App", files: files)
    let byPath = Dictionary(uniqueKeysWithValues: parts.map { ($0.path, $0) })
    #expect(parts.first?.path == "App.debug.dylib" && parts.first?.kind == "debug dylib")
    #expect(byPath["Frameworks/Kit.framework"]?.bytes == 901 && byPath["Frameworks/Kit.framework"]?.privacyManifest == true)
    #expect(byPath["Frameworks/Other.framework"]?.privacyManifest == false)
    #expect(byPath["PlugIns/Widget.appex"]?.kind == "extension")
    #expect(byPath["Res_Res.bundle"]?.kind == "resource bundle")
    #expect(byPath["(other files)"]?.bytes == 2)
}

// MARK: Crashes

@Test func summarizesACrashReport() throws {
    let header = #"{"app_name":"Crasher","bundleID":"io.example.Crasher","app_version":"1.0","bug_type":"309","os_version":"macOS 26.6.2 (25G83)"}"#
    let body = #"""
    {"procName":"Crasher","procPath":"\/Users\/USER\/Library\/Developer\/CoreSimulator\/Devices\/ABC\/data\/Crasher.app\/Crasher",
     "captureTime":"2026-11-06 15:48:17.7435 -0800","bundleInfo":{"CFBundleShortVersionString":"1.0"},
     "exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"termination":{"indicator":"Trace\/BPT trap: 5"},
     "asi":{"libswiftCore.dylib":["Fatal error: Index out of range"]},
     "faultingThread":0,
     "threads":[{"triggered":true,"frames":[
       {"imageOffset":958048,"symbol":"Array._checkSubscript(_:wasNativeTypeChecked:)","imageIndex":1},
       {"imageOffset":2556,"sourceLine":2,"sourceFile":"main.swift","symbol":"pickScore(_:at:)","imageIndex":0}]}],
     "usedImages":[{"base":4307304448,"name":"Crasher","uuid":"bbf25d83-84fc-4831-8a84-64f3ba32855c","path":"\/nowhere\/Crasher"},
                   {"base":7539011584,"name":"libswiftCore.dylib","path":"\/Volumes\/VOLUME\/*\/libswiftCore.dylib"}]}
    """#
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Crasher-\(UUID().uuidString).ips")
    try (header + "\n" + body).write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let report = try Crashes.details(url.path, maxFrames: 10)
    #expect(report.process == "Crasher" && report.bundleID == "io.example.Crasher" && report.simulator)
    #expect(report.exception == "EXC_BREAKPOINT" && report.reason == "Fatal error: Index out of range")
    #expect(report.frames?.map(\.image) == ["libswiftCore.dylib", "Crasher"])
    #expect(report.frames?[1].location == "main.swift:2")
    #expect(report.frames?[1].address == "0x100bc49fc")

    let notACrash = FileManager.default.temporaryDirectory.appendingPathComponent("other-\(UUID().uuidString).ips")
    try (#"{"bug_type":"298"}"# + "\n{}").write(to: notACrash, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: notACrash) }
    #expect(try Crashes.summary(notACrash) == nil)
}

// MARK: Profile

@Test func aggregatesTimeProfilerSamples() {
    // Two samples share a backtrace by reference; one is from another process and one isn't running.
    let xml = """
    <?xml version="1.0"?><trace-query-result><node>
    <row><sample-time id="1" fmt="00:00.1">1</sample-time>
      <thread id="2" fmt="Main Thread (0x1) (App, pid: 9)"><tid id="3" fmt="0x1">1</tid><process id="4" fmt="App (9)"><pid id="5" fmt="9">9</pid></process></thread>
      <process ref="4"/><core id="6" fmt="CPU 1">1</core><thread-state id="7" fmt="Running">Running</thread-state><weight id="8" fmt="1.00 ms">1000000</weight>
      <tagged-backtrace id="9"><frame id="10" name="leafWork" addr="0x1"><binary id="11" name="App.debug.dylib"/></frame>
        <frame id="12" name="render" addr="0x2"><binary ref="11"/></frame>
        <frame id="13" name="main" addr="0x3"><binary id="14" name="App"/></frame></tagged-backtrace></row>
    <row><sample-time id="20" fmt="00:00.2">2</sample-time><thread ref="2"/><process ref="4"/><core ref="6"/><thread-state ref="7"/><weight ref="8"/><tagged-backtrace ref="9"/></row>
    <row><sample-time id="21" fmt="00:00.3">3</sample-time><thread ref="2"/><process ref="4"/><core ref="6"/><thread-state ref="7"/><weight ref="8"/>
      <tagged-backtrace id="22"><frame id="23" name="memcpy" addr="0x9"><binary id="24" name="libsystem_platform.dylib"/></frame><frame ref="12"/><frame ref="13"/></tagged-backtrace></row>
    <row><sample-time id="30" fmt="00:00.4">4</sample-time><thread ref="2"/><process ref="4"/><core ref="6"/><thread-state id="31" fmt="Blocked">Blocked</thread-state><weight ref="8"/><tagged-backtrace ref="9"/></row>
    </node></trace-query-result>
    """
    let samples = TimeProfileParser.parse(Data(xml.utf8))
    #expect(samples.count == 4)
    #expect(samples[2].frames.map(\.name) == ["memcpy", "render", "main"])
    let summary = Profiler.aggregate(samples, trace: "t", template: "Time Profiler", tables: [],
                                     appBinaries: ["App", "App.debug.dylib"], limit: 10)
    #expect(summary.process == "App (9)" && summary.sampledMs == 3)
    #expect(summary.threads.map(\.thread) == ["Main Thread (0x1)"])
    #expect(summary.appFunctions.first?.function == "render" || summary.appFunctions.first?.function == "main")
    let render = summary.appFunctions.first { $0.function == "render" }
    #expect(render?.totalMs == 3 && render?.selfMs == 0)
    #expect(summary.topSelf.map(\.function) == ["leafWork", "memcpy"])
}
