import Combine
import Darwin
import Foundation
import SQLite3

/// Only bounded previews are kept in the panel. Full text is read for a single explicit copy.
struct DictationHistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let preview: String
}

@MainActor final class DictationHistory: ObservableObject {
    nonisolated static let defaultLimit = 100
    nonisolated static let limits = 0...500
    @Published private(set) var entries: [DictationHistoryEntry] = []
    @Published private(set) var limit = defaultLimit
    @Published private(set) var isLoaded = false
    @Published private(set) var issue: String?

    private let directory: URL
    private let temporary: Bool
    private let queue = DispatchQueue(label: "com.untitled.app.dictation-history", qos: .utility)
    private var removed = false
    private var submitted = 0, applied = 0
    private var loading = false

    static func directory(for preferencesURL: URL) -> URL {
        preferencesURL.deletingPathExtension().appendingPathExtension("history")
    }

    init(preferencesURL: URL?) {
        temporary = preferencesURL == nil
        directory = preferencesURL.map(Self.directory(for:)) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-history-" + UUID().uuidString, isDirectory: true)
    }
    deinit { if temporary { try? FileManager.default.removeItem(at: directory) } }

    func load() async {
        guard !isLoaded, !loading, !removed else { return }
        loading = true
        defer { loading = false }
        do { try await update(.read) }
        catch { if !removed { issue = "无法读取识别历史，原文件已保留。" } }
    }
    func record(id: UUID, text: String, date: Date = Date()) async {
        guard !removed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try await update(.insert(id, date, text)) }
        catch { if !removed { issue = "未能保存本次识别，请复制需要的文字。" } }
    }
    func setLimit(_ value: Int) async throws {
        guard Self.limits.contains(value) else { throw PluginError.invalid("保留条数须为 0–500。") }
        try await update(.resize(value))
    }
    func clear() async throws { try await update(.clear) }
    func text(for id: UUID) async throws -> String {
        let text = try await perform { try HistoryFile.text(for: id, in: $0) }
        guard !removed else { throw CancellationError() }
        return text
    }

    func finishPendingIO() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    /// The host can uninstall synchronously. Drain previously submitted I/O before it removes
    /// the private directory; a retained old view or a late final must never recreate it.
    func invalidateForUninstall() {
        removed = true
        queue.sync {}
        entries = []; isLoaded = false; issue = nil
    }

    private func update(_ change: HistoryFile.Change) async throws {
        submitted += 1
        let ticket = submitted
        let snapshot = try await perform { try HistoryFile.apply(change, in: $0) }
        guard !removed, ticket > applied else { return }
        applied = ticket; limit = snapshot.limit; entries = snapshot.entries; isLoaded = true; issue = nil
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable (URL) throws -> T) async throws -> T {
        guard !removed else { throw CancellationError() }
        let directory = directory
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work(directory) }) }
        }
    }
}

private enum HistoryFile {
    enum Change: Sendable { case read, insert(UUID, Date, String), resize(Int), clear }
    struct Snapshot: Sendable { let limit: Int; let entries: [DictationHistoryEntry] }
    static let unavailable = PluginError.invalid("无法访问识别历史，请检查应用支持目录的空间和权限。")
    private static let defaultLimit = DictationHistory.defaultLimit

    static func apply(_ change: Change, in directory: URL) throws -> Snapshot {
        let file = directory.appendingPathComponent("records.sqlite3")
        let exists = FileManager.default.fileExists(atPath: file.path)
        if case .read = change, !exists { return Snapshot(limit: defaultLimit, entries: []) }
        if case .clear = change, !exists { return Snapshot(limit: defaultLimit, entries: []) }
        let writing: Bool = if case .read = change { false } else { true }
        let db = try Connection(file, writing: writing)
        if !exists {
            try db.exec("""
                BEGIN IMMEDIATE;
                CREATE TABLE retention (id INTEGER PRIMARY KEY CHECK(id=1), amount INTEGER NOT NULL);
                INSERT INTO retention VALUES (1, \(defaultLimit));
                CREATE TABLE entries (seq INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, date REAL NOT NULL,
                                      preview TEXT NOT NULL, body TEXT NOT NULL);
                COMMIT;
                """)
        }
        // Closing an uncommitted connection rolls back both the limit and any deleted rows.
        if writing { try db.exec("PRAGMA secure_delete = ON; BEGIN IMMEDIATE") }
        var limit = try db.readLimit()
        switch change {
        case .read: break
        case let .resize(newLimit):
            let set = try db.statement("UPDATE retention SET amount=? WHERE id=1")
            try set.integer(newLimit, at: 1); try set.finish(); limit = newLimit
            try db.trim(to: limit)
        case .clear: try db.exec("DELETE FROM entries")
        case let .insert(id, date, text):
            if limit > 0 {
                guard text.utf16.count <= DoubaoASRLimits.textLength else { throw unavailable }
                let insert = try db.statement("INSERT INTO entries (id,date,preview,body) VALUES (?,?,?,?)")
                try insert.string(id.uuidString, at: 1)
                guard sqlite3_bind_double(insert.handle, 2, date.timeIntervalSince1970) == SQLITE_OK else { throw unavailable }
                let prefix = text.unicodeScalars.prefix(160)
                try insert.string(String(prefix) + (prefix.endIndex == text.unicodeScalars.endIndex ? "" : "…"), at: 3)
                try insert.string(text, at: 4); try insert.finish()
                try db.trim(to: limit)
            }
        }
        let select = try db.statement("SELECT id,date,preview FROM entries ORDER BY seq DESC LIMIT ?")
        try select.integer(limit, at: 1)
        var entries: [DictationHistoryEntry] = []
        while try select.row() {
            guard let id = UUID(uuidString: select.string(at: 0)) else { throw unavailable }
            entries.append(.init(id: id, date: Date(timeIntervalSince1970: sqlite3_column_double(select.handle, 1)),
                                 preview: select.string(at: 2)))
        }
        if writing { try db.exec("COMMIT") }
        return Snapshot(limit: limit, entries: entries)
    }

    static func text(for id: UUID, in directory: URL) throws -> String {
        let db = try Connection(directory.appendingPathComponent("records.sqlite3"), writing: false)
        let read = try db.statement("SELECT body FROM entries WHERE id=?")
        try read.string(id.uuidString, at: 1)
        guard try read.row() else { throw PluginError.invalid("这条识别记录已清除。") }
        return read.string(at: 0)
    }

    /// All handles are short-lived and confined to the history's serial I/O queue.
    private final class Connection {
        let handle: OpaquePointer
        init(_ file: URL, writing: Bool) throws {
            if writing {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            // macOS temporary roots can start with /var (a symlink to /private/var).
            // Canonicalize the trusted parent, but never follow a symlink for the plugin's
            // history directory or database itself.
            let directory = file.deletingLastPathComponent()
            guard let parent = realpath(directory.deletingLastPathComponent().path, nil) else { throw unavailable }
            defer { free(parent) }
            let path = String(cString: parent) + "/" + directory.lastPathComponent + "/" + file.lastPathComponent
            var raw: OpaquePointer?
            let flags = writing ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
            guard sqlite3_open_v2(path, &raw, flags | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let raw else {
                sqlite3_close(raw); throw unavailable
            }
            handle = raw
            sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 256 * 1024)
            sqlite3_busy_timeout(handle, 500)
        }
        deinit { sqlite3_close_v2(handle) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw unavailable }
        }
        func statement(_ sql: String) throws -> Statement { try Statement(db: self, sql: sql) }
        func readLimit() throws -> Int {
            let read = try statement("SELECT amount FROM retention WHERE id=1")
            guard try read.row(), sqlite3_column_type(read.handle, 0) == SQLITE_INTEGER else { throw unavailable }
            let value = Int(sqlite3_column_int64(read.handle, 0))
            guard DictationHistory.limits.contains(value) else { throw unavailable }
            return value
        }
        func trim(to limit: Int) throws {
            let delete = try statement("DELETE FROM entries WHERE seq <= (SELECT seq FROM entries ORDER BY seq DESC LIMIT 1 OFFSET ?)")
            try delete.integer(limit, at: 1); try delete.finish()
        }
    }

    private final class Statement {
        let handle: OpaquePointer
        private let database: Connection
        init(db: Connection, sql: String) throws {
            database = db
            var raw: OpaquePointer?
            guard sqlite3_prepare_v2(db.handle, sql, -1, &raw, nil) == SQLITE_OK, let raw else { throw unavailable }
            handle = raw
        }
        deinit { sqlite3_finalize(handle) }
        func integer(_ value: Int, at index: Int32) throws {
            guard sqlite3_bind_int64(handle, index, Int64(value)) == SQLITE_OK else { throw unavailable }
        }
        func string(_ value: String, at index: Int32) throws {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(handle, index, value, Int32(value.utf8.count), transient) == SQLITE_OK else { throw unavailable }
        }
        func string(at index: Int32) -> String {
            guard let bytes = sqlite3_column_text(handle, index) else { return "" }
            return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(handle, index))), as: UTF8.self)
        }
        func row() throws -> Bool {
            switch sqlite3_step(handle) { case SQLITE_ROW: return true; case SQLITE_DONE: return false; default: throw unavailable }
        }
        func finish() throws { guard try !row() else { throw unavailable } }
    }
}
