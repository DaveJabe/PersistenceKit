//
//  DatabaseSuspension.swift
//  PersistenceKit
//
// Letting go of SQLite's locks before iOS suspends the app. GRDB does the work; this names the opt-in,
// posts its two notifications, and tells a database's "not now" apart from its "no".

import Foundation
import GRDB

/// Putting databases to sleep while the app may be suspended, so iOS never kills it for holding a lock.
///
/// **The crash this prevents.** iOS ends an app that is suspended while it holds a lock on a file or a
/// SQLite database, with the exception code `0xdead10cc`. Any read or write in flight when the user
/// switches away is enough: the app is frozen mid-transaction, still holding the lock, and killed.
///
/// **Opting in** is per connection and off by default, so an app that never posts these notifications
/// sees no change. Open the database with GRDB's `observesSuspensionNotifications`:
///
/// ```swift
/// var configuration = DatabaseActor.defaultConfiguration
/// configuration.observesSuspensionNotifications = true
/// let database = try DatabaseActor(path: url, migrator: migrator, configuration: configuration)
/// ```
///
/// (A file opened with ``ReadOnlyDatabase/open(at:immutable:configuration:)`` opts in the same way.)
///
/// Then call ``suspend()`` when the app may be suspended and ``resume()`` before it touches the
/// database again. When is the app's decision, because only the app knows what work it still has
/// running. GRDB's guidance: suspend on the way to the background when nothing is running, and in the
/// expiration handler of any background task; resume when the app comes back to the foreground and
/// whenever work starts in the background.
///
/// **While suspended**, a database that observes suspension rolls back a transaction in flight, which
/// releases its lock, and refuses any statement that could take one, throwing `SQLITE_ABORT`. Reads of a
/// WAL database keep working; every statement on a database in another journal mode is refused.
/// ``isInterruption(_:)`` recognises the refusal: the work did not happen, and the same work succeeds
/// after ``resume()``, so a caller stops and tries again later rather than treating it as a failure of
/// the data.
///
/// The notifications reach every database in the process that observes them (GRDB listens on
/// `NotificationCenter.default` and nowhere else). Tests that post them belong in a serialized suite, or
/// they put each other's databases to sleep.
public enum DatabaseSuspension {

    /// Puts every database opened with `observesSuspensionNotifications` to sleep.
    ///
    /// Callable from any thread. GRDB interrupts a statement in flight and rolls its transaction back
    /// before the next statement runs.
    public static func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    /// Wakes every database ``suspend()`` put to sleep. Callable from any thread.
    public static func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    /// Whether `error` is a database saying "not now" rather than "no".
    ///
    /// A suspended database throws `SQLITE_ABORT` ("Database is suspended"), and a statement it
    /// interrupted throws `SQLITE_INTERRUPT`; a database access whose task was cancelled throws
    /// `CancellationError`. None of the three is a fact about the data: the transaction rolled back
    /// whole, and the same work succeeds later. A caller that meets one stops, and never writes down a
    /// default in place of the answer it was refused.
    public static func isInterruption(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let database = error as? DatabaseError {
            return database.resultCode == .SQLITE_ABORT
                || database.resultCode == .SQLITE_INTERRUPT
        }
        return false
    }
}
