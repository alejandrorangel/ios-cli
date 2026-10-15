import Foundation

public enum DocsPage {
    static let cacheLifetime: TimeInterval = 7 * 24 * 3600

    /// Normalizes `doc://swiftui/view`, `swiftui/view`, `/documentation/swiftui/view`
    /// and developer.apple.com URLs to `/documentation/swiftui/view`.
    public static func normalizePath(_ input: String) -> String {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("doc://") { path = "/documentation/" + path.dropFirst("doc://".count) }
        path = path.replacing(/^https?:\/\/developer\.apple\.com/, with: "")
        if !path.hasPrefix("/") { path = "/documentation/" + path }
        while path.hasSuffix("/") { path.removeLast() }
        return path.lowercased()
    }

    /// The page's DocC render JSON, from the disk cache when fresh.
    public static func fetchJSON(_ input: String, refresh: Bool = false) throws -> Data {
        let path = normalizePath(input)
        let cache = DocsPaths.directory.appendingPathComponent("pages/\(MetadataCache.sha256(path)).json")
        if !refresh,
           let modified = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(modified) < cacheLifetime,
           let data = try? Data(contentsOf: cache) {
            return data
        }

        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = "\(DocsPaths.base)\(encoded).json"
        let result = try Shell.run("/usr/bin/curl", [
            "--silent", "--show-error", "--location", "--max-time", "30", "--user-agent", DocsPaths.userAgent,
            "--write-out", "\n%{http_code}", url,
        ])
        guard result.status == 0 else { throw IOSError.download(url: url, message: result.stderr) }
        // The status code is appended on its own line by --write-out.
        var body = result.stdout
        let newline = body.lastIndex(of: 0x0A) ?? body.endIndex
        let status = String(decoding: body[body.index(after: newline)...], as: UTF8.self)
        body = body[..<newline]
        if status == "404" { throw IOSError.docNotFound(path: path) }
        guard status == "200" else { throw IOSError.download(url: url, message: "HTTP \(status)") }

        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(body).write(to: cache, options: .atomic)
        return Data(body)
    }

    public static func markdown(_ input: String, refresh: Bool = false) throws -> String {
        try toMarkdown(fetchJSON(input, refresh: refresh))
    }

    // MARK: DocC render JSON → markdown

    public static func toMarkdown(_ data: Data) throws -> String {
        guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IOSError.invalidOutput(tool: "DocC JSON", reason: "not an object")
        }
        return Renderer(page).render()
    }

    private struct Renderer {
        let page: [String: Any]
        let references: [String: [String: Any]]

        init(_ page: [String: Any]) {
            self.page = page
            references = page["references"] as? [String: [String: Any]] ?? [:]
        }

        func render() -> String {
            let metadata = page["metadata"] as? [String: Any] ?? [:]
            var out = ["# \(metadata["title"] as? String ?? "")"]

            let module = (metadata["modules"] as? [[String: Any]])?.first?["name"] as? String
            let subtitle = [metadata["roleHeading"] as? String, module].compactMap { $0 }
            if !subtitle.isEmpty { out.append(subtitle.joined(separator: " · ")) }

            if let platforms = metadata["platforms"] as? [[String: Any]], !platforms.isEmpty {
                out.append("**Availability:** " + platforms.map(platformText).joined(separator: ", "))
            }
            if let abstract = page["abstract"] as? [[String: Any]] { out.append(inline(abstract)) }

            for section in page["primaryContentSections"] as? [[String: Any]] ?? [] {
                switch section["kind"] as? String {
                case "declarations":
                    for declaration in section["declarations"] as? [[String: Any]] ?? [] {
                        let tokens = declaration["tokens"] as? [[String: Any]] ?? []
                        let code = tokens.compactMap { $0["text"] as? String }.joined()
                        out.append("```swift\n\(code.trimmingCharacters(in: .whitespacesAndNewlines))\n```")
                    }
                case "parameters":
                    out.append("## Parameters")
                    for parameter in section["parameters"] as? [[String: Any]] ?? [] {
                        out.append("- `\(parameter["name"] as? String ?? "")`: " + blocks(parameter["content"]).joined(separator: " "))
                    }
                case "content":
                    out += blocks(section["content"])
                case "properties":
                    out.append("## Properties")
                    for item in section["items"] as? [[String: Any]] ?? [] {
                        out.append("- `\(item["name"] as? String ?? "")`")
                    }
                default:
                    break
                }
            }

            for (key, fallback, prefix) in [("topicSections", "Topics", ""), ("relationshipsSections", "Relationships", ""),
                                            ("seeAlsoSections", "", "See Also: ")] {
                for section in page[key] as? [[String: Any]] ?? [] {
                    out.append("## \(prefix)\(section["title"] as? String ?? fallback)")
                    for identifier in section["identifiers"] as? [String] ?? [] {
                        out.append("- " + reference(identifier, override: nil))
                    }
                }
            }
            // Lists are joined tighter than paragraphs, as in the prototype.
            return out.joined(separator: "\n\n").replacingOccurrences(of: "\n\n- ", with: "\n- ")
        }

        private func platformText(_ p: [String: Any]) -> String {
            var text = p["name"] as? String ?? ""
            if let introduced = p["introducedAt"] as? String { text += " \(introduced)+" }
            if p["beta"] as? Bool == true { text += " (beta)" }
            if let deprecated = p["deprecatedAt"] as? String { text += " (deprecated \(deprecated))" }
            return text
        }

        /// Links to other documentation pages become `doc://` so they can be fetched next.
        private func reference(_ identifier: String, override: [[String: Any]]?) -> String {
            let ref = references[identifier] ?? [:]
            let overrideTitle = override.map(inline) ?? ""
            let title = !overrideTitle.isEmpty ? overrideTitle
                : (ref["title"] as? String ?? String(identifier.split(separator: "/").last ?? ""))
            let url = ref["url"] as? String ?? ""
            if ref["type"] as? String == "link" { return "[\(title)](\(url))" }
            if url.hasPrefix("/documentation/") { return "[`\(title)`](\(DocsPaths.docURL(forPath: url)))" }
            return "`\(title)`"
        }

        private func inline(_ items: [[String: Any]]) -> String {
            items.map { item -> String in
                let children = item["inlineContent"] as? [[String: Any]] ?? []
                switch item["type"] as? String {
                case "text": return item["text"] as? String ?? ""
                case "codeVoice": return "`\(item["code"] as? String ?? "")`"
                case "emphasis", "newTerm": return "*\(inline(children))*"
                case "strong": return "**\(inline(children))**"
                case "link":
                    let destination = item["destination"] as? String ?? ""
                    return "[\(item["title"] as? String ?? destination)](\(destination))"
                case "reference":
                    return reference(item["identifier"] as? String ?? "", override: item["overridingTitleInlineContent"] as? [[String: Any]])
                case "image": return "![\(item["identifier"] as? String ?? "image")]"
                default: return inline(children)
                }
            }.joined()
        }

        private func blocks(_ value: Any?, depth: Int = 0) -> [String] {
            var out: [String] = []
            for block in value as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "heading":
                    let level = min((block["level"] as? Int ?? 2) + 1, 6)
                    out.append(String(repeating: "#", count: level) + " " + (block["text"] as? String ?? ""))
                case "paragraph":
                    out.append(inline(block["inlineContent"] as? [[String: Any]] ?? []))
                case "codeListing":
                    let code = (block["code"] as? [String] ?? []).joined(separator: "\n")
                    out.append("```\(block["syntax"] as? String ?? "")\n\(code)\n```")
                case "aside":
                    let name = block["name"] as? String ?? (block["style"] as? String ?? "note").capitalized
                    let lines = blocks(block["content"], depth: depth).joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false)
                    out.append(lines.enumerated().map { $0 == 0 ? "> **\(name):** \($1)" : "> \($1)" }.joined(separator: "\n"))
                case let type? where type == "unorderedList" || type == "orderedList":
                    for (index, item) in (block["items"] as? [[String: Any]] ?? []).enumerated() {
                        let bullet = type == "orderedList" ? "\(index + 1)." : "-"
                        let body = blocks(item["content"], depth: depth + 1).joined(separator: " ")
                        out.append(String(repeating: "  ", count: depth) + "\(bullet) \(body)")
                    }
                case "termList":
                    for item in block["items"] as? [[String: Any]] ?? [] {
                        let term = inline((item["term"] as? [String: Any])?["inlineContent"] as? [[String: Any]] ?? [])
                        let definition = blocks((item["definition"] as? [String: Any])?["content"]).joined(separator: " ")
                        out.append("- **\(term)**: \(definition)")
                    }
                case "table":
                    let rows = (block["rows"] as? [[Any]] ?? []).map { row in
                        row.map { blocks($0).joined(separator: " ").replacingOccurrences(of: "|", with: "\\|") }
                    }
                    if let header = rows.first {
                        var lines = ["| " + header.joined(separator: " | ") + " |", "|" + String(repeating: "---|", count: header.count)]
                        lines += rows.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }
                        out.append(lines.joined(separator: "\n"))
                    }
                case "links":
                    out += (block["items"] as? [String] ?? []).map { "- " + reference($0, override: nil) }
                case "row", "tabNavigator":
                    for column in (block["columns"] as? [[String: Any]]) ?? (block["tabs"] as? [[String: Any]]) ?? [] {
                        out += blocks(column["content"], depth: depth)
                    }
                case "small":
                    out.append(inline(block["inlineContent"] as? [[String: Any]] ?? []))
                default:
                    if block["content"] != nil { out += blocks(block["content"], depth: depth) }
                }
            }
            return out
        }
    }
}
