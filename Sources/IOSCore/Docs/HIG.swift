import Foundation

/// A crawled page for the search index: Human Interface Guidelines, tutorials, Review Guidelines
/// sections, WWDC sessions.
public struct GuidePage: Equatable, Sendable {
    public let path: String
    public let title: String
    /// "article", "collection", "tutorial", "guideline", "video"…
    public let kind: String
    /// Title of the page or section that lists it (e.g. "Selection and input").
    public let parent: String
    public let abstract: String
    /// Source shown in results and used by `--source`: hig, tutorials, app-review, wwdc.
    public let framework: String

    public init(path: String, title: String, kind: String, parent: String, abstract: String, framework: String = "hig") {
        self.path = path
        self.title = title
        self.kind = kind
        self.parent = parent
        self.abstract = abstract
        self.framework = framework
    }
}

/// The Human Interface Guidelines: no downloadable index, but the same DocC JSON as the API docs.
public enum HIG {
    public static let root = "/design/human-interface-guidelines"

    static func crawl(work: URL, progress: (String) -> Void) throws -> [GuidePage] {
        try DocCCrawler.crawl(roots: [root], linkPrefix: root + "/", framework: "hig", work: work.appendingPathComponent("hig"))
            .filter { $0.path != root }
    }

    /// Kept for callers and tests: parse one HIG page.
    static func parse(_ data: Data, path: String, parent: String) -> (GuidePage, [String])? {
        DocCCrawler.parse(data, path: path, parent: parent, linkPrefix: root + "/", framework: "hig")
    }
}

/// Apple's guided tutorials (developer.apple.com/tutorials/…): DocC "overview" and "project" pages.
public enum Tutorials {
    /// The collections; none are listed in the technologies catalog.
    public static let roots = ["swiftui", "develop-in-swift", "app-dev-training", "sample-apps", "swiftui-concepts"].map { "/tutorials/" + $0 }

    static func crawl(work: URL, progress: (String) -> Void) throws -> [GuidePage] {
        try DocCCrawler.crawl(roots: roots, linkPrefix: "/tutorials/", framework: "tutorials", work: work.appendingPathComponent("tutorials"))
    }
}

/// Crawls DocC sites level by level from their root pages: every reference carries the linked page's
/// title, and each page's own JSON has its abstract. Pages are downloaded 4 at a time.
enum DocCCrawler {
    static func crawl(roots: [String], linkPrefix: String, framework: String, work dir: URL, limit: Int = 3000) throws -> [GuidePage] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var pages: [String: GuidePage] = [:]
        var parents: [String: String] = [:]
        var visited = Set<String>()
        var frontier = roots

        while !frontier.isEmpty, visited.count < limit {
            let batch = frontier
            frontier = []
            visited.formUnion(batch)
            let files = Dictionary(uniqueKeysWithValues: batch.map { path in
                ("\(DocsPaths.base)\(path).json", dir.appendingPathComponent(MetadataCache.sha256(path) + ".json"))
            })
            try? DocsIndex.download(files)
            for path in batch {
                guard
                    let data = try? Data(contentsOf: dir.appendingPathComponent(MetadataCache.sha256(path) + ".json")),
                    let (page, links) = parse(data, path: path, parent: parents[path] ?? "", linkPrefix: linkPrefix, framework: framework)
                else { continue }
                pages[path] = page
                for link in links where !visited.contains(link) && !frontier.contains(link) {
                    frontier.append(link)
                    if parents[link] == nil { parents[link] = page.title }
                }
            }
        }
        return pages.values.sorted { $0.path < $1.path }
    }

    /// The page itself and the pages under `linkPrefix` it links to.
    static func parse(_ data: Data, path: String, parent: String, linkPrefix: String, framework: String) -> (GuidePage, [String])? {
        guard
            let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let metadata = page["metadata"] as? [String: Any],
            let title = metadata["title"] as? String
        else { return nil }
        let role = (metadata["role"] as? String ?? page["kind"] as? String ?? "article").lowercased()
        var abstract = inlineText(page["abstract"])
        if abstract.isEmpty, let hero = (page["sections"] as? [[String: Any]])?.first(where: { $0["kind"] as? String == "hero" }) {
            abstract = blockText(hero["content"])
        }

        let references = page["references"] as? [String: [String: Any]] ?? [:]
        let links = references.values.compactMap { ref -> String? in
            guard ref["type"] as? String == "topic", let url = ref["url"] as? String, url.hasPrefix(linkPrefix) else { return nil }
            return String(url.lowercased().prefix { $0 != "#" })
        }
        let kind = role.hasPrefix("collection") || role == "overview" ? "collection" : (role == "project" ? "tutorial" : "article")
        return (GuidePage(path: path, title: title, kind: kind, parent: parent, abstract: abstract, framework: framework),
                Array(Set(links)).sorted())
    }

    static func inlineText(_ value: Any?) -> String {
        (value as? [[String: Any]] ?? []).map { $0["text"] as? String ?? $0["code"] as? String ?? inlineText($0["inlineContent"]) }.joined()
    }

    /// Plain text of the first paragraphs of a DocC content block list.
    static func blockText(_ value: Any?) -> String {
        (value as? [[String: Any]] ?? []).compactMap { block in
            block["type"] as? String == "paragraph" ? inlineText(block["inlineContent"]) : nil
        }.prefix(2).joined(separator: " ")
    }
}
