import Foundation
import Testing
@testable import IOSCore

@Test func picksNavigatorPathMatchingTheFolders() {
    let candidates = ["SampleApp/Features/Home/ContentView.swift", "SampleApp/Legacy/ContentView.swift", "Widgets/ContentView.swift"]
    #expect(Previews.bestMatch(for: "/repo/SampleApp/Legacy/ContentView.swift", among: candidates) == "SampleApp/Legacy/ContentView.swift")
    #expect(Previews.bestMatch(for: "Features/Home/ContentView.swift", among: candidates) == "SampleApp/Features/Home/ContentView.swift")
    #expect(Previews.bestMatch(for: "ContentView.swift", among: ["App/ContentView.swift"]) == "App/ContentView.swift")
    #expect(Previews.bestMatch(for: "Other.swift", among: candidates) == nil)
    #expect(Previews.bestMatch(for: "ContentView.swift", among: []) == nil)
}

@Test func readsVariantOverridesInEitherShape() {
    let dict: [String: Any] = ["Color Scheme": ["Light Appearance", "Dark Appearance"]]
    #expect(Previews.variants(dict) == ["Color Scheme": ["Light Appearance", "Dark Appearance"]])

    let list: [[String: Any]] = [["name": "Orientation", "values": ["Portrait", "Landscape Left"]]]
    #expect(Previews.variants(list) == ["Orientation": ["Portrait", "Landscape Left"]])

    let nested: [String: Any] = ["Dynamic Type": [["name": "Large"], ["name": "AX 5"]]]
    #expect(Previews.variants(nested) == ["Dynamic Type": ["Large", "AX 5"]])
    #expect(Previews.variants(nil).isEmpty)
}

@Test func resolvesTemplateAliases() {
    #expect(Templates.resolve("app") == "com.apple.dt.unit.multiPlatform.app")
    #expect(Templates.resolve("iOS-App") == "com.apple.dt.unit.singleViewApplication")
    #expect(Templates.resolve("com.apple.dt.unit.osxbundle") == "com.apple.dt.unit.osxbundle") // identifiers pass through
}

@Test func classifiesBridgeErrors() {
    let approval = XcodeBridge.toolError("XcodeListTemplates",
        text: "This agent isn't approved to use Xcode's tools yet. Call XcodeOpenWorkspace or XcodeNewProject first")
    guard case .bridgeNotApproved = approval else { Issue.record("expected bridgeNotApproved, got \(approval)"); return }

    let json = XcodeBridge.toolError("DeviceInteractionStartSession",
        text: #"{"type":"error","data":"Cannot select specified device."}"#)
    #expect(json == .bridgeFailed(tool: "DeviceInteractionStartSession", message: "Cannot select specified device."))

    let plain = XcodeBridge.toolError("RenderPreview", text: "Unsupported variant ‘Purple’")
    #expect(plain == .bridgeFailed(tool: "RenderPreview", message: "Unsupported variant ‘Purple’"))
}

@Test func parsesCodeIssues() {
    let content = """
    Current issues in 'App/ContentView.swift' (3 total):

    1. [Error] [Line: 65] Cannot convert value of type 'Int' to specified type 'String'
    2. [Warning] [Line: 64] Initialization of immutable value 'unused' was never used
    3. [Note] Did you mean 'text'?
       second line of the note
    """
    let diagnostics = CodeIssues.parse(content, file: "/src/ContentView.swift")
    #expect(diagnostics.map(\.severity) == ["error", "warning", "note"])
    #expect(diagnostics.map(\.line) == [65, 64, nil])
    #expect(diagnostics[0].summary == "/src/ContentView.swift:65: error: Cannot convert value of type 'Int' to specified type 'String'")
    #expect(diagnostics[2].message == "Did you mean 'text'?\nsecond line of the note")
    #expect(CodeIssues.parse("No issues found in 'App/App.swift'.", file: "/src/App.swift").isEmpty)
}
