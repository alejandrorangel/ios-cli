import Foundation

public struct APISymbol: Codable, Equatable, Sendable {
    public let module: String
    public let path: String
    public let kind: String
    public let declaration: String
    public let documentation: String
    public let availability: [Availability]

    public struct Availability: Codable, Equatable, Sendable {
        public struct Version: Codable, Equatable, Sendable {
            public let major: Int
            public let minor: Int?
            public let patch: Int?

            var text: String { [major, minor ?? 0].map(String.init).joined(separator: ".") + (patch.map { $0 > 0 ? ".\($0)" : "" } ?? "") }
        }

        public let domain: String?
        public let introduced: Version?
        public let deprecated: Version?
        public let isUnconditionallyDeprecated: Bool?
        public let isUnconditionallyUnavailable: Bool?

        public var text: String {
            var s = domain ?? "*"
            if let introduced { s += " \(introduced.text)+" }
            if let deprecated { s += " (deprecated \(deprecated.text))" }
            if isUnconditionallyDeprecated == true { s += " (deprecated)" }
            if isUnconditionallyUnavailable == true { s += " (unavailable)" }
            return s
        }
    }
}

/// API declarations read from the installed SDK (swift-symbolgraph-extract), so signatures and
/// availability match the Xcode actually in use, including betas. Built per module on first use.
public enum SymbolStore {
    static var database: URL {
        DocsPaths.directory.appendingPathComponent("symbols-\(Describer.cachedXcodeBuildForSymbols).db")
    }

    /// `SwiftUI.View.navigationDestination` → declarations, best match first.
    /// The first component is the module; it's extracted from the SDK the first time (~10–40 s).
    public static func lookup(_ query: String, limit: Int = 5, progress: (String) -> Void = { _ in }) throws -> [APISymbol] {
        let parts = query.split(separator: ".").map(String.init)
        guard parts.count >= 2 else {
            throw IOSError.invalidOutput(tool: "ios docs api", reason: "use Module.Symbol, e.g. SwiftUI.View or UIKit.UIView.layoutSubviews")
        }
        let path = parts.dropFirst().joined(separator: ".")
        let db = try open()
        let primary = try loadedModule(parts[0], db: db, progress: progress)
        var matches = try find(path, in: primary, db: db, limit: limit)

        // Some modules re-export a "…Core" module that declares the base types: in iOS 27,
        // SwiftUI.View is declared in SwiftUICore. Look there when there's no exact match.
        if matches.first?.rank != 0, let core = try companionCore(of: primary) {
            let coreModule = try loadedModule(core, db: db, progress: progress)
            matches += try find(path, in: coreModule, db: db, limit: limit)
            matches.sort { ($0.rank, $0.symbol.path.count) < ($1.rank, $1.symbol.path.count) }
        }
        return matches.prefix(limit).map(\.symbol)
    }

    /// The module's canonical name, extracting it from the SDK the first time.
    private static func loadedModule(_ name: String, db: SQLiteDatabase, progress: (String) -> Void) throws -> String {
        if let known = try db.query("SELECT name FROM modules WHERE name = ? COLLATE NOCASE", [.text(name)], map: { $0.text(0) }).first {
            return known
        }
        let module = try sdkModuleNames().first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
        progress("Reading \(module) from the iOS SDK (first use of this module)…")
        try extract(module: module, into: db)
        return module
    }

    /// Rank 0: exact path. 1: members/overloads of it (`View.foo`, `foo(_:)`). 2: other names with
    /// the prefix (`ViewThatFits`). 3: path contains the query.
    private static func find(_ path: String, in module: String, db: SQLiteDatabase, limit: Int) throws -> [(symbol: APISymbol, rank: Int)] {
        let columns = "module, path, kind, declaration, doc, availability"
        let prefixMatches = try db.query("""
            SELECT \(columns), CASE WHEN path = ?2 COLLATE NOCASE THEN 0
                                    WHEN substr(path, length(?2) + 1, 1) IN ('.', '(') THEN 1 ELSE 2 END AS rank
            FROM symbols
            WHERE module = ?1 AND path >= ?2 COLLATE NOCASE AND path < ?3 COLLATE NOCASE
            ORDER BY rank, length(path) LIMIT ?4
            """, [.text(module), .text(path), .text(path + "\u{FFFF}"), .int(limit)]) { (row($0), $0.int(6)) }
        if !prefixMatches.isEmpty { return prefixMatches }
        return try db.query("SELECT \(columns) FROM symbols WHERE module = ? AND path LIKE ? ORDER BY length(path) LIMIT ?",
                            [.text(module), .text("%" + path + "%"), .int(limit)]) { (row($0), 3) }
    }

    /// Framework names in the iOS simulator SDK and the platform's developer frameworks (XCTest,
    /// XCUIAutomation, Testing), plus the Swift standard library.
    static func sdkModuleNames() throws -> [String] {
        let sdk = try Shell.checked("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let names = { (dir: String) in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".framework") && !$0.hasPrefix("_") }.map { String($0.dropLast(".framework".count)) }
        }
        let developer = (try? developerSearchPaths().frameworks).map(names) ?? []
        return names(sdk + "/System/Library/Frameworks") + developer + ["Swift"]
    }

    /// The test frameworks ship with the platform, outside the SDK: Developer/Library/Frameworks for
    /// XCTest, XCUIAutomation and Testing, and Developer/usr/lib for XCTest's Swift module.
    static func developerSearchPaths() throws -> (frameworks: String, libraries: String) {
        let platform = try Shell.checked("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-platform-path"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (platform + "/Developer/Library/Frameworks", platform + "/Developer/usr/lib")
    }

    private static func companionCore(of module: String) throws -> String? {
        guard !module.hasSuffix("Core") else { return nil }
        let core = module + "Core"
        return try sdkModuleNames().contains(core) ? core : nil
    }

    private static func row(_ s: Statement) -> APISymbol {
        let availability = (try? JSONDecoder().decode([APISymbol.Availability].self, from: Data(s.text(5).utf8))) ?? []
        return APISymbol(module: s.text(0), path: s.text(1), kind: s.text(2), declaration: s.text(3),
                         documentation: s.text(4), availability: availability)
    }

    private static func open() throws -> SQLiteDatabase {
        try FileManager.default.createDirectory(at: DocsPaths.directory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: database.path)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS modules(name TEXT PRIMARY KEY, sdk TEXT, symbols INT);
            CREATE TABLE IF NOT EXISTS symbols(module TEXT, path TEXT, kind TEXT, declaration TEXT, doc TEXT,
                                               availability TEXT, precise TEXT, UNIQUE(module, precise));
            CREATE INDEX IF NOT EXISTS symbols_path ON symbols(module, path COLLATE NOCASE);
            """)
        return db
    }

    /// Extracts the module's symbol graph to a temp directory, compacts it into the database
    /// and deletes the raw JSON (hundreds of MB for SwiftUI).
    static func extract(module: String, into db: SQLiteDatabase) throws {
        let sdk = try Shell.checked("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = try Shell.checked("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-version"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-symbols-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }

        let result = try Shell.run("/usr/bin/xcrun", [
            "swift-symbolgraph-extract", "-module-name", module, "-target", "arm64-apple-ios\(version)-simulator",
            "-sdk", sdk, "-output-dir", out.path, "-minimum-access-level", "public",
        ] + ((try? developerSearchPaths()).map { ["-F", $0.frameworks, "-I", $0.libraries] } ?? []))
        let files = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasSuffix(".symbols.json") } ?? []
        guard result.status == 0, !files.isEmpty else {
            throw IOSError.symbolModuleUnavailable(module: module, detail: String(result.stderr.suffix(400)))
        }

        let insert = try db.prepare("INSERT OR IGNORE INTO symbols VALUES (?, ?, ?, ?, ?, ?, ?)")
        let encoder = JSONEncoder()
        var count = 0
        try db.transaction {
            for file in files {
                let graph = try JSONDecoder().decode(SymbolGraph.self, from: Data(contentsOf: file))
                for symbol in graph.symbols {
                    let availability = (try? encoder.encode(symbol.availability ?? [])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
                    try insert.run([
                        .text(module), .text(symbol.pathComponents.joined(separator: ".")), .text(symbol.kind.displayName),
                        .text((symbol.declarationFragments ?? []).map(\.spelling).joined()
                            .trimmingCharacters(in: .whitespacesAndNewlines)),
                        .text((symbol.docComment?.lines ?? []).map(\.text).joined(separator: "\n")),
                        .text(availability), .text(symbol.identifier.precise),
                    ])
                    count += 1
                }
            }
            try db.prepare("INSERT OR REPLACE INTO modules VALUES (?, ?, ?)").run([.text(module), .text(version), .int(count)])
        }
    }

    /// The parts of the symbol graph format we keep.
    struct SymbolGraph: Decodable {
        struct Symbol: Decodable {
            struct Identifier: Decodable { let precise: String }
            struct Kind: Decodable { let displayName: String }
            struct Fragment: Decodable { let spelling: String }
            struct DocComment: Decodable {
                struct Line: Decodable { let text: String }
                let lines: [Line]
            }
            let identifier: Identifier
            let kind: Kind
            let pathComponents: [String]
            let declarationFragments: [Fragment]?
            let docComment: DocComment?
            let availability: [APISymbol.Availability]?
        }
        let symbols: [Symbol]
    }
}
