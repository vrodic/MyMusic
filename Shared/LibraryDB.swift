import Foundation

/// The `tracks` table shared by both apps. Platform specific tables are added via `extraMigrations`.
final class LibraryDB: @unchecked Sendable {
    let db: SQLiteDB
    let sync: SyncStore
    /// Whose plays, favorites and playlists this device shows and records.
    var currentUser = SyncStore.defaultUserID

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
        try db.execute(SyncStore.migration)   // idempotent (IF NOT EXISTS)
        sync = SyncStore(db: db)
    }

    /// Replace everything with a database copy (e.g. restoring a Mac from the web player),
    /// then bring it up to this app's schema.
    func restore(from path: String) throws {
        try db.restore(from: path)
        try db.migrate(migrations)
        try db.execute(SyncStore.migration)
        // the backup came from another device: write our own plays under a new id
        sync.setReplicaID(UUID().uuidString)
        try? db.execute("DELETE FROM sync_peers")
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

    /// Take the web player's song list as this device's index. Songs it doesn't list are gone: their
    /// files can't be played from there. Known songs keep their spelling (a scan may have used
    /// another accent encoding). `updateKnown` also takes the server's size and mtime for them;
    /// leave it off while a music folder is configured, or its next scan would re-read those files.
    func mergeServerIndex(_ remote: [Track], updateKnown: Bool) throws {
        let local = fileStamps()
        var spelling: [String: String] = [:]
        for p in local.keys { spelling[SyncStore.key(p)] = p }
        var seen = Set<String>()
        var changes: [Track] = []
        for var t in remote {
            let k = SyncStore.key(t.relPath)
            seen.insert(k)
            t.origin = .server   // like a scanned song; where its bytes come from depends on the mode
            if let known = spelling[k] {
                guard updateKnown, let s = local[known], s.0 != t.size || abs(s.1 - t.mtime) > 1 else { continue }
                t.relPath = known
            }
            changes.append(t)
        }
        try upsert(changes)
        // an empty list means a server still starting up, not a library with no songs
        if !remote.isEmpty { try delete(local.keys.filter { !seen.contains(SyncStore.key($0)) }) }
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

    // MARK: stats & favorites (stored in the replicated SyncStore, per user; the tracks table
    // keeps a copy of the current user's numbers so lists and sorting stay simple and fast)

    func recordPlay(_ relPath: String, at date: Date = Date()) {
        sync.recordPlay(user: currentUser, relPath: relPath, at: date.timeIntervalSince1970)
        refreshCache([relPath])
    }

    func recordSkip(_ relPath: String) {
        sync.recordSkip(user: currentUser, relPath: relPath)
        refreshCache([relPath])
    }

    func setFavorite(_ relPath: String, _ fav: Bool) {
        sync.setFavorite(user: currentUser, relPath: relPath, fav)
        refreshCache([relPath])
    }

    func setFavorite(_ relPaths: [String], _ fav: Bool) {
        let at = SyncStore.now()
        try? db.transaction { for p in relPaths { sync.setFavorite(user: currentUser, relPath: p, fav, at: at) } }
        refreshCache(relPaths)
    }

    /// Copy the current user's totals (all devices, duplicates folded in) into the tracks table.
    func refreshCache(_ relPaths: [String]? = nil) {
        let totals = sync.totals(user: currentUser), favs = sync.favorites(user: currentUser), alias = sync.aliases()
        let paths = relPaths ?? ((try? db.query("SELECT rel_path FROM tracks")) ?? []).compactMap { $0.string("rel_path") }
        try? db.transaction {
            for p in paths {
                let k0 = SyncStore.key(p), k = alias[k0] ?? k0
                let t = totals[k], f = favs[k]
                try db.execute("UPDATE tracks SET play_count = ?, skip_count = ?, last_played = ?, favorite = ?, favorite_at = ? WHERE rel_path = ?",
                               [t?.plays ?? 0, t?.skips ?? 0, t?.lastPlayed, f?.0 ?? false, f.map { $0.1 > 0 ? $0.1 : nil } ?? nil, p])
            }
        }
    }

    /// One-time move of pre-sync data (this device's counts and favorites on the tracks table,
    /// plus whatever the app passes: other devices' backed-up counts, duplicate merges) into the
    /// replicated store, under the default user.
    /// `historyReplica`: the counter cell this device's existing counts go into (an iPhone uses
    /// "legacy-<its name>", matching how the Mac files its old backups, so they don't add up twice).
    func migrateLegacyStats(replica: String? = nil, historyReplica: String? = nil, otherDevices: [SyncStore.PlayCell] = [], aliases: [(String, String)] = []) {
        guard !sync.flag("legacyMigrated") else { return }
        if let replica { sync.setReplicaID(replica) }
        let me = historyReplica ?? sync.replicaID, u = SyncStore.defaultUserID
        let rows = (try? db.query("SELECT rel_path, play_count, skip_count, last_played, favorite, favorite_at FROM tracks WHERE play_count > 0 OR skip_count > 0 OR favorite = 1 OR favorite_at IS NOT NULL")) ?? []
        try? db.transaction {
            for r in rows {
                let k = SyncStore.key(r.string("rel_path") ?? "")
                if (r.int("play_count") ?? 0) > 0 || (r.int("skip_count") ?? 0) > 0 {
                    sync.mergePlay(.init(u: u, k: k, r: me, p: r.int("play_count") ?? 0, s: r.int("skip_count") ?? 0, l: r.double("last_played")))
                }
                if r.bool("favorite") || r.double("favorite_at") != nil {
                    // hearts from before timestamps existed get a tiny time, so any real change wins
                    sync.mergeFavorite(.init(u: u, k: k, f: r.bool("favorite"), t: r.double("favorite_at") ?? 1, b: me))
                }
            }
            for c in otherDevices { sync.mergePlay(c) }
            for (o, k) in aliases { sync.mergeAlias(.init(o: SyncStore.key(o), k: SyncStore.key(k), t: 1, b: me)) }
        }
        sync.setFlag("legacyMigrated")
        refreshCache()
    }

    func statEntries() -> [PlayStatEntry] {
        // include un-favorites (favorite_at set) so they propagate too
        let rows = (try? db.query("SELECT rel_path, play_count, skip_count, last_played, favorite, favorite_at FROM tracks WHERE play_count > 0 OR skip_count > 0 OR favorite = 1 OR favorite_at IS NOT NULL")) ?? []
        return rows.map { PlayStatEntry(relPath: $0.string("rel_path") ?? "", playCount: $0.int("play_count") ?? 0,
                                        skipCount: $0.int("skip_count") ?? 0, lastPlayed: $0.double("last_played"),
                                        favorite: $0.bool("favorite"), favoriteAt: $0.double("favorite_at")) }
    }

    /// Favorites from a device that doesn't replicate yet: newest change wins.
    @discardableResult
    func applyRemoteFavorites(_ remote: [(relPath: String, favorite: Bool, at: Double?)], by: String = "legacy") -> Int {
        var changed = 0
        try? db.transaction {
            for r in remote where r.at != nil || r.favorite {
                if sync.mergeFavorite(.init(u: currentUser, k: SyncStore.key(r.relPath), f: r.favorite, t: r.at ?? 1, b: by)) { changed += 1 }
            }
        }
        if changed > 0 { refreshCache(remote.map(\.relPath)) }
        return changed
    }

    /// A duplicate was removed: its stats count for the kept song from now on, on every device.
    @discardableResult
    func absorbStats(from: String, into keep: String) -> Bool {
        guard from != keep else { return false }
        sync.addAlias(old: from, keep: keep)
        refreshCache([keep])
        return true
    }

    /// Stats from an old-style backup: only favorites still matter (plays come from the devices).
    func mergeStats(_ entries: [PlayStatEntry]) throws {
        applyRemoteFavorites(entries.map { ($0.relPath, $0.favorite, $0.favoriteAt) })
    }
}
