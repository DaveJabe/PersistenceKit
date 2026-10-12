//
//  ReadOnlyDatabase.swift
//  PersistenceKit
//
// Opening a SQLite file the app ships (a dictionary, a catalogue) without migrating it. A migrator writes,
// and a file inside the app bundle cannot be written, so ``DatabaseActor`` (which always migrates) is the
// wrong door for it.

import Foundation
import GRDB

/// Opens SQLite files the app reads and never writes, such as one shipped inside its bundle.
public enum ReadOnlyDatabase {

    /// Opens the SQLite file at `url` read-only, without migrating it, and returns GRDB's queue over it.
    ///
    /// A queue rather than a ``DatabaseActor``: a shipped file has no schema to migrate, nothing to write
    /// and no lifecycle to own, and lookups in one are often synchronous. The queue reads both ways
    /// (`read { }` and `try await read { }`); a write throws (`SQLITE_READONLY`).
    ///
    /// - Parameters:
    ///   - url: an existing SQLite file. A missing file throws; nothing is ever created.
    ///   - immutable: whether SQLite may treat the file as one that cannot change while it is open
    ///     (`immutable=1`). No default, because the wrong answer fails quietly. True is right for a file
    ///     inside the app bundle, which nothing can write: SQLite then takes no lock at all, so a read in
    ///     flight when iOS suspends the app holds nothing iOS could kill it for (see
    ///     ``DatabaseSuspension``). False for any file another connection or process may still write (a
    ///     store shared with a widget or a watch app, say): told such a file never changes, SQLite would
    ///     read stale rows or report corruption. Reads then take SQLite's shared lock like any other.
    ///   - configuration: the caller's GRDB configuration, to label the connection or to opt in to
    ///     ``DatabaseSuspension`` with `observesSuspensionNotifications`. `readonly` is always turned on,
    ///     whatever it says.
    public static func open(
        at url: URL, immutable: Bool, configuration: Configuration = Configuration()
    ) throws -> DatabaseQueue {
        var configuration = configuration
        configuration.readonly = true
        let path = immutable ? try immutablePath(for: url) : url.path
        return try DatabaseQueue(path: path, configuration: configuration)
    }

    /// The file as SQLite is asked to open it when it is immutable: a `file:` URI with `mode=ro` and
    /// `immutable=1`, which Apple's SQLite reads as a URI. Built with `URLComponents`, so a space, `?`,
    /// `#` or `%` in the path is percent-encoded and cannot end the path early, and with an empty host,
    /// so the URI is `file:///...` and a path that starts with `//` stays a path rather than being read
    /// as a host. A URI that still cannot be formed throws rather than opening the file some other way,
    /// which would quietly take the locks the caller asked to avoid.
    static func immutablePath(for url: URL) throws -> String {
        var components = URLComponents()
        components.scheme = "file"
        components.host = ""
        components.path = url.path
        components.queryItems = [
            URLQueryItem(name: "mode", value: "ro"),
            URLQueryItem(name: "immutable", value: "1"),
        ]
        guard let uri = components.string else {
            throw DatabaseError(
                resultCode: .SQLITE_CANTOPEN,
                message: "cannot open \(url.path) as an immutable file: no file: URI for that path"
            )
        }
        return uri
    }
}
