import Foundation

public enum Output {
    /// Prints `value` as JSON when `json` is set, otherwise the human-readable text.
    /// Agents should pass `--json`; the text form is for people and may change.
    public static func emit<T: Encodable>(_ value: T, json: Bool, text: () -> String) throws {
        print(try render(value, json: json, text: text))
    }

    /// What `emit` prints, as a string (to write to a file instead).
    public static func render<T: Encodable>(_ value: T, json: Bool, text: () -> String) throws -> String {
        guard json else { return text() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Left-aligned columns for text tables.
    public static func table(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        let widths = (0..<first.count).map { col in rows.map { $0[col].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { col, cell in
                col == row.count - 1 ? cell : cell.padding(toLength: widths[col], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
