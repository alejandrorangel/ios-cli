import Foundation

/// Just enough HTML handling for Apple's non-DocC pages (Review Guidelines, WWDC sessions):
/// strip tags, decode entities, normalize whitespace. No dependencies and no WebKit.
enum HTMLText {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "mdash": "—", "ndash": "–", "hellip": "…", "trade": "™", "reg": "®", "copy": "©",
        "eacute": "é", "bull": "•", "middot": "·", "rarr": "→", "larr": "←", "times": "×", "shy": "",
    ]

    /// Text content of an HTML fragment: block-level tags become line breaks, list items get "- ".
    static func text(_ html: String) -> String {
        var s = html
        s = s.replacing(/<(script|style)\b[^>]*>.*?<\/\1>/.dotMatchesNewlines(), with: "")
        s = s.replacing(/<li\b[^>]*>/, with: "\n- ")
        s = s.replacing(/<\/?(p|div|br|h[1-6]|ul|ol|section|tr)\b[^>]*>/, with: "\n")
        s = s.replacing(/<[^>]+>/, with: "")
        s = decode(s)
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/[ \t\u{00A0}]+/, with: " ").trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        var bullet = false
        for line in lines {
            // A list item that starts with a nested block leaves its "-" alone on a line: carry it
            // to the item's first line of text.
            if line == "-" { bullet = true; continue }
            if line.isEmpty { if out.last?.isEmpty == false { out.append("") }; continue }
            out.append(bullet && !line.hasPrefix("- ") ? "- " + line : line)
            bullet = false
        }
        // Keep lists tight: no blank line between consecutive items (one stays before the list).
        out = out.enumerated().filter { index, line in
            !(line.isEmpty && index > 0 && index + 1 < out.count && out[index - 1].hasPrefix("- ") && out[index + 1].hasPrefix("- "))
        }.map(\.element)
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line of text (for titles and abstracts).
    static func line(_ html: String) -> String {
        text(html).replacing(/\s+/, with: " ").replacingOccurrences(of: "- ", with: "", options: .anchored)
    }

    static func decode(_ s: String) -> String {
        s.replacing(/&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);/) { match in
            let entity = String(match.output.1)
            if entity.hasPrefix("#x"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                return String(Character(scalar))
            }
            if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                return String(Character(scalar))
            }
            return named[entity] ?? "&\(entity);"
        }
    }

    /// Value of an attribute in a tag string, e.g. data-filter-description.
    static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=\"") else { return nil }
        let rest = tag[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return decode(String(rest[..<end]))
    }
}
