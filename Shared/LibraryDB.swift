import Foundation

/// The `tracks` table shared by both apps. Platform specific tables are added via `extraMigrations`.
final class LibraryDB: @unchecked Sendable {
    let db: SQLiteDB

    static let baseMigrations = [
        """
        CREATE TABLE tracks (
            rel_path TEXT PRIMARY KEY,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            title TEXT NOT NULL,
            artist TEXT, album TEXT, album_artist TEXT,
            track_no INTEGER, disc_no INTEGER,
            duration REAL, genre TEXT, year INTEGER,
            source TEXT NOT NULL DEFAULT 'local',
            origin TEXT NOT NULL DEFAULT 'server',
            added_at REAL NOT NULL,
            play_count INTEGER NOT NULL DEFAULT 0,
            skip_count INTEGER NOT NULL DEFAULT 0,
            last_played REAL,
            favorite INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX tracks_artist ON tracks(artist);
        CREATE INDEX tracks_album ON tracks(album);
        """,
    ]

    /// When favorite last changed (for two-way sync: newest change wins). Each app appends this
    /// to its own migration list, because migration numbers differ per app.
    static let favoriteAtMigration = "ALTER TABLE tracks ADD COLUMN favorite_at REAL"

    private let migrations: [String]

    init(path: String, extraMigrations: [String] = []) throws {
        db = try SQLiteDB(path: path)
        migrations = Self.baseMigrations + extraMigrations
        try db.migrate(migrations)
    }

    /// Replace everything with a database copy (e.g. restoring a Mac from the web player),
    /// then bring it up to this app's schema.
    func restore(from path: String) throws {
        try db.restore(from: path)
        try db.migrate(migrations)
    }

    // MARK: reading

    static func track(from r: SQLRow) -> Track {
        Track(relPath: r.string("rel_path") ?? "",
              size: Int64(r.int("size") ?? 0),
              mtime: r.double("mtime") ?? 0,
              title: r.string("title") ?? "",
              artist: r.string("artist"), album: r.string("album"), albumArtist: r.string("album_artist"),
              trackNumber: r.int("track_no"), discNumber: r.int("disc_no"),
              duration: r.double("duration"), genre: r.string("genre"), year: r.int("year"),
              source: TrackSource(rawValue: r.string("source") ?? "") ?? .local,
              origin: TrackOrigin(rawValue: r.string("origin") ?? "") ?? .server,
              addedAt: r.double("added_at") ?? 0,
              playCount: r.int("play_count") ?? 0, skipCount: r.int("skip_count") ?? 0,
              lastPlayed: r.double("last_played"), favorite: r.bool("favorite"), favoriteAt: r.double("favorite_at"))
    }

    func allTracks() -> [Track] {
        ((try? db.query("SELECT * FROM tracks")) ?? []).map(Self.track(from:))
    }

    func track(relPath: String) -> Track? {
        (try? db.query("SELECT * FROM tracks WHERE rel_path = ?", [relPath]))?.first.map(Self.track(from:))
    }

    /// relPath -> (size, mtime) for incremental scanning.
    func fileStamps(origin: TrackOrigin? = nil) -> [String: (Int64, Double)] {
        let rows: [SQLRow]
        if let origin {
            rows = (try? db.query("SELECT rel_path, size, mtime FROM tracks WHERE origin = ?", [origin.rawValue])) ?? []
        } else {
            rows = (try? db.query("SELECT rel_path, size, mtime FROM tracks")) ?? []
        }
        var out: [String: (Int64, Double)] = [:]
        for r in rows { out[r.string("rel_path") ?? ""] = (Int64(r.int("size") ?? 0), r.double("mtime") ?? 0) }
        return out
    }

    // MARK: writing

    /// Inserts or updates metadata, keeping existing stats.
    func upsert(_ tracks: [Track]) throws {
        try db.transaction {
            for t in tracks {
                try db.execute("""
                    INSERT INTO tracks (rel_path,size,mtime,title,artist,album,album_artist,track_no,disc_no,duration,genre,year,source,origin,added_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(rel_path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, title=excluded.title,
                      artist=excluded.artist, album=excluded.album, album_artist=excluded.album_artist, track_no=excluded.track_no,
                      disc_no=excluded.disc_no, duration=excluded.duration, genre=excluded.genre, year=excluded.year,
                      source=excluded.source, origin=excluded.origin
                    """, [t.relPath, t.size, t.mtime, t.title, t.artist, t.album, t.albumArtist, t.trackNumber, t.discNumber,
                          t.duration, t.genre, t.year, t.source.rawValue, t.origin.rawValue, t.addedAt])
            }
        }
    }

    /// Re-key a song (same file, different spelling of its path, e.g. accent encoding).
    func renamePath(_ old: String, to new: String, origin: TrackOrigin) {
        try? db.execute("UPDATE tracks SET rel_path = ?, origin = ? WHERE rel_path = ?", [new, origin.rawValue, old])
    }

    func delete(_ relPaths: [String]) throws {
        try db.transaction {
            for p in relPaths { try db.execute("DELETE FROM tracks WHERE rel_path = ?", [p]) }
        }
    }

    func recordPlay(_ relPath: String, at date: Date = Date()) {
        try? db.execute("UPDATE tracks SET play_count = play_count + 1, last_played = ? WHERE rel_path = ?",
                        [date.timeIntervalSince1970, relPath])
    }

    func recordSkip(_ relPath: String) {
        try? db.execute("UPDATE tracks SET skip_count = skip_count + 1 WHERE rel_path = ?", [relPath])
    }

    func setFavorite(_ relPath: String, _ fav: Bool) {
        try? db.execute("UPDATE tracks SET favorite = ?, favorite_at = ? WHERE rel_path = ?", [fav, Date().timeIntervalSince1970, relPath])
    }

    func setFavorite(_ relPaths: [String], _ fav: Bool) {
        let now = Date().timeIntervalSince1970
        try? db.transaction { for p in relPaths { try db.execute("UPDATE tracks SET favorite = ?, favorite_at = ? WHERE rel_path = ?", [fav, now, p]) } }
    }

    func statEntries() -> [PlayStatEntry] {
        // include un-favorites (favorite_at set) so they propagate too
        let rows = (try? db.query("SELECT rel_path, play_count, skip_count, last_played, favorite, favorite_at FROM tracks WHERE play_count > 0 OR skip_count > 0 OR favorite = 1 OR favorite_at IS NOT NULL")) ?? []
        return rows.map { PlayStatEntry(relPath: $0.string("rel_path") ?? "", playCount: $0.int("play_count") ?? 0,
                                        skipCount: $0.int("skip_count") ?? 0, lastPlayed: $0.double("last_played"),
                                        favorite: $0.bool("favorite"), favoriteAt: $0.double("favorite_at")) }
    }

    /// Two-way favorite sync: take the other side's favorite state when it changed more recently.
    /// Favorites from before timestamps existed (no time on either side) are kept as favorites.
    /// Returns how many tracks changed.
    @discardableResult
    func applyRemoteFavorites(_ remote: [(relPath: String, favorite: Bool, at: Double?)]) -> Int {
        var changed = 0
        try? db.transaction {
            for r in remote {
                if let at = r.at {
                    try db.execute("UPDATE tracks SET favorite = ?, favorite_at = ? WHERE rel_path = ? AND (favorite_at IS NULL OR favorite_at < ?) AND (favorite != ? OR favorite_at IS NULL OR favorite_at != ?)",
                                   [r.favorite, at, r.relPath, at, r.favorite, at])
                } else if r.favorite {
                    try db.execute("UPDATE tracks SET favorite = 1 WHERE rel_path = ? AND favorite = 0 AND favorite_at IS NULL", [r.relPath])
                } else { continue }
                changed += db.changes
            }
        }
        return changed
    }

    /// Fold one song's stats into another (duplicate removed): plays and skips add up, latest
    /// last-played wins, favorite if either was. Returns false if `from` isn't in the library.
    @discardableResult
    func absorbStats(from: String, into keep: String) -> Bool {
        guard from != keep, let old = track(relPath: from), track(relPath: keep) != nil else { return false }
        try? db.execute("""
            UPDATE tracks SET play_count = play_count + ?, skip_count = skip_count + ?,
              last_played = NULLIF(MAX(COALESCE(last_played, 0), COALESCE(?, 0)), 0),
              favorite_at = CASE WHEN ? = 1 AND favorite = 0 THEN ? ELSE favorite_at END,
              favorite = MAX(favorite, ?)
            WHERE rel_path = ?
            """, [old.playCount, old.skipCount, old.lastPlayed, old.favorite, Date().timeIntervalSince1970, old.favorite, keep])
        return true
    }

    /// Merge a stats backup: max of counters, latest lastPlayed, OR of favorites.
    func mergeStats(_ entries: [PlayStatEntry]) throws {
        try db.transaction {
            for e in entries {
                try db.execute("""
                    UPDATE tracks SET play_count = MAX(play_count, ?), skip_count = MAX(skip_count, ?),
                      last_played = NULLIF(MAX(COALESCE(last_played, 0), COALESCE(?, 0)), 0), favorite = MAX(favorite, ?)
                    WHERE rel_path = ?
                    """, [e.playCount, e.skipCount, e.lastPlayed, e.favorite, e.relPath])
            }
        }
    }
}
