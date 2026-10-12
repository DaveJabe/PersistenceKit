# PersistenceKit

An app-agnostic actor over [GRDB](https://github.com/groue/GRDB.swift) — extracted from a production
iOS app.

`DatabaseActor` owns the boring-but-critical parts of an on-device SQLite database so your app doesn't
have to: opening the connection with WAL + foreign keys, running *your* migrations, generic
read/write/fetch/save/delete primitives, a `ValueObservation` → Combine bridge, and a consistent
online-backup copy. **Your schema, records, and migrations stay in your app** — PersistenceKit owns only
the connection lifecycle and the plumbing.

Since 1.2 it also lets an iOS app put its databases to sleep before the system suspends it
(`DatabaseSuspension`), opens files the app ships without migrating them (`ReadOnlyDatabase`), and
takes your own GRDB `Configuration` when the default is not what you need.

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
.package(url: "https://github.com/DaveJabe/PersistenceKit.git", from: "1.2.0")
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

### 6. Your own configuration

`init(path:migrator:configuration:)` and `inMemory(migrator:configuration:)` open the connection with
your GRDB `Configuration` instead of the default. It is used exactly as given, so start from
`DatabaseActor.defaultConfiguration` (WAL, foreign keys on) and change only what you mean to:

```swift
var configuration = DatabaseActor.defaultConfiguration
configuration.label = "app"
let database = try DatabaseActor(path: url, migrator: migrator, configuration: configuration)

database.configuration.label   // "app": what the connection was opened with
```

The 1.1 initialisers are unchanged and still open with `defaultConfiguration`.

### 7. Letting go when iOS suspends the app

iOS kills an app that is suspended while it holds a SQLite lock (`0xdead10cc`): a read or write in
flight when the user switches away is enough. GRDB can put a database to sleep first, and
`DatabaseSuspension` is the opt-in. It is off by default, so nothing changes for an app that does not
use it.

1. Open the database observing suspension:

   ```swift
   var configuration = DatabaseActor.defaultConfiguration
   configuration.observesSuspensionNotifications = true
   let database = try DatabaseActor(path: url, migrator: migrator, configuration: configuration)
   ```

2. Put it to sleep when the app may be suspended, and wake it before it is used again:

   ```swift
   DatabaseSuspension.suspend()   // on the way to the background with nothing running,
                                  // and in a background task's expiration handler
   DatabaseSuspension.resume()    // when the app comes back, and when background work starts
   ```

   When to call them is the app's decision, because only the app knows what work it still has running.

3. Treat a refusal as "not now". A sleeping database rolls back a transaction in flight and refuses
   anything that could take a lock (reads of a WAL database keep working). The work did not happen,
   and the same work succeeds after `resume()`:

   ```swift
   do {
       try await database.save(record)
   } catch let error where DatabaseSuspension.isInterruption(error) {
       // Stop; the next launch or the next trigger finishes this.
   }
   ```

The notifications reach every database in the process that observes them, so tests that post them
belong in a serialized suite.

### 8. Files you ship

A database inside the app bundle (a dictionary, a catalogue) cannot be written, and `DatabaseActor`
always runs a migrator, which writes. `ReadOnlyDatabase.open(at:immutable:)` opens such a file read-only
without migrating it, and returns GRDB's `DatabaseQueue`, which reads synchronously or with `await`:

```swift
let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite")!
let dictionary = try ReadOnlyDatabase.open(at: url, immutable: true)
let entry = try dictionary.read { db in try String.fetchOne(db, sql: "SELECT gloss FROM entry WHERE word = ?", arguments: ["cat"]) }
```

`immutable` has no default, because the wrong answer fails quietly. Pass `true` only for a file nothing
can write, such as one inside the app bundle: SQLite then takes no lock on it at all, so a lookup in
flight when the app is suspended holds nothing iOS could object to. Pass `false` for any file another
connection or process may still write (a store shared with a widget or a watch app): told such a file
never changes, SQLite would read stale rows or report corruption. Pass a `configuration` to label the
connection or to observe suspension; `readonly` is always on. A missing file throws, and is never
created.

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
