import Foundation

/// A crash report (.ips, bug type 309) from a simulator or a device.
public struct CrashReport: Codable, Sendable {
    public struct Frame: Codable, Sendable {
        public let image: String
        public let symbol: String?
        public let address: String?
        /// "file.swift:42" when symbolication found the line.
        public let location: String?
    }

    public let path: String
    public let process: String
    public let bundleID: String?
    public let version: String?
    public let time: String?
    /// The OS that wrote the report: the device's iOS, or for a simulator app the Mac's macOS.
    public let osVersion: String?
    public let simulator: Bool
    public let exception: String?
    public let signal: String?
    public let reason: String?
    /// The crashed thread's frames, top first (filled by `details`).
    public var frames: [Frame]?
    /// For uncaught Objective-C/Swift exceptions: the backtrace where it was thrown.
    public var exceptionFrames: [Frame]?
    /// How many app frames were symbolicated from a dSYM or the local binary.
    public var symbolicated: Int?
}

public enum Crashes {
    static let crashBugType = "309"

    /// Recent crash reports for the target, newest first.
    public static func list(on target: Target, bundleID: String?, process: String?, hours: Double, limit: Int) throws -> [CrashReport] {
        let since = Date().addingTimeInterval(-hours * 3600)
        let files: [URL]
        switch target {
        case let .simulator(s):
            files = localReports(since: since).filter { url in
                // The body's procPath runs through the simulator's own folder (JSON writes "/" as "\/").
                (try? String(contentsOf: url, encoding: .utf8))?.contains("Devices\\/\(s.udid)\\/") == true
            }
        case let .device(d):
            files = try deviceReports(d, since: since, process: process)
        }
        var reports = files.compactMap { try? summary($0) }
        if let bundleID { reports = reports.filter { $0.bundleID == bundleID } }
        if let process { reports = reports.filter { $0.process.caseInsensitiveCompare(process) == .orderedSame } }
        return Array(reports.sorted { ($0.time ?? "") > ($1.time ?? "") }.prefix(limit))
    }

    static func localReports(since: Date) -> [URL] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { url in
            url.pathExtension == "ips"
                && ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= since
        }
    }

    /// Reports the system writes for itself, not app crashes; skipped so they aren't copied off the device.
    static let systemReportPrefixes = ["stacks-", "SFA-", "log-power", "xp_amp", "proactive_event_tracker", "SiriSearchFeedback",
                                       "JetsamEvent", "ExcResource", "Analytics", "DiskWrites", "sysdiagnose", "WiFi", "awdd"]

    /// Copies the device's recent .ips reports into the cache (once per file) and returns the local copies.
    static func deviceReports(_ device: PhysicalDevice, since: Date, process: String?) throws -> [URL] {
        let listing = try Shell.checked("/usr/bin/xcrun", [
            "devicectl", "device", "info", "files", "--device", device.udid, "--domain-type", "systemCrashLogs", "--timeout", "60", "-j", "-",
        ]).stdout
        guard let root = try? JSONSerialization.jsonObject(with: listing) as? [String: Any],
              let files = (root["result"] as? [String: Any])?["files"] as? [[String: Any]] else {
            throw IOSError.invalidOutput(tool: "devicectl device info files", reason: "missing result.files")
        }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ios-cli/crashes/\(device.udid)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [URL] = []
        for file in files {
            guard let relative = file["relativePath"] as? String, relative.hasSuffix(".ips") else { continue }
            let name = URL(fileURLWithPath: relative).lastPathComponent
            if systemReportPrefixes.contains(where: name.hasPrefix) { continue }
            if let process, !name.lowercased().hasPrefix(process.lowercased() + "-") { continue }
            let metadata = file["metadata"] as? [String: Any] ?? [:]
            if let date = (metadata["lastModDate"] as? String).flatMap(iso.date(from:)), date < since { continue }
            let size = metadata["size"] as? Int ?? 0
            let local = cache.appendingPathComponent("\(size)-\(name)")
            if !FileManager.default.fileExists(atPath: local.path) {
                let copied = try? Shell.run("/usr/bin/xcrun", [
                    "devicectl", "device", "copy", "from", "--device", device.udid, "--domain-type", "systemCrashLogs",
                    "--source", relative, "--destination", local.path, "--timeout", "60",
                ])
                guard copied?.status == 0 else { continue }
            }
            out.append(local)
        }
        return out
    }

    /// The report's header line and JSON body; nil when it isn't a crash report.
    static func read(_ url: URL) throws -> (header: [String: Any], body: [String: Any])? {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let newline = text.firstIndex(of: "\n"),
              let header = try JSONSerialization.jsonObject(with: Data(text[..<newline].utf8)) as? [String: Any],
              "\(header["bug_type"] ?? "")" == crashBugType,
              let body = try JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any]
        else { return nil }
        return (header, body)
    }

    public static func summary(_ url: URL) throws -> CrashReport? {
        guard let (header, body) = try read(url) else { return nil }
        let exception = body["exception"] as? [String: Any]
        let termination = body["termination"] as? [String: Any]
        let bundleInfo = body["bundleInfo"] as? [String: Any]
        var reason = termination?["indicator"] as? String
        if let details = (termination?["details"] as? [String])?.first { reason = (reason.map { $0 + ": " } ?? "") + details }
        if let asi = body["asi"] as? [String: [String]], let message = asi.values.flatMap({ $0 }).first {
            reason = message // "Fatal error: Index out of range" — the most useful line when there is one
        }
        return CrashReport(
            path: url.path, process: body["procName"] as? String ?? header["app_name"] as? String ?? url.deletingPathExtension().lastPathComponent,
            bundleID: header["bundleID"] as? String ?? bundleInfo?["CFBundleIdentifier"] as? String,
            version: (bundleInfo?["CFBundleShortVersionString"] ?? header["app_version"]) as? String,
            time: body["captureTime"] as? String ?? header["timestamp"] as? String, osVersion: header["os_version"] as? String,
            simulator: (body["procPath"] as? String)?.contains("/CoreSimulator/Devices/") == true,
            exception: exception?["type"] as? String, signal: exception?["signal"] as? String, reason: reason,
            frames: nil, exceptionFrames: nil, symbolicated: nil
        )
    }

    /// The summary plus the crashed thread's frames, symbolicated where the binary or dSYM is on this Mac.
    public static func details(_ path: String, maxFrames: Int) throws -> CrashReport {
        let url = URL(fileURLWithPath: path)
        guard var report = try summary(url), let (_, body) = try read(url) else {
            throw IOSError.failed("\(path) isn't a crash report (.ips with bug type 309).")
        }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        let raw = faulting < threads.count ? (threads[faulting]["frames"] as? [[String: Any]] ?? []) : []
        var count = 0
        report.frames = frames(Array(raw.prefix(maxFrames)), images: images, symbolicated: &count)
        if let thrown = body["lastExceptionBacktrace"] as? [[String: Any]], !thrown.isEmpty {
            report.exceptionFrames = frames(Array(thrown.prefix(maxFrames)), images: images, symbolicated: &count)
        }
        report.symbolicated = count
        return report
    }

    static func frames(_ raw: [[String: Any]], images: [[String: Any]], symbolicated: inout Int) -> [CrashReport.Frame] {
        // Group unsymbolicated frames by image so atos runs once per image.
        var resolved: [Int: (String, String?)] = [:]
        var byImage: [Int: [(frame: Int, address: UInt64)]] = [:]
        for (i, frame) in raw.enumerated() where frame["symbol"] == nil {
            guard let index = frame["imageIndex"] as? Int, index < images.count,
                  let base = (images[index]["base"] as? NSNumber)?.uint64Value,
                  let offset = (frame["imageOffset"] as? NSNumber)?.uint64Value else { continue }
            byImage[index, default: []].append((i, base + offset))
        }
        for (index, entries) in byImage {
            let image = images[index]
            guard let binary = symbolFile(uuid: image["uuid"] as? String, path: image["path"] as? String, name: image["name"] as? String),
                  let base = (image["base"] as? NSNumber)?.uint64Value else { continue }
            let arguments = ["atos", "-o", binary, "-arch", image["arch"] as? String ?? "arm64", "-l", String(format: "0x%llx", base)]
                + entries.map { String(format: "0x%llx", $0.address) }
            guard let output = try? Shell.xcrun(arguments).stdoutString else { continue }
            for (entry, line) in zip(entries, output.split(separator: "\n")) {
                // "foo() (in App) (File.swift:42)"; atos echoes the address when it can't resolve it.
                guard !line.hasPrefix("0x") else { continue }
                let symbol = line.components(separatedBy: " (in ").first
                let location = line.split(separator: "(").last.flatMap { $0.contains(":") ? String($0.dropLast()) : nil }
                resolved[entry.frame] = (symbol ?? String(line), location)
                symbolicated += 1
            }
        }
        return raw.enumerated().map { i, frame in
            let index = frame["imageIndex"] as? Int ?? -1
            let image = index >= 0 && index < images.count ? images[index] : [:]
            let address = ((image["base"] as? NSNumber)?.uint64Value).flatMap { base in
                (frame["imageOffset"] as? NSNumber).map { String(format: "0x%llx", base + $0.uint64Value) }
            }
            let symbol = frame["symbol"] as? String ?? resolved[i]?.0
            var location = resolved[i]?.1
            if location == nil, let file = frame["sourceFile"] as? String, let line = frame["sourceLine"] as? Int { location = "\(file):\(line)" }
            return CrashReport.Frame(image: image["name"] as? String ?? "???", symbol: symbol, address: address, location: location)
        }
    }

    /// Where to read symbols for an image: its dSYM (found by UUID through Spotlight), else the binary
    /// itself when it's on this Mac (simulator builds run from DerivedData).
    static func symbolFile(uuid: String?, path: String?, name: String?) -> String? {
        if let uuid,
           let found = try? Shell.run("/usr/bin/mdfind", ["com_apple_xcode_dsym_uuids == \(uuid.uppercased())"]).stdoutString
            .split(separator: "\n").first.map(String.init) {
            let dwarf = URL(fileURLWithPath: found).appendingPathComponent("Contents/Resources/DWARF")
            if let file = try? FileManager.default.contentsOfDirectory(atPath: dwarf.path).first(where: { $0 == name }) ?? FileManager.default.contentsOfDirectory(atPath: dwarf.path).first {
                return dwarf.appendingPathComponent(file).path
            }
        }
        // Reports hide the user's name: /Users/USER/… is this Mac's home folder.
        if let path = path.map({ $0.replacingOccurrences(of: "/Users/USER/", with: FileManager.default.homeDirectoryForCurrentUser.path + "/") }),
           FileManager.default.fileExists(atPath: path) { return path }
        return nil
    }
}
