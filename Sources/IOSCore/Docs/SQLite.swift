import Foundation
import SQLite3

/// Minimal wrapper over the system SQLite (which includes FTS5).
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw IOSError.database(path: path, message: message)
        }
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw IOSError.database(path: "", message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw IOSError.database(path: "", message: String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(statement)
    }

    /// Runs a query and maps each row.
    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (Statement) -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(values)
        var rows: [T] = []
        while try statement.step() { rows.append(map(statement)) }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

enum SQLValue {
    case text(String)
    case int(Int)
    case null
}

final class Statement {
    private let handle: OpaquePointer

    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_finalize(handle) }

    /// SQLITE_TRANSIENT: SQLite copies bound strings (the C macro isn't imported into Swift).
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .text(text): sqlite3_bind_text(handle, index, text, -1, Self.transient)
            case let .int(number): sqlite3_bind_int64(handle, index, Int64(number))
            case .null: sqlite3_bind_null(handle, index)
            }
        }
    }

    /// Advances to the next row; false when done.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw IOSError.database(path: "", message: String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
        }
    }

    /// Binds and runs a statement that returns no rows (INSERT etc.).
    func run(_ values: [SQLValue]) throws {
        try bind(values)
        _ = try step()
    }

    func text(_ column: Int32) -> String {
        sqlite3_column_text(handle, column).map { String(cString: $0) } ?? ""
    }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
}
