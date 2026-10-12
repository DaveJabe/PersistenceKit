# Changelog

## 1.2.0

Additive: every 1.1 API keeps its signature and its behaviour, so an app that updates and changes
nothing opens its database exactly as before.

- **Your own configuration.** `DatabaseActor.init(path:migrator:configuration:)` and
  `DatabaseActor.inMemory(migrator:configuration:)` open the connection with the caller's GRDB
  `Configuration`, used exactly as given. `DatabaseActor.defaultConfiguration` (WAL, foreign keys on)
  is what the 1.1 initialisers use and the starting point for your own; `configuration` reads back what
  a connection was opened with.
- **Letting go when iOS suspends the app.** `DatabaseSuspension.suspend()` and `.resume()` put to sleep
  and wake every database opened with `observesSuspensionNotifications`, so a suspended app holds no
  SQLite lock (the `0xdead10cc` crash). `DatabaseSuspension.isInterruption(_:)` tells a sleeping
  database's refusal (or a cancelled task) apart from a real failure. Opt-in, off by default.
- **Files you ship.** `ReadOnlyDatabase.open(at:immutable:configuration:)` opens a SQLite file
  read-only without migrating it and returns GRDB's `DatabaseQueue`. The caller says whether the file
  is immutable (no default): `true` for a file nothing can write, such as one in the app bundle, so
  reads take no lock; `false` for a file another connection or process may still write.

## 1.1.0

Hardened `DatabaseActor`: WAL and foreign keys through GRDB's `Configuration`, the
`inMemory(migrator:)` factory, typed `set(...)`, the observation and fetch helpers, an idempotent
`close()`, and iOS 16 / macOS 13 / watchOS 9 / tvOS 16 floors.

## 1.0.0

`DatabaseActor` over GRDB: a caller-supplied migrator, read/write primitives, a `ValueObservation` to
Combine bridge, and an online-backup copy.
