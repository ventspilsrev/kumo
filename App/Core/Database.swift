import Foundation
import SQLite3

/// Thin wrapper around the SQLite library that ships with iOS.
///
/// Data safety: the schema is versioned. `migrations` is an append-only list;
/// entry N upgrades the database from version N to N+1 and the current
/// version is stored in the file (`PRAGMA user_version`). An app update only
/// runs the steps the file has not seen yet, so existing data is kept.
/// NEVER edit or reorder an existing migration. Only add new ones at the end.
final class Database {
    static let shared = Database()

    private static let migrations: [String] = [
        // 0 -> 1: library, chapters with reading progress, settings.
        """
        CREATE TABLE manga(
            source_id TEXT NOT NULL,
            manga_id TEXT NOT NULL,
            title TEXT NOT NULL,
            cover TEXT,
            author TEXT,
            status TEXT,
            description TEXT,
            tags TEXT,
            in_library INTEGER NOT NULL DEFAULT 0,
            added_at REAL,
            last_read_at REAL,
            last_chapter_id TEXT,
            PRIMARY KEY(source_id, manga_id)
        );
        CREATE TABLE chapter(
            source_id TEXT NOT NULL,
            manga_id TEXT NOT NULL,
            chapter_id TEXT NOT NULL,
            name TEXT,
            chap_num REAL,
            volume REAL,
            grp TEXT,
            time TEXT,
            lang TEXT,
            position INTEGER NOT NULL,
            read INTEGER NOT NULL DEFAULT 0,
            last_page INTEGER NOT NULL DEFAULT 0,
            page_count INTEGER NOT NULL DEFAULT 0,
            read_at REAL,
            PRIMARY KEY(source_id, manga_id, chapter_id)
        );
        CREATE INDEX chapter_by_manga ON chapter(source_id, manga_id, position);
        CREATE TABLE setting(key TEXT PRIMARY KEY, value TEXT);
        """
    ]

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "kumo.database")
    /// Set when the database could not be opened or upgraded. Shown in the UI.
    private(set) var problem: String?

    private init() {
        let url = AppPaths.support.appendingPathComponent("kumo.sqlite")
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            problem = "The library database could not be opened: \(lastError())"
            Log.error(problem ?? "")
            return
        }
        _ = run("PRAGMA journal_mode=WAL")
        _ = run("PRAGMA foreign_keys=ON")
        migrate()
    }

    private func lastError() -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    private func migrate() {
        var version = Int(rows("PRAGMA user_version").first?["user_version"] as? Int64 ?? 0)
        if version > Database.migrations.count {
            // The file was written by a NEWER build. Do not touch it.
            problem = "The library was created by a newer version of Kumo. Install the newest build."
            Log.error(problem ?? "")
            return
        }
        while version < Database.migrations.count {
            let sql = "BEGIN;\n\(Database.migrations[version])\nPRAGMA user_version=\(version + 1);\nCOMMIT;"
            if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
                let message = lastError()
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
                problem = "Library upgrade step \(version + 1) failed: \(message)"
                Log.error(problem ?? "")
                return
            }
            version += 1
            Log.info("Database upgraded to version \(version)")
        }
    }

    // MARK: Statements

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ statement: OpaquePointer?, _ values: [Any?]) {
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, index)
            case let v as String: sqlite3_bind_text(statement, index, v, -1, Database.transient)
            case let v as Int: sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(statement, index, v)
            case let v as Bool: sqlite3_bind_int64(statement, index, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(statement, index, v)
            default: sqlite3_bind_text(statement, index, "\(value!)", -1, Database.transient)
            }
        }
    }

    private func unlockedRun(_ sql: String, _ values: [Any?]) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            Log.error("SQL prepare failed: \(lastError()) in: \(sql.prefix(80))")
            return false
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        let code = sqlite3_step(statement)
        if code != SQLITE_DONE && code != SQLITE_ROW {
            Log.error("SQL failed: \(lastError()) in: \(sql.prefix(80))")
            return false
        }
        return true
    }

    /// Runs one statement that returns nothing.
    @discardableResult
    func run(_ sql: String, _ values: [Any?] = []) -> Bool {
        queue.sync { handle != nil && unlockedRun(sql, values) }
    }

    /// Runs many statements as one all-or-nothing transaction.
    @discardableResult
    func transaction(_ statements: [(String, [Any?])]) -> Bool {
        queue.sync {
            guard handle != nil else { return false }
            sqlite3_exec(handle, "BEGIN", nil, nil, nil)
            for (sql, values) in statements where !unlockedRun(sql, values) {
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
                return false
            }
            return sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK
        }
    }

    /// Runs a query. Values come back as Int64, Double, String or NSNull.
    func rows(_ sql: String, _ values: [Any?] = []) -> [[String: Any]] {
        queue.sync {
            var statement: OpaquePointer?
            guard handle != nil, sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                if handle != nil { Log.error("SQL prepare failed: \(lastError()) in: \(sql.prefix(80))") }
                return []
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, values)
            var result: [[String: Any]] = []
            let columns = sqlite3_column_count(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                var row: [String: Any] = [:]
                for c in 0..<columns {
                    let name = String(cString: sqlite3_column_name(statement, c))
                    switch sqlite3_column_type(statement, c) {
                    case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, c)
                    case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, c)
                    case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, c))
                    default: row[name] = NSNull()
                    }
                }
                result.append(row)
            }
            return result
        }
    }
}
