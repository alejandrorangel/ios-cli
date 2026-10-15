import Foundation
import Testing
@testable import IOSCore

@Test func parsesCoordinates() {
    #expect(SimControl.parseCoordinate("37.3349,-122.0090")! == (37.3349, -122.009))
    #expect(SimControl.parseCoordinate(" 1.5 , 2 ")! == (1.5, 2))
    #expect(SimControl.parseCoordinate("91,0") == nil)
    #expect(SimControl.parseCoordinate("here") == nil)
}

@Test func buildsStatusBarOverrides() {
    let bar = SimControl.StatusBar.clean.merging(SimControl.StatusBar(batteryLevel: 42))
    #expect(bar.arguments.contains("42"))
    #expect(bar.arguments.prefix(2) == ["--time", "9:41"])
    #expect(bar.arguments.contains("--wifiMode"))
    #expect(SimControl.StatusBar().isEmpty)
}

@Test func buildsPushPayload() throws {
    let payload = SimControl.pushPayload(title: "Hi", body: "There", badge: 3, sound: true)
    let aps = try #require(payload["aps"] as? [String: Any])
    #expect((aps["alert"] as? [String: String]) == ["title": "Hi", "body": "There"])
    #expect(aps["badge"] as? Int == 3)
    #expect(aps["sound"] as? String == "default")
}

@Test func parsesSimctlListapps() throws {
    let plist = """
    {
        "com.example.App" = { ApplicationType = User; CFBundleDisplayName = "My App"; CFBundleShortVersionString = "1.2"; };
        "com.apple.Maps" = { ApplicationType = System; CFBundleName = Maps; };
    }
    """
    let apps = try AppControl.parseSimctlApps(Data(plist.utf8)).sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    #expect(apps == [
        InstalledApp(bundleIdentifier: "com.apple.Maps", name: "Maps", version: nil, kind: "system"),
        InstalledApp(bundleIdentifier: "com.example.App", name: "My App", version: "1.2", kind: "user"),
    ])
}

@Test func findsTheAppProcessNotItsExtensions() {
    let app = "file:///private/var/containers/Bundle/Application/ABC/My.app/"
    let processes = #"""
    {"result": {"runningProcesses": [
      {"executable": "file:///private/var/containers/Bundle/Application/ABC/My.app/PlugIns/Widget.appex/Widget", "processIdentifier": 10},
      {"executable": "file:///System/Library/CoreServices/SpringBoard.app/SpringBoard", "processIdentifier": 38},
      {"executable": "file:///private/var/containers/Bundle/Application/ABC/My.app/My", "processIdentifier": 42}
    ]}}
    """#
    #expect(AppControl.pid(inApp: app, processes: Data(processes.utf8)) == 42)
    #expect(AppControl.pid(inApp: "file:///nowhere/Other.app", processes: Data(processes.utf8)) == nil)
}
