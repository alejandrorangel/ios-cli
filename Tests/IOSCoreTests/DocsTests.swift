import Foundation
import Testing
@testable import IOSCore

private func words(_ s: String) -> [String] {
    DocsIndex.splitWords(s).split(separator: " ").map(String.init)
}

@Test func splitsCamelCaseLikeThePrototype() {
    #expect(words("navigationDestination(for:destination:)") == ["navigation", "destination", "for", "destination"])
    #expect(words("URLSession") == ["url", "session"])
    #expect(words("AVAudioSession.Category") == ["av", "audio", "session", "category"])
    #expect(words("UIView2D") == ["ui", "view2", "d"]) // matches the Python regexes
    #expect(words("core-bluetooth") == ["core", "bluetooth"])
    #expect(words("") == [])
}

@Test func normalizesDocPaths() {
    #expect(DocsPage.normalizePath("doc://swiftui/view") == "/documentation/swiftui/view")
    #expect(DocsPage.normalizePath("SwiftUI/View/") == "/documentation/swiftui/view")
    #expect(DocsPage.normalizePath("https://developer.apple.com/documentation/UIKit/UIView") == "/documentation/uikit/uiview")
    #expect(DocsPage.normalizePath("/documentation/xcode/configuring-background-execution-modes")
            == "/documentation/xcode/configuring-background-execution-modes")
    #expect(DocsPaths.docURL(forPath: "/documentation/swiftui/view") == "doc://swiftui/view")
}

@Test func handlesHumanInterfaceGuidelinesPaths() {
    #expect(DocsPage.normalizePath("hig://sliders") == "/design/human-interface-guidelines/sliders")
    #expect(DocsPage.normalizePath("hig://") == "/design/human-interface-guidelines")
    #expect(DocsPage.normalizePath("https://developer.apple.com/design/human-interface-guidelines/sliders")
            == "/design/human-interface-guidelines/sliders")
    #expect(DocsPaths.docURL(forPath: "/design/human-interface-guidelines/dark-mode") == "hig://dark-mode")
    #expect(DocsPaths.docURL(forPath: "/design/human-interface-guidelines") == "hig://")
}

@Test func parsesHIGPagesAndTheirLinks() throws {
    let page = #"""
    {"metadata": {"title": "Sliders", "role": "article"},
     "abstract": [{"type": "text", "text": "A slider is a horizontal track with a control."}],
     "references": {
       "a": {"type": "topic", "url": "/design/human-interface-guidelines/steppers", "title": "Steppers"},
       "b": {"type": "topic", "url": "/design/human-interface-guidelines/Text-Fields#best-practices", "title": "Text fields"},
       "c": {"type": "topic", "url": "/documentation/swiftui/slider", "title": "Slider"},
       "d": {"type": "image", "url": "/images/slider.png"}
     }}
    """#
    let (guide, links) = try #require(HIG.parse(Data(page.utf8), path: "/design/human-interface-guidelines/sliders", parent: "Selection and input"))
    #expect(guide.title == "Sliders")
    #expect(guide.kind == "article")
    #expect(guide.parent == "Selection and input")
    #expect(guide.abstract == "A slider is a horizontal track with a control.")
    // Only HIG pages are followed; fragments are dropped and paths lowercased.
    #expect(links == ["/design/human-interface-guidelines/steppers", "/design/human-interface-guidelines/text-fields"])
}

@Test func linksGuidelinePagesInMarkdown() throws {
    let page = #"""
    {"metadata": {"title": "Sliders"},
     "primaryContentSections": [{"kind": "content", "content": [
       {"type": "paragraph", "inlineContent": [{"type": "text", "text": "See "}, {"type": "reference", "identifier": "s"},
                                               {"type": "text", "text": " and "}, {"type": "reference", "identifier": "u"}]}]}],
     "references": {
       "s": {"title": "Steppers", "url": "/design/human-interface-guidelines/steppers"},
       "u": {"title": "UISlider", "url": "/documentation/uikit/uislider"}
     }}
    """#
    let markdown = try DocsPage.toMarkdown(Data(page.utf8))
    #expect(markdown.contains("See [`Steppers`](hig://steppers) and [`UISlider`](doc://uikit/uislider)"))
}

@Test func readsFrameworkNamesFromCatalog() throws {
    let catalog = #"""
    {"references": {
      "a": {"url": "/documentation/swiftui", "title": "SwiftUI"},
      "b": {"url": "/documentation/swiftui/view", "title": "View"},
      "c": {"url": "/documentation/corebluetooth", "title": "Core Bluetooth"},
      "d": {"url": "https://example.com", "title": "External"}
    }}
    """#
    #expect(try DocsIndex.frameworkNames(fromCatalog: Data(catalog.utf8)) == ["corebluetooth", "swiftui"])
}

@Test func rendersDocCPageAsMarkdown() throws {
    let page = #"""
    {
      "metadata": {"title": "navigationDestination(for:destination:)", "roleHeading": "Instance Method",
                   "modules": [{"name": "SwiftUI"}],
                   "platforms": [{"name": "iOS", "introducedAt": "16.0"}, {"name": "visionOS", "introducedAt": "1.0", "beta": true}]},
      "abstract": [{"type": "text", "text": "Associates a destination view with a "}, {"type": "codeVoice", "code": "NavigationStack"}, {"type": "text", "text": "."}],
      "primaryContentSections": [
        {"kind": "declarations", "declarations": [{"tokens": [{"text": "func "}, {"text": "navigationDestination"}]}]},
        {"kind": "content", "content": [
          {"type": "heading", "level": 2, "text": "Discussion"},
          {"type": "paragraph", "inlineContent": [{"type": "text", "text": "Use a "}, {"type": "reference", "identifier": "doc://com.apple.SwiftUI/documentation/SwiftUI/NavigationLink"}]},
          {"type": "aside", "style": "important", "name": "Important", "content": [{"type": "paragraph", "inlineContent": [{"type": "text", "text": "Not in lazy containers."}]}]},
          {"type": "codeListing", "syntax": "swift", "code": ["NavigationStack {", "}"]},
          {"type": "table", "rows": [
            [[{"type": "paragraph", "inlineContent": [{"type": "text", "text": "Key"}]}], [{"type": "paragraph", "inlineContent": [{"type": "text", "text": "Value"}]}]],
            [[{"type": "paragraph", "inlineContent": [{"type": "text", "text": "a|b"}]}], [{"type": "paragraph", "inlineContent": [{"type": "text", "text": "1"}]}]]
          ]}
        ]}
      ],
      "references": {
        "doc://com.apple.SwiftUI/documentation/SwiftUI/NavigationLink": {"title": "NavigationLink", "url": "/documentation/swiftui/navigationlink"}
      }
    }
    """#
    let markdown = try DocsPage.toMarkdown(Data(page.utf8))
    #expect(markdown.hasPrefix("# navigationDestination(for:destination:)\n\nInstance Method · SwiftUI"))
    #expect(markdown.contains("**Availability:** iOS 16.0+, visionOS 1.0+ (beta)"))
    #expect(markdown.contains("Associates a destination view with a `NavigationStack`."))
    #expect(markdown.contains("```swift\nfunc navigationDestination\n```"))
    #expect(markdown.contains("### Discussion"))
    #expect(markdown.contains("Use a [`NavigationLink`](doc://swiftui/navigationlink)"))
    #expect(markdown.contains("> **Important:** Not in lazy containers."))
    #expect(markdown.contains("| Key | Value |\n|---|---|\n| a\\|b | 1 |"))
}

@Test func searchesABuiltIndex() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-docs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = #"""
    {"interfaceLanguages": {"swift": [
      {"path": "/documentation/swiftui", "title": "SwiftUI", "type": "module", "children": [
        {"title": "Navigation", "type": "groupMarker"},
        {"path": "/documentation/swiftui/navigationstack", "title": "NavigationStack", "type": "struct"},
        {"path": "/documentation/swiftui/view/navigationdestination(for:destination:)",
         "title": "func navigationDestination<D, C>(for: D.Type, destination: (D) -> C) -> some View", "type": "method"},
        {"path": "/documentation/swiftui/navigationview", "title": "NavigationView", "type": "struct", "deprecated": true}
      ]}
    ]}}
    """#
    let db = dir.appendingPathComponent("docs.db").path
    let other = #"""
    {"interfaceLanguages": {"swift": [
      {"path": "/documentation/appkit", "title": "AppKit", "type": "module", "children": [
        {"path": "/documentation/appkit/nscolorpicker", "title": "NSColorPicker", "type": "class"},
        {"path": "/documentation/appkit/color-picker", "title": "Color Picker", "type": "collection"}
      ]},
      {"path": "/documentation/uikit", "title": "UIKit", "type": "module", "children": [
        {"path": "/documentation/uikit/uicolorpickerviewcontroller", "title": "UIColorPickerViewController", "type": "class"},
        {"path": "/documentation/uikit/uiapplication/registerforremotenotifications()",
         "title": "func registerForRemoteNotifications()", "type": "method"}
      ]}
    ]}}
    """#
    let pages = try DocsIndex.build(database: db) { insert in
        try insert("swiftui", Data(index.utf8))
        try insert("appkit", Data(other.utf8))
    }
    #expect(pages == 10) // group markers aren't pages
    // Pin the other-platform list instead of reading the installed SDKs.
    try JSONEncoder().encode(["appkit"]).write(to: dir.appendingPathComponent("platform-frameworks-\(Describer.cachedXcodeBuildForSymbols).json"))

    setenv("IOS_CLI_DOCS_DIR", dir.path, 1)
    defer { unsetenv("IOS_CLI_DOCS_DIR") }
    let results = try DocsIndex.search("navigation destination")
    #expect(results.first?.path == "/documentation/swiftui/view/navigationdestination(for:destination:)")
    let stack = try DocsIndex.search("navigation", kind: "struct")
    #expect(stack.first?.title == "NavigationStack") // deprecated NavigationView ranks lower

    // iOS first: the UIKit picker beats AppKit's, even AppKit's exactly named "Color Picker" collection…
    #expect(try DocsIndex.search("color picker").first?.title == "UIColorPickerViewController")
    // …unless AppKit is asked for, by framework or by exact symbol name.
    #expect(try DocsIndex.search("color picker", framework: "appkit").first?.framework == "appkit")
    #expect(try DocsIndex.search("NSColorPicker").first?.title == "NSColorPicker")
    // "push" also matches Apple's "remote".
    #expect(try DocsIndex.search("push notifications register").first?.title == "func registerForRemoteNotifications()")
}
