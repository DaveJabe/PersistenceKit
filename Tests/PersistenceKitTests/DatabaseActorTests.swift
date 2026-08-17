//
//  DatabaseActorTests.swift
//  PersistenceKitTests
//

import Testing
import Combine
import Foundation
import GRDB
import PersistenceKit

@Suite("DatabaseActor")
struct DatabaseActorTests {

    // MARK: - Records

    /// Auto-incremented row id, captured back via `didInsert` (so a `MutablePersistableRecord`).
    private struct Item: Codable, FetchableRecord, MutablePersistableRecord, TableRecord, Equatable {
        var id: Int64?
        var name: String
        static let databaseTableName = "item"
        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    }

    /// Caller-supplied integer primary key (so a non-mutating `PersistableRecord`); exercises
    /// `save` upsert, `saveAll`, and `delete`.
    private struct Widget: Codable, FetchableRecord, PersistableRecord, TableRecord, Equatable {
        var id: Int64
        var name: String
        static let databaseTableName = "widget"
    }

    /// Keyed on a non-`id` text column; exercises `set(..., idColumn:)` and `fetchOne(key:)`.
    private struct Keyed: Codable, FetchableRecord, PersistableRecord, TableRecord {
        var code: String
        var value: String
        static let databaseTableName = "keyed"
    }

    private struct Parent: Codable, FetchableRecord, PersistableRecord, TableRecord {
        var id: Int64
        static let databaseTableName = "parent"
    }

    /// References `parent` with `ON DELETE CASCADE`; exercises foreign-key enforcement.
    private struct Child: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        var id: Int64?
        var parentId: Int64
        static let databaseTableName = "child"
        enum CodingKeys: String, CodingKey {
            case id
            case parentId = "parent_id"
        }
        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    }

    /// Caller-keyed record referencing `parent` — a non-mutating `PersistableRecord` (unlike `Child`),
    /// so it is usable with `saveAll` while still able to violate a foreign-key constraint. Its table
    /// comes from an extra migration registered by the tests that need it, not the shared schema.
    private struct Link: Codable, FetchableRecord, PersistableRecord, TableRecord {
        var id: Int64
        var parentId: Int64
        static let databaseTableName = "link"
        enum CodingKeys: String, CodingKey {
            case id
            case parentId = "parent_id"
        }
    }

    // MARK: - Fixtures

    private func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("schema") { database in
            try database.create(table: "item") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull()
            }
            try database.create(table: "widget") { table in
                table.primaryKey("id", .integer)
                table.column("name", .text).notNull()
            }
            try database.create(table: "keyed") { table in
                table.primaryKey("code", .text)
                table.column("value", .text).notNull()
            }
            try database.create(table: "parent") { table in
                table.primaryKey("id", .integer)
            }
            try database.create(table: "child") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("parent_id", .integer).notNull()
                    .references("parent", onDelete: .cascade)
            }
        }
        return migrator
    }

    /// Creates a unique temporary directory, runs `body` with it, then removes it (and any WAL
    /// sidecars). The actor(s) created inside must be `close()`d before `body` returns.
    private func withTemporaryDirectory<T>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    // MARK: - Construction & migrations

    @Test("in-memory factory: migrator runs, and write → fetch round-trips")
    func migratorRunsAndRoundTrips() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())

        try await actor.write { database in
            var item = Item(id: nil, name: "hello")
            try item.insert(database)
        }
        let items = try await actor.fetchAll(Item.self)

        #expect(items.count == 1)
        #expect(items.first?.name == "hello")
        try await actor.close()
    }

    @Test("a throwing migration propagates out of the initializer")
    func throwingMigrationPropagatesFromInit() {
        struct MigrationFailure: Error {}
        var migrator = DatabaseMigrator()
        migrator.registerMigration("explode") { _ in throw MigrationFailure() }

        #expect(throws: MigrationFailure.self) {
            _ = try DatabaseActor.inMemory(migrator: migrator)
        }
    }

    @Test("a failed second migration keeps the committed first; a fixed migrator resumes on reopen")
    func failedSecondMigrationResumesOnReopen() async throws {
        struct MigrationFailure: Error {}
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("migrating.sqlite")
            let v1 = { @Sendable (database: Database) throws in
                try database.create(table: "widget") { table in
                    table.primaryKey("id", .integer)
                    table.column("name", .text).notNull()
                }
                try database.execute(sql: "INSERT INTO widget (id, name) VALUES (1, 'seeded')")
            }

            var broken = DatabaseMigrator()
            broken.registerMigration("v1", migrate: v1)
            broken.registerMigration("v2") { _ in throw MigrationFailure() }
            #expect(throws: MigrationFailure.self) {
                _ = try DatabaseActor(path: url, migrator: broken)
            }

            // Each migration runs in its own transaction, so v1 is committed on disk. Reopening
            // with a fixed migrator must skip v1 (no "table exists" error, no duplicate seed row)
            // and apply v2 where the failed run left off.
            var fixed = DatabaseMigrator()
            fixed.registerMigration("v1", migrate: v1)
            fixed.registerMigration("v2") { database in
                try database.create(table: "extra") { table in
                    table.autoIncrementedPrimaryKey("id")
                }
            }
            let reopened = try DatabaseActor(path: url, migrator: fixed)
            #expect(try await reopened.fetchAll(Widget.self) == [Widget(id: 1, name: "seeded")])
            #expect(try await reopened.read { database in try database.tableExists("extra") })
            try await reopened.close()
        }
    }

    @Test("deprecated init(inMemory:) still works")
    func deprecatedInMemoryInitStillWorks() async throws {
        let actor = try DatabaseActor(inMemory: true, migrator: makeMigrator())
        #expect(try await actor.fetchCount(Item.self) == 0)
        try await actor.close()
    }

    // MARK: - File-backed storage

    @Test("file init(path:): data persists across close + reopen")
    func fileRoundTripPersistsAcrossReopen() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("db.sqlite")

            let actor = try DatabaseActor(path: url, migrator: makeMigrator())
            try await actor.write { database in
                var item = Item(id: nil, name: "persisted")
                try item.insert(database)
            }
            #expect(actor.path == url.path)
            try await actor.close()

            let reopened = try DatabaseActor(path: url, migrator: makeMigrator())
            let items = try await reopened.fetchAll(Item.self)
            #expect(items.count == 1)
            #expect(items.first?.name == "persisted")
            try await reopened.close()
        }
    }

    @Test("WAL journal mode is active on a file database")
    func walIsActiveOnFileDatabase() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("wal.sqlite")
            let actor = try DatabaseActor(path: url, migrator: makeMigrator())

            let journalMode = try await actor.read { database in
                try String.fetchOne(database, sql: "PRAGMA journal_mode")
            }
            #expect(journalMode == "wal")
            try await actor.close()
        }
    }

    @Test("makeBackupCopy: single-file copy, no -wal/-shm sidecars, rows equal source")
    func backupCopyIsSelfContainedAndEqualsSource() async throws {
        try await withTemporaryDirectory { directory in
            let sourceURL = directory.appendingPathComponent("source.sqlite")
            let actor = try DatabaseActor(path: sourceURL, migrator: makeMigrator())
            try await actor.write { database in
                for name in ["a", "b", "c"] {
                    var item = Item(id: nil, name: name)
                    try item.insert(database)
                }
            }

            let backupURL = directory.appendingPathComponent("backup.sqlite")
            try await actor.makeBackupCopy(to: backupURL)

            let fileManager = FileManager.default
            #expect(fileManager.fileExists(atPath: backupURL.path))
            #expect(!fileManager.fileExists(atPath: backupURL.path + "-wal"))
            #expect(!fileManager.fileExists(atPath: backupURL.path + "-shm"))

            let restored = try DatabaseActor(path: backupURL, migrator: makeMigrator())
            let sourceNames = try await actor.fetchAll(Item.self).map(\.name).sorted()
            let restoredNames = try await restored.fetchAll(Item.self).map(\.name).sorted()
            #expect(restoredNames == sourceNames)
            #expect(restoredNames == ["a", "b", "c"])

            try await restored.close()
            try await actor.close()
        }
    }

    @Test("makeBackupCopy replaces whatever is at the destination, backup after backup")
    func backupCopyOverwritesPreviousBackup() async throws {
        try await withTemporaryDirectory { directory in
            let sourceURL = directory.appendingPathComponent("source.sqlite")
            let backupURL = directory.appendingPathComponent("backup.sqlite")
            let actor = try DatabaseActor(path: sourceURL, migrator: makeMigrator())

            // A stale non-database file at the destination must not break the first backup
            // (the destination-cleanup path), and a second backup to the same URL must reflect
            // writes made since the first — the periodic-backup loop production relies on.
            try Data("not a database".utf8).write(to: backupURL)
            try await actor.save(Widget(id: 1, name: "first"))
            try await actor.makeBackupCopy(to: backupURL)

            try await actor.save(Widget(id: 2, name: "second"))
            try await actor.makeBackupCopy(to: backupURL)

            let fileManager = FileManager.default
            #expect(!fileManager.fileExists(atPath: backupURL.path + "-wal"))
            #expect(!fileManager.fileExists(atPath: backupURL.path + "-shm"))

            let copy = try DatabaseQueue(path: backupURL.path)
            let names = try await copy.read { database in
                try String.fetchAll(database, sql: "SELECT name FROM widget ORDER BY id")
            }
            #expect(names == ["first", "second"])
            try copy.close()
            try await actor.close()
        }
    }

    @Test("makeBackupCopy after close() throws DatabaseActorError.closed")
    func backupCopyAfterCloseThrows() async throws {
        try await withTemporaryDirectory { directory in
            let actor = try DatabaseActor(
                path: directory.appendingPathComponent("db.sqlite"), migrator: makeMigrator()
            )
            try await actor.close()

            let backupURL = directory.appendingPathComponent("backup.sqlite")
            await #expect(throws: DatabaseActorError.self) {
                try await actor.makeBackupCopy(to: backupURL)
            }
            #expect(!FileManager.default.fileExists(atPath: backupURL.path))
        }
    }

    @Test("makeBackupCopy taken during a stream of writes is a coherent snapshot", .timeLimit(.minutes(1)))
    func backupCopyIsCoherentUnderInterleavedWrites() async throws {
        try await withTemporaryDirectory { directory in
            let sourceURL = directory.appendingPathComponent("live.sqlite")
            let actor = try DatabaseActor(path: sourceURL, migrator: makeMigrator())
            let seedCount = 10
            let totalCount = 200
            try await actor.saveAll((0..<seedCount).map { Widget(id: Int64($0), name: "w\($0)") })

            // Stream sequential commits through the actor while the backup runs.
            let writer = Task {
                for i in seedCount..<totalCount {
                    try await actor.save(Widget(id: Int64(i), name: "w\(i)"))
                }
            }
            try await Task.sleep(for: .milliseconds(5)) // let some of the stream land first
            let backupURL = directory.appendingPathComponent("snapshot.sqlite")
            try await actor.makeBackupCopy(to: backupURL)
            try await writer.value

            // The copy must be structurally sound and a consistent point-in-time snapshot:
            // the saves commit in id order, so a coherent snapshot is a contiguous prefix.
            let copy = try DatabaseQueue(path: backupURL.path)
            let integrity = try await copy.read { database in
                try String.fetchOne(database, sql: "PRAGMA integrity_check")
            }
            #expect(integrity == "ok")
            let ids = try await copy.read { database in
                try Int64.fetchAll(database, sql: "SELECT id FROM widget ORDER BY id")
            }
            #expect(ids.count >= seedCount)
            #expect(ids == Array(0..<Int64(ids.count)))
            try copy.close()
            try await actor.close()
        }
    }

    // MARK: - Foreign keys

    @Test("foreign-key enforcement: a dangling reference insert throws")
    func foreignKeyViolationThrows() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())

        await #expect(throws: (any Error).self) {
            try await actor.write { database in
                var child = Child(id: nil, parentId: 999)
                try child.insert(database)
            }
        }
        try await actor.close()
    }

    @Test("foreign-key enforcement: ON DELETE CASCADE removes children")
    func onDeleteCascadeRemovesChildren() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())

        try await actor.save(Parent(id: 1))
        try await actor.write { database in
            var child = Child(id: nil, parentId: 1)
            try child.insert(database)
        }
        #expect(try await actor.fetchCount(Child.self) == 1)

        let deleted = try await actor.delete(Parent(id: 1))
        #expect(deleted == true)
        #expect(try await actor.fetchCount(Child.self) == 0)
        try await actor.close()
    }

    // MARK: - CRUD helpers

    @Test("save inserts a new row, then updates the existing row for the same key")
    func saveInsertsThenUpdates() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())

        try await actor.save(Widget(id: 1, name: "first"))
        #expect(try await actor.fetchCount(Widget.self) == 1)

        try await actor.save(Widget(id: 1, name: "second"))
        let widgets = try await actor.fetchAll(Widget.self)
        #expect(widgets.count == 1)
        #expect(widgets.first?.name == "second")
        try await actor.close()
    }

    @Test("saveAll persists every record")
    func saveAllPersistsEveryRecord() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())

        try await actor.saveAll([Widget(id: 1, name: "a"), Widget(id: 2, name: "b")])
        #expect(try await actor.fetchCount(Widget.self) == 2)
        try await actor.close()
    }

    @Test("saveAll is atomic: a mid-batch failure rolls back the earlier records")
    func saveAllRollsBackWholeBatchOnFailure() async throws {
        var migrator = makeMigrator()
        migrator.registerMigration("link") { database in
            try database.create(table: "link") { table in
                table.primaryKey("id", .integer)
                table.column("parent_id", .integer).notNull()
                    .references("parent", onDelete: .cascade)
            }
        }
        let actor = try DatabaseActor.inMemory(migrator: migrator)
        try await actor.save(Parent(id: 1))

        // The first record is valid; the second violates the foreign key. The documented
        // single-transaction contract requires the valid first record to be rolled back too.
        await #expect(throws: (any Error).self) {
            try await actor.saveAll([Link(id: 1, parentId: 1), Link(id: 2, parentId: 999)])
        }
        #expect(try await actor.fetchCount(Link.self) == 0)
        try await actor.close()
    }

    @Test("delete returns true when a row existed, false otherwise")
    func deleteReturnsWhetherRowExisted() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())

        try await actor.save(Widget(id: 1, name: "x"))
        #expect(try await actor.delete(Widget(id: 1, name: "x")) == true)
        #expect(try await actor.delete(Widget(id: 2, name: "y")) == false)
        try await actor.close()
    }

    @Test("deleteAll removes every row and returns the count")
    func deleteAllRemovesEveryRow() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())

        try await actor.saveAll([Widget(id: 1, name: "a"), Widget(id: 2, name: "b")])
        #expect(try await actor.deleteAll(Widget.self) == 2)
        #expect(try await actor.fetchCount(Widget.self) == 0)
        try await actor.close()
    }

    @Test("fetchOne returns the keyed row (or nil), fetchCount counts rows")
    func fetchOneAndFetchCount() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())

        let rowID = try await actor.write { database -> Int64 in
            var item = Item(id: nil, name: "one")
            try item.insert(database)
            return item.id!
        }
        #expect(try await actor.fetchCount(Item.self) == 1)
        #expect(try await actor.fetchOne(Item.self, key: rowID)?.name == "one")
        #expect(try await actor.fetchOne(Item.self, key: rowID + 999) == nil)
        try await actor.close()
    }

    @Test("set updates a column by id and returns the changed-row count")
    func setUpdatesColumnByID() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())

        let rowID = try await actor.write { database -> Int64 in
            var item = Item(id: nil, name: "before")
            try item.insert(database)
            return item.id!
        }
        let changed = try await actor.set(Item.self, id: rowID, column: Column("name"), to: "after")
        #expect(changed == 1)

        let items = try await actor.fetchAll(Item.self)
        #expect(items.first?.name == "after")
        try await actor.close()
    }

    @Test("set honors a non-default idColumn and returns 0 when nothing matches")
    func setUpdatesColumnByCustomIDColumn() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())

        try await actor.save(Keyed(code: "abc", value: "before"))
        let changed = try await actor.set(
            Keyed.self, id: "abc", column: Column("value"), to: "after", idColumn: "code"
        )
        #expect(changed == 1)
        #expect(try await actor.fetchOne(Keyed.self, key: "abc")?.value == "after")

        let unchanged = try await actor.set(
            Keyed.self, id: "missing", column: Column("value"), to: "x", idColumn: "code"
        )
        #expect(unchanged == 0)
        try await actor.close()
    }

    // MARK: - Cancellation & concurrency

    @Test("a write cancelled mid-transaction throws CancellationError and rolls back", .timeLimit(.minutes(1)))
    func cancelledWriteThrowsCancellationErrorAndRollsBack() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())
        let writeStarted = EmissionRecorder<Bool>()
        let cancelDelivered = DispatchSemaphore(value: 0)

        let writeTask = Task {
            try await actor.write { database in
                var first = Item(id: nil, name: "rolled-back")
                try first.insert(database)
                writeStarted.record(true)
                // Blocks GRDB's writer dispatch queue (not a cooperative thread) until the test
                // has cancelled the wrapping task; the next statement then sees the cancellation.
                cancelDelivered.wait()
                var second = Item(id: nil, name: "never-lands")
                try second.insert(database)
            }
        }

        _ = await writeStarted.next()
        writeTask.cancel() // Task.cancel() runs GRDB's cancellation handler before returning.
        cancelDelivered.signal()

        // GRDB 7 contract: the cancelled access throws CancellationError (not a DatabaseError)…
        let result = await writeTask.result
        #expect(throws: CancellationError.self) { try result.get() }

        // …and the whole transaction is rolled back: the first insert never became visible.
        #expect(try await actor.fetchCount(Item.self) == 0)
        try await actor.close()
    }

    @Test("concurrent saves through the actor all persist", .timeLimit(.minutes(1)))
    func concurrentSavesAllPersist() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 1...100 {
                group.addTask {
                    try await actor.save(Widget(id: Int64(i), name: "widget-\(i)"))
                }
            }
            try await group.waitForAll()
        }

        #expect(try await actor.fetchCount(Widget.self) == 100)
        try await actor.close()
    }

    // MARK: - close() lifecycle

    @Test("close() is idempotent")
    func closeIsIdempotent() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())
        try await actor.close()
        try await actor.close()
    }

    @Test("read/write after close() throw")
    func operationsAfterCloseThrow() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())
        try await actor.close()

        await #expect(throws: DatabaseActorError.self) {
            _ = try await actor.fetchAll(Item.self)
        }
        await #expect(throws: DatabaseActorError.self) {
            try await actor.write { database in try database.execute(sql: "SELECT 1") }
        }
    }

    // MARK: - Observation (ValueObservation → Combine)

    @Test("publisher bridges the initial value and re-emits after a write", .timeLimit(.minutes(1)))
    func publisherEmitsInitialAndReEmits() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())
        let recorder = EmissionRecorder<[Item]>()
        let observation = ValueObservation.tracking { database in try Item.fetchAll(database) }
        let cancellable = actor.publisher(observation).sink(
            receiveCompletion: { _ in },
            receiveValue: { recorder.record($0) }
        )
        defer { cancellable.cancel() }

        #expect(await recorder.next().isEmpty)

        try await actor.write { database in
            var item = Item(id: nil, name: "bridged")
            try item.insert(database)
        }

        #expect(await recorder.next().map(\.name) == ["bridged"])
        try await actor.close()
    }

    @Test("observeAll emits the initial rows and re-emits after a write", .timeLimit(.minutes(1)))
    func observeAllEmitsInitialAndReEmits() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())
        let recorder = EmissionRecorder<[Item]>()
        let cancellable = actor.observeAll(Item.self).sink(
            receiveCompletion: { _ in },
            receiveValue: { recorder.record($0) }
        )
        defer { cancellable.cancel() }

        #expect(await recorder.next().isEmpty)

        try await actor.write { database in
            var item = Item(id: nil, name: "observed")
            try item.insert(database)
        }

        let afterWrite = await recorder.next()
        #expect(afterWrite.count == 1)
        #expect(afterWrite.first?.name == "observed")
        try await actor.close()
    }

    @Test("observeOne tracks a single record by key", .timeLimit(.minutes(1)))
    func observeOneTracksByKey() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())
        let rowID = try await actor.write { database -> Int64 in
            var item = Item(id: nil, name: "initial")
            try item.insert(database)
            return item.id!
        }

        let recorder = EmissionRecorder<Item?>()
        let cancellable = actor.observeOne(Item.self, key: rowID).sink(
            receiveCompletion: { _ in },
            receiveValue: { recorder.record($0) }
        )
        defer { cancellable.cancel() }

        #expect(await recorder.next()?.name == "initial")

        try await actor.set(Item.self, id: rowID, column: Column("name"), to: "changed")
        #expect(await recorder.next()?.name == "changed")
        try await actor.close()
    }

    @Test("observeAll (plain overload) observes a non-Equatable record", .timeLimit(.minutes(1)))
    func observeAllPlainOverloadObservesNonEquatableRecord() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())
        let recorder = EmissionRecorder<[Keyed]>()
        // `Keyed` is not Equatable, so overload resolution must select the plain (non-deduplicating)
        // overload — this stops compiling if that overload is ever removed.
        let cancellable = actor.observeAll(Keyed.self).sink(
            receiveCompletion: { _ in },
            receiveValue: { recorder.record($0) }
        )
        defer { cancellable.cancel() }

        #expect(await recorder.next().isEmpty)

        try await actor.save(Keyed(code: "k", value: "v"))
        let afterWrite = await recorder.next()
        #expect(afterWrite.map(\.code) == ["k"])
        try await actor.close()
    }

    @Test("observeAll (Equatable overload) collapses consecutive identical emissions", .timeLimit(.minutes(1)))
    func observeAllEquatableCollapsesDuplicateEmissions() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())
        let recorder = EmissionRecorder<[Widget]>()
        let cancellable = actor.observeAll(Widget.self).sink(
            receiveCompletion: { _ in },
            receiveValue: { recorder.record($0) }
        )
        defer { cancellable.cancel() }

        #expect(await recorder.next().isEmpty)

        try await actor.save(Widget(id: 1, name: "same"))
        #expect(await recorder.next() == [Widget(id: 1, name: "same")])

        // A same-value upsert touches the tracked region, so the observation re-fetches an identical
        // array — removeDuplicates must swallow it. The pause lets that cycle finish, so it cannot be
        // coalesced with the real change below into a single fetch.
        try await actor.save(Widget(id: 1, name: "same"))
        try await Task.sleep(for: .milliseconds(200))

        try await actor.save(Widget(id: 1, name: "changed"))
        #expect(await recorder.next() == [Widget(id: 1, name: "changed")])
        try await actor.close()
    }

    @Test("close() under an active subscription: the publisher goes quiet, no error, no hang", .timeLimit(.minutes(1)))
    func closeUnderActiveSubscriptionGoesQuiet() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())
        let events = EmissionRecorder<String>()
        let cancellable = actor.observeAll(Item.self).sink(
            receiveCompletion: { completion in
                switch completion {
                case .failure: events.record("failure")
                case .finished: events.record("finished")
                }
            },
            receiveValue: { events.record("value(\($0.count))") }
        )
        defer { cancellable.cancel() }

        #expect(await events.next() == "value(0)")
        try await actor.close()

        // Current contract (pinned deliberately): close() succeeds under an active observation, and
        // with no further writes possible the publisher simply stays silent — it does not error out.
        try await Task.sleep(for: .milliseconds(200))
        #expect(events.poll() == nil)
    }

    @Test("subscribing after close() fails with a GRDB error, not a hang", .timeLimit(.minutes(1)))
    func subscribingAfterCloseFailsWithGRDBError() async throws {
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())
        try await actor.close()

        // The nonisolated observation surface bypasses the actor's isClosed guard, so the initial
        // fetch reaches GRDB and surfaces its "closed database" DatabaseError as a .failure —
        // pinned here so the contract (GRDB error, not DatabaseActorError.closed) cannot drift.
        let events = EmissionRecorder<String>()
        let cancellable = actor.observeAll(Item.self).sink(
            receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    events.record(error is DatabaseError ? "failure(DatabaseError)" : "failure(\(type(of: error)))")
                } else {
                    events.record("finished")
                }
            },
            receiveValue: { _ in events.record("value") }
        )
        defer { cancellable.cancel() }

        #expect(await events.next() == "failure(DatabaseError)")
    }
}

// MARK: - Test support

/// Bridges a Combine subscription (push) to an `async` pull, preserving emission order without any
/// fixed sleeps. Values delivered while no consumer is waiting are buffered; `next()` suspends until
/// the next value arrives. Lock-guarded, so it is safe to `record` from GRDB's delivery queue while
/// `next()` is awaited from the test task.
private final class EmissionRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Value] = []
    private var waiter: CheckedContinuation<Value, Never>?

    func record(_ value: Value) {
        // Synchronous context: take the lock, decide, release it, and only then resume — never
        // holding the lock across the (potential) continuation resume.
        let waiterToResume: CheckedContinuation<Value, Never>?
        lock.lock()
        if let waiter {
            self.waiter = nil
            waiterToResume = waiter
        } else {
            buffer.append(value)
            waiterToResume = nil
        }
        lock.unlock()
        waiterToResume?.resume(returning: value)
    }

    func next() async -> Value {
        await withCheckedContinuation { continuation in
            // The continuation body is synchronous, so locking here is async-safe.
            let buffered: Value?
            lock.lock()
            if buffer.isEmpty {
                waiter = continuation
                buffered = nil
            } else {
                buffered = buffer.removeFirst()
            }
            lock.unlock()
            if let buffered {
                continuation.resume(returning: buffered)
            }
        }
    }

    /// Pops the next buffered value without suspending, or returns `nil` when nothing has arrived —
    /// for asserting that a publisher stayed silent.
    func poll() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return buffer.isEmpty ? nil : buffer.removeFirst()
    }
}
