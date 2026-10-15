import Foundation

/// A node of an app's SwiftUI view tree (`ios layout --swiftui`).
public struct SwiftUIViewNode: Codable, Sendable {
    /// Short type name, e.g. "VStack", "HomeView", "Text".
    public let name: String
    /// Module of the type, e.g. "SwiftUI" or "MyApp".
    public let module: String
    /// The string a Text displays, when known.
    public let text: String?
    /// App types named in this node's generic parameters, e.g. ["ItemCard"] for
    /// `Button<MyApp.ItemCard>`. SwiftUI's debug data records most custom views only this way.
    public let contains: [String]
    public let children: [SwiftUIViewNode]
}

public enum SwiftUITree {
    /// SwiftUI views worth showing besides the app's own; everything else (modifiers,
    /// internal adaptors) is collapsed and its children moved up.
    static let structuralViews: Set<String> = [
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "LazyVGrid", "LazyHGrid", "Grid", "GridRow",
        "List", "ScrollView", "ForEach", "Group", "Section", "Form", "GeometryReader", "NavigationStack",
        "NavigationSplitView", "NavigationLink", "TabView", "Text", "Image", "AsyncImage", "Label", "Button",
        "Toggle", "TextField", "SecureField", "TextEditor", "Picker", "Slider", "Stepper", "DatePicker", "Link",
        "Menu", "ProgressView", "Spacer", "Divider", "ViewThatFits", "Canvas", "Map",
    ]

    /// Relaunches the app with SwiftUI's view-debug data enabled. The tree can be read until the
    /// app is relaunched without it (e.g. by `ios run`).
    public static func relaunchForDebugging(_ bundleID: String, on target: Target) throws -> Int {
        switch target {
        case let .simulator(s):
            try Launcher.prepare(target)
            let out = try Shell.run("/usr/bin/xcrun", ["simctl", "launch", "--terminate-running-process", s.udid, bundleID],
                                    environment: ["SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG": "1"])
            guard out.status == 0, let pid = Launcher.parseSimctlPid(out.stdoutString) else {
                throw IOSError.toolFailed(command: "simctl launch", status: out.status, stderr: out.stderr)
            }
            return pid
        case let .device(d):
            let out = try Shell.checked("/usr/bin/xcrun", [
                "devicectl", "device", "process", "launch", "--device", d.udid, "--terminate-existing",
                "--environment-variables", #"{"SWIFTUI_VIEW_DEBUG":"1"}"#, bundleID, "-j", "-",
            ])
            guard let pid = Launcher.parseDevicectlPid(out.stdout) else {
                throw IOSError.invalidOutput(tool: "devicectl process launch", reason: "no process identifier")
            }
            return pid
        }
    }

    /// Reads the raw view-debug JSON of every SwiftUI hosting view in the running app.
    /// The app is paused while LLDB is attached (~4 s on a simulator, ~15 s on a device).
    public static func dumpRaw(_ bundleID: String, on target: Target) throws -> [Data] {
        let pid = try runningPid(of: bundleID, on: target)
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-swiftui-\(UUID().uuidString).py")
        try lldbScript.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }

        let lldbPath = try Shell.checked("/usr/bin/xcrun", ["lldb", "-P"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = target.isSimulator ? "simulator" : "device"
        let result = try Shell.run("/usr/bin/python3", [script.path, mode, target.udid, String(pid)],
                                   environment: ["PYTHONPATH": lldbPath])
        guard
            let reply = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
            reply["ok"] as? Bool == true
        else {
            let reason = ((try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any])?["error"] as? String
            throw IOSError.swiftUIDumpFailed(reason: reason ?? (result.stderr.isEmpty ? result.stdoutString : result.stderr))
        }
        let paths = (reply["output"] as? String ?? "").split(separator: "\n").map(String.init).filter { $0.hasSuffix(".json") }
        return try paths.map { try readDump($0, bundleID: bundleID, on: target) }
    }

    /// Simulator files are on the Mac already; device files are copied out of the app's container.
    private static func readDump(_ path: String, bundleID: String, on target: Target) throws -> Data {
        guard case let .device(d) = target else { return try Data(contentsOf: URL(fileURLWithPath: path)) }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: local) }
        try Shell.checked("/usr/bin/xcrun", [
            "devicectl", "device", "copy", "from", "--device", d.udid, "--domain-type", "appDataContainer",
            "--domain-identifier", bundleID, "--source", "tmp/" + (path as NSString).lastPathComponent, "--destination", local.path,
        ])
        return try Data(contentsOf: local)
    }

    /// True when no hosting view returned data (each dump is "[]" until SwiftUI produces it).
    public static func isEmpty(_ dumps: [Data]) -> Bool {
        dumps.allSatisfy { ((try? JSONSerialization.jsonObject(with: $0)) as? [Any])?.isEmpty ?? true }
    }

    /// Modules that ship with the SDK (or the Swift runtime); types from any other module are
    /// the app's own, including its frameworks and packages.
    public static func systemModules() throws -> Set<String> {
        Set(try SymbolStore.sdkModuleNames()).union(["Swift", "_Concurrency", "_StringProcessing", "SwiftUICore"])
    }

    /// Filtered trees, one per hosting view.
    public static func parse(_ dumps: [Data], isSystemModule: (String) -> Bool) throws -> [SwiftUIViewNode] {
        try dumps.flatMap { data -> [SwiftUIViewNode] in
            let object = try JSONSerialization.jsonObject(with: data)
            let roots = (object as? [[String: Any]]) ?? [object as? [String: Any]].compactMap { $0 }
            return roots.flatMap { filter($0, isSystemModule: isSystemModule) }
        }
    }

    /// Keeps app and structural views; returns the kept nodes standing in for `raw`.
    static func filter(_ raw: [String: Any], isSystemModule: (String) -> Bool) -> [SwiftUIViewNode] {
        let properties = raw["properties"] as? [[String: Any]] ?? []
        let typeInfo = properties.first { $0["id"] as? Int == 0 }?["attribute"] as? [String: Any] ?? [:]
        let value = properties.first { $0["id"] as? Int == 1 }?["attribute"] as? [String: Any]
        let fullType = typeInfo["type"] as? String ?? ""
        let readable = typeInfo["readableType"] as? String ?? fullType

        let module = fullType.split(separator: ".").first.map(String.init) ?? ""
        let base = String(readable.prefix { $0 != "<" })
        // SwiftUI's debug data lists children last-to-first; reverse to match the code and screen order.
        let children = (raw["children"] as? [[String: Any]] ?? []).reversed().flatMap { filter($0, isSystemModule: isSystemModule) }

        let isAppType = !module.isEmpty && !isSystemModule(module) && !base.hasPrefix("_") && !fullType.hasPrefix("(")
            && !fullType.contains("(unknown context")
        let isStructural = module == "SwiftUI" && structuralViews.contains(base)
        guard isAppType || isStructural else { return children }
        let name = base.split(separator: ".").last.map(String.init) ?? base
        return [SwiftUIViewNode(name: name, module: module, text: base == "Text" ? value.flatMap(firstString) : nil,
                                contains: appTypes(in: fullType, excluding: name, isSystemModule: isSystemModule), children: children)]
    }

    /// Module-qualified app types inside a type string, in order, without duplicates.
    static func appTypes(in type: String, excluding own: String, isSystemModule: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return type.matches(of: /([A-Za-z_][A-Za-z0-9_]*)\.([A-Z][A-Za-z0-9_]*)/).compactMap { match in
            let module = String(match.output.1), name = String(match.output.2)
            guard !isSystemModule(module), name != own, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    /// The first String value in a node's value tree (a Text's verbatim or localized key).
    static func firstString(_ attribute: [String: Any]) -> String? {
        if attribute["type"] as? String == "Swift.String", let value = attribute["value"] as? String { return value }
        for sub in attribute["subattributes"] as? [[String: Any]] ?? [] {
            if let found = firstString(sub) { return found }
        }
        return nil
    }

    static func runningPid(of bundleID: String, on target: Target) throws -> Int {
        switch target {
        case let .simulator(s):
            guard s.isBooted else { throw IOSError.appNotRunning(bundleID: bundleID) }
            // launchctl labels app processes "UIKitApplication:<bundle id>[…]".
            let list = try Shell.checked("/usr/bin/xcrun", ["simctl", "spawn", s.udid, "launchctl", "list"]).stdoutString
            for line in list.split(separator: "\n") {
                let columns = line.split(separator: "\t")
                if columns.count == 3, columns[2].hasPrefix("UIKitApplication:\(bundleID)["), let pid = Int(columns[0]) {
                    return pid
                }
            }
        case let .device(d):
            let apps = try Shell.checked("/usr/bin/xcrun", ["devicectl", "device", "info", "apps", "--device", d.udid,
                                                           "--bundle-id", bundleID, "-j", "-"]).stdout
            guard
                let appURL = (((try? JSONSerialization.jsonObject(with: apps)) as? [String: Any])?["result"] as? [String: Any])
                    .flatMap({ ($0["apps"] as? [[String: Any]])?.first?["url"] as? String })
            else { throw IOSError.appNotInstalled(bundleID: bundleID, udid: d.udid) }
            let bundleName = URL(string: appURL)?.lastPathComponent ?? ""
            let processes = try Shell.checked("/usr/bin/xcrun", ["devicectl", "device", "info", "processes", "--device", d.udid, "-j", "-"]).stdout
            let running = (((try? JSONSerialization.jsonObject(with: processes)) as? [String: Any])?["result"] as? [String: Any])?["runningProcesses"] as? [[String: Any]] ?? []
            if let match = running.first(where: { ($0["executable"] as? String)?.contains("/\(bundleName)/") == true }),
               let pid = match["processIdentifier"] as? Int {
                return pid
            }
        }
        throw IOSError.appNotRunning(bundleID: bundleID)
    }

    /// Attaches LLDB (async API, with a timeout: batch mode hangs on device attach), asks every
    /// _UIHostingView for makeViewDebugData, writes each to the app's tmp directory, detaches.
    static let lldbScript = #"""
    import json, sys, time
    import lldb

    mode, udid, pid = sys.argv[1], sys.argv[2], int(sys.argv[3])
    dbg = lldb.SBDebugger.Create()
    dbg.SetAsync(True)
    ci = dbg.GetCommandInterpreter()

    def run(cmd):
        r = lldb.SBCommandReturnObject()
        ci.HandleCommand(cmd, r)
        return r

    def finish(ok, **fields):
        print(json.dumps(dict(ok=ok, **fields)))
        sys.exit(0)

    if mode == "device":
        run("device select " + udid)
        run("device process attach -p %d" % pid)
    else:
        run("process attach -p %d" % pid)

    # Wait for a "stopped" state-change event. Polling GetState() isn't reliable on devices:
    # it can read "stopped" while the attach is still only "connected".
    deadline = time.time() + 90
    listener = dbg.GetListener()
    while True:
        if time.time() > deadline:
            finish(False, error="timed out attaching to pid %d" % pid)
        event = lldb.SBEvent()
        if listener.WaitForEvent(1, event) and lldb.SBProcess.EventIsProcessEvent(event):
            state = lldb.SBProcess.GetStateFromEvent(event)
            if state == lldb.eStateStopped:
                break
            if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed):
                finish(False, error="process %d ended while attaching" % pid)

    # A device reports "stopped" before LLDB has finished loading the app's images; importing
    # UIKit at that point fails. Let pending events drain, then retry the imports.
    quiet_until = time.time() + 1.0
    settle_deadline = time.time() + 10
    while time.time() < min(quiet_until, settle_deadline) or time.time() < quiet_until:
        if listener.WaitForEvent(1, lldb.SBEvent()):
            quiet_until = time.time() + 1.0
        if time.time() > settle_deadline:
            break

    dbg.SetAsync(False)
    for attempt in range(6):
        imported = run("expr -l objc -- @import Foundation").Succeeded() and run("expr -l objc -- @import UIKit").Succeeded()
        if imported:
            break
        time.sleep(1)
    expr = ('expr -l objc -O -- NSMutableString *out = [NSMutableString string]; NSMutableArray *stack = [NSMutableArray array]; '
            'for (UIWindow *w in (NSArray *)[[UIApplication sharedApplication] valueForKeyPath:@"connectedScenes.@distinctUnionOfArrays.windows"]) [stack addObject:w]; '
            'int vdIdx = 0; NSString *stamp = [[NSUUID UUID] UUIDString]; '
            'while ([stack count] > 0) { UIView *vdView = (UIView *)[stack lastObject]; [stack removeLastObject]; '
            'if ([vdView respondsToSelector:@selector(makeViewDebugData)]) { NSData *vdData = (NSData *)[(id)vdView makeViewDebugData]; '
            'NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ios-cli-swiftui-%@-%d.json", stamp, vdIdx++]]; '
            '[vdData writeToFile:p atomically:YES]; [out appendFormat:@"%@\\n", p]; } '
            'for (UIView *s in [vdView subviews]) [stack addObject:s]; } out')
    result = run(expr)
    output, error = result.GetOutput() or "", result.GetError() or ""
    run("detach")
    if not result.Succeeded():
        # The first errors explain the failure; later ones are consequences.
        finish(False, error=("imports failed; " if not imported else "") + error.strip()[:600])
    finish(True, output=output)
    """#
}
