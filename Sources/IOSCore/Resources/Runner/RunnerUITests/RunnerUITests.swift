import Network
import XCTest

/// Long-running UI automation server used by `ios layout` / `ios input`.
///
/// Started by the CLI with `xcodebuild test-without-building`; listens on IOS_CLI_PORT
/// (passed as TEST_RUNNER_IOS_CLI_PORT). Protocol: one command per line, one JSON object
/// per reply, terminated by a NUL byte: {"ok": true, "result": ..., "elapsed": seconds}.
///
/// Any XCTest failure ends the test and with it the server, so every command validates
/// its input and checks preconditions (e.g. keyboard focus) before calling XCUITest.
final class RunnerUITests: XCTestCase {
    var app: XCUIApplication?
    let lock = NSLock()
    var pending: [(String, NWConnection)] = []

    /// XCUITest waits for the app to go idle before and after every event, up to 60 s. Apps that
    /// animate continuously (a playhead, a Lottie loop) never go idle, so each tap took a minute.
    /// Skip those waits through XCUIApplicationProcess's private switches, as WebDriverAgent does;
    /// applied only if the methods exist, and IOS_CLI_WAIT_FOR_IDLE=1 keeps Apple's behavior.
    static func skipIdleWaits() -> [String] {
        guard ProcessInfo.processInfo.environment["IOS_CLI_WAIT_FOR_IDLE"] != "1",
              let cls = NSClassFromString("XCUIApplicationProcess") else { return [] }
        return ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"].compactMap { name in
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { return nil }
            let alwaysSkip: @convention(block) (AnyObject) -> Bool = { _ in true }
            method_setImplementation(method, imp_implementationWithBlock(alwaysSkip))
            return name
        }
    }

    static let includeNonModal = NSSelectorFromString("includingNonModalElements")
    static var canIncludeNonModal: Bool { XCUIElement.instancesRespond(to: includeNonModal) }

    /// Accessibility hides everything beside a modal view, and XCUITest snapshots honor that. A
    /// SwiftUI .fullScreenCover is modal, so a .sheet presented on top of it vanished from the tree
    /// (VoiceOver and XCUITest's own debugDescription still see it). XCUIElement's private
    /// includingNonModalElements returns a copy whose snapshots and queries skip that pruning;
    /// fall back to the element itself if a future Xcode removes it.
    static func unpruned(_ element: XCUIElement) -> XCUIElement {
        guard canIncludeNonModal,
              let copy = element.perform(includeNonModal)?.takeUnretainedValue() as? XCUIElement else { return element }
        return copy
    }

    /// XCTest's own snapshot parameters (maxDepth, maxChildren, snapshotKeyHonorModalViews, …).
    static func defaultSnapshotParameters() -> [String: Any]? {
        // Xcode 27 reaches the accessibility client (XCAXClient_iOS) through XCUIDevice.
        let device = XCUIDevice.shared as NSObject
        guard
            device.responds(to: NSSelectorFromString("accessibilityInterface")),
            let client = device.perform(NSSelectorFromString("accessibilityInterface"))?.takeUnretainedValue() as? NSObject,
            client.responds(to: NSSelectorFromString("defaultParameters")),
            let defaults = client.perform(NSSelectorFromString("defaultParameters"))?.takeUnretainedValue() as? [String: Any]
        else { return nil }
        return defaults
    }

    /// A snapshot that doesn't prune elements beside modal views (see `unpruned`): XCTest's default
    /// parameters with snapshotKeyHonorModalViews off, through XCUIElement's private
    /// snapshotWithParameters:error:. Falls back to the public snapshot() if either is missing.
    static func fullSnapshot(_ element: XCUIElement) throws -> XCUIElementSnapshot {
        let selector = NSSelectorFromString("snapshotWithParameters:error:")
        guard element.responds(to: selector), var parameters = defaultSnapshotParameters() else { return try element.snapshot() }
        parameters["snapshotKeyHonorModalViews"] = false
        typealias SnapshotWithParameters = @convention(c) (AnyObject, Selector, NSDictionary, AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject?
        let call = unsafeBitCast(element.method(for: selector), to: SnapshotWithParameters.self)
        var error: NSError?
        if let snapshot = call(element, selector, parameters as NSDictionary, &error) as? XCUIElementSnapshot { return snapshot }
        return try element.snapshot()
    }

    func testServe() throws {
        continueAfterFailure = true
        let skipped = Self.skipIdleWaits()
        print("IOS_CLI_RUNNER idle waits skipped: \(skipped)")
        let portValue = ProcessInfo.processInfo.environment["IOS_CLI_PORT"].flatMap(UInt16.init) ?? 8100
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: portValue)!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            self.receive(on: connection)
        }
        // If the port is taken, exit instead of running deaf: the CLI would otherwise
        // talk to whatever else is listening there.
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                print("IOS_CLI_RUNNER FAILED port=\(portValue): \(error)")
                exit(1)
            }
        }
        listener.start(queue: .global())
        print("IOS_CLI_RUNNER READY port=\(portValue)")

        // XCUITest calls must run on the main thread; the network side only queues commands.
        while true {
            lock.lock()
            let batch = pending
            pending.removeAll()
            lock.unlock()
            if batch.isEmpty {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                continue
            }
            for (line, connection) in batch {
                let start = Date()
                var reply: [String: Any]
                do {
                    reply = ["ok": true, "result": try handle(line)]
                } catch let error as RunnerError {
                    reply = ["ok": false, "error": error.message]
                } catch {
                    reply = ["ok": false, "error": "\(error)"]
                }
                reply["elapsed"] = Date().timeIntervalSince(start)
                var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"ok":false}"#.utf8)
                data.append(0)
                connection.send(content: data, completion: .contentProcessed { _ in })
                if line == "quit" {
                    listener.cancel()
                    return
                }
            }
        }
    }

    struct RunnerError: Error { let message: String }

    func receive(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer = Data(buffer[buffer.index(after: newline)...])
                self.lock.lock()
                self.pending.append((line.trimmingCharacters(in: .whitespacesAndNewlines), connection))
                self.lock.unlock()
            }
            if done || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    func currentApp() throws -> XCUIApplication {
        guard let app else { throw RunnerError(message: "no app selected; send `activate <bundle id>` first") }
        guard app.state == .runningForeground else {
            throw RunnerError(message: "\(currentBundle) isn't in the foreground (state \(app.state.rawValue)); pass --bundle-id to bring it back")
        }
        return app
    }

    func numbers(_ text: String, count: Int, usage: String) throws -> [Double] {
        let values = text.split(separator: " ").compactMap { Double($0) }
        guard values.count >= count else { throw RunnerError(message: "usage: \(usage)") }
        return values
    }

    func handle(_ line: String) throws -> Any {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "ping":
            let bundle: Any = app == nil ? NSNull() : currentBundle
            return ["bundleIdentifier": bundle, "includesNonModalElements": Self.canIncludeNonModal,
                    "snapshotDefaults": Self.defaultSnapshotParameters().map { $0.mapValues { "\($0)" } } ?? [:]]

        case "activate":
            guard !argument.isEmpty else { throw RunnerError(message: "usage: activate <bundle id>") }
            let target = XCUIApplication(bundleIdentifier: argument)
            target.activate()
            app = target
            currentBundle = argument
            return ["bundleIdentifier": argument, "state": target.state.rawValue]

        case "snapshot":
            let target = Self.unpruned(try currentApp())
            // Snapshots only carry tvOS-style focus; find the keyboard focus with a query.
            let focused = target.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
            keyboardFocus = focused.exists ? (focused.elementType, focused.frame) : nil
            return node(try Self.fullSnapshot(target))

        case "snapshot-public":
            // Diagnostic: XCTest's public snapshot (modal pruning on), to compare with "snapshot".
            return node(try currentApp().snapshot())

        case "describe":
            return try currentApp().debugDescription

        case "tap":
            let v = try numbers(argument, count: 2, usage: "tap <x> <y> [duration]")
            let point = try coordinate(v[0], v[1])
            if v.count > 2 { point.press(forDuration: v[2]) } else { point.tap() }
            return "ok"

        case "doubletap":
            let v = try numbers(argument, count: 2, usage: "doubletap <x> <y>")
            try coordinate(v[0], v[1]).doubleTap()
            return "ok"

        case "swipe":
            let v = try numbers(argument, count: 4, usage: "swipe <x1> <y1> <x2> <y2> [hold]")
            try coordinate(v[0], v[1]).press(forDuration: v.count > 4 ? v[4] : 0.05, thenDragTo: try coordinate(v[2], v[3]))
            return "ok"

        case "type":
            let target = Self.unpruned(try currentApp())
            let focused = target.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
            guard focused.exists else { throw RunnerError(message: "no element has keyboard focus; tap a text field first") }
            focused.typeText(argument)
            return "ok"

        case "button":
            switch argument {
            case "home": XCUIDevice.shared.press(.home)
            default: throw RunnerError(message: "usage: button home")
            }
            return "ok"

        case "screenshot":
            return XCUIScreen.main.screenshot().pngRepresentation.base64EncodedString()

        case "quit":
            return "bye"

        default:
            throw RunnerError(message: "unknown command: \(line)")
        }
    }

    var currentBundle = ""
    var keyboardFocus: (XCUIElement.ElementType, CGRect)?

    func coordinate(_ x: Double, _ y: Double) throws -> XCUICoordinate {
        try currentApp().coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    func node(_ e: XCUIElementSnapshot) -> [String: Any] {
        var d: [String: Any] = [
            "type": e.elementType.rawValue,
            "frame": [e.frame.origin.x, e.frame.origin.y, e.frame.size.width, e.frame.size.height],
        ]
        if !e.identifier.isEmpty { d["id"] = e.identifier }
        if !e.label.isEmpty { d["label"] = e.label }
        if let value = e.value as? String, !value.isEmpty { d["value"] = value }
        if let placeholder = e.placeholderValue, !placeholder.isEmpty { d["placeholder"] = placeholder }
        if !e.isEnabled { d["enabled"] = false }
        if e.isSelected { d["selected"] = true }
        if let focus = keyboardFocus, focus.0 == e.elementType, focus.1 == e.frame { d["focused"] = true }
        if !e.children.isEmpty { d["children"] = e.children.map(node) }
        return d
    }
}
