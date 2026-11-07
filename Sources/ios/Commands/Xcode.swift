import ArgumentParser
import Foundation
import IOSCore

struct XcodeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode",
        abstract: "Use Xcode's own tools (the tool service behind check and preview).",
        subcommands: [Tools.self, Call.self]
    )

    struct Call: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Call any of Xcode's tools by name (see `ios xcode tools`).",
            discussion: """
            Arguments as --arg name=value (numbers and true/false are converted) or --args '{json}'. The project \
            in the current directory is opened and passed as workspaceIdentifier. Example: \
            `ios xcode call GetTestList`, `ios xcode call XcodeGrep --arg pattern=PracticeLoop`.
            """
        )
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Tool name.") var tool: String
        @Option(help: "Argument as name=value (repeatable).") var arg: [String] = []
        @Option(help: "Arguments as a JSON object.") var args: String?
        @Option(help: "Path to an .xcworkspace (default: the one in the current directory).") var workspace: String?
        @Option(help: "Path to an .xcodeproj.") var project: String?

        func run() throws {
            var arguments: [String: Any] = [:]
            if let args {
                guard let object = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any] else {
                    throw ValidationError("--args must be a JSON object.")
                }
                arguments = object
            }
            for pair in arg {
                guard let eq = pair.firstIndex(of: "=") else { throw ValidationError("--arg takes name=value, got '\(pair)'.") }
                let value = String(pair[pair.index(after: eq)...])
                arguments[String(pair[..<eq])] = value == "true" ? true : value == "false" ? false : Int(value).map { $0 as Any } ?? value
            }
            try callXcodeTool(tool, arguments, workspace: workspace, project: project, json: global.json)
        }
    }

    struct Tools: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the tools Xcode's tool service offers.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let tools = try XcodeBridge().tools()
            if global.json {
                let data = try JSONSerialization.data(withJSONObject: tools, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            print(tools.map { tool in
                let name = tool["name"] as? String ?? "?"
                let summary = (tool["description"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
                return name.padding(toLength: 28, withPad: " ", startingAt: 0) + " " + summary
            }.joined(separator: "\n"))
        }
    }
}
