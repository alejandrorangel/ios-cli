import Foundation
import Testing
@testable import IOSCore

private func node(_ type: String, _ readable: String, value: [String: Any]? = nil, _ children: [[String: Any]] = []) -> [String: Any] {
    var properties: [[String: Any]] = [["id": 0, "attribute": ["type": type, "readableType": readable, "flags": 1]]]
    if let value { properties.append(["id": 1, "attribute": value]) }
    return ["properties": properties, "children": children]
}

private func text(_ string: String) -> [String: Any] {
    node("SwiftUI.Text", "Text", value: [
        "type": "SwiftUI.Text", "readableType": "Text",
        "subattributes": [["name": "storage", "type": "SwiftUI.Text.Storage",
                           "subattributes": [["name": "verbatim", "type": "Swift.String", "value": string]]]],
    ])
}

// SwiftUI lists children last-to-first, so this is the welcome screen bottom-up.
private func dump() -> [[String: Any]] { [
    node("SampleApp.WelcomeView", "WelcomeView", [
        node("SwiftUI.ModifiedContent<SwiftUI.VStack<…>, SwiftUI._PaddingLayout>", "ModifiedContent<VStack<…>, _PaddingLayout>", [
            node("SwiftUI._PaddingLayout", "_PaddingLayout", [
                node("SwiftUI.VStack<SwiftUI.TupleView<…>>", "VStack<TupleView<…>>", [
                    text("Get started today"),
                    node("(extension in SwiftUI):SwiftUI.Text.Resolved", "Resolved"),
                    text("Welcome"),
                    node("DesignSystem.CardView", "CardView"),
                ]),
            ]),
        ]),
    ]),
] }

private func parse() throws -> [SwiftUIViewNode] {
    let data = try JSONSerialization.data(withJSONObject: dump())
    return try SwiftUITree.parse([data]) { ["SwiftUI", "SwiftUICore", "Swift"].contains($0) }
}

@Test func keepsAppAndStructuralViewsInScreenOrder() throws {
    let roots = try parse()
    let welcome = try #require(roots.first)
    #expect(welcome.name == "WelcomeView")
    #expect(welcome.module == "SampleApp")
    // ModifiedContent and _PaddingLayout are collapsed; VStack moves up under WelcomeView.
    let stack = try #require(welcome.children.first)
    #expect(stack.name == "VStack")
    // Reversed to top-to-bottom; the app's framework view (DesignSystem) is kept,
    // the "(extension in SwiftUI)" internal type is dropped.
    #expect(stack.children.map(\.name) == ["CardView", "Text", "Text"])
    #expect(stack.children.compactMap(\.text) == ["Welcome", "Get started today"])
    #expect(stack.children[0].module == "DesignSystem")
}

@Test func extractsAppTypesFromGenericParameters() {
    let system: (String) -> Bool = { ["SwiftUI", "Swift"].contains($0) }
    let type = "SwiftUI.ModifiedContent<SwiftUI.Button<SampleApp.ItemCard>, SwiftUI._PaddingLayout>"
    #expect(SwiftUITree.appTypes(in: type, excluding: "Button", isSystemModule: system) == ["ItemCard"])
    let forEach = "SwiftUI.ForEach<Swift.Array<SampleApp.Item>, Swift.String, SampleApp.ItemRow>"
    #expect(SwiftUITree.appTypes(in: forEach, excluding: "ForEach", isSystemModule: system) == ["Item", "ItemRow"])
    #expect(SwiftUITree.appTypes(in: "SampleApp.WelcomeView", excluding: "WelcomeView", isSystemModule: system).isEmpty)
}

@Test func detectsEmptyDumps() throws {
    #expect(SwiftUITree.isEmpty([Data("[]".utf8), Data("[]".utf8)]))
    #expect(SwiftUITree.isEmpty([]))
    #expect(!SwiftUITree.isEmpty([try JSONSerialization.data(withJSONObject: dump())]))
}

@Test func findsFirstStringInValueTree() {
    let value: [String: Any] = ["subattributes": [["type": "SwiftUI.Font"], ["subattributes": [["type": "Swift.String", "value": "Hello"]]]]]
    #expect(SwiftUITree.firstString(value) == "Hello")
    #expect(SwiftUITree.firstString(["type": "Swift.Int", "value": 3]) == nil)
}
