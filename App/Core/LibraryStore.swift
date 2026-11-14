import Combine
import Foundation

/// One manga as stored on the iPad (library entry and/or reading history).
struct StoredManga: Identifiable, Equatable {
    var sourceId: String
    var mangaId: String
    var title: String
    var cover: String?
    var author: String?
    var status: String?
    var description: String?
    var tags: [String]
    var inLibrary: Bool
    var lastReadAt: Double?
    var lastChapterId: String?
    var unread: Int
    var total: Int

    var id: String { sourceId + "|" + mangaId }
}

/// Saved state of one chapter.
struct ChapterProgress: Equatable {
    var read = false
    var lastPage = 0
    var pageCount = 0
}

/// Library, history and reading progress. All of it lives in the SQLite
/// database, so it survives app updates.
@MainActor
final class LibraryStore: ObservableObject {
    /// Bumped after every change so screens showing library data reload.
    @Published private(set) var revision = 0

    private let db = Database.shared
    var databaseProblem: String? { db.problem }

    private func changed() { revision += 1 }

    private static let mangaColumns = """
        m.*, (SELECT COUNT(*) FROM chapter c WHERE c.source_id = m.source_id AND c.manga_id = m.manga_id AND c.read = 0) AS unread,
        (SELECT COUNT(*) FROM chapter c WHERE c.source_id = m.source_id AND c.manga_id = m.manga_id) AS total
        """

    private func manga(from row: [String: Any]) -> StoredManga {
        let tagsText = row["tags"] as? String ?? ""
        return StoredManga(
            sourceId: row["source_id"] as? String ?? "",
            mangaId: row["manga_id"] as? String ?? "",
            title: row["title"] as? String ?? "",
            cover: row["cover"] as? String,
            author: row["author"] as? String,
            status: row["status"] as? String,
            description: row["description"] as? String,
            tags: tagsText.isEmpty ? [] : tagsText.components(separatedBy: "\u{1F}"),
            inLibrary: (row["in_library"] as? Int64 ?? 0) != 0,
            lastReadAt: row["last_read_at"] as? Double,
            lastChapterId: row["last_chapter_id"] as? String,
            unread: Int(row["unread"] as? Int64 ?? 0),
            total: Int(row["total"] as? Int64 ?? 0))
    }

    // MARK: Reading

    func library() -> [StoredManga] {
        db.rows("SELECT \(LibraryStore.mangaColumns) FROM manga m WHERE in_library = 1 ORDER BY COALESCE(last_read_at, added_at) DESC")
            .map(manga(from:))
    }

    /// Recently read titles, newest first (library or not).
    func history(limit: Int = 20) -> [StoredManga] {
        db.rows("SELECT \(LibraryStore.mangaColumns) FROM manga m WHERE last_read_at IS NOT NULL ORDER BY last_read_at DESC LIMIT ?", [limit])
            .map(manga(from:))
    }

    /// Where reading stopped in a title: chapter name, page and page count.
    func lastRead(_ manga: StoredManga) -> (name: String, page: Int, pageCount: Int)? {
        guard let chapterId = manga.lastChapterId,
              let row = db.rows("SELECT name, chap_num, last_page, page_count FROM chapter WHERE source_id = ? AND manga_id = ? AND chapter_id = ?",
                                [manga.sourceId, manga.mangaId, chapterId]).first else { return nil }
        var name = row["name"] as? String ?? ""
        if name.isEmpty, let number = row["chap_num"] as? Double {
            name = "Chapter \(number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(number)) : String(number))"
        }
        return (name, Int(row["last_page"] as? Int64 ?? 0), Int(row["page_count"] as? Int64 ?? 0))
    }

    /// Numbers for the tiles on the Library screen.
    func stats() -> (titles: Int, chaptersRead: Int, unread: Int) {
        let titles = db.rows("SELECT COUNT(*) AS n FROM manga WHERE in_library = 1").first?["n"] as? Int64 ?? 0
        let read = db.rows("SELECT COUNT(*) AS n FROM chapter WHERE read = 1").first?["n"] as? Int64 ?? 0
        let unread = db.rows("""
            SELECT COUNT(*) AS n FROM chapter c JOIN manga m ON m.source_id = c.source_id AND m.manga_id = c.manga_id
            WHERE m.in_library = 1 AND c.read = 0
            """).first?["n"] as? Int64 ?? 0
        return (Int(titles), Int(read), Int(unread))
    }

    /// Everything in the library or in the history: the basis for suggestions.
    func tasteTitles() -> [StoredManga] {
        db.rows("SELECT \(LibraryStore.mangaColumns) FROM manga m WHERE in_library = 1 OR last_read_at IS NOT NULL")
            .map(manga(from:))
    }

    func manga(sourceId: String, mangaId: String) -> StoredManga? {
        db.rows("SELECT \(LibraryStore.mangaColumns) FROM manga m WHERE source_id = ? AND manga_id = ?", [sourceId, mangaId])
            .first.map(manga(from:))
    }

    /// Chapters as last saved, in the source's own order. Used when offline.
    func cachedChapters(sourceId: String, mangaId: String) -> [Chapter] {
        db.rows("SELECT * FROM chapter WHERE source_id = ? AND manga_id = ? ORDER BY position", [sourceId, mangaId]).map { row in
            Chapter(id: row["chapter_id"] as? String ?? "",
                    chapNum: row["chap_num"] as? Double,
                    name: row["name"] as? String,
                    volume: row["volume"] as? Double,
                    group: row["grp"] as? String,
                    time: row["time"] as? String,
                    langCode: row["lang"] as? String)
        }
    }

    func progress(sourceId: String, mangaId: String) -> [String: ChapterProgress] {
        var result: [String: ChapterProgress] = [:]
        for row in db.rows("SELECT chapter_id, read, last_page, page_count FROM chapter WHERE source_id = ? AND manga_id = ?", [sourceId, mangaId]) {
            guard let id = row["chapter_id"] as? String else { continue }
            result[id] = ChapterProgress(read: (row["read"] as? Int64 ?? 0) != 0,
                                         lastPage: Int(row["last_page"] as? Int64 ?? 0),
                                         pageCount: Int(row["page_count"] as? Int64 ?? 0))
        }
        return result
    }

    // MARK: Writing

    /// Creates or refreshes the stored details of a manga. Library membership
    /// and history are left untouched.
    func saveDetails(sourceId: String, mangaId: String, title: String, cover: String?, info: MangaInfo?) {
        let tags = (info?.tags ?? []).flatMap { $0.tags ?? [] }.map { $0.label }.joined(separator: "\u{1F}")
        db.run("""
            INSERT INTO manga(source_id, manga_id, title, cover, author, status, description, tags)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id, manga_id) DO UPDATE SET
                title = excluded.title,
                cover = COALESCE(excluded.cover, cover),
                author = COALESCE(excluded.author, author),
                status = COALESCE(excluded.status, status),
                description = COALESCE(excluded.description, description),
                tags = CASE WHEN excluded.tags = '' THEN tags ELSE excluded.tags END
            """, [sourceId, mangaId, title, (cover?.isEmpty ?? true) ? nil : cover, info?.author, info?.status, info?.desc, tags])
        changed()
    }

    /// Stores the chapter list. Read marks and page positions of chapters
    /// that still exist are kept; chapters the source removed are dropped.
    func saveChapters(sourceId: String, mangaId: String, chapters: [Chapter]) {
        var statements: [(String, [Any?])] = [
            ("UPDATE chapter SET position = -1 WHERE source_id = ? AND manga_id = ?", [sourceId, mangaId])
        ]
        for (position, c) in chapters.enumerated() {
            statements.append(("""
                INSERT INTO chapter(source_id, manga_id, chapter_id, name, chap_num, volume, grp, time, lang, position)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id, manga_id, chapter_id) DO UPDATE SET
                    name = excluded.name, chap_num = excluded.chap_num, volume = excluded.volume,
                    grp = excluded.grp, time = excluded.time, lang = excluded.lang, position = excluded.position
                """, [sourceId, mangaId, c.id, c.name, c.chapNum, c.volume, c.group, c.time, c.langCode, position]))
        }
        statements.append(("DELETE FROM chapter WHERE source_id = ? AND manga_id = ? AND position = -1", [sourceId, mangaId]))
        db.transaction(statements)
        changed()
    }

    func setInLibrary(_ value: Bool, sourceId: String, mangaId: String) {
        db.run("UPDATE manga SET in_library = ?, added_at = COALESCE(added_at, ?) WHERE source_id = ? AND manga_id = ?",
               [value, Date().timeIntervalSince1970, sourceId, mangaId])
        changed()
    }

    /// Called by the reader whenever the visible page changes.
    /// `finished` is true once the last page of the chapter has been shown.
    func savePosition(sourceId: String, mangaId: String, chapterId: String, page: Int, pageCount: Int, finished: Bool) {
        let now = Date().timeIntervalSince1970
        db.transaction([
            ("""
             UPDATE chapter SET last_page = ?, page_count = ?, read_at = ?, read = CASE WHEN ? THEN 1 ELSE read END
             WHERE source_id = ? AND manga_id = ? AND chapter_id = ?
             """, [page, pageCount, now, finished, sourceId, mangaId, chapterId]),
            ("UPDATE manga SET last_read_at = ?, last_chapter_id = ? WHERE source_id = ? AND manga_id = ?",
             [now, chapterId, sourceId, mangaId])
        ])
        changed()
    }

    func setRead(_ read: Bool, sourceId: String, mangaId: String, chapterIds: [String]) {
        let sql = "UPDATE chapter SET read = ?, last_page = CASE WHEN ? THEN last_page ELSE 0 END WHERE source_id = ? AND manga_id = ? AND chapter_id = ?"
        var statements: [(String, [Any?])] = []
        for id in chapterIds {
            let values: [Any?] = [read, read, sourceId, mangaId, id]
            statements.append((sql, values))
        }
        db.transaction(statements)
        changed()
    }

    func removeFromHistory(sourceId: String, mangaId: String) {
        db.run("UPDATE manga SET last_read_at = NULL, last_chapter_id = NULL WHERE source_id = ? AND manga_id = ?", [sourceId, mangaId])
        changed()
    }
}

/// Works out reading order and where "Continue" should go.
enum ReadingOrder {
    /// Sources usually list the newest chapter first. Returns the chapters
    /// oldest-first, which is the order they are read in.
    static func ordered(_ chapters: [Chapter]) -> [Chapter] {
        guard let first = chapters.first(where: { $0.chapNum != nil })?.chapNum,
              let last = chapters.last(where: { $0.chapNum != nil })?.chapNum else {
            return chapters.reversed()
        }
        return first > last ? chapters.reversed() : chapters
    }

    struct Target {
        var index: Int      // index into the ordered list
        var page: Int
        var isStart: Bool   // true when nothing has been read yet
    }

    static func continueTarget(ordered: [Chapter], progress: [String: ChapterProgress], lastChapterId: String?) -> Target? {
        guard !ordered.isEmpty else { return nil }
        if let lastId = lastChapterId, let i = ordered.firstIndex(where: { $0.id == lastId }) {
            let state = progress[lastId] ?? ChapterProgress()
            if !state.read { return Target(index: i, page: state.lastPage, isStart: false) }
            // Finished that one: go to the next chapter that is not read yet.
            if let next = ordered.indices.first(where: { $0 > i && !(progress[ordered[$0].id]?.read ?? false) }) {
                return Target(index: next, page: progress[ordered[next].id]?.lastPage ?? 0, isStart: false)
            }
            return Target(index: i, page: 0, isStart: false)
        }
        if let firstUnread = ordered.indices.first(where: { !(progress[ordered[$0].id]?.read ?? false) }) {
            let anyRead = progress.values.contains { $0.read || $0.lastPage > 0 }
            return Target(index: firstUnread, page: progress[ordered[firstUnread].id]?.lastPage ?? 0, isStart: !anyRead)
        }
        return Target(index: ordered.count - 1, page: 0, isStart: false)
    }
}
