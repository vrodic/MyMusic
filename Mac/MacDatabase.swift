import Foundation

enum YTPriority: Int, CaseIterable, Identifiable, Codable {
    case skip = 0, normal = 1, high = 2, maximum = 3
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .skip: "Do not download"
        case .normal: "Normal"
        case .high: "High"
        case .maximum: "Maximum"
        }
    }
}

enum YTStatus: String, Codable, CaseIterable { case pending, downloading, done, failed }

struct YTItem: Identifiable, Hashable {
    var videoID: String
    var title: String
    var uploader: String?
    var duration: Double?
    var playlistIndex: Int
    var priority: YTPriority
    var status: YTStatus
    var relPath: String?
    var error: String?
    var attempts: Int
    var inPlaylist: Bool
    var favorite: Bool = false
    var libraryMatch: String?       // relPath of the library song it matches
    var matchScore: Double?
    var matchOverride = false       // you said: download it anyway
    var favoriteSort: Int { favorite ? 1 : 0 }
    var id: String { videoID }
    /// Probably already in the library, so it won't be downloaded (unless you override).
    var likelyInLibrary: Bool { !matchOverride && status != .done && (matchScore ?? 0) >= YTLibraryMatcher.likelyThreshold }
    var possibleMatch: Bool { !likelyInLibrary && status != .done && (matchScore ?? 0) >= YTLibraryMatcher.possibleThreshold }
}

struct DeviceStatTotal: Hashable { var relPath: String; var plays: Int; var favorite: Bool }

extension LibraryDB {
    static let macMigrations = [
        """
        CREATE TABLE yt_items (
            video_id TEXT PRIMARY KEY, title TEXT NOT NULL, uploader TEXT, duration REAL,
            playlist_index INTEGER NOT NULL DEFAULT 0, priority INTEGER NOT NULL DEFAULT 1,
            status TEXT NOT NULL DEFAULT 'pending', rel_path TEXT, error TEXT,
            attempts INTEGER NOT NULL DEFAULT 0, added_at REAL NOT NULL, in_playlist INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE devices (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, last_sync REAL NOT NULL);
        CREATE TABLE device_stats (
            device_id TEXT NOT NULL, rel_path TEXT NOT NULL, play_count INTEGER NOT NULL DEFAULT 0,
            skip_count INTEGER NOT NULL DEFAULT 0, last_played REAL, favorite INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (device_id, rel_path)
        );
        """,
        // v3: when a download was last attempted (for hourly / daily throttling)
        "ALTER TABLE yt_items ADD COLUMN last_attempt_at REAL",
        // v4: favorite flag for liked songs that aren't downloaded yet (copied to the track when it is)
        "ALTER TABLE yt_items ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0",
        // v5
        LibraryDB.favoriteAtMigration,
        // v6: duplicates removed (here or on the web player), so iPhones/web can move their stats too
        "CREATE TABLE merged_paths (old TEXT PRIMARY KEY, keep TEXT NOT NULL, merged_at REAL NOT NULL)",
        // v7: liked songs that look like they're already in the library (fuzzy match), and your override
        "ALTER TABLE yt_items ADD COLUMN library_match TEXT; ALTER TABLE yt_items ADD COLUMN match_score REAL; ALTER TABLE yt_items ADD COLUMN match_override INTEGER NOT NULL DEFAULT 0;",
        // v8: app settings stored with the library, so a backup restores them too
        "CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    ]

    /// UserDefaults keys that travel with a library backup (not machine-specific ones like the music root).
    static let backedUpSettings = ["syncSelection", "syncFavorites", "yt.playlistURL", "yt.cookiesBrowser", "yt.defaultPriority",
                                   "yt.autoRefreshHours", "yt.delaySeconds", "yt.maxPerHour", "yt.maxPerDay", "yt.rateLimit",
                                   "yt.sleepRequests", "yt.cooldownHours", "server.name"]

    func saveSettingsForBackup() {
        let d = UserDefaults.standard
        try? db.transaction {
            for k in Self.backedUpSettings {
                guard let v = d.object(forKey: k) else { continue }
                let data = try PropertyListSerialization.data(fromPropertyList: v, format: .xml, options: 0)
                try db.execute("INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               [k, String(decoding: data, as: UTF8.self)])
            }
        }
    }

    func restoreSettingsFromBackup() {
        let rows = (try? db.query("SELECT key, value FROM app_settings")) ?? []
        for r in rows {
            guard let k = r.string("key"), Self.backedUpSettings.contains(k), let v = r.string("value"),
                  let obj = try? PropertyListSerialization.propertyList(from: Data(v.utf8), format: nil) else { continue }
            UserDefaults.standard.set(obj, forKey: k)
        }
    }

    func recordMerge(old: String, keep: String) {
        try? db.execute("INSERT INTO merged_paths (old, keep, merged_at) VALUES (?,?,?) ON CONFLICT(old) DO UPDATE SET keep = excluded.keep, merged_at = excluded.merged_at",
                        [old, keep, Date().timeIntervalSince1970])
        // anything that was merged into `old` earlier now points at `keep`
        try? db.execute("UPDATE merged_paths SET keep = ? WHERE keep = ?", [keep, old])
    }

    /// Merges from the last 90 days (old → keep), sent along with the library.
    func recentMerges() -> [String: String] {
        let since = Date().timeIntervalSince1970 - 90 * 86400
        let rows = (try? db.query("SELECT old, keep FROM merged_paths WHERE merged_at > ?", [since])) ?? []
        var out: [String: String] = [:]
        for r in rows { if let o = r.string("old"), let k = r.string("keep") { out[o] = k } }
        return out
    }

    // MARK: YouTube

    func setYTFavorite(_ ids: [String], _ fav: Bool) {
        try? db.transaction { for id in ids { try db.execute("UPDATE yt_items SET favorite = ? WHERE video_id = ?", [fav, id]) } }
    }

    func markYTAttempt(_ id: String) {
        try? db.execute("UPDATE yt_items SET last_attempt_at = ? WHERE video_id = ?", [Date().timeIntervalSince1970, id])
    }

    /// Attempt timestamps within the last `window` seconds, oldest first.
    func ytAttempts(within window: Double) -> [Double] {
        let since = Date().timeIntervalSince1970 - window
        return ((try? db.query("SELECT last_attempt_at FROM yt_items WHERE last_attempt_at > ? ORDER BY last_attempt_at", [since])) ?? [])
            .compactMap { $0.double("last_attempt_at") }
    }

    func ytItem(_ id: String) -> YTItem? { ytItems().first { $0.videoID == id } }

    func ytItems() -> [YTItem] {
        let rows = (try? db.query("SELECT * FROM yt_items ORDER BY playlist_index")) ?? []
        return rows.map {
            YTItem(videoID: $0.string("video_id") ?? "", title: $0.string("title") ?? "", uploader: $0.string("uploader"),
                   duration: $0.double("duration"), playlistIndex: $0.int("playlist_index") ?? 0,
                   priority: YTPriority(rawValue: $0.int("priority") ?? 1) ?? .normal,
                   status: YTStatus(rawValue: $0.string("status") ?? "") ?? .pending,
                   relPath: $0.string("rel_path"), error: $0.string("error"), attempts: $0.int("attempts") ?? 0,
                   inPlaylist: $0.bool("in_playlist"), favorite: $0.bool("favorite"),
                   libraryMatch: $0.string("library_match"), matchScore: $0.double("match_score"), matchOverride: $0.bool("match_override"))
        }
    }

    /// Upserts the liked playlist. New items get `defaultPriority`; existing items keep their priority/status.
    func syncYTPlaylist(_ entries: [(id: String, title: String, uploader: String?, duration: Double?)], defaultPriority: YTPriority) throws {
        try db.transaction {
            try db.execute("UPDATE yt_items SET in_playlist = 0")
            for (i, e) in entries.enumerated() {
                try db.execute("""
                    INSERT INTO yt_items (video_id, title, uploader, duration, playlist_index, priority, added_at, in_playlist)
                    VALUES (?,?,?,?,?,?,?,1)
                    ON CONFLICT(video_id) DO UPDATE SET title=excluded.title, uploader=excluded.uploader,
                      duration=excluded.duration, playlist_index=excluded.playlist_index, in_playlist=1
                    """, [e.id, e.title, e.uploader, e.duration, i, defaultPriority.rawValue, Date().timeIntervalSince1970])
            }
        }
    }

    func setYTPriority(_ ids: [String], _ p: YTPriority) {
        try? db.transaction { for id in ids { try db.execute("UPDATE yt_items SET priority = ? WHERE video_id = ?", [p.rawValue, id]) } }
    }

    func setYTStatus(_ id: String, _ s: YTStatus, relPath: String? = nil, error: String? = nil) {
        try? db.execute("UPDATE yt_items SET status = ?, rel_path = COALESCE(?, rel_path), error = ?, attempts = attempts + (CASE WHEN ? = 'failed' THEN 1 ELSE 0 END) WHERE video_id = ?",
                        [s.rawValue, relPath, error, s.rawValue, id])
    }

    func resetYT(_ ids: [String]) {
        try? db.transaction { for id in ids { try db.execute("UPDATE yt_items SET status='pending', attempts=0, error=NULL WHERE video_id = ?", [id]) } }
    }

    func resetStuckDownloads() { try? db.execute("UPDATE yt_items SET status='pending' WHERE status='downloading'") }

    /// Store fuzzy-match results (nil = no match). Only for songs not downloaded yet.
    func setYTLibraryMatches(_ results: [String: YTLibraryMatcher.Match?]) {
        try? db.transaction {
            for (id, m) in results {
                try db.execute("UPDATE yt_items SET library_match = ?, match_score = ? WHERE video_id = ?", [m?.relPath, m?.score, id])
            }
        }
    }

    func setYTMatchOverride(_ ids: [String], _ on: Bool) {
        try? db.transaction { for id in ids { try db.execute("UPDATE yt_items SET match_override = ? WHERE video_id = ?", [on, id]) } }
    }

    /// "It's in my library": mark by hand (score 1, no automatic re-check overrides that).
    func markYTInLibrary(_ ids: [String]) {
        try? db.transaction { for id in ids { try db.execute("UPDATE yt_items SET match_score = 1.0, match_override = 0, library_match = '' WHERE video_id = ?", [id]) } }
    }

    func nextYTDownload(maxAttempts: Int = 3) -> YTItem? {
        ytItems().filter { $0.priority != .skip && !$0.likelyInLibrary && ($0.status == .pending || ($0.status == .failed && $0.attempts < maxAttempts)) }
            .sorted { ($0.priority.rawValue, -$0.playlistIndex, -$0.attempts) > ($1.priority.rawValue, -$1.playlistIndex, -$1.attempts) }
            .first
    }

    // MARK: device stats backup

    func storeDeviceStats(_ up: StatsUpload) throws {
        try db.transaction {
            try db.execute("INSERT INTO devices (device_id, name, last_sync) VALUES (?,?,?) ON CONFLICT(device_id) DO UPDATE SET name=excluded.name, last_sync=excluded.last_sync",
                           [up.deviceID, up.deviceName, Date().timeIntervalSince1970])
            try db.execute("DELETE FROM device_stats WHERE device_id = ?", [up.deviceID])
            for e in up.entries {
                try db.execute("INSERT INTO device_stats VALUES (?,?,?,?,?,?)",
                               [up.deviceID, e.relPath, e.playCount, e.skipCount, e.lastPlayed, e.favorite])
            }
        }
        // Favorites are shared state: newest change (Mac or iPhone) wins, so hearts match everywhere.
        applyRemoteFavorites(up.entries.map { ($0.relPath, $0.favorite, $0.favoriteAt) })
    }

    func deviceBackups() -> [DeviceBackup] {
        let rows = (try? db.query("SELECT d.device_id, d.name, d.last_sync, (SELECT COUNT(*) FROM device_stats s WHERE s.device_id = d.device_id) AS n FROM devices d ORDER BY d.last_sync DESC")) ?? []
        return rows.map { DeviceBackup(deviceID: $0.string("device_id") ?? "", deviceName: $0.string("name") ?? "",
                                       lastSync: $0.double("last_sync") ?? 0, entryCount: $0.int("n") ?? 0) }
    }

    func deviceStats(_ deviceID: String) -> [PlayStatEntry] {
        let rows = (try? db.query("SELECT * FROM device_stats WHERE device_id = ?", [deviceID])) ?? []
        return rows.map { PlayStatEntry(relPath: $0.string("rel_path") ?? "", playCount: $0.int("play_count") ?? 0,
                                        skipCount: $0.int("skip_count") ?? 0, lastPlayed: $0.double("last_played"),
                                        favorite: $0.bool("favorite")) }
    }

    /// Sum of plays across all devices, per track.
    func devicePlayTotals(excluding deviceID: String? = nil) -> [String: DeviceStatTotal] {
        let rows = (try? db.query("SELECT rel_path, SUM(play_count) AS p, MAX(favorite) AS f FROM device_stats WHERE device_id != ? GROUP BY rel_path",
                                  [deviceID ?? ""])) ?? []
        var out: [String: DeviceStatTotal] = [:]
        for r in rows {
            let p = r.string("rel_path") ?? ""
            out[p] = DeviceStatTotal(relPath: p, plays: r.int("p") ?? 0, favorite: r.bool("f"))
        }
        return out
    }
}
