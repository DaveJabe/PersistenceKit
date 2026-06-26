# PersistenceKit

An app-agnostic actor over [GRDB](https://github.com/groue/GRDB.swift) — extracted from a production
iOS app.

`DatabaseActor` owns the boring-but-critical parts of an on-device SQLite database so your app doesn't
have to: opening the connection with WAL + foreign keys, running *your* migrations, generic
read/write/fetch/save/delete primitives, a `ValueObservation` → Combine bridge, and a consistent
online-backup copy. **Your schema, records, and migrations stay in your app** — PersistenceKit owns only
the connection lifecycle and the plumbing.

## Why it exists

Every GRDB app re-writes the same actor: a `DatabaseQueue` behind an `actor`, the WAL / foreign-keys
pragmas, the `ValueObservation.publisher` boilerplate, an in-memory initializer for tests. This is that
actor, factored out — so a new app gets the plumbing for free and only writes its domain (records +
migrations + stores).

## Requirements

- iOS 18.6+ / macOS 14+
- Swift 6
- GRDB 7.x (resolved transitively)

## Installation

```swift
.package(url: "https://github.com/DaveJabe/PersistenceKit.git", from: "1.0.0")
```

## Usage

### 1. Your schema lives in your app

Define your records (GRDB) and a `DatabaseMigrator`:

```swift
import GRDB

struct Commitment: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

let migrator: DatabaseMigrator = {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("createCommitment") { db in
        try db.create(table: "commitment") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("name", .text).notNull()
        }
    }
    return migrator
}()
```

### 2. Create the actor

The migrator is injected — PersistenceKit makes no assumption about your schema:

```swift
import PersistenceKit

let url = URL.documentsDirectory.appending(path: "app.sqlite")
let database = try DatabaseActor(path: url, migrator: migrator)

// …or, in tests:
let database = try DatabaseActor(inMemory: true, migrator: migrator)
```

### 3. Read and write

```swift
// Generic primitives:
let all = try await database.fetchAll(Commitment.self)
try await database.save(Commitment(id: nil, name: "Running"))
try await database.delete(commitment)

// Update one column by primary key (`idColumn` defaults to "id"):
try await database.set(Commitment.self, id: 1, column: Column("name"), to: "Walking")

// …or arbitrary work inside a transaction:
try await database.write { db in
    try Commitment(id: nil, name: "Cycling").insert(db)
}
```

### 4. Observe changes (Combine)

`publisher(_:)` bridges a GRDB `ValueObservation` to Combine — the basis of a reactive "Store":

```swift
func observeCommitments() -> AnyPublisher<[Commitment], Error> {
    database.publisher(
        ValueObservation.tracking { db in try Commitment.fetchAll(db) }
    )
}
```

### 5. Back up

`makeBackupCopy(to:)` writes a single self-contained `.sqlite` file (no `-wal` / `-shm` sidecars) using
SQLite's online-backup API — safe to wrap in a `CKAsset` for iCloud, even while the live database is
being written to:

```swift
try await database.makeBackupCopy(to: backupURL)
```

## Design notes

- **Migrator inversion.** The `DatabaseMigrator` is an `init` parameter, not a static the actor reaches
  for — so the package never references an app symbol, and your app keeps its own `static let migrator`
  if it likes.
- **Connection lifecycle.** Keep one actor for the app's lifetime; `close()` exists for test teardown
  (releasing WAL handles so SQLite's online backup doesn't trip over still-open connections).

## Testing

```sh
swift test
```

The in-memory initializer makes the actor fully testable on the macOS host.

## License

MIT — see [LICENSE](LICENSE).
