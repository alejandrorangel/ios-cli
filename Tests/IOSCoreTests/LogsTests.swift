import Foundation
import Testing
@testable import IOSCore

@Test func parsesUnifiedLogNDJSON() throws {
    let line = #"""
    {"timestamp":"2026-10-14 15:17:12.961693-0700","messageType":"Default","subsystem":"com.example.net","category":"HTTP","processImagePath":"/Sim/Bundle/SampleApp.app/SampleApp","processID":70851,"eventMessage":"request started"}
    """#
    let entry = try #require(Logs.parseUnifiedLogLine(line))
    #expect(entry.process == "SampleApp")
    #expect(entry.pid == 70851)
    #expect(entry.level == "Default")
    #expect(entry.source == "unifiedLog")
    #expect(entry.textLine == "15:17:12.961 [Default] com.example.net/HTTP: request started")
}

@Test func skipsNonEventLogLines() {
    #expect(Logs.parseUnifiedLogLine("Filtering the log data using \"process == \\\"SampleApp\\\"\"") == nil)
    #expect(Logs.parseUnifiedLogLine(#"{"count":12,"finished":1}"#) == nil) // log show summary
}

@Test func textLineOmitsEmptySubsystem() {
    let entry = LogEntry(timestamp: "2026-10-14 15:17:12.961693-0700", level: "Default", subsystem: "", category: "",
                         process: "SampleApp", pid: 1, message: "Analytics SDK version 1.2.3", source: "unifiedLog")
    #expect(entry.textLine == "15:17:12.961 [Default] Analytics SDK version 1.2.3")
}

@Test func consoleLinesPrintVerbatim() {
    let entry = LogEntry(timestamp: nil, level: nil, subsystem: nil, category: nil, process: nil, pid: nil,
                         message: "AppModel.start()", source: "console")
    #expect(entry.textLine == "AppModel.start()")
}

@Test func readsExecutableNameFromAppinfo() {
    let appinfo = """
    {
        CFBundleExecutable = "SampleApp";
        CFBundleIdentifier = "com.example.sampleapp";
    }
    """
    #expect(Logs.parseExecutableName(appinfo) == "SampleApp")
    #expect(Logs.parseExecutableName("{ CFBundleExecutable = Simple; }") == "Simple")
    #expect(Logs.parseExecutableName("{}") == nil)
}

@Test func filtersDevicectlStatusLines() {
    #expect(Logs.isDevicectlStatus("Launched application with com.example.app bundle identifier."))
    #expect(Logs.isDevicectlStatus("Waiting for the application to terminate…"))
    #expect(!Logs.isDevicectlStatus("AppModel: loading session…"))
}

@Test func readsBundleIdentifierFromAppBundle() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-\(UUID().uuidString).app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: app) }
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.app"], format: .binary, options: 0)
    try plist.write(to: app.appendingPathComponent("Info.plist"))

    #expect(try Launcher.bundleIdentifier(ofApp: app.path) == "com.example.app")
    #expect(throws: IOSError.self) { try Launcher.bundleIdentifier(ofApp: "/nonexistent.app") }
}
