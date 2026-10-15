import Foundation

public struct Rect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    func intersection(_ other: Rect) -> Rect? {
        let left = max(x, other.x), top = max(y, other.y)
        let right = min(maxX, other.maxX), bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return nil }
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

public struct Point: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One element of the screen tree, as XCUITest sees it.
public struct UIElementNode: Codable, Sendable {
    public let type: String
    public let id: String?
    public let label: String?
    public let value: String?
    public let placeholder: String?
    public let frame: Rect
    public let enabled: Bool
    public let selected: Bool
    public let focused: Bool
    public let children: [UIElementNode]
}

/// An element in the flat list `ios layout` prints: visible, meaningful, with a tap point.
public struct LayoutElement: Codable, Equatable, Sendable {
    public let index: Int
    public let type: String
    public let id: String?
    public let label: String?
    public let value: String?
    public let placeholder: String?
    public let frame: Rect
    /// Center of the element's on-screen part; where `ios input tap --id` taps.
    public let center: Point
    public let enabled: Bool
    public let selected: Bool
    public let focused: Bool

    public var textLine: String {
        var parts = ["[\(index)] \(type)"]
        if let id { parts.append("id=\(id)") }
        if let label { parts.append("\"\(label)\"") }
        if let value { parts.append("value=\"\(value)\"") }
        if let placeholder, value == nil { parts.append("placeholder=\"\(placeholder)\"") }
        if !enabled { parts.append("disabled") }
        if selected { parts.append("selected") }
        if focused { parts.append("focused") }
        parts.append("@(\(Int(center.x.rounded())),\(Int(center.y.rounded())))")
        return parts.joined(separator: " ")
    }
}

public enum Layout {
    /// XCUIElement.ElementType raw values, in the order of XCUIElementTypes.h (Xcode 27).
    static let typeNames = [
        "Any", "Other", "Application", "Group", "Window", "Sheet", "Drawer", "Alert", "Dialog", "Button",
        "RadioButton", "RadioGroup", "CheckBox", "DisclosureTriangle", "PopUpButton", "ComboBox", "MenuButton",
        "ToolbarButton", "Popover", "Keyboard", "Key", "NavigationBar", "TabBar", "TabGroup", "Toolbar", "StatusBar",
        "Table", "TableRow", "TableColumn", "Outline", "OutlineRow", "Browser", "CollectionView", "Slider",
        "PageIndicator", "ProgressIndicator", "ActivityIndicator", "SegmentedControl", "Picker", "PickerWheel",
        "Switch", "Toggle", "Link", "Image", "Icon", "SearchField", "ScrollView", "ScrollBar", "StaticText",
        "TextField", "SecureTextField", "DatePicker", "TextView", "Menu", "MenuItem", "MenuBar", "MenuBarItem", "Map",
        "WebView", "IncrementArrow", "DecrementArrow", "Timeline", "RatingIndicator", "ValueIndicator", "SplitGroup",
        "Splitter", "RelevanceIndicator", "ColorWell", "HelpTag", "Matte", "DockItem", "Ruler", "RulerMarker", "Grid",
        "LevelIndicator", "Cell", "LayoutArea", "LayoutItem", "Handle", "Stepper", "Tab", "TouchBar", "StatusItem",
    ]

    static let interactiveTypes: Set<String> = [
        "Button", "Link", "TextField", "SecureTextField", "SearchField", "TextView", "Switch", "Toggle", "Slider",
        "Stepper", "SegmentedControl", "Picker", "PickerWheel", "DatePicker", "Cell", "Tab", "MenuItem", "Icon",
    ]

    /// Converts the runner's snapshot JSON into a tree.
    public static func parse(_ object: Any?) throws -> UIElementNode {
        guard let dict = object as? [String: Any] else {
            throw IOSError.invalidOutput(tool: "runner snapshot", reason: "not an object")
        }
        return node(dict)
    }

    private static func node(_ d: [String: Any]) -> UIElementNode {
        let raw = d["type"] as? Int ?? 1
        let f = (d["frame"] as? [Double]) ?? (d["frame"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0, 0]
        return UIElementNode(
            type: raw < typeNames.count ? typeNames[raw] : "Type\(raw)",
            id: d["id"] as? String, label: d["label"] as? String, value: d["value"] as? String,
            placeholder: d["placeholder"] as? String,
            frame: Rect(x: f[safe: 0], y: f[safe: 1], width: f[safe: 2], height: f[safe: 3]),
            enabled: d["enabled"] as? Bool ?? true, selected: d["selected"] as? Bool ?? false,
            focused: d["focused"] as? Bool ?? false,
            children: (d["children"] as? [[String: Any]] ?? []).map(node)
        )
    }

    /// Visible elements worth acting on: anything with an identifier, label, value or
    /// placeholder, plus interactive controls. Off-screen and zero-size elements are dropped,
    /// and keyboard keys are left out (use `type` to enter text).
    public static func flatten(_ root: UIElementNode) -> [LayoutElement] {
        let screen = root.children.first { $0.type == "Window" }?.frame ?? root.frame
        var out: [LayoutElement] = []
        func visit(_ n: UIElementNode, insideKeyboard: Bool) {
            let keyboard = insideKeyboard || n.type == "Keyboard"
            let meaningful = n.id != nil || n.label != nil || n.value != nil || n.placeholder != nil || interactiveTypes.contains(n.type)
            if meaningful, !keyboard, !["Application", "Window"].contains(n.type), let visible = n.frame.intersection(screen), !visible.isEmpty {
                out.append(LayoutElement(
                    index: out.count + 1, type: n.type, id: n.id, label: n.label, value: n.value, placeholder: n.placeholder,
                    frame: n.frame, center: Point(x: visible.x + visible.width / 2, y: visible.y + visible.height / 2),
                    enabled: n.enabled, selected: n.selected, focused: n.focused
                ))
            }
            n.children.forEach { visit($0, insideKeyboard: keyboard) }
        }
        visit(root, insideKeyboard: false)
        return out
    }

    /// Finds the element to act on: exact identifier, else exact label, else label containing
    /// the text (case-insensitive). Interactive elements win over static ones.
    public static func find(in elements: [LayoutElement], id: String? = nil, label: String? = nil) -> LayoutElement? {
        func best(_ matches: [LayoutElement]) -> LayoutElement? {
            matches.first { interactiveTypes.contains($0.type) } ?? matches.first
        }
        if let id { return best(elements.filter { $0.id == id }) }
        guard let label else { return nil }
        if let exact = best(elements.filter { $0.label == label }) { return exact }
        return best(elements.filter { $0.label?.localizedCaseInsensitiveContains(label) == true })
    }

    /// Start and end points for a swipe across the middle of the screen.
    public static func swipePoints(direction: String, screen: Rect) -> (Point, Point)? {
        let cx = screen.x + screen.width / 2, cy = screen.y + screen.height / 2
        let dy = screen.height * 0.25, dx = screen.width * 0.3
        switch direction {
        case "up": return (Point(x: cx, y: cy + dy), Point(x: cx, y: cy - dy))
        case "down": return (Point(x: cx, y: cy - dy), Point(x: cx, y: cy + dy))
        case "left": return (Point(x: cx + dx, y: cy), Point(x: cx - dx, y: cy))
        case "right": return (Point(x: cx - dx, y: cy), Point(x: cx + dx, y: cy))
        default: return nil
        }
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double { index < count ? self[index] : 0 }
}
