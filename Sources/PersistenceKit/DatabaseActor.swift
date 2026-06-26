//
//  DatabaseActor.swift
//  PersistenceKit
//
// A small, app-agnostic actor wrapping a GRDB `DatabaseQueue`: WAL + foreign-keys configured, a
// caller-supplied `DatabaseMigrator` run at open, generic read/write/fetch/save/delete primitives, a
// `ValueObservation` → Combine bridge, and SQLite's online-backup copy. The schema (migrations,
// record types) is the consuming app's; this owns only the connection lifecycle and the plumbing.

import Combine
import Foundation
import GRDB

public actor DatabaseActor {
    private let databaseQueue: DatabaseQueue
    private nonisolated var reader: any DatabaseReader { databaseQueue }

    /// Opens (or creates) a file-backed database at `path` and runs `migrator` against it.
    public init(path: URL, migrator: DatabaseMigrator) throws {
        self.databaseQueue = try DatabaseQueue(path: path.path)
        try Self.configure(databaseQueue, migrator: migrator)
    }

    /// Creates a true SQLite in-memory database (no file I/O) and runs `migrator` against it.
    /// Useful for testing or sandboxed environments where file-backed storage is unavailable.
    public init(inMemory: Bool, migrator: DatabaseMigrator) throws {
        precondition(inMemory, "Pass inMemory: true to use the in-memory initializer.")
        self.databaseQueue = try DatabaseQueue(path: ":memory:")
        try Self.configure(databaseQueue, migrator: migrator)
    }

    private static func configure(_ queue: DatabaseQueue, migrator: DatabaseMigrator) throws {
        try queue.inDatabase { database in
            // Enables enforcement of FOREIGN KEY constraints.
            //
            // IMPORTANT:
            // - SQLite parses FOREIGN KEY clauses by default, but does NOT enforce them
            //   unless this is explicitly turned ON.
            // - Without this, ON DELETE CASCADE, NOT NULL references, etc. are silently ignored.
            //
            // Rule of thumb:
            // Always turn this ON for application databases.
            try database.execute(sql: "PRAGMA foreign_keys = ON")

            // Enables Write-Ahead Logging (WAL) journaling mode.
            //
            // What this changes:
            // - Writes are appended to a WAL file instead of locking the main database.
            // - Readers do NOT block writers, and writers do NOT block readers.
            //
            // Important constraints:
            // - This PRAGMA MUST be executed outside of a transaction,
            // - hence why we're using `.inDatabase` instead of `.write` here.
            // - It should be set once when the database is opened.
            //
            // Rule of thumb:
            // WAL is almost always the correct choice for on-device app databases.
            try database.execute(sql: "PRAGMA journal_mode = WAL")
        }
        try migrator.migrate(queue)
    }

    // MARK: Database Methods
    /// The blocks are prefixed with `@Sendable` to ensure sendable rules on these closures

    public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        try await databaseQueue.read(block)
    }

    public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        try await databaseQueue.write(block)
    }

    /// Closes the underlying SQLite connection, releasing its WAL handle and file locks. An app keeps
    /// one actor for its whole lifetime and never calls this; tests call it during teardown so test
    /// connections are released rather than left open until ARC catches up — several open WAL handles
    /// in one temp dir make SQLite's online backup throw a "disk I/O error".
    public func close() throws {
        try databaseQueue.close()
    }

    // MARK: Backup copy

    /// Writes a consistent, self-contained copy of the live database to `url`.
    ///
    /// Uses SQLite's online backup API (via GRDB `backup(to:)`), which produces a coherent
    /// snapshot even while the live DB is in WAL mode and being written to. The destination
    /// queue is created **without** the WAL pragma so the result is a single `.sqlite` file
    /// with no `-wal`/`-shm` sidecars — suitable for wrapping in a `CKAsset`.
    public func makeBackupCopy(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let destination = try DatabaseQueue(path: url.path)
        try databaseQueue.backup(to: destination)
    }
}

// MARK: - Helpers

extension DatabaseActor {
    public func fetchAll<T: Sendable & FetchableRecord & TableRecord>(_ type: T.Type) async throws -> [T] {
        try await read { database in
            try T.fetchAll(database)
        }
    }

    public func save<R: Sendable & PersistableRecord>(_ record: R) async throws {
        try await write { database in
            try record.save(database)
        }
    }

    /// Sets a single `column` to `value` for the row whose primary-key `idColumn` equals `id`.
    /// `idColumn` defaults to `"id"`; pass a different name for tables keyed on another column.
    public func set<T: TableRecord>(
        _ type: T.Type,
        id: some DatabaseValueConvertible & Sendable,
        column: Column,
        to value: some DatabaseValueConvertible & Sendable,
        idColumn: String = "id"
    ) async throws {
        try await write { database in
            try database.execute(
                sql: """
                    UPDATE \(T.databaseTableName)
                    SET \(column.name) = ?
                    WHERE \(idColumn) = ?
                    """,
                arguments: [value, id]
            )
        }
    }

    @discardableResult
    public func delete<R: Sendable & PersistableRecord>(_ record: R) async throws -> Bool {
        try await write { database in
            try record.delete(database)
        }
    }

    public nonisolated func publisher<R: ValueReducer>(
        _ observation: ValueObservation<R>
    ) -> AnyPublisher<R.Value, Error> {
        observation.publisher(in: reader)
            .eraseToAnyPublisher()
    }
}
