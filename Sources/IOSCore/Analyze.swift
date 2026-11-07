import Foundation

/// What's inside a built app: identity, size by part, signing, entitlements and privacy manifests.
/// Reads an .app, an .ipa or an .xcarchive; nothing is sent anywhere.
public struct AppAnalysis: Codable, Sendable {
    public struct Identity: Codable, Sendable {
        public let name: String?
        public let bundleID: String?
        public let version: String?
        public let build: String?
        public let minimumOS: String?
        public let platform: String?
        public let sdk: String?
        public let xcode: String?
        public let deviceFamilies: [String]
        public let architectures: [String]
    }

    public struct Part: Codable, Sendable {
        public let path: String
        public let kind: String
        public let bytes: Int64
        /// Whether a PrivacyInfo.xcprivacy ships in it (frameworks and extensions).
        public let privacyManifest: Bool?
    }

    public struct Signing: Codable, Sendable {
        /// "adhoc", "development", "distribution" or "unsigned".
        public let kind: String
        public let authority: String?
        public let teamID: String?
        public let profile: Profile?
        public let entitlements: [String: String]

        public struct Profile: Codable, Sendable {
            public let name: String?
            public let teamName: String?
            public let expires: Date?
            public let devices: Int?
            public let allDevices: Bool
        }
    }

    public let path: String
    /// The .app analysed (inside the .ipa or archive, when given one).
    public let app: String
    public let identity: Identity
    /// Size on disk of the .app.
    public let bytes: Int64
    /// Size of the .ipa file itself, when one was given.
    public let downloadBytes: Int64?
    public let parts: [Part]
    public let largestFiles: [Part]
    public let signing: Signing
    public let privacyManifest: Bool
    /// Libraries loaded by @rpath (embedded frameworks and dylibs), from the executable's load commands.
    public let embeddedLibraries: [String]
    /// Debug symbols in the archive (.xcarchive only).
    public let dSYMs: [String]?
    public let notes: [String]
}

public enum Analyze {
    public static func run(_ input: String) throws -> AppAnalysis {
        let url = URL(fileURLWithPath: input).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw IOSError.failed("No file at \(url.path).")
        }
        switch url.pathExtension.lowercased() {
        case "app":
            return try analyze(app: url, input: url, downloadBytes: nil, dSYMs: nil)
        case "ipa":
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-analyze-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            try Shell.checked("/usr/bin/ditto", ["-x", "-k", url.path, scratch.path])
            let app = try onlyApp(in: scratch.appendingPathComponent("Payload"), input: url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            return try analyze(app: app, input: url, downloadBytes: size, dSYMs: nil,
                               shownAs: url.path + "/Payload/" + app.lastPathComponent)
        case "xcarchive":
            let app = try onlyApp(in: url.appendingPathComponent("Products/Applications"), input: url)
            let dSYMs = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("dSYMs").path))?.sorted() ?? []
            return try analyze(app: app, input: url, downloadBytes: nil, dSYMs: dSYMs)
        default:
            throw IOSError.failed("\(url.lastPathComponent) isn't an .app, .ipa or .xcarchive.")
        }
    }

    private static func onlyApp(in directory: URL, input: URL) throws -> URL {
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".app") }
        guard let first = apps.sorted().first else { throw IOSError.failed("No .app inside \(input.lastPathComponent).") }
        return directory.appendingPathComponent(first)
    }

    /// `shownAs` names the .app in the report when it was unpacked to a temporary folder.
    static func analyze(app: URL, input: URL, downloadBytes: Int64?, dSYMs: [String]?, shownAs: String? = nil) throws -> AppAnalysis {
        let info = plist(app.appendingPathComponent("Info.plist")) ?? [:]
        let executableName = info["CFBundleExecutable"] as? String ?? app.deletingPathExtension().lastPathComponent
        let executable = app.appendingPathComponent(executableName)
        let architectures = (try? Shell.run("/usr/bin/lipo", ["-archs", executable.path]))
            .map { $0.stdoutString.split(whereSeparator: \.isWhitespace).map(String.init) } ?? []
        let families = (info["UIDeviceFamily"] as? [Int] ?? []).map { [1: "iPhone", 2: "iPad", 3: "TV", 4: "Watch", 6: "Mac", 7: "Vision"][$0] ?? "\($0)" }
        let identity = AppAnalysis.Identity(
            name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String, bundleID: info["CFBundleIdentifier"] as? String,
            version: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String,
            minimumOS: info["MinimumOSVersion"] as? String, platform: info["DTPlatformName"] as? String,
            sdk: info["DTSDKName"] as? String, xcode: info["DTXcode"] as? String,
            deviceFamilies: families, architectures: architectures
        )

        let files = allFiles(in: app)
        let total = files.reduce(0) { $0 + $1.bytes }
        let parts = breakdown(app: app, executable: executableName, files: files)
        let largest = files.sorted { $0.bytes > $1.bytes }.prefix(10).map {
            AppAnalysis.Part(path: $0.path, kind: kind(of: $0.path, executable: executableName), bytes: $0.bytes, privacyManifest: nil)
        }
        let signing = signingInfo(app)
        let libraries = (try? Shell.xcrun(["otool", "-L", executable.path]))?.stdoutString
            .split(separator: "\n").dropFirst()
            .compactMap { line -> String? in
                let path = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " (").first ?? ""
                return path.hasPrefix("@rpath/") ? String(path.dropFirst("@rpath/".count)) : nil
            } ?? []
        let privacy = FileManager.default.fileExists(atPath: app.appendingPathComponent("PrivacyInfo.xcprivacy").path)
        let analysis = AppAnalysis(
            path: input.path, app: shownAs ?? app.path, identity: identity, bytes: total, downloadBytes: downloadBytes,
            parts: parts, largestFiles: Array(largest), signing: signing, privacyManifest: privacy,
            embeddedLibraries: libraries, dSYMs: dSYMs, notes: []
        )
        return withNotes(analysis)
    }

    /// Things worth a second look, in plain words.
    static func withNotes(_ a: AppAnalysis) -> AppAnalysis {
        var notes: [String] = []
        if a.identity.platform?.hasSuffix("simulator") == true {
            notes.append("A simulator build: it won't install on a device or go to the App Store.")
        }
        if a.signing.entitlements["get-task-allow"] == "true" {
            notes.append("get-task-allow is on: a debuggable development build, not one for TestFlight or the App Store.")
        }
        if let dylib = a.parts.first(where: { $0.kind == "debug dylib" }) {
            notes.append("The code is in \(dylib.path) (ENABLE_DEBUG_DYLIB, for previews): a Debug build. Release builds link it into the executable.")
        }
        if a.signing.kind == "unsigned" { notes.append("Not signed.") }
        if let expires = a.signing.profile?.expires, expires < Date() {
            notes.append("The provisioning profile expired \(ISO8601DateFormatter().string(from: expires)).")
        }
        if !a.privacyManifest { notes.append("No PrivacyInfo.xcprivacy in the app (App Store Connect requires one for some APIs).") }
        let missing = a.parts.filter { $0.privacyManifest == false && $0.kind == "framework" }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        if !missing.isEmpty { notes.append("Frameworks without a privacy manifest: \(missing.joined(separator: ", ")).") }
        if a.identity.architectures.count > 1, a.identity.platform == "iphoneos" {
            notes.append("The executable has several architectures (\(a.identity.architectures.joined(separator: ", "))); iOS devices need only arm64.")
        }
        return AppAnalysis(path: a.path, app: a.app, identity: a.identity, bytes: a.bytes, downloadBytes: a.downloadBytes, parts: a.parts,
                           largestFiles: a.largestFiles, signing: a.signing, privacyManifest: a.privacyManifest,
                           embeddedLibraries: a.embeddedLibraries, dSYMs: a.dSYMs, notes: notes)
    }

    struct File {
        let path: String // relative to the .app
        let bytes: Int64
    }

    static func allFiles(in app: URL) -> [File] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: keys) else { return [] }
        let root = app.resolvingSymlinksInPath().path + "/"
        var files: [File] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
            files.append(File(path: url.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: ""), bytes: bytes))
        }
        return files
    }

    /// Size by part: the executable, each framework and extension, the asset catalog, and the rest.
    static func breakdown(app: URL, executable: String, files: [File]) -> [AppAnalysis.Part] {
        var groups: [String: (kind: String, bytes: Int64)] = [:]
        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            let key: String, kind: String
            if ["Frameworks", "PlugIns", "Extensions", "Watch", "AppClips"].contains(components.first ?? ""), components.count > 2 {
                key = components[0] + "/" + components[1]
                kind = components[1].hasSuffix(".framework") ? "framework" : components[1].hasSuffix(".dylib") ? "library"
                    : components[1].hasSuffix(".appex") ? "extension" : components[1].hasSuffix(".app") ? "app" : "other"
            } else if components.count > 1, components[0].hasSuffix(".bundle") {
                key = components[0]
                kind = "resource bundle"
            } else if components.first == "Frameworks" {
                key = file.path
                kind = "library"
            } else {
                key = self.kind(of: file.path, executable: executable) == "other" ? "(other files)" : file.path
                kind = self.kind(of: file.path, executable: executable)
            }
            groups[key, default: (kind, 0)].bytes += file.bytes
        }
        return groups.map { key, value in
            let manifest: Bool? = ["framework", "extension"].contains(value.kind)
                ? files.contains { $0.path.hasPrefix(key + "/") && $0.path.hasSuffix("PrivacyInfo.xcprivacy") } : nil
            return AppAnalysis.Part(path: key, kind: value.kind, bytes: value.bytes, privacyManifest: manifest)
        }.sorted { $0.bytes > $1.bytes }
    }

    static func kind(of path: String, executable: String) -> String {
        if path == executable { return "executable" }
        if path == executable + ".debug.dylib" { return "debug dylib" }
        if path.hasSuffix("Assets.car") { return "asset catalog" }
        if path.hasSuffix(".lproj/Localizable.strings") || path.hasSuffix(".lproj/Localizable.stringsdict") { return "localization" }
        if path.contains(".framework/") { return "framework" }
        if path.contains(".appex/") { return "extension" }
        return "other"
    }

    static func signingInfo(_ app: URL) -> AppAnalysis.Signing {
        let details = (try? Shell.run("/usr/bin/codesign", ["-dvv", app.path]))?.stderr ?? ""
        func field(_ name: String) -> [String] {
            details.split(separator: "\n").compactMap { line in
                line.hasPrefix(name + "=") ? String(line.dropFirst(name.count + 1)) : nil
            }
        }
        let authority = field("Authority").first
        let team = field("TeamIdentifier").first.flatMap { $0 == "not set" ? nil : $0 }
        let kind: String
        if details.contains("not signed") || details.isEmpty { kind = "unsigned" }
        else if field("Signature").first == "adhoc" { kind = "adhoc" }
        else if authority?.hasPrefix("Apple Distribution") == true || authority?.hasPrefix("iPhone Distribution") == true
            || authority == "Apple iPhone OS Application Signing" { kind = "distribution" }
        else { kind = "development" }

        var entitlements: [String: String] = [:]
        if let data = (try? Shell.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path]))?.stdout, !data.isEmpty,
           let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            entitlements = dict.mapValues(describe)
        }

        var profile: AppAnalysis.Signing.Profile?
        let embedded = app.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: embedded.path),
           let data = (try? Shell.run("/usr/bin/security", ["cms", "-D", "-i", embedded.path]))?.stdout,
           let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            profile = .init(name: dict["Name"] as? String, teamName: dict["TeamName"] as? String,
                            expires: dict["ExpirationDate"] as? Date, devices: (dict["ProvisionedDevices"] as? [Any])?.count,
                            allDevices: dict["ProvisionsAllDevices"] as? Bool ?? false)
        }
        return .init(kind: kind, authority: authority, teamID: team, profile: profile, entitlements: entitlements)
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let bool as Bool: bool ? "true" : "false"
        case let array as [Any]: array.map(describe).joined(separator: ", ")
        default: "\(value)"
        }
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
