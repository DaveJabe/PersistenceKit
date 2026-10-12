//
//  DatabaseActorConfigurationTests.swift
//  PersistenceKitTests
//

import Testing
import Foundation
import GRDB
import PersistenceKit

/// 1.2's caller-supplied configuration, and the 1.1 initialisers' default staying exactly as it was.
///
/// Nothing here observes suspension: those databases live in the serialized suspension suite, where a
/// posted notification cannot reach another suite's database.
@Suite("DatabaseActor configuration")
struct DatabaseActorConfigurationTests {

    private struct Parent: Codable, FetchableRecord, PersistableRecord, TableRecord {
        var id: Int64
        static let databaseTableName = "parent"
    }

    /// References `parent`, so whether foreign keys are enforced is visible from the outside.
    private struct Child: Codable, FetchableRecord, PersistableRecord, TableRecord {
        var id: Int64
        var parentId: Int64
        static let databaseTableName = "child"
        enum CodingKeys: String, CodingKey {
            case id
            case parentId = "parent_id"
        }
    }

    private func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("schema") { database in
            try database.create(table: "parent") { table in
                table.primaryKey("id", .integer)
            }
            try database.create(table: "child") { table in
                table.primaryKey("id", .integer)
                table.column("parent_id", .integer).notNull().references("parent")
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

    /// A configuration nothing else in the package would choose: foreign keys off, and (on a file) the
    /// default rollback journal instead of WAL.
    private func callersConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        configuration.label = "callers"
        return configuration
    }

    @Test("the 1.1 initialisers open as they always have: WAL, foreign keys on, suspension not observed")
    func theDefaultIsUnchanged() async throws {
        try await withTemporaryDirectory { directory in
            let file = try DatabaseActor(
                path: directory.appendingPathComponent("default.sqlite"), migrator: makeMigrator()
            )
            let journalMode = try await file.read { database in
                try String.fetchOne(database, sql: "PRAGMA journal_mode")
            }
            #expect(journalMode == "wal")
            #expect(file.configuration.foreignKeysEnabled)
            #expect(!file.configuration.observesSuspensionNotifications,
                    "an app that never posts the notifications must not have its database opted in")
            #expect(!file.configuration.readonly)
            try await file.close()

            let memory = try DatabaseActor.inMemory(migrator: makeMigrator())
            #expect(memory.configuration.foreignKeysEnabled)
            #expect(!memory.configuration.observesSuspensionNotifications)
            try await memory.close()

            #expect(!DatabaseActor.defaultConfiguration.observesSuspensionNotifications)
            #expect(DatabaseActor.defaultConfiguration.foreignKeysEnabled)
        }
    }

    @Test("a caller's configuration on a file is the one the connection opens with, and the migrator still runs")
    func callersConfigurationOnAFile() async throws {
        try await withTemporaryDirectory { directory in
            let actor = try DatabaseActor(
                path: directory.appendingPathComponent("callers.sqlite"), migrator: makeMigrator(),
                configuration: callersConfiguration()
            )
            #expect(actor.configuration.label == "callers")
            #expect(!actor.configuration.foreignKeysEnabled)

            // Used exactly as given: no WAL, because the caller did not ask for it.
            let journalMode = try await actor.read { database in
                try String.fetchOne(database, sql: "PRAGMA journal_mode")
            }
            #expect(journalMode == "delete")

            // Foreign keys off: a child of a parent that does not exist goes in.
            try await actor.save(Child(id: 1, parentId: 999))
            #expect(try await actor.fetchCount(Child.self) == 1)
            try await actor.close()
        }
    }

    @Test("a caller's configuration in memory is the one the connection opens with, and the migrator still runs")
    func callersConfigurationInMemory() async throws {
        let actor = try DatabaseActor.inMemory(
            migrator: makeMigrator(), configuration: callersConfiguration()
        )
        #expect(actor.configuration.label == "callers")
        #expect(!actor.configuration.foreignKeysEnabled)
        try await actor.save(Child(id: 1, parentId: 999))
        #expect(try await actor.fetchCount(Child.self) == 1)
        try await actor.close()
    }

    @Test("the default configuration refuses the same dangling child, so the tests above prove the caller's")
    func theDefaultEnforcesForeignKeys() async throws {
        // The control for the two tests above: without it, a migrator that forgot the reference would
        // let the dangling child in under any configuration.
        let actor = try DatabaseActor.inMemory(migrator: makeMigrator())
        await #expect(throws: DatabaseError.self) {
            try await actor.save(Child(id: 1, parentId: 999))
        }
        try await actor.close()
    }
}
