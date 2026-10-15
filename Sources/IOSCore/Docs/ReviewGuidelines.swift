import Foundation

/// The App Store Review Guidelines: one HTML page whose guidelines carry numbered ids
/// (`1.1`, `1.1.1`, …) under top-level sections (`1. Safety`, …).
public enum ReviewGuidelines {
    public static let url = "https://developer.apple.com/app-store/review/guidelines/"
    public static let pathPrefix = "/app-store/review/guidelines"

    public struct Section: Equatable, Sendable {
        /// "1.1.1", or "1" for a top-level section.
        public let number: String
        public let title: String
        public let text: String
    }

    static var cacheFile: URL { DocsPaths.directory.appendingPathComponent("app-review-guidelines.html") }

    /// The page's HTML, downloaded at most once a week.
    static func html(refresh: Bool = false) throws -> String {
        let file = cacheFile
        if !refresh,
           let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(modified) < DocsPage.cacheLifetime,
           let cached = try? String(contentsOf: file, encoding: .utf8) {
            return cached
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DocsIndex.download([url: file])
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else {
            throw IOSError.download(url: url, message: "empty response")
        }
        return text
    }

    /// Top-level sections and numbered guidelines, in page order.
    public static func sections(in html: String) -> [Section] {
        struct Marker { let offset: String.Index; let number: String; let title: String? }
        var markers: [Marker] = []
        // Top-level headings: <h3 …>1. Safety</h3>
        for match in html.matches(of: /<h[23][^>]*>(.*?)<\/h[23]>/.dotMatchesNewlines()) {
            // Headings may wrap their text in links or spans: match on the text.
            let heading = HTMLText.line(String(match.output.1))
            if let parts = heading.firstMatch(of: /^(\d+)\.\s+(.+)$/) {
                markers.append(Marker(offset: match.range.lowerBound, number: String(parts.output.1), title: String(parts.output.2)))
            }
        }
        // Guidelines: any element with a numbered id, e.g. <li id="1.1.1"> or <span id="1.1">.
        for match in html.matches(of: /<[a-z]+[^>]*\bid="(\d+(?:\.\d+)+)"[^>]*>/) {
            markers.append(Marker(offset: match.range.lowerBound, number: String(match.output.1), title: nil))
        }
        markers.sort { $0.offset < $1.offset }
        // Section text ends at the next marker; the footer ends the last one.
        let end = html.range(of: "<footer")?.lowerBound ?? html.endIndex

        var out: [Section] = []
        var seen = Set<String>()
        for (index, marker) in markers.enumerated() where seen.insert(marker.number).inserted {
            let stop = index + 1 < markers.count ? markers[index + 1].offset : end
            guard marker.offset < stop else { continue }
            let segment = String(html[marker.offset..<stop])
            let text = HTMLText.text(segment)
            // Prefer the bold heading ("5.1 Privacy") when it has words beyond the number.
            let bold = segment.firstMatch(of: /<strong>(.*?)<\/strong>/).map { HTMLText.line(String($0.output.1)) }
            let heading = bold.flatMap { $0.hasPrefix(marker.number) && $0.count > marker.number.count + 1 ? $0 : nil }
            out.append(Section(number: marker.number, title: marker.title ?? heading ?? title(for: marker.number, text: text), text: text))
        }
        return out
    }

    /// "1.1 Objectionable Content" from the bold heading, or the number plus the first words.
    static func title(for number: String, text: String) -> String {
        var body = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("- ") { body.removeFirst(2) }
        if body.hasPrefix(number) { body = String(body.dropFirst(number.count)).trimmingCharacters(in: .whitespaces) }
        let words = body.split(separator: " ").prefix(9).joined(separator: " ")
        return "\(number) \(words)\(body.split(separator: " ").count > 9 ? "…" : "")"
    }

    static func pages(in html: String) -> [GuidePage] {
        let all = sections(in: html)
        let topTitles = Dictionary(all.filter { !$0.number.contains(".") }.map { ($0.number, $0.title) }, uniquingKeysWith: { a, _ in a })
        return all.map { section in
            let top = String(section.number.split(separator: ".").first ?? "")
            let isTop = !section.number.contains(".")
            return GuidePage(
                path: "\(pathPrefix)/\(section.number)",
                title: isTop ? "\(section.number). \(section.title)" : section.title,
                kind: "guideline",
                parent: isTop ? "App Store Review Guidelines" : "\(top). \(topTitles[top] ?? "")",
                abstract: String(section.text.prefix(400)),
                framework: "app-review"
            )
        }
    }

    /// Markdown for one guideline and everything numbered under it (e.g. "4.2" includes 4.2.1…),
    /// or the table of contents when `number` is empty.
    public static func markdown(_ number: String, refresh: Bool = false) throws -> String {
        let all = sections(in: try html(refresh: refresh))
        if number.isEmpty {
            let toc = all.filter { $0.number.split(separator: ".").count <= 2 }
                .map { $0.number.contains(".") ? "  - [\($0.title)](asrg://\($0.number))" : "- [\($0.number). \($0.title)](asrg://\($0.number))" }
            return "# App Store Review Guidelines\n\n\(url)\n\n" + toc.joined(separator: "\n")
        }
        let selected = all.filter { $0.number == number || $0.number.hasPrefix(number + ".") }
        guard !selected.isEmpty else { throw IOSError.docNotFound(path: "asrg://\(number)") }
        let body = selected.map { section -> String in
            let depth = section.number.split(separator: ".").count
            let heading = String(repeating: "#", count: min(depth + 1, 6))
            var text = section.text
            for prefix in ["\(section.number). \(section.title)", section.title, "- \(section.number)", section.number] where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            return "\(heading) \(depth == 1 ? "\(section.number). " : "")\(section.title)\n\n\(text)"
        }
        return "# App Store Review Guidelines — \(number)\n\n\(url)#\(number)\n\n" + body.joined(separator: "\n\n")
    }
}
