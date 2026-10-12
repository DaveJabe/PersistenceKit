//
//  DatabaseSuspensionTests.swift
//  PersistenceKitTests
//

import Testing
import Foundation
import GRDB
import PersistenceKit

/// Putting databases to sleep before iOS suspends the app (`0xdead10cc`).
///
/// Serialized, and the only suite whose databases observe suspension: the notification reaches every
/// observing database in the process, so two of these tests running at once would put each other's
/// databases to sleep, and a test in another suite running beside one must never hear it. Every test
/// wakes the databases before it checks anything.
@Suite("Database suspension", .serialized)
struct DatabaseSuspensionTests {

    private struct Widget: Codable, FetchableRecord, PersistableRecord, TableRecord, Equatable {
        var id: Int64
        var name: String
        static let databaseTableName = "widget"
    }

    private func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("schema") { database in
            try database.create(table: "widget") { table in
                table.primaryKey("id", .integer)
                table.column("name", .text).notNull()
            }
        }
        return migrator
    }

    private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    /// A file in the default rollback journal, built and closed before anything opens it.
    private static func makeShippedFile(at url: URL) throws {
        let writer = try DatabaseQueue(path: url.path)
        try writer.write { database in
            try database.execute(sql: "CREATE TABLE word (text TEXT NOT NULL)")
            try database.execute(sql: "INSERT INTO word (text) VALUES ('cat')")
        }
        try writer.close()
    }

    private static var observingConfiguration: Configuration {
        var configuration = DatabaseActor.defaultConfiguration
        configuration.observesSuspensionNotifications = true
        return configuration
    }

    @Test("observing suspension: asleep, a write is refused and nothing lands, a WAL read still answers; awake, the write lands")
    func aSuspendedDatabaseRefusesAWriteAndWakes() async throws {
        try await withTemporaryDirectory { directory in
            let actor = try DatabaseActor(
                path: directory.appendingPathComponent("app.sqlite"), migrator: makeMigrator(),
                configuration: Self.observingConfiguration
            )

            DatabaseSuspension.suspend()
            var refused: (any Error)?
            do {
                try await actor.save(Widget(id: 1, name: "asleep"))
            } catch {
                refused = error
            }
            let readAsleep = await Result(awaiting: { try await actor.fetchCount(Widget.self) })
            DatabaseSuspension.resume()

            let error = try #require(refused, "a sleeping database took a write")
            #expect(DatabaseSuspension.isInterruption(error), "refused as not now: \(error)")
            #expect(try readAsleep.get() == 0, "a WAL read keeps working asleep, and nothing landed")

            try await actor.save(Widget(id: 1, name: "awake"))
            #expect(try await actor.fetchAll(Widget.self) == [Widget(id: 1, name: "awake")])
            try await actor.close()
        }
    }

    @Test("a transaction open when the app is suspended is rolled back whole at its next statement", .timeLimit(.minutes(1)))
    func aSuspensionRollsBackAnOpenTransaction() async throws {
        try await withTemporaryDirectory { directory in
            let actor = try DatabaseActor(
                path: directory.appendingPathComponent("app.sqlite"), migrator: makeMigrator(),
                configuration: Self.observingConfiguration
            )
            let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
            let carryOn = DispatchSemaphore(value: 0)

            // The write takes the lock with its first insert, then waits on GRDB's writer queue (not a
            // cooperative thread) while the app goes to the background.
            let write = Task {
                try await actor.write { database in
                    // Ends the test's wait on every path: a write that throws before it yields must not
                    // leave the test waiting for a signal that never comes.
                    defer { startedContinuation.finish() }
                    try Widget(id: 1, name: "first").insert(database)
                    startedContinuation.yield()
                    carryOn.wait()
                    try Widget(id: 2, name: "second").insert(database)
                }
            }
            for await _ in started { break }
            DatabaseSuspension.suspend()
            carryOn.signal()
            let outcome = await write.result
            DatabaseSuspension.resume()

            #expect(throws: DatabaseError.self) { try outcome.get() }
            if case .failure(let error) = outcome {
                #expect(DatabaseSuspension.isInterruption(error), "\(error)")
            }
            #expect(try await actor.fetchCount(Widget.self) == 0, "the first insert went with the rollback")
            try await actor.close()
        }
    }

    @Test("a database opened the 1.1 way does not hear the notification")
    func theDefaultIgnoresSuspension() async throws {
        // An app that updates to 1.2 and opts nothing in keeps the behaviour it had: Committed's case.
        try await withTemporaryDirectory { directory in
            let actor = try DatabaseActor(
                path: directory.appendingPathComponent("app.sqlite"), migrator: makeMigrator()
            )
            DatabaseSuspension.suspend()
            let outcome = await Result(awaiting: { try await actor.save(Widget(id: 1, name: "asleep")) })
            DatabaseSuspension.resume()

            try outcome.get()
            #expect(try await actor.fetchCount(Widget.self) == 1)
            try await actor.close()
        }
    }

    @Test("a shipped file that observes suspension refuses a read asleep and answers awake")
    func aSuspendedReadOnlyFileRefusesAReadAndWakes() async throws {
        try await withTemporaryDirectory { directory in
            // A file in the default rollback journal, as a shipped file usually is: a sleeping database
            // in any mode but WAL refuses reads too.
            let url = directory.appendingPathComponent("shipped.sqlite")
            try Self.makeShippedFile(at: url)

            var configuration = Configuration()
            configuration.observesSuspensionNotifications = true
            let shipped = try ReadOnlyDatabase.open(at: url, immutable: true, configuration: configuration)

            DatabaseSuspension.suspend()
            var refused: (any Error)?
            var answeredAsleep: [String]?
            do {
                answeredAsleep = try await shipped.read { database in
                    try String.fetchAll(database, sql: "SELECT text FROM word")
                }
            } catch {
                refused = error
            }
            DatabaseSuspension.resume()

            #expect(answeredAsleep == nil, "a sleeping file answered \(String(describing: answeredAsleep))")
            let error = try #require(refused)
            #expect(DatabaseSuspension.isInterruption(error), "refused as not now: \(error)")
            let awake = try await shipped.read { database in
                try String.fetchAll(database, sql: "SELECT text FROM word")
            }
            #expect(awake == ["cat"])
            try shipped.close()
        }
    }

    @Test("a database saying not now is told apart from a database saying no")
    func interruptionsAreRecognised() {
        #expect(DatabaseSuspension.isInterruption(CancellationError()))
        #expect(DatabaseSuspension.isInterruption(DatabaseError(resultCode: .SQLITE_ABORT)))
        #expect(DatabaseSuspension.isInterruption(DatabaseError(resultCode: .SQLITE_ABORT_ROLLBACK)))
        #expect(DatabaseSuspension.isInterruption(DatabaseError(resultCode: .SQLITE_INTERRUPT)))
        #expect(!DatabaseSuspension.isInterruption(DatabaseError(resultCode: .SQLITE_CONSTRAINT)))
        #expect(!DatabaseSuspension.isInterruption(DatabaseError(resultCode: .SQLITE_CORRUPT)))
        #expect(!DatabaseSuspension.isInterruption(DatabaseError(resultCode: .SQLITE_BUSY)))
        struct Other: Error {}
        #expect(!DatabaseSuspension.isInterruption(Other()))
    }
}

private extension Result where Failure == any Error {
    /// The outcome of async work, caught, so a test can wake the databases before it checks anything.
    init(awaiting body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
