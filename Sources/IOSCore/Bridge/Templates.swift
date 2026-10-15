import Foundation

public struct ProjectTemplate: Codable, Sendable {
    public struct Option: Codable, Sendable {
        public let identifier: String
        public let name: String
        public let type: String
        public let defaultValue: String?
        public let possibleValues: [String]?
    }

    public let identifier: String
    public let name: String
    public let category: String
    public let platforms: [String]
    public let options: [Option]
}

public struct CreateRequest: Sendable {
    public let name: String
    public let template: String
    public let directory: String
    public let organization: String?
    public let team: String?
    public let options: [String: String]

    public init(name: String, template: String, directory: String, organization: String?, team: String?, options: [String: String]) {
        self.name = name
        self.template = template
        self.directory = directory
        self.organization = organization
        self.team = team
        self.options = options
    }
}

public struct CreateResult: Codable, Sendable {
    public let project: String
    public let targets: [String]
    public let template: String
}

public enum Templates {
    /// Short names for common Xcode 27 project templates; any full identifier works too.
    public static let aliases: [String: String] = [
        "app": "com.apple.dt.unit.multiPlatform.app", // Xcode 27's default "App" (iOS, macOS, visionOS…)
        "ios-app": "com.apple.dt.unit.singleViewApplication",
        "document-app": "com.apple.dt.unit.multiPlatform.app.document-based",
        "game": "com.apple.dt.unit.ios.game",
        "framework": "com.apple.dt.unit.iosFramework",
        "multiplatform-framework": "com.apple.dt.unit.multiPlatform.framework",
        "empty": "com.apple.dt.unit.emptyProject",
    ]

    public static func resolve(_ template: String) -> String { aliases[template.lowercased()] ?? template }

    /// Project templates; options are only reported for filtered queries, so filter by platform.
    public static func list(platform: String?, name: String?) throws -> [ProjectTemplate] {
        var arguments: [String: Any] = ["kind": "project"]
        if let platform { arguments["platformFilter"] = [platform] }
        if let name { arguments["nameFilter"] = name }
        let result = try XcodeBridge().call("XcodeListTemplates", arguments)
        return (result["templates"] as? [[String: Any]] ?? []).map { t in
            ProjectTemplate(
                identifier: t["identifier"] as? String ?? "", name: t["templateName"] as? String ?? "",
                category: t["templateCategory"] as? String ?? "", platforms: t["platforms"] as? [String] ?? [],
                options: (t["options"] as? [[String: Any]] ?? []).compactMap { o in
                    guard let id = o["identifier"] as? String, !["productName", "bundleIdentifierPrefix"].contains(id) else { return nil }
                    return .init(identifier: id, name: o["name"] as? String ?? id, type: o["type"] as? String ?? "",
                                 defaultValue: o["defaultValue"] as? String, possibleValues: o["possibleValues"] as? [String])
                }
            )
        }
    }

    /// Creates a project from a template with Xcode's own template engine.
    public static func create(_ request: CreateRequest) throws -> CreateResult {
        let template = resolve(request.template)
        var arguments: [String: Any] = [
            "templateIdentifier": template, "productName": request.name,
            "destinationPath": URL(fileURLWithPath: request.directory).standardizedFileURL.path,
        ]
        if let organization = request.organization { arguments["organizationIdentifier"] = organization }
        if let team = request.team { arguments["teamIdentifier"] = team }
        if !request.options.isEmpty { arguments["options"] = request.options }
        let result = try XcodeBridge().call("XcodeNewProject", arguments)
        guard let project = result["projectPath"] as? String else {
            throw IOSError.bridgeFailed(tool: "XcodeNewProject", message: "no project path returned")
        }
        return CreateResult(project: project, targets: result["createdTargets"] as? [String] ?? [], template: template)
    }
}
