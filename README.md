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

- iOS 16+ / macOS 13+ / watchOS 9+ / tvOS 16+
- Swift 6
- GRDB 7.x (resolved transitively)

Because the public API surfaces GRDB types directly (`Column`, `ValueObservation`, `Database`,
`FetchableRecord`/`PersistableRecord`, …), consuming code that calls those APIs also needs
`import GRDB`.

## Installation

```swift
.package(url: "https://github.com/DaveJabe/PersistenceKit.git", from: "1.1.0")
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
let database = try DatabaseActor.inMemory(migrator: migrator)
```

File-backed connections are opened through GRDB's `Configuration` with `journalMode = .wal`, so GRDB —
not hand-rolled pragmas — turns on WAL (with its activation `CHECK`, `synchronous = NORMAL`, and a
pre-seeded `-wal` file so `ValueObservation` observes from the first transaction) and keeps foreign-key
enforcement on (its default). In-memory databases can't use WAL, and GRDB skips it automatically.

`DatabaseActor.inMemory(migrator:)` is the blessed in-memory entry point. The older
`init(inMemory: Bool, migrator:)` is deprecated (it traps on `false`) but still functional.

### 3. Read and write

```swift
// Generic primitives:
let all = try await database.fetchAll(Commitment.self)
let one = try await database.fetchOne(Commitment.self, key: 1)   // by primary key
let count = try await database.fetchCount(Commitment.self)
try await database.save(Commitment(id: nil, name: "Running"))     // insert or update (upsert)
try await database.saveAll([Commitment(id: nil, name: "Cycling")])
let didDelete = try await database.delete(commitment)             // -> Bool
let removed = try await database.deleteAll(Commitment.self)       // -> Int

// Set one column on every row whose `idColumn` matches (defaults to "id"); returns the
// number of rows changed. Expressed through GRDB's typed query interface — identifiers are
// quoted and values are bound, so there is no string interpolation into SQL:
let changed = try await database.set(Commitment.self, id: 1, column: Column("name"), to: "Walking")

// …or arbitrary work inside a transaction:
try await database.write { db in
    try Commitment(id: nil, name: "Cycling").insert(db)
}
```

### 4. Observe changes (Combine)

Every observation publisher emits the **current** value on subscription, then **re-emits** whenever a
write touches the observed rows — the basis of a reactive "Store".

`observeAll(_:)` is the common case (and, when your record is `Equatable`, an overload adds
`.removeDuplicates()` for free). `observeOne(_:key:)` tracks a single record by primary key:

```swift
func observeCommitments() -> AnyPublisher<[Commitment], Error> {
    database.observeAll(Commitment.self)
}

func observeCommitment(id: Int64) -> AnyPublisher<Commitment?, Error> {
    database.observeOne(Commitment.self, key: id)
}
```

For anything custom, `publisher(_:)` bridges any GRDB `ValueObservation` to Combine directly:

```swift
func observeNames() -> AnyPublisher<[String], Error> {
    database.publisher(
        ValueObservation.tracking { db in try Commitment.select(Column("name"), as: String.self).fetchAll(db) }
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
  (releasing WAL handles so SQLite's online backup doesn't trip over still-open connections). `close()`
  is idempotent — a second call is a no-op — and reads/writes attempted after it throw
  `DatabaseActorError.closed`.

## Testing

```sh
swift test
```

`DatabaseActor.inMemory(migrator:)` makes the actor fully testable on the macOS host.

## License

MIT — see [LICENSE](LICENSE).
