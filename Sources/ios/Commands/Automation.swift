import ArgumentParser
import Foundation
import IOSCore

/// Options shared by commands that drive the UI through the XCUITest runner.
struct AutomationOptions: ParsableArguments {
    @Option(name: .long, help: "Simulator or device UDID or name. Defaults to the only booted simulator or connected device.")
    var device: String?

    @Option(help: "App to inspect or drive; it's brought to the front (launched if needed). Defaults to the last app used.")
    var bundleId: String?

    @Option(help: "Development team for signing the runner on a physical device (or IOS_CLI_TEAM).")
    var team: String?

    @Flag(help: "Let xcodebuild create provisioning profiles in your developer account if needed.")
    var allowProvisioningUpdates = false

    /// The runner session for the target, with the requested app in front.
    func session() throws -> RunnerSession {
        let target = try TargetResolver.resolve(device)
        let signing = RunnerSigning(team: team, allowProvisioningUpdates: allowProvisioningUpdates)
        let session = try RunnerSessions.ensure(target, signing: signing, progress: Docs.progress)
        if let bundleId {
            _ = try session.send("activate \(bundleId)")
            RunnerSessions.rememberApp(bundleId, for: target)
        } else {
            let ping = try session.send("ping").result as? [String: Any]
            if !(ping?["bundleIdentifier"] is String) {
                // A restarted runner has no app selected; reuse the last one used on this target.
                guard let last = RunnerSessions.lastApp(for: target) else { throw IOSError.noAppSelected }
                _ = try session.send("activate \(last)")
            }
        }
        return session
    }
}

func snapshot(_ session: RunnerSession) throws -> UIElementNode {
    try Layout.parse(session.send("snapshot").result)
}

struct LayoutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "layout",
        abstract: "List the visible elements on screen, with identifiers, labels and tap points.",
        discussion: """
        Uses an XCUITest runner on the target (built and started on first use; it keeps running for fast \
        follow-up commands — stop it with `ios runner stop`). Physical devices need Settings → Developer → \
        Enable UI Automation.
        """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var automation: AutomationOptions

    @Flag(help: "Print the full element tree, including off-screen and unlabeled elements.")
    var full = false

    @Flag(help: "Print the SwiftUI view tree (the app's own views and SwiftUI structure) instead. Debug builds only; the app pauses while it's read.")
    var swiftui = false

    @Flag(help: "With --swiftui: relaunch the app with SwiftUI view-debug data enabled (needed once per launch).")
    var relaunch = false

    @Option(help: "With --relaunch: seconds to wait for the app's UI before reading the tree.")
    var wait: Double = 4

    @Flag(help: "With --swiftui: print SwiftUI's unfiltered debug data (large).")
    var raw = false

    @Flag(help: "List what VoiceOver reads, in its navigation order (iOS 27+). Elements hidden from accessibility don't appear. Turns VoiceOver on for the walk and back off after.")
    var voiceover = false

    @Option(help: "With --voiceover: maximum number of elements to visit.")
    var max = 200

    struct VoiceOverResult: Encodable {
        let spoken: [String]
        /// False when the walk stopped at --max before reaching the last element.
        let complete: Bool
        /// A system alert (Low Battery, a permission prompt…) that took VoiceOver's focus; `items`
        /// are the 1-based positions in `spoken` read from it.
        let systemAlert: SystemAlert?

        struct SystemAlert: Encodable {
            let title: String
            let items: [Int]
        }
    }

    func run() throws {
        if swiftui { return try runSwiftUI() }
        if voiceover {
            let reply = try automation.session().send("voiceover \(max)", timeout: 900).result as? [String: Any] ?? [:]
            let alert = (reply["systemAlert"] as? [String: Any]).map {
                VoiceOverResult.SystemAlert(title: $0["title"] as? String ?? "System alert", items: $0["items"] as? [Int] ?? [])
            }
            let result = VoiceOverResult(spoken: reply["spoken"] as? [String] ?? [], complete: reply["complete"] as? Bool ?? false,
                                         systemAlert: alert)
            try Output.emit(result, json: global.json) {
                var lines = result.spoken.enumerated().map { index, text in
                    "\(index + 1). \(text)" + (alert?.items.contains(index + 1) == true ? "  (system alert)" : "")
                }
                if lines.isEmpty { lines = ["VoiceOver read nothing (the app may still be loading)."] }
                if !result.complete { lines.append("… stopped after \(max) elements (raise --max to continue)") }
                if let alert {
                    lines.append("⚠ A system alert (\"\(alert.title)\") is showing and took VoiceOver's focus, so this isn't the app's full "
                                 + "screen. Dismiss it and run `ios layout --voiceover` again.")
                }
                return lines.joined(separator: "\n")
            }
            return
        }
        let tree = try snapshot(automation.session())
        if full {
            try Output.emit(tree, json: global.json) { treeText(tree) }
            return
        }
        let elements = Layout.flatten(tree)
        try Output.emit(elements, json: global.json) {
            elements.isEmpty ? "No visible elements (the app may still be loading)." : elements.map(\.textLine).joined(separator: "\n")
        }
    }

    private func runSwiftUI() throws {
        let target = try TargetResolver.resolve(automation.device)
        guard let bundleID = automation.bundleId ?? RunnerSessions.lastApp(for: target) else { throw IOSError.noAppSelected }
        RunnerSessions.rememberApp(bundleID, for: target)
        if relaunch {
            Docs.progress("Relaunching \(bundleID) with SwiftUI view-debug data…")
            _ = try SwiftUITree.relaunchForDebugging(bundleID, on: target)
            Thread.sleep(forTimeInterval: wait)
        }
        // Right after a relaunch SwiftUI may not have produced its debug data yet (it appears a few
        // seconds after the first render), so retry a few times before giving up.
        var dumps: [Data] = []
        for attempt in 1...(relaunch ? 3 : 1) {
            Docs.progress("Reading the SwiftUI tree (the app pauses briefly)…")
            dumps = try SwiftUITree.dumpRaw(bundleID, on: target)
            if !SwiftUITree.isEmpty(dumps) { break }
            if attempt < 3 && relaunch { Thread.sleep(forTimeInterval: 3) }
        }
        if SwiftUITree.isEmpty(dumps) {
            throw IOSError.swiftUIDumpFailed(reason: relaunch
                ? "no SwiftUI debug data yet; the app may still be starting. Try `ios layout --swiftui` again in a few seconds."
                : "no SwiftUI debug data; the app wasn't started with it. Add --relaunch "
                    + "(navigate afterwards with `ios input`; `ios run` relaunches it without the data).")
        }
        if raw {
            let combined = try dumps.map { try JSONSerialization.jsonObject(with: $0) }
            let data = try JSONSerialization.data(withJSONObject: combined, options: [.prettyPrinted])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let system = try SwiftUITree.systemModules()
        let trees = try SwiftUITree.parse(dumps) { system.contains($0) }
        try Output.emit(trees, json: global.json) {
            trees.map { swiftUIText($0) }.joined(separator: "\n")
        }
    }

    private func swiftUIText(_ node: SwiftUIViewNode, depth: Int = 0) -> String {
        var line = String(repeating: "  ", count: depth) + node.name
        if node.module != "SwiftUI" { line += "  [\(node.module)]" }
        if let text = node.text { line += " \"\(text)\"" }
        if !node.contains.isEmpty { line += "  ‹" + node.contains.prefix(4).joined(separator: ", ") + "›" }
        return ([line] + node.children.map { swiftUIText($0, depth: depth + 1) }).joined(separator: "\n")
    }

    private func treeText(_ node: UIElementNode, depth: Int = 0) -> String {
        var line = String(repeating: "  ", count: depth) + node.type
        if let id = node.id { line += " id=\(id)" }
        if let label = node.label { line += " \"\(label)\"" }
        if let value = node.value { line += " value=\"\(value)\"" }
        line += " (\(Int(node.frame.x)),\(Int(node.frame.y)) \(Int(node.frame.width))×\(Int(node.frame.height)))"
        return ([line] + node.children.map { treeText($0, depth: depth + 1) }).joined(separator: "\n")
    }
}

struct Input: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tap, swipe, type and press buttons on a simulator or device.",
        subcommands: [Tap.self, DoubleTap.self, Swipe.self, TypeText.self, Key.self, Button.self, Wait.self, ScrollTo.self]
    )

    struct Result: Encodable {
        let action: String
        let point: Point?
        let element: LayoutElement?
        let elapsed: Double
    }

    /// Resolves the point to act on from coordinates or an element query.
    static func point(_ coordinates: [Double], id: String?, label: String?, session: RunnerSession) throws -> (Point, LayoutElement?) {
        if id != nil || label != nil {
            let elements = Layout.flatten(try snapshot(session))
            guard let element = Layout.find(in: elements, id: id, label: label) else {
                throw IOSError.elementNotFound(query: id.map { "id '\($0)'" } ?? "label '\(label ?? "")'")
            }
            return (element.center, element)
        }
        guard coordinates.count == 2 else { throw ValidationError("Pass <x> <y>, --id or --label.") }
        return (Point(x: coordinates[0], y: coordinates[1]), nil)
    }

    static func report(_ result: Result, json: Bool) throws {
        try Output.emit(result, json: json) {
            var text = result.action
            if let element = result.element { text += " \(element.type) " + (element.id.map { "id=\($0)" } ?? "\"\(element.label ?? "")\"") }
            if let point = result.point { text += " at (\(Int(point.x.rounded())),\(Int(point.y.rounded())))" }
            return text + String(format: " — %.2fs", result.elapsed)
        }
    }

    struct Tap: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Tap an element (--id / --label) or a point.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var automation: AutomationOptions
        @Argument(help: "x y in points (from `ios layout`).") var coordinates: [Double] = []
        @Option(help: "Accessibility identifier of the element to tap.") var id: String?
        @Option(help: "Label of the element to tap (exact, else contains).") var label: String?
        @Option(help: "Hold for this many seconds (long press).") var duration: Double?

        func run() throws {
            let session = try automation.session()
            let (point, element) = try Input.point(coordinates, id: id, label: label, session: session)
            let command = "tap \(point.x) \(point.y)" + (duration.map { " \($0)" } ?? "")
            let reply = try session.send(command)
            try Input.report(Result(action: duration == nil ? "Tapped" : "Long-pressed", point: point, element: element, elapsed: reply.elapsed), json: global.json)
        }
    }

    struct DoubleTap: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "doubletap", abstract: "Double-tap an element or a point.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var automation: AutomationOptions
        @Argument(help: "x y in points.") var coordinates: [Double] = []
        @Option(help: "Accessibility identifier.") var id: String?
        @Option(help: "Label (exact, else contains).") var label: String?

        func run() throws {
            let session = try automation.session()
            let (point, element) = try Input.point(coordinates, id: id, label: label, session: session)
            let reply = try session.send("doubletap \(point.x) \(point.y)")
            try Input.report(Result(action: "Double-tapped", point: point, element: element, elapsed: reply.elapsed), json: global.json)
        }
    }

    struct Swipe: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Swipe between two points, or across the screen with --direction.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var automation: AutomationOptions
        @Argument(help: "x1 y1 x2 y2 in points.") var coordinates: [Double] = []
        @Option(help: "up, down, left or right (finger direction; up scrolls content down).") var direction: String?

        func run() throws {
            let session = try automation.session()
            let from: Point, to: Point
            if let direction {
                let screen = try snapshot(session).frame
                guard let points = Layout.swipePoints(direction: direction, screen: screen) else {
                    throw ValidationError("--direction must be up, down, left or right.")
                }
                (from, to) = points
            } else {
                guard coordinates.count == 4 else { throw ValidationError("Pass x1 y1 x2 y2, or --direction.") }
                (from, to) = (Point(x: coordinates[0], y: coordinates[1]), Point(x: coordinates[2], y: coordinates[3]))
            }
            let reply = try session.send("swipe \(from.x) \(from.y) \(to.x) \(to.y)")
            try Input.report(Result(action: "Swiped (\(Int(from.x)),\(Int(from.y))) →", point: to, element: nil, elapsed: reply.elapsed), json: global.json)
        }
    }

    struct TypeText: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text into the focused field (tap the field first).")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var automation: AutomationOptions
        @Argument(help: "Text to type.") var text: [String]
        @Flag(help: "Press Return afterwards (submit a search, go to the next field…).") var submit = false

        func run() throws {
            let session = try automation.session()
            var elapsed = try session.send("type \(text.joined(separator: " "))").elapsed
            if submit { elapsed += try session.send("key return").elapsed }
            let action = "Typed \"\(text.joined(separator: " "))\"" + (submit ? " and pressed Return" : "")
            try Input.report(Result(action: action, point: nil, element: nil, elapsed: elapsed), json: global.json)
        }
    }

    struct Key: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Press a keyboard key in the focused field: return, delete, tab or space.",
            discussion: "`ios input key delete --count 20` clears up to 20 characters before the cursor."
        )
        @OptionGroup var global: GlobalOptions
        @OptionGroup var automation: AutomationOptions
        @Argument(help: "return, delete, tab or space.") var name: String
        @Option(help: "Press it this many times.") var count = 1

        func validate() throws {
            guard ["return", "delete", "tab", "space"].contains(name) else { throw ValidationError("Key must be return, delete, tab or space.") }
            guard (1...500).contains(count) else { throw ValidationError("--count must be 1–500.") }
        }

        func run() throws {
            let reply = try automation.session().send("key \(name) \(count)")
            try Input.report(Result(action: "Pressed \(name)" + (count > 1 ? " ×\(count)" : ""), point: nil, element: nil, elapsed: reply.elapsed), json: global.json)
        }
    }

    struct Wait: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Wait until an element appears (or disappears with --gone).",
            discussion: """
            Polls the screen until a visible, uncovered element matches --id / --label, then prints it; \
            use it after a tap that loads a screen instead of retrying. Exits non-zero on timeout.
            """
        )
        @OptionGroup var global: GlobalOptions
        @OptionGroup var automation: AutomationOptions
        @Option(help: "Accessibility identifier to wait for.") var id: String?
        @Option(help: "Label to wait for (exact, ignoring case).") var label: String?
        @Flag(help: "Wait until it's gone instead (e.g. a spinner).") var gone = false
        @Option(help: "Seconds before giving up.") var timeout: Double = 10
        @Option(help: "Seconds between checks.") var interval: Double = 0.5

        func validate() throws {
            if (id == nil) == (label == nil) { throw ValidationError("Pass --id or --label.") }
            if timeout <= 0 || interval <= 0 { throw ValidationError("--timeout and --interval must be positive.") }
        }

        func run() throws {
            let session = try automation.session()
            let query = id.map { "id '\($0)'" } ?? "label '\(label ?? "")'"
            let start = Date()
            var coveredMatch = false
            while true {
                // The app can be briefly out of the foreground (a system sheet, a transition); keep polling.
                if let elements = try? Layout.flatten(snapshot(session)) {
                    let match = Layout.find(in: elements, id: id, label: label, exactLabel: true)
                    coveredMatch = match?.covered == true
                    let visible = match.flatMap { $0.covered ? nil : $0 }
                    let elapsed = Date().timeIntervalSince(start)
                    if gone, visible == nil {
                        try Input.report(Result(action: "\(query) is gone", point: nil, element: nil, elapsed: elapsed), json: global.json)
                        return
                    }
                    if !gone, let visible {
                        try Input.report(Result(action: "Found", point: visible.center, element: visible, elapsed: elapsed), json: global.json)
                        return
                    }
                }
                if Date().timeIntervalSince(start) + interval > timeout {
                    throw IOSError.waitTimedOut(query: query, seconds: timeout, gone: gone, covered: !gone && coveredMatch)
                }
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }

    struct ScrollTo: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scroll-to",
            abstract: "Scroll until an element is on screen, then print it (tap it next with --id / --label).",
            discussion: """
            If the element exists off screen, scrolls toward it; otherwise (lazy lists create rows only when \
            shown) scrolls in --direction. By default it scrolls up (finger up, revealing content further \
            down) and, at the end, back the other way. Stops when the content stops moving.
            """
        )
        @OptionGroup var global: GlobalOptions
        @OptionGroup var automation: AutomationOptions
        @Option(help: "Accessibility identifier to scroll to.") var id: String?
        @Option(help: "Label to scroll to (exact, ignoring case).") var label: String?
        @Option(help: "Finger direction when the element isn't found yet: up, down, left or right. Default: up, then back down if the end is reached.") var direction: String?
        @Option(help: "Give up after this many swipes.") var maxSwipes = 15

        func validate() throws {
            if (id == nil) == (label == nil) { throw ValidationError("Pass --id or --label.") }
            if let direction, !["up", "down", "left", "right"].contains(direction) { throw ValidationError("--direction must be up, down, left or right.") }
            if !(1...100).contains(maxSwipes) { throw ValidationError("--max-swipes must be 1–100.") }
        }

        func run() throws {
            let session = try automation.session()
            let query = id.map { "id '\($0)'" } ?? "label '\(label ?? "")'"
            let start = Date()
            let opposite = ["up": "down", "down": "up", "left": "right", "right": "left"]
            var way = direction ?? "up"
            var reversed = direction != nil // only the default direction turns back at the end
            var previous: [LayoutElement]?
            for swipes in 0...maxSwipes {
                let tree = try snapshot(session)
                let screen = Layout.screen(of: tree)
                let elements = Layout.flatten(tree)
                if let match = Layout.find(in: elements, id: id, label: label, exactLabel: true), !match.covered,
                   Layout.visibleFraction(match, screen: screen) >= 0.6 || match.frame.height > screen.height / 2 {
                    let action = swipes == 0 ? "Already on screen:" : "Scrolled (\(swipes) swipe\(swipes == 1 ? "" : "s")) to"
                    try Input.report(Result(action: action, point: match.center, element: match, elapsed: Date().timeIntervalSince(start)), json: global.json)
                    return
                }
                // Same elements in the same places as before the last swipe: nothing more to reveal.
                if let previous, previous.map(\.textLine) == elements.map(\.textLine) {
                    guard !reversed else { throw IOSError.scrollTargetNotFound(query: query, swipes: swipes, reachedEnd: true) }
                    reversed = true
                    way = opposite[way]!
                }
                if swipes == maxSwipes { break }
                previous = elements
                // An element that exists off screen says which way to go; lazy lists don't have it yet.
                let toward = Layout.locate(in: tree, id: id, label: label, exactLabel: true)
                    .flatMap { Layout.scrollDirection(toward: $0.frame, screen: screen) }
                guard let (from, to) = Layout.swipePoints(direction: toward ?? way, screen: screen, reach: 0.32) else { break }
                _ = try session.send("swipe \(from.x) \(from.y) \(to.x) \(to.y) 0.05 0.1")
            }
            throw IOSError.scrollTargetNotFound(query: query, swipes: maxSwipes, reachedEnd: false)
        }
    }

    struct Button: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Press a hardware button (home).")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var automation: AutomationOptions
        @Argument(help: "Button name: home.") var name: String

        func run() throws {
            let reply = try automation.session().send("button \(name)")
            try Input.report(Result(action: "Pressed \(name)", point: nil, element: nil, elapsed: reply.elapsed), json: global.json)
        }
    }
}

struct RunnerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runner",
        abstract: "Manage the UI automation runner used by `layout` and `input`.",
        subcommands: [Status.self, Stop.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether a runner is running on the target.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: TargetOptions

        struct Result: Encodable {
            let running: Bool
            let session: RunnerSession?
        }

        func run() throws {
            let session = RunnerSessions.current(try TargetResolver.resolve(target.device))
            try Output.emit(Result(running: session != nil, session: session), json: global.json) {
                guard let session else { return "No runner running." }
                return "Running on \(session.host):\(session.port) (pid \(session.pid)) since \(session.startedAt)\nLog: \(session.log)"
            }
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the runner on the target.")
        @OptionGroup var target: TargetOptions

        func run() throws {
            let stopped = RunnerSessions.stop(try TargetResolver.resolve(target.device))
            print(stopped ? "Stopped." : "No runner was running.")
        }
    }
}
