//
//  DatabaseActor.swift
//  PersistenceKit
//
// A small, app-agnostic actor wrapping a GRDB `DatabaseQueue`: WAL + foreign-keys configured via GRDB's
// `Configuration` (or the caller's own), a caller-supplied `DatabaseMigrator` run at open, generic
// read/write/fetch/save/delete primitives, a `ValueObservation` → Combine bridge, and SQLite's
// online-backup copy. The schema (migrations, record types) is the consuming app's; this owns only the
// connection lifecycle and the plumbing.

import Combine
import Foundation
import GRDB

/// Errors thrown by ``DatabaseActor`` itself (as opposed to GRDB).
public enum DatabaseActorError: Error, Sendable {
    /// A database operation was attempted after ``DatabaseActor/close()`` released the connection.
    case closed
}

public actor DatabaseActor {
    private let databaseQueue: DatabaseQueue
    private nonisolated var reader: any DatabaseReader { databaseQueue }

    /// Tracks whether ``close()`` has released the connection, so a second `close()` is a no-op and
    /// post-close reads/writes throw ``DatabaseActorError/closed`` deterministically.
    private var isClosed = false

    /// The GRDB `Configuration` that ``init(path:migrator:)`` and ``inMemory(migrator:)`` open every
    /// connection with, and the starting point for a caller's own
    /// (``init(path:migrator:configuration:)``).
    ///
    /// Setting `journalMode = .wal` lets GRDB do the right thing instead of hand-rolled pragmas:
    /// - Foreign-key enforcement is ON (GRDB's default), so `ON DELETE CASCADE` / `NOT NULL` references
    ///   are honored rather than silently ignored.
    /// - The database is opened in WAL mode with GRDB's activation `CHECK`, `synchronous = NORMAL`, and a
    ///   pre-seeded `-wal` file so `ValueObservation` observes correctly from the first transaction.
    /// - For in-memory databases (which cannot use WAL) GRDB skips the WAL setup automatically.
    ///
    /// It does not observe suspension; an app opts in (see ``DatabaseSuspension``).
    public static var defaultConfiguration: Configuration {
        var configuration = Configuration()
        configuration.journalMode = .wal
        return configuration
    }

    /// The configuration this actor's connection was opened with: ``defaultConfiguration``, or the
    /// caller's own.
    ///
    /// `nonisolated` for the same reason as ``path``; useful for asserting in tests that a database was
    /// opened the way the app means to open it (observing suspension, say).
    public nonisolated var configuration: Configuration { databaseQueue.configuration }

    /// Opens (or creates) a file-backed database at `path` and runs `migrator` against it.
    ///
    /// The connection is opened in WAL mode with foreign-key enforcement on (see
    /// ``defaultConfiguration``).
    public init(path: URL, migrator: DatabaseMigrator) throws {
        try self.init(path: path, migrator: migrator, configuration: Self.defaultConfiguration)
    }

    /// Opens (or creates) a file-backed database at `path` with the caller's GRDB `configuration`, and
    /// runs `migrator` against it.
    ///
    /// The configuration is used exactly as given, so start from ``defaultConfiguration`` to keep WAL
    /// and change only what you mean to change:
    ///
    /// ```swift
    /// var configuration = DatabaseActor.defaultConfiguration
    /// configuration.observesSuspensionNotifications = true
    /// let database = try DatabaseActor(path: url, migrator: migrator, configuration: configuration)
    /// ```
    public init(path: URL, migrator: DatabaseMigrator, configuration: Configuration) throws {
        self.databaseQueue = try DatabaseQueue(path: path.path, configuration: configuration)
        try migrator.migrate(databaseQueue)
    }

    /// Designated in-memory initializer. Creates an independent SQLite in-memory database (no file I/O)
    /// and runs `migrator` against it. The default configuration asks for WAL, and GRDB skips it for
    /// in-memory databases.
    private init(memory migrator: DatabaseMigrator, configuration: Configuration) throws {
        self.databaseQueue = try DatabaseQueue(named: nil, configuration: configuration)
        try migrator.migrate(databaseQueue)
    }

    /// Creates a true SQLite in-memory database (no file I/O) and runs `migrator` against it.
    /// Useful for testing or sandboxed environments where file-backed storage is unavailable.
    ///
    /// This is the blessed, non-crashable in-memory entry point.
    public static func inMemory(migrator: DatabaseMigrator) throws -> DatabaseActor {
        try DatabaseActor(memory: migrator, configuration: defaultConfiguration)
    }

    /// Creates a true SQLite in-memory database (no file I/O) with the caller's GRDB `configuration`,
    /// and runs `migrator` against it. The configuration is used exactly as given (see
    /// ``init(path:migrator:configuration:)``).
    public static func inMemory(
        migrator: DatabaseMigrator, configuration: Configuration
    ) throws -> DatabaseActor {
        try DatabaseActor(memory: migrator, configuration: configuration)
    }

    /// Creates a true SQLite in-memory database (no file I/O) and runs `migrator` against it.
    ///
    /// - Warning: Passing `inMemory: false` traps. Prefer ``inMemory(migrator:)``, which cannot crash.
    @available(*, deprecated, message: "Use DatabaseActor.inMemory(migrator:)")
    public init(inMemory: Bool, migrator: DatabaseMigrator) throws {
        precondition(inMemory, "Pass inMemory: true to use the in-memory initializer.")
        try self.init(memory: migrator, configuration: Self.defaultConfiguration)
    }

    // MARK: Database Methods
    /// The blocks are prefixed with `@Sendable` to ensure sendable rules on these closures

    public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        guard !isClosed else { throw DatabaseActorError.closed }
        return try await databaseQueue.read(block)
    }

    public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        guard !isClosed else { throw DatabaseActorError.closed }
        return try await databaseQueue.write(block)
    }

    /// The on-disk path of the underlying database file (or `:memory:` for an in-memory database).
    ///
    /// `nonisolated` because the queue is an immutable, `Sendable` `let`; useful for logging, building a
    /// backup URL alongside the live file, or asserting in tests.
    public nonisolated var path: String { databaseQueue.path }

    /// Closes the underlying SQLite connection, releasing its WAL handle and file locks.
    ///
    /// Idempotent: a second `close()` is a no-op. After a successful close, `read`/`write` (and the
    /// helpers built on them) throw ``DatabaseActorError/closed``.
    ///
    /// An app keeps one actor for its whole lifetime and never calls this; tests call it during teardown
    /// so test connections are released rather than left open until ARC catches up — several open WAL
    /// handles in one temp dir make SQLite's online backup throw a "disk I/O error".
    public func close() throws {
        guard !isClosed else { return }
        try databaseQueue.close()
        isClosed = true
    }

    // MARK: Backup copy

    /// Writes a consistent, self-contained copy of the live database to `url`.
    ///
    /// Uses SQLite's online backup API (via GRDB `backup(to:)`), which produces a coherent
    /// snapshot even while the live DB is in WAL mode and being written to. The destination
    /// queue uses GRDB's default journal mode (no WAL) and is explicitly closed afterwards, so the
    /// result is a single `.sqlite` file with no `-wal`/`-shm` sidecars — suitable for wrapping in a
    /// `CKAsset`.
    public func makeBackupCopy(to url: URL) throws {
        guard !isClosed else { throw DatabaseActorError.closed }
        try? FileManager.default.removeItem(at: url)
        let destination = try DatabaseQueue(path: url.path)
        try databaseQueue.backup(to: destination)
        try destination.close()
    }
}

// MARK: - Helpers

extension DatabaseActor {
    /// Fetches every row of `type`'s table.
    public func fetchAll<T: Sendable & FetchableRecord & TableRecord>(_ type: T.Type) async throws -> [T] {
        try await read { database in
            try T.fetchAll(database)
        }
    }

    /// Fetches the single row of `type`'s table whose primary key equals `key`, or `nil` if none.
    public func fetchOne<T: Sendable & FetchableRecord & TableRecord>(
        _ type: T.Type,
        key: some DatabaseValueConvertible & Sendable
    ) async throws -> T? {
        try await read { database in
            try T.fetchOne(database, key: key)
        }
    }

    /// The number of rows in `type`'s table.
    public func fetchCount<T: TableRecord>(_ type: T.Type) async throws -> Int {
        try await read { database in
            try T.fetchCount(database)
        }
    }

    /// Inserts `record`, or updates it when a row with its primary key already exists (GRDB upsert).
    public func save<R: Sendable & PersistableRecord>(_ record: R) async throws {
        try await write { database in
            try record.save(database)
        }
    }

    /// Saves every record in `records` within a single transaction.
    public func saveAll<R: Sendable & PersistableRecord>(_ records: [R]) async throws {
        try await write { database in
            for record in records {
                try record.save(database)
            }
        }
    }

    /// Sets a single `column` to `value` for **every** row whose `idColumn` equals `id`.
    ///
    /// `idColumn` defaults to `"id"`; pass a different name for tables keyed on another column. The
    /// update is expressed through GRDB's typed query interface, which quotes identifiers and binds
    /// values — there is no string interpolation of column names into SQL.
    ///
    /// - Returns: the number of rows changed (0 when nothing matched).
    @discardableResult
    public func set<T: TableRecord>(
        _ type: T.Type,
        id: some DatabaseValueConvertible & Sendable,
        column: Column,
        to value: some DatabaseValueConvertible & Sendable,
        idColumn: String = "id"
    ) async throws -> Int {
        try await write { database in
            try T.filter(Column(idColumn) == id).updateAll(database, [column.set(to: value)])
        }
    }

    /// Deletes `record`. Returns `true` if a row was deleted, `false` if no matching row existed.
    @discardableResult
    public func delete<R: Sendable & PersistableRecord>(_ record: R) async throws -> Bool {
        try await write { database in
            try record.delete(database)
        }
    }

    /// Deletes every row of `type`'s table. Returns the number of rows deleted.
    @discardableResult
    public func deleteAll<T: TableRecord>(_ type: T.Type) async throws -> Int {
        try await write { database in
            try T.deleteAll(database)
        }
    }
}

// MARK: - Observation (ValueObservation → Combine)

extension DatabaseActor {
    /// Bridges a GRDB `ValueObservation` to Combine — the basis of a reactive "Store".
    ///
    /// The publisher emits the current value on subscription, then re-emits whenever a write touches the
    /// observed region.
    public nonisolated func publisher<R: ValueReducer>(
        _ observation: ValueObservation<R>
    ) -> AnyPublisher<R.Value, Error> {
        observation.publisher(in: reader)
            .eraseToAnyPublisher()
    }

    /// Observes every row of `type`'s table, emitting the current rows on subscription and again after
    /// each write that changes them.
    public nonisolated func observeAll<T: Sendable & FetchableRecord & TableRecord>(
        _ type: T.Type
    ) -> AnyPublisher<[T], Error> {
        publisher(ValueObservation.tracking { database in try T.fetchAll(database) })
    }

    /// Observes every row of `type`'s table, collapsing consecutive identical emissions.
    ///
    /// Overload selected automatically when `T` is `Equatable`.
    public nonisolated func observeAll<T: Sendable & FetchableRecord & TableRecord & Equatable>(
        _ type: T.Type
    ) -> AnyPublisher<[T], Error> {
        publisher(ValueObservation.tracking { database in try T.fetchAll(database) })
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Observes the single row of `type`'s table whose primary key equals `key` (or `nil` if none),
    /// emitting on subscription and again after each write that changes it.
    public nonisolated func observeOne<T: Sendable & FetchableRecord & TableRecord>(
        _ type: T.Type,
        key: some DatabaseValueConvertible & Sendable
    ) -> AnyPublisher<T?, Error> {
        publisher(ValueObservation.tracking { database in try T.fetchOne(database, key: key) })
    }
}
