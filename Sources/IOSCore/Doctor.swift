import Foundation

/// One finding of `ios doctor`.
public struct DoctorCheck: Codable, Sendable {
    /// "ok", "warn" (some commands won't work) or "fail" (most commands won't work).
    public let status: String
    public let area: String
    public let summary: String
    public let fix: String?

    static func ok(_ area: String, _ summary: String) -> DoctorCheck { .init(status: "ok", area: area, summary: summary, fix: nil) }
    static func warn(_ area: String, _ summary: String, fix: String?) -> DoctorCheck { .init(status: "warn", area: area, summary: summary, fix: fix) }
    static func fail(_ area: String, _ summary: String, fix: String?) -> DoctorCheck { .init(status: "fail", area: area, summary: summary, fix: fix) }
}

/// Read-only checks of everything ios-cli depends on; nothing is changed.
public enum Doctor {
    public static func run(version: String, skillsDirectory: URL, checkBridge: Bool, checkLatest: Bool,
                           progress: (String) -> Void = { _ in }) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        func attempt(_ area: String, _ body: () throws -> [DoctorCheck]) {
            do { checks += try body() } catch { checks.append(.fail(area, "\(error)", fix: nil)) }
        }
        attempt("xcode") { try xcode() }
        guard !checks.contains(where: { $0.area == "xcode" && $0.status == "fail" }) else { return checks }
        attempt("simulators") { [try simulators()] }
        attempt("devices") { try devices() }
        attempt("signing") { [signing()] }
        if checkBridge {
            progress("Checking Xcode's tool service…")
            attempt("bridge") { [bridge()] }
        }
        attempt("docs") { [docs()] }
        attempt("skills") { [try skills(in: skillsDirectory)] }
        attempt("install") { install(version: version, checkLatest: checkLatest) }
        return checks
    }

    // MARK: Checks

    static func xcode() throws -> [DoctorCheck] {
        let directory = (try? Shell.run("/usr/bin/xcode-select", ["-p"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        if directory.isEmpty || directory.hasPrefix("/Library/Developer/CommandLineTools") {
            return [.fail("xcode", "The selected developer directory is \(directory.isEmpty ? "unset" : "the Command Line Tools"), not Xcode",
                          fix: "sudo xcode-select -s /Applications/Xcode.app")]
        }
        let info = try XcodeInfo.load()
        let app = URL(fileURLWithPath: directory).deletingLastPathComponent().deletingLastPathComponent().path
        var out: [DoctorCheck] = []
        let major = Int(info.version.split(separator: ".").first ?? "") ?? 0
        if major < 27 {
            out.append(.warn("xcode", "Xcode \(info.version) (\(info.build)) at \(app)",
                             fix: "preview, create, check and layout --voiceover need Xcode 27; select it with sudo xcode-select -s <Xcode 27>.app"))
        } else {
            out.append(.ok("xcode", "Xcode \(info.version) (\(info.build)) at \(app)"))
        }
        let firstLaunch = try Shell.run("/usr/bin/xcrun", ["xcodebuild", "-checkFirstLaunchStatus"])
        out.append(firstLaunch.status == 0
            ? .ok("xcode", "Xcode's first-launch setup is done")
            : .fail("xcode", "Xcode's first-launch setup (license, system components) isn't done", fix: "sudo xcodebuild -runFirstLaunch"))
        return out
    }

    static func simulators() throws -> DoctorCheck {
        let simulators = try SimulatorList.load().filter { $0.runtime.contains("iOS") }
        let versions = Array(Set(simulators.compactMap(\.osVersion))).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        guard !versions.isEmpty else {
            return .fail("simulators", "No iOS simulator runtime is installed",
                         fix: "xcodebuild -downloadPlatform iOS (or Xcode → Settings → Components)")
        }
        let booted = simulators.filter(\.isBooted).count
        return .ok("simulators", "iOS simulators: \(simulators.count) on iOS \(versions.joined(separator: ", ")); \(booted) booted")
    }

    static func devices() throws -> [DoctorCheck] {
        let devices = try DeviceList.load().filter(\.isConnected)
        if devices.isEmpty { return [.ok("devices", "No physical device connected (only needed for device runs)")] }
        return devices.map { device in
            let label = "\(device.name) (iOS \(device.osVersion ?? "?"), \(device.transport ?? "?"))"
            if let mode = device.developerMode, mode != "enabled" {
                return .warn("devices", "\(label): Developer Mode is \(mode)",
                             fix: "On the device: Settings → Privacy & Security → Developer Mode, then restart it")
            }
            return .ok("devices", "\(label): connected, Developer Mode on. For layout/input also turn on Settings → Developer → Enable UI Automation")
        }
    }

    static func signing() -> DoctorCheck {
        let identities = (try? Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).stdoutString) ?? ""
        let development = identities.split(separator: "\n").filter { $0.contains("\"Apple Development") }.count
        let teams = localProfileTeams()
        let teamText = teams.isEmpty ? "no development profiles yet" : "teams in local profiles: " + teams.map(\.label).joined(separator: ", ")
        guard development > 0 else {
            return .warn("signing", "No Apple Development signing identity (\(teamText))",
                         fix: "Needed only for physical devices: sign in to Xcode → Settings → Accounts and add a development certificate")
        }
        return .ok("signing", "\(development) development identit\(development == 1 ? "y" : "ies"); \(teamText). "
                   + "Device builds use the project's team or --team; ios-cli doesn't pick one for an app")
    }

    static func bridge() -> DoctorCheck {
        do {
            let bridge = try XcodeBridge()
            _ = try bridge.call("XcodeListWorkspaces")
            return .ok("bridge", "Xcode's tool service answers and has approved ios (preview, create, check)")
        } catch let error as IOSError {
            if case .bridgeNotApproved = error {
                // Xcode approves each binary build separately, and approvals of unsigned binaries expire after
                // a day, so this comes back after every update and daily.
                return .warn("bridge", "Xcode hasn't approved this ios binary for its tool service (needed by preview, create, check). "
                             + "Approvals are per build of ios and expire after 24 hours",
                             fix: "Run `ios check <File.swift>` (or `ios preview`) in a project and approve Xcode's dialog; "
                                + "`xcrun mcp-server status` lists current approvals")
            }
            return .warn("bridge", "Xcode's tool service failed: \(error)", fix: "Needs Xcode 27; open Xcode once, then retry")
        } catch {
            return .warn("bridge", "Xcode's tool service failed: \(error)", fix: nil)
        }
    }

    static func docs() -> DoctorCheck {
        let path = DocsPaths.indexDatabase
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let modified = attributes[.modificationDate] as? Date else {
            return .warn("docs", "The docs index isn't built (docs search/fetch need it)", fix: "ios docs update (~40 s, ~140 MB download)")
        }
        let days = Int(Date().timeIntervalSince(modified) / 86_400)
        let size = ByteCountFormatter.string(fromByteCount: (attributes[.size] as? Int64) ?? 0, countStyle: .file)
        if days > 60 { return .warn("docs", "The docs index is \(days) days old (\(size))", fix: "ios docs update") }
        return .ok("docs", "Docs index: \(size), updated \(days == 0 ? "today" : "\(days) day\(days == 1 ? "" : "s") ago")")
    }

    static func skills(in directory: URL) throws -> DoctorCheck {
        let installed = try SkillManager.list(in: directory).filter(\.installed)
        guard installed.contains(where: { $0.name == "ios-cli" }) else {
            return .warn("skills", "The ios-cli agent skill isn't installed in \(directory.path)",
                         fix: "ios skills add ios-cli (teaches Claude Code how to use ios)")
        }
        let outdated = try SkillManager.outdated(in: directory)
        if !outdated.isEmpty {
            return .warn("skills", "Installed skills differ from this version's: \(outdated.joined(separator: ", "))", fix: "ios skills update")
        }
        return .ok("skills", "Skills installed and current: \(installed.map(\.name).joined(separator: ", "))")
    }

    static func install(version: String, checkLatest: Bool) -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        let running = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let onPath = (try? Shell.run("/usr/bin/which", ["ios"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        if onPath.isEmpty {
            out.append(.warn("install", "ios \(version) isn't on PATH (running \(running))",
                             fix: "Add its folder to PATH, e.g. export PATH=\"$HOME/.local/bin:$PATH\" in ~/.zshrc"))
        } else if URL(fileURLWithPath: onPath).resolvingSymlinksInPath().path != running && !running.contains("/.build/") {
            out.append(.warn("install", "`ios` on PATH is \(onPath), not this binary (\(running))", fix: "Remove the other copy or reorder PATH"))
        } else {
            out.append(.ok("install", "ios \(version) at \(onPath)"))
        }
        if checkLatest, let latest = latestRelease() {
            if latest.compare(version, options: .numeric) == .orderedDescending {
                out.append(.warn("install", "ios \(latest) is available (you have \(version))",
                                 fix: "curl -fsSL https://github.com/alejandrorangel/ios-cli/releases/latest/download/get.sh | sh"))
            } else {
                out.append(.ok("install", "Up to date with the latest release (\(latest))"))
            }
        }
        return out
    }

    // MARK: Helpers

    /// The newest release's version from GitHub, or nil offline (5 s timeout).
    static func latestRelease() -> String? {
        guard let url = URL(string: "https://api.github.com/repos/alejandrorangel/ios-cli/releases/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("ios-cli", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        let box = LockedText()
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = object["tag_name"] as? String {
                _ = box.append(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.text.isEmpty ? nil : box.text
    }

    /// Teams with a valid local development profile, with names. Reported, never chosen.
    static func localProfileTeams() -> [RunnerBuild.DetectedTeam] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var teams = Set<RunnerBuild.DetectedTeam>()
        for dir in ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"] {
            let folder = home.appendingPathComponent(dir)
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "mobileprovision" {
                guard let decoded = try? Shell.run("/usr/bin/security", ["cms", "-D", "-i", file.path]), decoded.status == 0,
                      let plist = try? PropertyListSerialization.propertyList(from: decoded.stdout, format: nil) as? [String: Any],
                      let expiry = plist["ExpirationDate"] as? Date, expiry > Date(),
                      let team = (plist["TeamIdentifier"] as? [String])?.first else { continue }
                teams.insert(RunnerBuild.DetectedTeam(id: team, name: plist["TeamName"] as? String))
            }
        }
        return teams.sorted { $0.id < $1.id }
    }
}
