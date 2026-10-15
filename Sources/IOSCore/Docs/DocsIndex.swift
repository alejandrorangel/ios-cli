import Foundation

public struct DocsSearchResult: Codable, Equatable, Sendable {
    public let path: String
    public let title: String
    public let kind: String
    public let framework: String
    public let beta: Bool
    public let deprecated: Bool
    /// "swift" or "occ" (Objective-C only).
    public let language: String
    public let parent: String

    /// `doc://swiftui/view/...`, accepted by `ios docs fetch`.
    public var docURL: String { DocsPaths.docURL(forPath: path) }
}

public struct DocsIndexStatus: Codable, Sendable {
    public let path: String
    public let pages: Int
    public let frameworks: Int
    public let failedFrameworks: [String]
    /// Pages outside the framework catalog (HIG, tutorials, Review Guidelines, WWDC sessions).
    public let guidePages: Int
    /// Page count per source label (frameworks are counted as "api").
    public let sources: [String: Int]
    public let seconds: Double
}

public enum DocsPaths {
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["IOS_CLI_DOCS_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ios-cli/docs")
    }

    public static var indexDatabase: URL { directory.appendingPathComponent("docs.db") }

    static let userAgent = "ios-cli/0.2"
    static let base = "https://developer.apple.com/tutorials/data"
    /// The Swift Programming Language book lives on docs.swift.org (same DocC format).
    static let swiftBookBase = "https://docs.swift.org/swift-book/data"
    static let swiftBookIndex = "https://docs.swift.org/swift-book/index/index.json"
    static let swiftBookPrefix = "/documentation/the-swift-programming-language"

    /// `doc://swiftui/view` for API docs, `hig://sliders` for the Human Interface Guidelines.
    public static func docURL(forPath path: String) -> String {
        if path.hasPrefix("/documentation/") { return "doc://" + path.dropFirst("/documentation/".count) }
        if path.hasPrefix("/tutorials/") { return "tutorial://" + path.dropFirst("/tutorials/".count) }
        if path.hasPrefix(ReviewGuidelines.pathPrefix + "/") { return "asrg://" + path.dropFirst(ReviewGuidelines.pathPrefix.count + 1) }
        if let match = path.firstMatch(of: /^\/videos\/play\/wwdc(\d{4})\/(\d+)/) { return "wwdc://\(match.output.1)/\(match.output.2)" }
        if path.hasPrefix(HIG.root + "/") { return "hig://" + path.dropFirst(HIG.root.count + 1) }
        if path == HIG.root { return "hig://" }
        return path
    }
}

public enum DocsIndex {
    /// Search-term weight per page kind, from the prototype's tuning (spikes/docs-prototype/docs.py).
    static let kindBoost: [String: Double] = [
        "article": 2.0, "collection": 1.5, "sampleCode": 1.5, "tutorial": 1.0, "struct": 1.5, "class": 1.5,
        "protocol": 1.5, "module": 2.0, "framework": 2.0, "enum": 0.8, "func": 0.6, "method": 0.5, "init": 0.3,
        "property": 0.3, "var": 0.2, "case": 0.0, "typealias": 0.1, "op": -0.5,
    ]

    /// Source labels outside the framework catalog, with words that help queries find them.
    public static let sourceWords: [String: String] = [
        "hig": "hig human interface guidelines design",
        "tutorials": "tutorials tutorial learn guided",
        "swift-book": "swift book language programming",
        "app-review": "app review guidelines store submission",
        "wwdc": "wwdc video session talk",
    ]
    static var specialSourcesSQL: String { "(" + sourceWords.keys.sorted().map { "'\($0)'" }.joined(separator: ",") + ")" }

    /// Small ranking boosts: design guidance and learning material should surface for broad queries
    /// without outranking an exact API match.
    static let sourceBoost: [String: Double] = ["hig": 1, "tutorials": 0.5, "swift-book": 0.5]

    /// Everyday words → the words Apple's API names use instead, so intent queries find the symbol
    /// ("push notification register" → registerForRemoteNotifications). Kept small: each entry widens matches.
    static let synonyms: [String: [String]] = [
        "push": ["remote"],
        "login": ["sign", "signin"],
    ]

    /// Penalty for pages of frameworks that exist on other Apple platforms but not on iOS (AppKit,
    /// WatchKit, TVMLKit, DriverKit…), so iOS answers come first. Asking for the framework by name
    /// (`--framework appkit`, "appkit table view") still finds them.
    static let otherPlatformPenalty = 4.0

    /// Documentation-only technologies for other platforms that aren't SDK frameworks.
    static let otherPlatformTopics: Set<String> = ["tvml", "tvmljs", "visionos"]

    /// Frameworks (lowercased, as in the index) shipped in the macOS, tvOS, watchOS or visionOS SDK
    /// but not in the iOS one. Computed from the installed SDKs once per Xcode build and cached.
    static func otherPlatformFrameworks() -> Set<String> {
        let cache = DocsPaths.directory.appendingPathComponent("platform-frameworks-\(Describer.cachedXcodeBuildForSymbols).json")
        if let data = try? Data(contentsOf: cache), let names = try? JSONDecoder().decode([String].self, from: data) {
            return Set(names)
        }
        func sdkPath(_ sdk: String) -> String? {
            guard let result = try? Shell.run("/usr/bin/xcrun", ["--sdk", sdk, "--show-sdk-path"]), result.status == 0 else { return nil }
            return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func entries(_ dir: String, suffix: String) -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(suffix) }.map { $0.dropLast(suffix.count).lowercased() })
        }
        var iOS = Set<String>()
        for sdk in ["iphoneos", "iphonesimulator"] {
            guard let path = sdkPath(sdk) else { continue }
            iOS.formUnion(entries(path + "/System/Library/Frameworks", suffix: ".framework"))
            iOS.formUnion(entries(path + "/usr/lib/swift", suffix: ".swiftmodule")) // System, Spatial, simd…
        }
        if let developer = try? SymbolStore.developerSearchPaths() { iOS.formUnion(entries(developer.frameworks, suffix: ".framework")) }
        guard !iOS.isEmpty else { return otherPlatformTopics } // no iOS SDK: don't guess
        var others = Set<String>()
        for sdk in ["macosx", "appletvos", "watchos", "xros"] {
            if let path = sdkPath(sdk) { others.formUnion(entries(path + "/System/Library/Frameworks", suffix: ".framework")) }
        }
        let result = others.subtracting(iOS).union(otherPlatformTopics)
        if let data = try? JSONEncoder().encode(result.sorted()) {
            try? FileManager.default.createDirectory(at: DocsPaths.directory, withIntermediateDirectories: true)
            try? data.write(to: cache)
        }
        return result
    }

    public static var exists: Bool { FileManager.default.fileExists(atPath: DocsPaths.indexDatabase.path) }

    // MARK: Building

    /// Downloads Apple's per-framework documentation indexes and builds the search database.
    /// ~140 MB download, ~30 s; the raw files are deleted afterwards.
    @discardableResult
    public static func update(progress report: (String) -> Void = { _ in }) throws -> DocsIndexStatus {
        let start = Date()
        func progress(_ message: String) { report(String(format: "[%5.1fs] ", Date().timeIntervalSince(start)) + message) }
        let work = DocsPaths.directory.appendingPathComponent("download-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress("Downloading the Apple documentation catalog…")
        let catalog = work.appendingPathComponent("technologies.json")
        try download(["\(DocsPaths.base)/documentation/technologies.json": catalog])
        let frameworks = try frameworkNames(fromCatalog: Data(contentsOf: catalog))

        progress("Downloading \(frameworks.count) framework indexes…")
        var files = Dictionary(uniqueKeysWithValues: frameworks.map {
            ("\(DocsPaths.base)/index/\($0)", work.appendingPathComponent("\($0).json"))
        })
        files[DocsPaths.swiftBookIndex] = work.appendingPathComponent("swift-book.json")
        try? download(files) // partial failures are reported below, not fatal

        // Sources outside the catalog; each is optional, so one failing doesn't stop the build.
        progress("Crawling the Human Interface Guidelines and tutorials…")
        var guides = (try? HIG.crawl(work: work, progress: progress)) ?? []
        guides += (try? Tutorials.crawl(work: work, progress: progress)) ?? []
        progress("Reading the App Store Review Guidelines and WWDC sessions…")
        guides += (try? ReviewGuidelines.pages(in: ReviewGuidelines.html(refresh: true))) ?? []
        guides += (try? WWDC.crawl(work: work)) ?? []

        progress("Building the search index…")
        let temp = DocsPaths.directory.appendingPathComponent("docs.db.building")
        try? FileManager.default.removeItem(at: temp)
        var failed: [String] = []
        let pages = try build(database: temp.path, guides: guides) { insert in
            for framework in frameworks {
                let file = work.appendingPathComponent("\(framework).json")
                guard let data = try? Data(contentsOf: file), !data.isEmpty else {
                    failed.append(framework)
                    continue
                }
                try insert(framework, data)
            }
            if let book = try? Data(contentsOf: work.appendingPathComponent("swift-book.json")), !book.isEmpty {
                try insert("swift-book", book)
            }
        }
        _ = try FileManager.default.replaceItemAt(DocsPaths.indexDatabase, withItemAt: temp)
        let counts = try SQLiteDatabase(path: DocsPaths.indexDatabase.path, readOnly: true).query(
            "SELECT CASE WHEN framework IN \(specialSourcesSQL) THEN framework ELSE 'api' END, count(*) FROM docs GROUP BY 1") {
            ($0.text(0), $0.int(1))
        }
        return DocsIndexStatus(path: DocsPaths.indexDatabase.path, pages: pages, frameworks: frameworks.count - failed.count,
                               failedFrameworks: failed, guidePages: guides.count,
                               sources: Dictionary(counts, uniquingKeysWith: +), seconds: (Date().timeIntervalSince(start) * 10).rounded() / 10)
    }

    /// Framework identifiers from the technologies catalog (references to /documentation/<name>).
    static func frameworkNames(fromCatalog data: Data) throws -> [String] {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let references = root["references"] as? [String: [String: Any]]
        else { throw IOSError.invalidOutput(tool: "technologies.json", reason: "missing references") }
        let names = references.values.compactMap { ref -> String? in
            guard let url = ref["url"] as? String, url.hasPrefix("/documentation/") else { return nil }
            let parts = url.split(separator: "/")
            return parts.count == 2 ? String(parts[1]) : nil
        }
        return Set(names).sorted()
    }

    /// Creates the schema and inserts every page `feed` provides; returns the page count.
    static func build(database path: String, guides: [GuidePage] = [], feed: ((String, Data) throws -> Void) throws -> Void) throws -> Int {
        let db = try SQLiteDatabase(path: path)
        try db.execute("""
            CREATE TABLE docs(id INTEGER PRIMARY KEY, path TEXT UNIQUE, title TEXT, kind TEXT, framework TEXT,
                              lang TEXT, beta INT, deprecated INT, parent TEXT);
            CREATE INDEX docs_framework ON docs(framework);
            CREATE VIRTUAL TABLE fts USING fts5(title, terms, parent, framework, content='', tokenize='porter unicode61');
            """)
        let count = try insertPages(db, feed: feed) + insertGuides(db, guides)
        try db.execute("VACUUM")
        return count
    }

    /// HIG pages go in as framework "hig". Their abstract is added to the low-weight parent
    /// column, which helps queries like "slider" or "dark mode" without outranking titles.
    private static func insertGuides(_ db: SQLiteDatabase, _ guides: [GuidePage]) throws -> Int {
        let insertDoc = try db.prepare("""
            INSERT OR IGNORE INTO docs(path, title, kind, framework, lang, beta, deprecated, parent)
            VALUES (?, ?, ?, ?, 'swift', 0, 0, ?)
            """)
        let insertText = try db.prepare("INSERT INTO fts(rowid, title, terms, parent, framework) VALUES (last_insert_rowid(), ?, ?, ?, ?)")
        try db.transaction {
            for guide in guides {
                try insertDoc.run([.text(guide.path), .text(guide.title), .text(guide.kind), .text(guide.framework), .text(guide.parent)])
                try insertText.run([
                    .text(guide.title), .text(splitWords(guide.title) + " " + splitWords(String(guide.path.split(separator: "/").last ?? ""))),
                    .text(splitWords(guide.parent) + " " + guide.abstract.lowercased()), .text(sourceWords[guide.framework] ?? guide.framework),
                ])
            }
        }
        return guides.count
    }

    /// Kept separate so its prepared statements are finalized before VACUUM, which refuses
    /// to run while statements are open.
    private static func insertPages(_ db: SQLiteDatabase, feed: ((String, Data) throws -> Void) throws -> Void) throws -> Int {
        let insertDoc = try db.prepare("""
            INSERT OR IGNORE INTO docs(path, title, kind, framework, lang, beta, deprecated, parent)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
        let insertText = try db.prepare("INSERT INTO fts(rowid, title, terms, parent, framework) VALUES (last_insert_rowid(), ?, ?, ?, ?)")
        let changes = try db.prepare("SELECT changes()")
        var count = 0

        try db.transaction {
            try feed { framework, data in
                guard
                    let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let languages = root["interfaceLanguages"] as? [String: Any]
                else { return }
                for language in ["swift", "occ", "data"] { // "data": REST and JavaScript APIs (App Store Connect, MapKit JS…)
                    guard let nodes = languages[language] as? [[String: Any]] else { continue }
                    try walk(nodes, parent: "") { node, parent in
                        guard
                            let path = node["path"] as? String, let title = node["title"] as? String,
                            let kind = node["type"] as? String, kind != "groupMarker",
                            node["external"] as? Bool != true
                        else { return }
                        let parts = path.split(separator: "/")
                        let pageFramework = framework == "swift-book" ? framework : (parts.count >= 2 ? String(parts[1]) : framework)
                        try insertDoc.run([
                            .text(path), .text(title), .text(kind), .text(pageFramework), .text(language),
                            .int(node["beta"] as? Bool == true ? 1 : 0), .int(node["deprecated"] as? Bool == true ? 1 : 0),
                            .text(parent),
                        ])
                        // Pages appear under several parents and in both languages; index each once.
                        try changes.bind([])
                        guard try changes.step(), changes.int(0) == 1 else { return }
                        try insertText.run([
                            .text(title), .text(splitWords(title) + " " + splitWords(String(parts.last ?? ""))),
                            .text(splitWords(parent)), .text(splitWords(pageFramework)),
                        ])
                        count += 1
                    }
                }
            }
        }
        return count
    }

    private static func walk(_ nodes: [[String: Any]], parent: String, visit: ([String: Any], String) throws -> Void) throws {
        for node in nodes {
            try visit(node, parent)
            if let children = node["children"] as? [[String: Any]] {
                let title = node["path"] != nil ? (node["title"] as? String ?? parent) : parent
                try walk(children, parent: title, visit: visit)
            }
        }
    }

    /// "navigationDestination(for:)" → "navigation destination for"; makes camelCase searchable.
    /// A single pass over ASCII bytes: Swift Regex made index builds ~10× slower.
    static func splitWords(_ text: String) -> String {
        enum Kind { case other, lower, upper, digit }
        func kind(_ b: UInt8) -> Kind {
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): .lower
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): .upper
            case UInt8(ascii: "0")...UInt8(ascii: "9"): .digit
            default: .other
            }
        }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 8)
        for (i, byte) in bytes.enumerated() {
            let current = kind(byte)
            if current == .other {
                if out.last != UInt8(ascii: " ") { out.append(UInt8(ascii: " ")) }
                continue
            }
            if i > 0 {
                let previous = kind(bytes[i - 1])
                let next = i + 1 < bytes.count ? kind(bytes[i + 1]) : .other
                // fooBar → foo bar; URLSession → url session
                if (current == .upper && (previous == .lower || previous == .digit))
                    || (current == .upper && previous == .upper && next == .lower) {
                    out.append(UInt8(ascii: " "))
                }
            }
            out.append(current == .upper ? byte + 32 : byte)
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Search

    /// `excludeSources` limits results to API documentation (frameworks), leaving out the HIG,
    /// tutorials, Swift book, Review Guidelines and WWDC sessions.
    public static func search(_ query: String, framework: String? = nil, kind: String? = nil, limit: Int = 10,
                              excludeSources: Bool = false) throws -> [DocsSearchResult] {
        let db = try SQLiteDatabase(path: DocsPaths.indexDatabase.path, readOnly: true)
        var tokens = splitWords(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }

        // "core bluetooth scan" → framework hint "corebluetooth" (identifiers have no separators).
        let frameworks = Set(try db.query("SELECT DISTINCT framework FROM docs") { $0.text(0) })
        var hint: String?
        search: for n in [3, 2, 1] where tokens.count >= n {
            for i in 0...(tokens.count - n) {
                let joined = tokens[i..<(i + n)].joined()
                if frameworks.contains(joined), n > 1 || tokens.count > 1 {
                    hint = joined
                    tokens.removeSubrange(i..<(i + n))
                    break search
                }
            }
        }
        if let h = hint, tokens.isEmpty { tokens = [h]; hint = nil }

        // "NSTableView", "UIViewController": a symbol name, not a description.
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let queryIsIdentifier = !trimmed.contains(" ") && trimmed.contains(where: \.isUppercase)
        if let hint, framework == nil {
            let boosted = try rankedSearch(db, tokens: tokens, framework: hint, kind: kind, limit: limit, excludeSources: excludeSources,
                                           queryIsIdentifier: queryIsIdentifier)
            if !boosted.isEmpty { return boosted }
        }
        return try rankedSearch(db, tokens: tokens, framework: framework?.lowercased(), kind: kind, limit: limit, excludeSources: excludeSources,
                                queryIsIdentifier: queryIsIdentifier)
    }

    private static func rankedSearch(_ db: SQLiteDatabase, tokens: [String], framework: String?, kind: String?, limit: Int,
                                     excludeSources: Bool = false, queryIsIdentifier: Bool = false) throws -> [DocsSearchResult] {
        struct Row {
            let result: DocsSearchResult
            let score: Double
        }
        func run(_ match: String) throws -> [Row] {
            var sql = """
                SELECT d.path, d.title, d.kind, d.framework, d.beta, d.deprecated, d.lang, d.parent,
                       bm25(fts, 10.0, 6.0, 1.5, 3.0) AS score
                FROM fts JOIN docs d ON d.id = fts.rowid
                WHERE fts MATCH ?
                """
            var values: [SQLValue] = [.text(match)]
            if let framework { sql += " AND d.framework = ?"; values.append(.text(framework)) }
            if let kind { sql += " AND d.kind = ?"; values.append(.text(kind)) }
            if excludeSources { sql += " AND d.framework NOT IN \(specialSourcesSQL)" }
            sql += " ORDER BY score LIMIT 400"
            return try db.query(sql, values) { s in
                Row(result: DocsSearchResult(path: s.text(0), title: s.text(1), kind: s.text(2), framework: s.text(3),
                                             beta: s.int(4) != 0, deprecated: s.int(5) != 0, language: s.text(6), parent: s.text(7)),
                    score: s.double(8))
            }
        }

        // Each word also matches the word Apple's API names use for it ("push" → "remote").
        func term(_ token: String) -> String {
            let words = [token] + (synonyms[token] ?? [])
            return words.count == 1 ? "\"\(token)\"*" : "(" + words.map { "\"\($0)\"*" }.joined(separator: " OR ") + ")"
        }
        var rows = try run(tokens.map(term).joined(separator: " AND "))
        if rows.count < limit { // relax to OR when the strict query is too narrow
            let seen = Set(rows.map(\.result.path))
            rows += try run(tokens.map(term).joined(separator: " OR ")).filter { !seen.contains($0.result.path) }
        }
        let joinedTokens = tokens.joined()
        // Searching within one framework already chose the platform.
        let otherPlatforms = framework == nil ? otherPlatformFrameworks() : []
        func rank(_ row: Row) -> Double {
            let r = row.result
            var s = -row.score + (kindBoost[r.kind] ?? 0)
            if r.deprecated { s -= 3 }
            if r.language == "occ" { s -= 1 }
            s += sourceBoost[r.framework] ?? 0
            if tokens.contains(r.framework) || joinedTokens.contains(r.framework.replacingOccurrences(of: "-", with: "")) { s += 1 }
            s -= 0.15 * Double(r.path.filter { $0 == "/" }.count) // prefer shallower pages
            if otherPlatforms.contains(r.framework) { s -= otherPlatformPenalty }
            // The query is the page's exact name ("NSTableView", "color picker" → ColorPicker): that page,
            // whatever its platform, is what was asked for.
            // Only symbol-like titles ("ColorPicker", not the "Text Field" collection or a `window` property),
            // and other platforms' pages only when the query itself is an identifier.
            if r.title.lowercased().filter({ $0.isLetter || $0.isNumber }) == joinedTokens,
               !r.title.contains(" "), r.title.contains(where: \.isUppercase),
               !otherPlatforms.contains(r.framework) || queryIsIdentifier { s += 5 }
            return s
        }
        return rows.sorted { rank($0) > rank($1) }.prefix(limit).map(\.result)
    }

    // MARK: Downloads

    /// Downloads URLs to files with curl, 4 at a time. Throws only if curl itself can't run
    /// or nothing was downloaded; callers check which files exist.
    static func download(_ files: [String: URL]) throws {
        var config = ""
        for (url, file) in files.sorted(by: { $0.key < $1.key }) {
            config += "url = \"\(url)\"\noutput = \"\(file.path)\"\n"
        }
        let configFile = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cli-curl-\(UUID().uuidString).cfg")
        try config.write(to: configFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: configFile) }

        let result = try Shell.run("/usr/bin/curl", [
            "--silent", "--show-error", "--fail", "--location", "--parallel", "--parallel-max", "4",
            "--retry", "2", "--max-time", "120", "--user-agent", DocsPaths.userAgent, "--config", configFile.path,
        ])
        let downloaded = files.values.contains { FileManager.default.fileExists(atPath: $0.path) }
        if result.status != 0 && !downloaded {
            throw IOSError.download(url: files.keys.sorted().first ?? "", message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
