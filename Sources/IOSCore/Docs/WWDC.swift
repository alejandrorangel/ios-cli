import Foundation

/// WWDC session videos: each year's listing page has every session's title, category and
/// description; a session's page has its transcript (fetched on demand).
public enum WWDC {
    /// Years indexed by default (newest first); older sessions are still fetchable by URL.
    public static let years = [2026, 2025, 2024, 2023]

    struct Session: Equatable {
        let year: Int
        let id: String
        let title: String
        let category: String
        let description: String
        let duration: String
    }

    static func listingURL(_ year: Int) -> String { "https://developer.apple.com/videos/wwdc\(year)/" }
    static func sessionURL(_ year: Int, _ id: String) -> String { "https://developer.apple.com/videos/play/wwdc\(year)/\(id)/" }

    /// Downloads the listings and returns index pages for every session.
    static func crawl(work: URL) throws -> [GuidePage] {
        let dir = work.appendingPathComponent("wwdc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = Dictionary(uniqueKeysWithValues: years.map { (listingURL($0), dir.appendingPathComponent("\($0).html")) })
        try? DocsIndex.download(files)
        return years.flatMap { year -> [GuidePage] in
            guard let html = try? String(contentsOf: dir.appendingPathComponent("\(year).html"), encoding: .utf8) else { return [] }
            return sessions(in: html, year: year).map { s in
                GuidePage(path: "/videos/play/wwdc\(s.year)/\(s.id)", title: s.title, kind: "video",
                          parent: "WWDC\(s.year % 100) · \(s.category)", abstract: s.description, framework: "wwdc")
            }
        }
    }

    /// Session cards on a listing page: `<a href="/videos/play/wwdcYYYY/NNN/" … data-category="…">`
    /// with the title in `vc-card__title` and the description in `data-filter-description-en`.
    static func sessions(in html: String, year: Int) -> [Session] {
        let pattern = try! Regex("<a href=\"/videos/play/wwdc\(year)/(\\d+)/\"[^>]*>")
        let cards = html.matches(of: pattern)
        var out: [Session] = []
        var seen = Set<String>()
        for (index, card) in cards.enumerated() {
            guard let id = card.output[1].substring.map(String.init), seen.insert(id).inserted else { continue }
            let stop = index + 1 < cards.count ? cards[index + 1].range.lowerBound : html.endIndex
            let block = String(html[card.range.lowerBound..<stop])
            let tag = String(html[card.range])
            let title = block.firstMatch(of: /class="vc-card__title"[^>]*>([^<]*)</).map { HTMLText.decode(String($0.output.1)) } ?? ""
            let keywords = block.firstMatch(of: /<span class="vc-card__keywords[^>]*>/).map { String($0.output) } ?? ""
            let description = HTMLText.attribute("data-filter-description-en", in: keywords)
                ?? HTMLText.attribute("data-filter-description", in: keywords) ?? ""
            let duration = block.firstMatch(of: /vc-card__duration">([^<]*)</).map { String($0.output.1) } ?? ""
            guard !title.isEmpty else { continue }
            out.append(Session(year: year, id: id, title: title, category: HTMLText.attribute("data-category", in: tag) ?? "",
                               description: sentenceCase(description), duration: duration))
        }
        return out
    }

    /// Listing descriptions are lowercased for filtering; restore sentence starts.
    static func sentenceCase(_ text: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in text {
            out.append(capitalizeNext ? Character(ch.uppercased()) : ch)
            if ch == "." || ch == "?" || ch == "!" { capitalizeNext = true } else if ch != " " { capitalizeNext = false }
        }
        return out
    }

    /// `wwdc://2026/258` → (2026, "258").
    static func parse(_ reference: String) -> (Int, String)? {
        let parts = reference.split(separator: "/").map(String.init)
        guard parts.count == 2, let year = Int(parts[0].replacingOccurrences(of: "wwdc", with: "")) else { return nil }
        return (year < 100 ? 2000 + year : year, parts[1])
    }

    /// The session's title, description and transcript as markdown (transcript paragraphs carry a
    /// [mm:ss] timestamp so they can be matched to the video).
    public static func markdown(_ reference: String) throws -> String {
        guard let (year, id) = parse(reference) else { throw IOSError.docNotFound(path: "wwdc://\(reference)") }
        let url = sessionURL(year, id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-wwdc-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: file) }
        try DocsIndex.download([url: file])
        guard let html = try? String(contentsOf: file, encoding: .utf8), !html.isEmpty else { throw IOSError.docNotFound(path: url) }
        return render(html, url: url)
    }

    static func render(_ html: String, url: String) -> String {
        var title = html.firstMatch(of: /<title>([^<]*)<\/title>/).map { HTMLText.decode(String($0.output.1)) } ?? ""
        if let range = title.range(of: " - Videos - Apple Developer") { title.removeSubrange(range.lowerBound...) }
        let description = html.firstMatch(of: /<meta name="description" content="([^"]*)"/).map { HTMLText.decode(String($0.output.1)) } ?? ""
        var out = ["# \(title)", url]
        if !description.isEmpty { out.append(description) }

        if let start = html.range(of: "<section id=\"transcript-content\">") {
            let rest = html[start.upperBound...]
            let section = String(rest[..<(rest.range(of: "</section>")?.lowerBound ?? rest.endIndex)])
            var paragraphs: [String] = []
            for paragraph in section.components(separatedBy: "<p>") {
                let text = HTMLText.line(paragraph)
                guard !text.isEmpty else { continue }
                let start = paragraph.firstMatch(of: /data-start="([0-9.]+)"/).flatMap { Double($0.output.1) }
                paragraphs.append((start.map { String(format: "[%d:%02d] ", Int($0) / 60, Int($0) % 60) } ?? "") + text)
            }
            if !paragraphs.isEmpty { out.append("## Transcript\n\n" + paragraphs.joined(separator: "\n\n")) }
        }
        return out.joined(separator: "\n\n")
    }
}
