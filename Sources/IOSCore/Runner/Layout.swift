import Foundation

public struct Rect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    func union(_ other: Rect) -> Rect {
        let left = min(x, other.x), top = min(y, other.y)
        return Rect(x: left, y: top, width: max(maxX, other.maxX) - left, height: max(maxY, other.maxY) - top)
    }

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
    /// Behind a later full-screen presentation (e.g. the screen under a full-screen cover):
    /// listed for context, but a tap at its point lands on what covers it.
    public let covered: Bool

    public var textLine: String {
        var parts = ["[\(index)] \(type)"]
        if let id { parts.append("id=\(id)") }
        if let label { parts.append("\"\(label)\"") }
        if let value { parts.append("value=\"\(value)\"") }
        if let placeholder, value == nil { parts.append("placeholder=\"\(placeholder)\"") }
        if !enabled { parts.append("disabled") }
        if selected { parts.append("selected") }
        if focused { parts.append("focused") }
        if covered { parts.append("covered") }
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
        let root = node(dict)
        // The runner attaches SpringBoard's alert (a permission prompt…) separately; it becomes the
        // top layer, over everything in the app.
        guard let alert = dict["systemAlert"] as? [String: Any] else { return root }
        let layer = UIElementNode(type: systemAlertLayer, id: nil, label: nil, value: nil, placeholder: nil, frame: root.frame,
                                  enabled: true, selected: false, focused: false, children: [node(alert)])
        return UIElementNode(type: root.type, id: root.id, label: root.label, value: root.value, placeholder: root.placeholder,
                             frame: root.frame, enabled: root.enabled, selected: root.selected, focused: root.focused,
                             children: root.children + [layer])
    }

    static let systemAlertLayer = "SystemAlertLayer"

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
        // The application's frame is the screen. Not the first window: with iPad form sheets that
        // window can be smaller than the display, and a sheet drawn outside it was dropped.
        let windows = root.children.filter { $0.type == "Window" && !$0.frame.isEmpty }.map(\.frame)
        let screen = !root.frame.isEmpty ? root.frame : windows.reduce(windows.first ?? root.frame) { $0.union($1) }
        var out: [LayoutElement] = []
        func visit(_ n: UIElementNode, parent: UIElementNode?, insideKeyboard: Bool, covered: Bool) {
            let keyboard = insideKeyboard || n.type == "Keyboard"
            let meaningful = (n.id != nil || n.label != nil || n.value != nil || n.placeholder != nil || interactiveTypes.contains(n.type))
                && !isScrollIndicator(n)
            // A labeled SwiftUI Toggle is a row-wide Switch whose actual control is a nested Switch;
            // tapping the row's centre hits the label, which doesn't toggle. Aim at the control.
            let target = n.type == "Switch" ? (n.children.first { $0.type == "Switch" }?.frame ?? n.frame) : n.frame
            if meaningful, !keyboard, !["Application", "Window"].contains(n.type), !repeatsParent(n, parent),
               let visible = target.intersection(screen) ?? n.frame.intersection(screen), !visible.isEmpty {
                out.append(LayoutElement(
                    index: out.count + 1, type: n.type, id: n.id, label: n.label, value: n.value, placeholder: n.placeholder,
                    frame: n.frame, center: Point(x: visible.x + visible.width / 2, y: visible.y + visible.height / 2),
                    enabled: n.enabled, selected: n.selected, focused: n.focused, covered: covered
                ))
            }
            // A window's children are its presentation layers in order (screen, full-screen cover,
            // sheet…); a layer is covered when a later sibling spans the whole window.
            // A system alert is modal: it covers the whole app.
            let coveringFrom = n.type == "Window" ? n.children.lastIndex { covers($0.frame, n.frame) }
                : parent == nil ? n.children.lastIndex { $0.type == systemAlertLayer } : nil
            for (index, child) in n.children.enumerated() {
                visit(child, parent: n, insideKeyboard: keyboard, covered: covered || (coveringFrom.map { index < $0 } ?? false))
            }
        }
        visit(root, parent: nil, insideKeyboard: false, covered: false)
        return out
    }

    /// Children that add nothing to their labeled control: the inner switch of a labeled Toggle
    /// (`Switch "Count In"` → unlabeled `Switch`), or a text repeating the control's label
    /// (`Button "Sign in"` → `StaticText "Sign in"`). `--full` still shows them.
    static func repeatsParent(_ node: UIElementNode, _ parent: UIElementNode?) -> Bool {
        guard let parent, parent.label != nil, interactiveTypes.contains(parent.type) else { return false }
        if node.type == parent.type, node.id == nil, node.label == nil { return true }
        return node.type == "StaticText" && node.id == nil && node.label == parent.label
    }

    nonisolated(unsafe) private static let scrollIndicatorLabel = /^(Vertical|Horizontal) scroll bar, \d+ pages?$/

    /// Scroll views' indicators ("Vertical scroll bar, 2 pages"): noise, and not tappable.
    static func isScrollIndicator(_ node: UIElementNode) -> Bool {
        node.type == "Other" && node.id == nil && (node.label.map { (try? scrollIndicatorLabel.wholeMatch(in: $0)) != nil } ?? false)
    }

    /// True when `frame` spans (nearly) all of `area`.
    static func covers(_ frame: Rect, _ area: Rect) -> Bool {
        guard let overlap = frame.intersection(area), !area.isEmpty else { return false }
        return overlap.width * overlap.height >= 0.95 * area.width * area.height
    }

    /// Finds the element to act on: exact identifier, else exact label, else label containing
    /// the text (case-insensitive). Interactive elements win over static ones.
    public static func find(in elements: [LayoutElement], id: String? = nil, label: String? = nil) -> LayoutElement? {
        func best(_ matches: [LayoutElement]) -> LayoutElement? {
            let ranked = matches.filter { !$0.covered } + matches.filter(\.covered) // what's on top first
            return ranked.first { interactiveTypes.contains($0.type) } ?? ranked.first
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
