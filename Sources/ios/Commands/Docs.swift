import ArgumentParser
import Foundation
import IOSCore

struct Docs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search and read Apple developer documentation and the Human Interface Guidelines, and look up SDK APIs.",
        subcommands: [Search.self, Fetch.self, API.self, Update.self]
    )

    /// Progress messages go to stderr so stdout stays clean for --json.
    static func progress(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search Apple's documentation (all frameworks) and the Human Interface Guidelines.",
            discussion: "The first search downloads and indexes Apple's documentation catalog and the HIG (~140 MB, ~30 s). Results link to pages as doc://… (API docs) or hig://… (guidelines) for `ios docs fetch`."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Search words, e.g. \"navigation destination\" or \"core bluetooth scan\".")
        var query: [String]

        @Option(help: "Only this framework, e.g. swiftui or uikit.")
        var framework: String?

        @Flag(help: "Only the Human Interface Guidelines (design guidance, e.g. \"sliders\", \"dark mode\").")
        var hig = false

        @Option(help: "Only this page kind, e.g. struct, class, protocol, method, article, sampleCode.")
        var kind: String?

        @Option(help: "Number of results.")
        var limit = 10

        func run() throws {
            if !DocsIndex.exists {
                let status = try DocsIndex.update(progress: Docs.progress)
                Docs.progress("Indexed \(status.pages) pages from \(status.frameworks) frameworks in \(status.seconds)s.")
            }
            let results = try DocsIndex.search(query.joined(separator: " "), framework: hig ? "hig" : framework, kind: kind, limit: limit)
            try Output.emit(results, json: global.json) {
                guard !results.isEmpty else { return "No results." }
                return results.enumerated().map { index, r in
                    var flags = ""
                    if r.beta { flags += " [beta]" }
                    if r.deprecated { flags += " [deprecated]" }
                    if r.language == "occ" { flags += " [objc]" }
                    return "\(String(format: "%2d", index + 1)). \(r.title)  (\(r.kind), \(r.framework))\(flags)\n    \(r.docURL)"
                }.joined(separator: "\n")
            }
        }
    }

    struct Fetch: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a documentation page as markdown.",
            discussion: "Accepts doc://swiftui/view, swiftui/view, hig://sliders, /documentation/swiftui/view or a developer.apple.com URL (including Human Interface Guidelines pages). Pages are cached for 7 days."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Page path or URL.")
        var page: String

        @Flag(help: "Ignore the cached copy.")
        var refresh = false

        struct Result: Encodable {
            let path: String
            let markdown: String
        }

        func run() throws {
            let markdown = try DocsPage.markdown(page, refresh: refresh)
            try Output.emit(Result(path: DocsPage.normalizePath(page), markdown: markdown), json: global.json) { markdown }
        }
    }

    struct API: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "api",
            abstract: "Look up an API's declaration and availability in the installed SDK (offline).",
            discussion: "Reads the iOS SDK of the active Xcode, so results match what you compile against, including betas. The first lookup in a module extracts it (~10–40 s). Swift-native modules carry full doc comments; Objective-C-based ones (UIKit, AVFoundation) mostly have declarations only — use `ios docs fetch` for their prose."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Module.Symbol[.member], e.g. SwiftUI.View.navigationDestination or UIKit.UIView.")
        var symbol: String

        @Option(help: "Maximum number of matches (overloads).")
        var limit = 5

        func run() throws {
            let symbols = try SymbolStore.lookup(symbol, limit: limit, progress: Docs.progress)
            try Output.emit(symbols, json: global.json) {
                guard !symbols.isEmpty else { return "No match for \(symbol)." }
                return symbols.map { s in
                    var text = "## \(s.module).\(s.path)  (\(s.kind))\n```swift\n\(s.declaration)\n```"
                    if !s.availability.isEmpty { text += "\n**Availability:** " + s.availability.map(\.text).joined(separator: ", ") }
                    if !s.documentation.isEmpty { text += "\n\n\(s.documentation)" }
                    return text
                }.joined(separator: "\n\n")
            }
            if symbols.isEmpty { throw ExitCode.failure }
        }
    }

    struct Update: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download and rebuild the documentation search index.")

        @OptionGroup var global: GlobalOptions

        func run() throws {
            let status = try DocsIndex.update(progress: Docs.progress)
            try Output.emit(status, json: global.json) {
                var text = "Indexed \(status.pages) pages from \(status.frameworks) frameworks and \(status.guidePages) Human Interface Guidelines pages in \(status.seconds)s.\n\(status.path)"
                if !status.failedFrameworks.isEmpty {
                    text += "\nNot downloaded: \(status.failedFrameworks.joined(separator: ", "))"
                }
                return text
            }
        }
    }
}
