//
//  DatabaseActorTests.swift
//  PersistenceKitTests
//

import Testing
import Foundation
import GRDB
import PersistenceKit

@Suite("DatabaseActor")
struct DatabaseActorTests {

    private struct Item: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        var id: Int64?
        var name: String
        static let databaseTableName = "item"
        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    }

    private func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createItem") { db in
            try db.create(table: "item") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull()
            }
        }
        return migrator
    }

    @Test("in-memory: the supplied migrator runs, and write → fetch round-trips")
    func migrateWriteRead() async throws {
        let actor = try DatabaseActor(inMemory: true, migrator: makeMigrator())

        try await actor.write { db in
            var item = Item(id: nil, name: "hello")
            try item.insert(db)
        }
        let items = try await actor.fetchAll(Item.self)

        #expect(items.count == 1)
        #expect(items.first?.name == "hello")
        try await actor.close()
    }

    @Test("set updates a column by id")
    func setByID() async throws {
        let actor = try DatabaseActor(inMemory: true, migrator: makeMigrator())

        let rowID: Int64 = try await actor.write { db in
            var item = Item(id: nil, name: "before")
            try item.insert(db)
            return item.id!
        }
        try await actor.set(Item.self, id: rowID, column: Column("name"), to: "after")

        let items = try await actor.fetchAll(Item.self)
        #expect(items.first?.name == "after")
        try await actor.close()
    }
}
