import Foundation

public struct PreviewRequest: Sendable {
    public let container: Container
    public let file: String
    public let index: Int
    public let locale: String?
    /// Variant group → value, e.g. ["Color Scheme": "Dark"]; names come from a previous render.
    public let variants: [String: String]
    public let timeout: Int

    public init(container: Container, file: String, index: Int, locale: String?, variants: [String: String], timeout: Int) {
        self.container = container
        self.file = file
        self.index = index
        self.locale = locale
        self.variants = variants
        self.timeout = timeout
    }
}

public struct PreviewResult: Codable, Sendable {
    public let image: String
    public let displayName: String?
    public let sourceFile: String
    public let line: Int?
    public let destination: String?
    /// What can be passed back as --locale / --variant.
    public let supportedLocales: [String]
    public let supportedVariants: [String: [String]]
}

public enum Previews {
    /// Renders a SwiftUI preview through Xcode and copies the snapshot to `output`.
    public static func render(_ request: PreviewRequest, output: String) throws -> PreviewResult {
        let bridge = try XcodeBridge()
        let workspace = try bridge.openWorkspace(request.container.path)
        let navigatorPath = try projectPath(of: request.file, in: workspace, bridge: bridge)

        var arguments: [String: Any] = [
            "workspaceIdentifier": workspace, "sourceFilePath": navigatorPath,
            "previewDefinitionIndexInFile": request.index, "timeout": request.timeout,
        ]
        if let locale = request.locale { arguments["previewLocalizationOverride"] = locale }
        if !request.variants.isEmpty { arguments["previewVariantOverrides"] = request.variants }
        let result = try bridge.call("RenderPreview", arguments)

        let errors = (result["errors"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
        guard let snapshot = result["previewSnapshotPath"] as? String, errors.isEmpty else {
            throw IOSError.bridgeFailed(tool: "RenderPreview", message: errors.isEmpty ? "no snapshot produced" : errors.joined(separator: "\n"))
        }
        let destination = URL(fileURLWithPath: output).standardizedFileURL
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: snapshot), to: destination)

        let rendered = result["renderedDestination"] as? [String: Any]
        let destinationText = [rendered?["deviceModelName"], rendered?["platformName"], rendered?["systemVersion"]]
            .compactMap { $0 as? String }.joined(separator: ", ")
        return PreviewResult(
            image: destination.path, displayName: result["displayName"] as? String, sourceFile: navigatorPath,
            line: result["sourceLineNumber"] as? Int, destination: destinationText.isEmpty ? nil : destinationText,
            supportedLocales: result["supportedLocalizations"] as? [String] ?? [],
            supportedVariants: variants(result["supportedPreviewVariantOverrides"])
        )
    }

    /// RenderPreview takes the file's path in the project navigator ("App/Views/Home.swift"),
    /// not on disk; find it by file name and pick the match whose folders fit the given path.
    static func projectPath(of file: String, in workspace: String, bridge: XcodeBridge) throws -> String {
        let name = (file as NSString).lastPathComponent
        let result = try bridge.call("XcodeGlob", ["workspaceIdentifier": workspace, "pattern": "**/\(name)"])
        let matches = result["matches"] as? [String] ?? []
        guard let best = bestMatch(for: file, among: matches) else {
            throw IOSError.bridgeFailed(tool: "XcodeGlob", message: "\(name) isn't part of the project")
        }
        return best
    }

    /// The candidate sharing the longest run of trailing path components with `file`.
    static func bestMatch(for file: String, among candidates: [String]) -> String? {
        let wanted = Array(URL(fileURLWithPath: file).standardizedFileURL.pathComponents.reversed())
        func score(_ candidate: String) -> Int {
            zip(wanted, candidate.split(separator: "/").reversed()).prefix { $0 == String($1) }.count
        }
        return candidates.max { score($0) < score($1) }.flatMap { score($0) > 0 ? $0 : nil }
    }

    /// Accepts the variant overrides in either shape Xcode may return: a dictionary of
    /// group → values, or a list of {name, values}.
    static func variants(_ value: Any?) -> [String: [String]] {
        if let dict = value as? [String: [String]] { return dict }
        if let dict = value as? [String: Any] {
            return dict.compactMapValues { ($0 as? [String]) ?? ($0 as? [[String: Any]])?.compactMap { $0["name"] as? String } }
        }
        if let list = value as? [[String: Any]] {
            var out: [String: [String]] = [:]
            for group in list {
                guard let name = group["name"] as? String ?? group["group"] as? String else { continue }
                out[name] = (group["values"] as? [String]) ?? (group["variants"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            }
            return out
        }
        return [:]
    }
}
