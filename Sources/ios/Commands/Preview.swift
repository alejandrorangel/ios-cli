import ArgumentParser
import Foundation
import IOSCore

struct Preview: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render a SwiftUI #Preview to a PNG through Xcode.",
        discussion: """
        Uses Xcode 27's tool service (no Xcode window needed). The first render builds the project (can take \
        30 s or more); later renders take well under a second. Xcode asks you to approve `ios` the first time. \
        The output lists the locales and variants you can pass back with --locale / --variant.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "Path to an .xcworkspace. Defaults to the one in the current directory.")
    var workspace: String?

    @Option(help: "Path to an .xcodeproj.")
    var project: String?

    @Argument(help: "Swift file containing the preview.")
    var file: String

    @Option(help: "Which preview in the file by position (0 = first #Preview or PreviewProvider).")
    var index: Int?

    @Option(help: "Which preview by name: #Preview(\"Name\") or a PreviewProvider type (exact, else contains).")
    var name: String?

    @Flag(help: "List the file's previews (position, name, line) without rendering.")
    var list = false

    @Option(help: "Locale to render in, e.g. fr or ja (from a previous render's supported locales).")
    var locale: String?

    @Option(help: "Variant override as Group=Value, e.g. \"Color Scheme=Dark\" (repeatable; names from a previous render).")
    var variant: [String] = []

    @Option(name: .shortAndLong, help: "Output PNG. Defaults to <File>-preview.png in the current directory.")
    var output: String?

    @Option(help: "Seconds to wait for the render.")
    var timeout = 180

    func validate() throws {
        if index != nil && name != nil { throw ValidationError("Pass --index or --name, not both.") }
    }

    func run() throws {
        let definitions = Previews.definitions(inSource: (try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
        if list {
            try Output.emit(definitions, json: global.json) {
                definitions.isEmpty ? "No #Preview or PreviewProvider in \(file)." : definitions.map(Previews.describe).joined(separator: "\n")
            }
            return
        }
        let position = try name.map { try Previews.index(named: $0, in: definitions) } ?? index ?? 0
        let container = try ProjectLocator.locate(workspace: workspace, project: project,
                                                  directory: FileManager.default.currentDirectoryPath)
        var variants: [String: String] = [:]
        for pair in variant {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { throw ValidationError("--variant must look like Group=Value") }
            variants[parts[0]] = parts[1]
        }
        let base = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        let destination = output ?? "\(base)-preview.png"

        Docs.progress("Rendering \(base) preview #\(position)\(name.map { " (\"\($0)\")" } ?? "") with Xcode…")
        let result = try Previews.render(
            PreviewRequest(container: container, file: file, index: position, locale: locale, variants: variants, timeout: timeout),
            output: destination
        )
        try Output.emit(result, json: global.json) {
            var lines = ["Saved \(result.image)"]
            lines.append("Preview: \(result.displayName ?? base)" + (result.line.map { " (line \($0))" } ?? "")
                         + (result.destination.map { " on \($0)" } ?? ""))
            if !result.supportedLocales.isEmpty { lines.append("Locales: \(result.supportedLocales.joined(separator: ", "))") }
            for (group, values) in result.supportedVariants.sorted(by: { $0.key < $1.key }) {
                lines.append("Variant \(group): \(values.joined(separator: ", "))")
            }
            return lines.joined(separator: "\n")
        }
    }
}

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a new Xcode project from Xcode's templates.",
        discussion: """
        Templates: \(Templates.aliases.keys.sorted().joined(separator: ", ")), or any identifier from --list-templates. \
        Xcode 27's default "app" template is multiplatform (iOS, macOS, visionOS); use ios-app for iPhone/iPad only.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Product name, e.g. MyApp.")
    var name: String?

    @Option(help: "Template name or identifier.")
    var template = "app"

    @Option(name: .shortAndLong, help: "Directory to create the project in (a folder named after the product is created there).")
    var output = "."

    @Option(help: "Organization identifier used as the bundle ID prefix, e.g. com.example.")
    var org: String?

    @Option(help: "Development team ID for signing.")
    var team: String?

    @Option(help: "Storage: none, swiftdata or coredata (app templates).")
    var storage: String?

    @Option(help: "Testing system: none, xctest or swift-testing (app templates).")
    var testing: String?

    @Option(help: "Other template option as key=value (repeatable; see --list-templates).")
    var option: [String] = []

    @Flag(help: "List project templates and their options instead of creating a project.")
    var listTemplates = false

    @Option(help: "With --list-templates: platform to list, e.g. ios, macos, visionos.")
    var platform = "ios"

    func run() throws {
        if listTemplates { return try list() }
        guard let name else { throw ValidationError("Pass a product name, e.g. `ios create MyApp`.") }

        var options: [String: String] = [:]
        if let storage {
            let values = ["none": "None", "swiftdata": "SwiftData", "coredata": "Core Data"]
            guard let value = values[storage.lowercased()] else { throw ValidationError("--storage must be none, swiftdata or coredata") }
            options["storageType"] = value
        }
        if let testing {
            let values = ["none": "None", "xctest": "XCTest", "swift-testing": "Swift Testing"]
            guard let value = values[testing.lowercased()] else { throw ValidationError("--testing must be none, xctest or swift-testing") }
            options["testingSystem"] = value
        }
        for pair in option {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ValidationError("--option must look like key=value") }
            options[parts[0]] = parts[1]
        }

        let result = try Templates.create(CreateRequest(name: name, template: template, directory: output,
                                                        organization: org, team: team, options: options))
        try Output.emit(result, json: global.json) {
            "Created \(result.project)\nTargets: \(result.targets.joined(separator: ", "))\nTemplate: \(result.template)"
        }
    }

    private func list() throws {
        let templates = try Templates.list(platform: platform, name: nil)
        let aliasFor = Dictionary(Templates.aliases.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        try Output.emit(templates, json: global.json) {
            templates.map { t in
                var lines = ["\(t.name)  (\(t.category))  \(aliasFor[t.identifier].map { "--template \($0)" } ?? t.identifier)"]
                for o in t.options {
                    let values = o.possibleValues.map { $0.joined(separator: " | ") } ?? o.type
                    lines.append("    \(o.identifier): \(values)" + (o.defaultValue.map { "  (default \($0))" } ?? ""))
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n")
        }
    }
}
