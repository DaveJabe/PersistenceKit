//
//  ReadOnlyDatabaseTests.swift
//  PersistenceKitTests
//

import Testing
import Foundation
import GRDB
import PersistenceKit

/// Opening a file the app ships: read-only, never migrated, and by default holding no lock.
///
/// Nothing here observes suspension (see `DatabaseSuspensionTests` for the shipped file asleep).
@Suite("ReadOnlyDatabase")
struct ReadOnlyDatabaseTests {

    private func withTemporaryDirectory<T>(
        named name: String = "PersistenceKitTests-\(UUID().uuidString)",
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    /// A small database as an app would ship one: built elsewhere, in the default rollback journal,
    /// closed before the app ever opens it.
    private func makeShippedFile(at url: URL) throws {
        let writer = try DatabaseQueue(path: url.path)
        try writer.write { database in
            try database.execute(sql: "CREATE TABLE word (text TEXT NOT NULL)")
            try database.execute(sql: "INSERT INTO word (text) VALUES ('cat'), ('dog')")
        }
        try writer.close()
    }

    private static func words(_ database: Database) throws -> [String] {
        try String.fetchAll(database, sql: "SELECT text FROM word ORDER BY text")
    }

    /// GRDB's synchronous read and write, which an async context would not pick on its own.
    private static func readNow<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T {
        try queue.read(body)
    }

    private static func writeNow(_ queue: DatabaseQueue, sql: String) throws {
        try queue.write { database in try database.execute(sql: sql) }
    }

    /// Whether another connection can take the file's EXCLUSIVE lock right now, which it cannot while
    /// anybody holds even a SHARED one.
    private static func exclusiveLockIsFree(_ url: URL) -> Bool {
        do {
            let probe = try DatabaseQueue(path: url.path)
            defer { try? probe.close() }
            try probe.inDatabase { database in
                try database.execute(sql: "BEGIN EXCLUSIVE")
                try database.execute(sql: "ROLLBACK")
            }
            return true
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_BUSY || error.extendedResultCode == .SQLITE_IOERR_LOCK {
            // Refused for the lock: SQLite says BUSY, or IOERR_LOCK when the holder is a read-only
            // connection in this same process.
            return false
        } catch {
            Issue.record("the lock probe failed for another reason: \(error)")
            return false
        }
    }

    @Test("opens a shipped file and reads it both ways, without migrating it, writing it, or letting a write in")
    func opensAndReadsWithoutWriting() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("shipped.sqlite")
            try makeShippedFile(at: url)
            let before = try Data(contentsOf: url)

            let shipped = try ReadOnlyDatabase.open(at: url, immutable: true)
            #expect(shipped.configuration.readonly)
            #expect(try Self.readNow(shipped, Self.words) == ["cat", "dog"])
            #expect(try await shipped.read(Self.words) == ["cat", "dog"])
            #expect(try await shipped.read { database in try database.tableExists("grdb_migrations") } == false)

            var refusal: DatabaseError?
            do {
                try Self.writeNow(shipped, sql: "INSERT INTO word (text) VALUES ('eel')")
            } catch let error as DatabaseError {
                refusal = error
            }
            #expect(refusal?.resultCode == .SQLITE_READONLY, "a write was \(String(describing: refusal))")
            try shipped.close()

            #expect(try Data(contentsOf: url) == before, "the file is byte for byte what was shipped")
            let fileManager = FileManager.default
            #expect(!fileManager.fileExists(atPath: url.path + "-wal"))
            #expect(!fileManager.fileExists(atPath: url.path + "-journal"))
        }
    }

    @Test("a caller's configuration is kept, and read-only is forced whatever it says")
    func keepsTheCallersConfigurationButForcesReadOnly() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("shipped.sqlite")
            try makeShippedFile(at: url)
            var configuration = Configuration()
            configuration.label = "dictionary"
            configuration.readonly = false

            for immutable in [true, false] {
                let shipped = try ReadOnlyDatabase.open(
                    at: url, immutable: immutable, configuration: configuration
                )
                #expect(shipped.configuration.label == "dictionary")
                #expect(shipped.configuration.readonly, "immutable: \(immutable)")
                #expect(throws: DatabaseError.self, "immutable: \(immutable)") {
                    try Self.writeNow(shipped, sql: "DELETE FROM word")
                }
                try shipped.close()
            }
        }
    }

    @Test("a missing file is an error, never a new empty database")
    func aMissingFileThrowsAndIsNotCreated() async throws {
        try await withTemporaryDirectory { directory in
            for immutable in [true, false] {
                let url = directory.appendingPathComponent("missing-\(immutable).sqlite")
                #expect(throws: DatabaseError.self, "immutable: \(immutable)") {
                    _ = try ReadOnlyDatabase.open(at: url, immutable: immutable)
                }
                #expect(!FileManager.default.fileExists(atPath: url.path), "immutable: \(immutable)")
            }
        }
    }

    @Test("an immutable read holds no lock on the file, mid-read")
    func anImmutableReadHoldsNoLock() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("shipped.sqlite")
            try makeShippedFile(at: url)
            let shipped = try ReadOnlyDatabase.open(at: url, immutable: true)

            let freeMidRead = try Self.readNow(shipped) { database -> Bool in
                _ = try String.fetchOne(database, sql: "SELECT text FROM word LIMIT 1")
                return Self.exclusiveLockIsFree(url)
            }

            #expect(freeMidRead, "an immutable read held the file's lock")
            try shipped.close()
        }
    }

    @Test("the probe can see a lock: a read-only open that is not immutable holds SQLite's shared lock mid-read")
    func aPlainReadOnlyReadHoldsALock() async throws {
        // The control for the test above: without it, a probe that could never see a lock would pass
        // that test for the wrong reason.
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("shipped.sqlite")
            try makeShippedFile(at: url)
            let shipped = try ReadOnlyDatabase.open(at: url, immutable: false)

            let freeMidRead = try Self.readNow(shipped) { database -> Bool in
                _ = try String.fetchOne(database, sql: "SELECT text FROM word LIMIT 1")
                return Self.exclusiveLockIsFree(url)
            }

            #expect(!freeMidRead)
            try shipped.close()
        }
    }

    @Test("a path with a space, ?, # and % opens immutable all the same")
    func anAwkwardPathStillOpensImmutable() async throws {
        try await withTemporaryDirectory(named: "PersistenceKit Tests?#%\(UUID().uuidString)") { directory in
            let url = directory.appendingPathComponent("ship ped?#%20.sqlite")
            try makeShippedFile(at: url)
            let shipped = try ReadOnlyDatabase.open(at: url, immutable: true)

            let (words, freeMidRead) = try Self.readNow(shipped) { database in
                (try Self.words(database), Self.exclusiveLockIsFree(url))
            }

            #expect(words == ["cat", "dog"])
            #expect(freeMidRead, "the awkward path lost its immutability")
            try shipped.close()
        }
    }

    @Test("a path that starts with // opens immutable, never quietly as a file that takes locks")
    func aDoubleSlashPathStillOpensImmutable() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("shipped.sqlite")
            try makeShippedFile(at: url)
            // The same file, named the way POSIX allows and `URLComponents` refuses without a host.
            let doubled = URL(fileURLWithPath: "/" + url.path)
            #expect(doubled.path.hasPrefix("//"), "the fixture is the case under test: \(doubled.path)")
            let shipped = try ReadOnlyDatabase.open(at: doubled, immutable: true)

            let (words, freeMidRead) = try Self.readNow(shipped) { database in
                (try Self.words(database), Self.exclusiveLockIsFree(url))
            }

            #expect(words == ["cat", "dog"])
            #expect(freeMidRead, "a path starting with // lost its immutability")
            try shipped.close()
        }
    }
}
