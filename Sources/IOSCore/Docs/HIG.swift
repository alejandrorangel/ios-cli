import Foundation

/// A Human Interface Guidelines page for the search index.
public struct GuidePage: Equatable, Sendable {
    public let path: String
    public let title: String
    /// "article" or "collection" (category pages such as Components).
    public let kind: String
    /// Title of the page that lists it (e.g. "Selection and input").
    public let parent: String
    public let abstract: String
}

/// The HIG has no downloadable index, but it's built with the same DocC JSON as the API docs,
/// so it can be crawled: the root lists categories, categories list pages, and every
/// reference carries the linked page's title and abstract.
public enum HIG {
    public static let root = "/design/human-interface-guidelines"

    /// Crawls from the root, level by level, downloading pages 4 at a time (~200 pages, a few seconds).
    static func crawl(work: URL, progress: (String) -> Void) throws -> [GuidePage] {
        let dir = work.appendingPathComponent("hig")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var pages: [String: GuidePage] = [:]
        var parents: [String: String] = [:]
        var visited = Set<String>()
        var frontier = [root]

        while !frontier.isEmpty, visited.count < 2000 {
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
                    let (page, links) = parse(data, path: path, parent: parents[path] ?? "")
                else { continue }
                pages[path] = page
                for link in links where !visited.contains(link) && !frontier.contains(link) {
                    frontier.append(link)
                    if parents[link] == nil { parents[link] = page.title }
                }
            }
        }
        return pages.values.filter { $0.path != root }.sorted { $0.path < $1.path }
    }

    /// The page itself and the HIG pages it links to.
    static func parse(_ data: Data, path: String, parent: String) -> (GuidePage, [String])? {
        guard
            let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let metadata = page["metadata"] as? [String: Any],
            let title = metadata["title"] as? String
        else { return nil }
        let role = metadata["role"] as? String ?? "article"
        let abstract = (page["abstract"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String ?? $0["code"] as? String }.joined()

        let references = page["references"] as? [String: [String: Any]] ?? [:]
        let links = references.values.compactMap { ref -> String? in
            guard ref["type"] as? String == "topic", let url = ref["url"] as? String, url.hasPrefix(root + "/") else { return nil }
            return String(url.lowercased().prefix { $0 != "#" })
        }
        let kind = role.lowercased().hasPrefix("collection") ? "collection" : "article"
        return (GuidePage(path: path, title: title, kind: kind, parent: parent, abstract: abstract), Array(Set(links)).sorted())
    }
}
