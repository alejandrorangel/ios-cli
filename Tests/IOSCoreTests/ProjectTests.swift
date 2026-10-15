import Foundation
import Testing
@testable import IOSCore

// MARK: xcodebuild output parsing (samples trimmed from a workspace and a template app)

@Test func parsesWorkspaceAndProjectListings() throws {
    let workspace = try Describer.parseListing(Data(#"{"workspace": {"name": "Sample", "schemes": ["SampleApp", "SampleApp-Dev"]}}"#.utf8))
    #expect(workspace.name == "Sample")
    #expect(workspace.schemes == ["SampleApp", "SampleApp-Dev"])
    #expect(workspace.targets == nil)

    let project = try Describer.parseListing(Data(#"""
    {"project": {"name": "SpikeApp", "schemes": ["SpikeApp"], "targets": ["SpikeApp", "SpikeAppTests"],
                 "configurations": ["Debug", "Release"]}}
    """#.utf8))
    #expect(project.targets == ["SpikeApp", "SpikeAppTests"])
    #expect(project.configurations == ["Debug", "Release"])
}

@Test func keepsOnlyApplicationTargetsFromBuildSettings() throws {
    let json = #"""
    [
      {"action": "build", "target": "SampleApp-Dev", "buildSettings": {
        "PRODUCT_TYPE": "com.apple.product-type.application",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.example.sampleapp.dev",
        "FULL_PRODUCT_NAME": "SampleApp-Dev.app",
        "TARGET_BUILD_DIR": "/DD/Build/Products/Debug-iphonesimulator",
        "CONFIGURATION": "Debug", "PLATFORM_NAME": "iphonesimulator",
        "IPHONEOS_DEPLOYMENT_TARGET": "16.6"}},
      {"action": "build", "target": "CoreKit", "buildSettings": {
        "PRODUCT_TYPE": "com.apple.product-type.framework",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.example.CoreKit",
        "FULL_PRODUCT_NAME": "CoreKit.framework",
        "TARGET_BUILD_DIR": "/DD/Build/Products/Debug-iphonesimulator"}}
    ]
    """#
    let products = try Describer.parseBuildSettings(Data(json.utf8))
    #expect(products.count == 1)
    let app = try #require(products.first)
    #expect(app.bundleIdentifier == "com.example.sampleapp.dev")
    #expect(app.path == "/DD/Build/Products/Debug-iphonesimulator/SampleApp-Dev.app")
    #expect(app.sdk == "iphonesimulator")
    #expect(app.deploymentTarget == "16.6")
}

@Test func parsesAndDeduplicatesDiagnostics() {
    let log = """
    CompileSwift normal arm64 /src/A.swift
    /src/A.swift:26:19: error: cannot convert value of type 'String' to specified type 'Int'
    /src/B.swift:3:1: warning: 'foo' is deprecated
    ** BUILD FAILED **
    The following build commands failed:
    /src/A.swift:26:19: error: cannot convert value of type 'String' to specified type 'Int'
    error: No profiles for 'com.example.app' were found
    xcodebuild: error: Unable to find a destination matching the provided destination specifier
    """
    let diagnostics = Builder.parseDiagnostics(log)
    let errors = diagnostics.filter { $0.severity == "error" }
    #expect(errors.count == 3) // repeated compiler error counted once
    #expect(errors[0].file == "/src/A.swift")
    #expect(errors[0].line == 26)
    #expect(errors[0].column == 19)
    #expect(errors[1].file == nil)
    #expect(errors[1].message == "No profiles for 'com.example.app' were found")
    #expect(diagnostics.filter { $0.severity == "warning" }.count == 1)
}

@Test func parsesLaunchProcessIDs() {
    #expect(Launcher.parseSimctlPid("com.example.sampleapp: 40738\n") == 40738)
    #expect(Launcher.parseSimctlPid("garbage") == nil)
    let devicectl = Data(#"{"result": {"process": {"processIdentifier": 1001}}}"#.utf8)
    #expect(Launcher.parseDevicectlPid(devicectl) == 1001)
}

// MARK: Scheme and destination selection

private let listing = SchemeListing(name: "Sample", schemes: ["SampleApp", "SampleApp-Dev"], targets: nil, configurations: nil)

@Test func requiresSchemeWhenSeveralExist() throws {
    #expect(throws: IOSError.self) { try Describer.resolveScheme(nil, in: listing) }
    #expect(throws: IOSError.self) { try Describer.resolveScheme("Nope", in: listing) }
    #expect(try Describer.resolveScheme("SampleApp-Dev", in: listing) == "SampleApp-Dev")
    let single = SchemeListing(name: "App", schemes: ["App"], targets: nil, configurations: nil)
    #expect(try Describer.resolveScheme(nil, in: single) == "App")
}

@Test func picksAppMatchingSchemeName() throws {
    func app(_ target: String) -> AppProduct {
        AppProduct(target: target, bundleIdentifier: "id.\(target)", productName: "\(target).app",
                   path: "/p/\(target).app", configuration: "Debug", sdk: "iphonesimulator", deploymentTarget: nil)
    }
    #expect(try Describer.primaryApp([app("Other"), app("SampleApp-Dev")], scheme: "SampleApp-Dev").target == "SampleApp-Dev")
    #expect(try Describer.primaryApp([app("Only")], scheme: "SampleApp-Dev").target == "Only")
    #expect(throws: IOSError.self) { try Describer.primaryApp([], scheme: "SampleApp-Dev") }
}

@Test func buildsDestinationSpecifiers() {
    let sim = Simulator(udid: "SIM", name: "iPhone", state: "Booted", runtime: "iOS", osVersion: "27.0", deviceType: nil)
    #expect(Destination.target(.simulator(sim)).xcodebuildValue == "platform=iOS Simulator,id=SIM")
    #expect(Destination.target(.simulator(sim)).sdk == "iphonesimulator")
    #expect(Destination.genericDevice.xcodebuildValue == "generic/platform=iOS")
    #expect(Destination.genericDevice.sdk == "iphoneos")
}

// MARK: Project location and cache invalidation (temp directories)

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func locatesWorkspaceBeforeProjectBeforePackage() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent("Package.swift"))
    #expect(try ProjectLocator.locate(workspace: nil, project: nil, directory: dir.path).kind == "package")

    try FileManager.default.createDirectory(at: dir.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
    #expect(try ProjectLocator.locate(workspace: nil, project: nil, directory: dir.path).kind == "project")

    try FileManager.default.createDirectory(at: dir.appendingPathComponent("App.xcworkspace"), withIntermediateDirectories: true)
    let container = try ProjectLocator.locate(workspace: nil, project: nil, directory: dir.path)
    #expect(container.kind == "workspace")
    #expect(container.xcodebuildArguments.first == "-workspace")
}

@Test func failsWithoutAnyContainer() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: IOSError.self) { try ProjectLocator.locate(workspace: nil, project: nil, directory: dir.path) }
}

@Test func fingerprintTracksProjectFilesOnly() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let proj = dir.appendingPathComponent("App.xcodeproj")
    try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    try Data("a".utf8).write(to: proj.appendingPathComponent("project.pbxproj"))

    let first = ProjectFingerprint.compute(root: dir.path)
    try Data("source".utf8).write(to: dir.appendingPathComponent("Main.swift"))
    #expect(ProjectFingerprint.compute(root: dir.path) == first) // source edits don't invalidate

    // Hidden folders (e.g. agent worktrees) are ignored.
    let hidden = dir.appendingPathComponent(".claude/worktrees/x/App.xcodeproj")
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try Data("b".utf8).write(to: hidden.appendingPathComponent("project.pbxproj"))
    #expect(ProjectFingerprint.compute(root: dir.path) == first)

    try Data("changed".utf8).write(to: proj.appendingPathComponent("project.pbxproj"))
    #expect(ProjectFingerprint.compute(root: dir.path) != first)
}

@Test func cacheReturnsValueOnlyForMatchingFingerprint() throws {
    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = MetadataCache(directory: dir)
    cache.write(["a", "b"], key: "k", fingerprint: "f1")
    #expect(cache.read([String].self, key: "k", fingerprint: "f1") == ["a", "b"])
    #expect(cache.read([String].self, key: "k", fingerprint: "f2") == nil)
    #expect(cache.read([String].self, key: "other", fingerprint: "f1") == nil)
}
