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

enum YTStatus: String, Codable, CaseIterable { case pending, downloading, done, failed, deleted }

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
    var uploaderSort: String { (uploader ?? "").localizedLowercase }
    var durationSort: Double { duration ?? 0 }
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

    // MARK: YouTube queue replication (shared with the other Macs through SyncStore)

    /// Send these songs' current state to the other Macs: `user` = priority/favorite/override
    /// changed, `download` = download state changed.
    func publishYT(_ ids: [String], user: Bool, download: Bool, info: Bool = false) {
        guard !ids.isEmpty else { return }
        let want = Set(ids)
        try? db.transaction {
            for it in ytItems() where want.contains(it.videoID) {
                var f: [String: Any] = [:]
                if info || user || download {
                    f["title"] = it.title; f["playlistIndex"] = it.playlistIndex; f["inPlaylist"] = it.inPlaylist
                    if let u = it.uploader { f["uploader"] = u }
                    if let d = it.duration { f["duration"] = d }
                }
                if user { f["priority"] = it.priority.rawValue; f["favorite"] = it.favorite; f["matchOverride"] = it.matchOverride }
                if download {
                    f["status"] = it.status == .downloading ? YTStatus.pending.rawValue : it.status.rawValue
                    f["relPath"] = it.relPath ?? NSNull(); f["error"] = it.error ?? NSNull(); f["attempts"] = it.attempts
                }
                sync.putYT(id: it.videoID, fields: f, user: user, download: download, done: it.status == .done)
            }
        }
    }

    /// Take the other Macs' YouTube changes into the local queue. Returns songs that another Mac
    /// downloaded (so this Mac can index the file it now sees on the shared drive).
    func applySyncedYT(_ ids: [String]? = nil) -> [String] {
        let want = ids.map(Set.init)
        let local = Dictionary(uniqueKeysWithValues: ytItems().map { ($0.videoID, $0) })
        var downloadedElsewhere: [String] = []
        try? db.transaction {
            for (id, doc, done) in sync.ytDocs() where want?.contains(id) ?? true {
                let title = doc["title"] as? String ?? id
                if local[id] == nil {
                    try db.execute("INSERT INTO yt_items (video_id, title, uploader, duration, playlist_index, priority, added_at, in_playlist) VALUES (?,?,?,?,?,?,?,?)",
                                   [id, title, doc["uploader"] as? String, doc["duration"] as? Double, doc["playlistIndex"] as? Int ?? 0,
                                    doc["priority"] as? Int ?? YTPriority.normal.rawValue, Date().timeIntervalSince1970, (doc["inPlaylist"] as? Bool ?? true)])
                }
                if let p = doc["priority"] as? Int {
                    try db.execute("UPDATE yt_items SET priority = ?, favorite = ?, match_override = ? WHERE video_id = ?",
                                   [p, doc["favorite"] as? Bool ?? false, doc["matchOverride"] as? Bool ?? false, id])
                }
                if let st = doc["status"] as? String {
                    let cur = local[id]
                    // never interrupt our own running download with someone else's older state
                    if cur?.status == .downloading && !done && st != YTStatus.deleted.rawValue { continue }
                    if st == YTStatus.deleted.rawValue {
                        try db.execute("UPDATE yt_items SET status = ?, rel_path = NULL, priority = ?, error = ?, attempts = ? WHERE video_id = ?",
                                       [st, YTPriority.skip.rawValue, doc["error"] as? String, doc["attempts"] as? Int ?? 0, id])
                    } else {
                        try db.execute("UPDATE yt_items SET status = ?, rel_path = COALESCE(?, rel_path), error = ?, attempts = ? WHERE video_id = ?",
                                       [done ? YTStatus.done.rawValue : st, doc["relPath"] as? String, doc["error"] as? String, doc["attempts"] as? Int ?? 0, id])
                    }
                    if done, cur?.status != .done, let rel = doc["relPath"] as? String { downloadedElsewhere.append(rel) }
                }
            }
        }
        return downloadedElsewhere
    }

    func setYTFavorite(_ ids: [String], _ fav: Bool) {
        try? db.transaction { for id in ids { try db.execute("UPDATE yt_items SET favorite = ? WHERE video_id = ?", [fav, id]) } }
        publishYT(ids, user: true, download: false)
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
        let known = Set(ytItems().map(\.videoID))
        defer {
            // newly liked songs go to the other Macs (just the song; their priority stays each Mac's until changed)
            publishYT(entries.map(\.id).filter { !known.contains($0) }, user: false, download: false, info: true)
        }
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
        publishYT(ids, user: true, download: false)
    }

    func setYTStatus(_ id: String, _ s: YTStatus, relPath: String? = nil, error: String? = nil) {
        try? db.execute("UPDATE yt_items SET status = ?, rel_path = COALESCE(?, rel_path), error = ?, attempts = attempts + (CASE WHEN ? = 'failed' THEN 1 ELSE 0 END) WHERE video_id = ?",
                        [s.rawValue, relPath, error, s.rawValue, id])
        if s != .downloading { publishYT([id], user: false, download: true) }
    }

    func resetYT(_ ids: [String]) {
        try? db.transaction { for id in ids { try db.execute("UPDATE yt_items SET status='pending', attempts=0, error=NULL WHERE video_id = ?", [id]) } }
        publishYT(ids, user: false, download: true)
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
        publishYT(ids, user: true, download: false)
    }

    /// "It's in my library": mark by hand (score 1, no automatic re-check overrides that).
    func markYTInLibrary(_ ids: [String]) {
        try? db.transaction { for id in ids { try db.execute("UPDATE yt_items SET match_score = 1.0, match_override = 0, library_match = '' WHERE video_id = ?", [id]) } }
    }

    /// Mark YouTube items as deleted and do not download when a song file is deleted.
    func markYTDeleted(_ relPaths: [String]) {
        let set = Set(relPaths)
        let affected = ytItems().filter { item in
            if let r = item.relPath, set.contains(r) { return true }
            if let m = item.libraryMatch, set.contains(m) { return true }
            return false
        }
        guard !affected.isEmpty else { return }
        try? db.transaction {
            for it in affected {
                try db.execute("UPDATE yt_items SET status = 'deleted', priority = ?, rel_path = NULL WHERE video_id = ?",
                               [YTPriority.skip.rawValue, it.videoID])
            }
        }
        publishYT(affected.map(\.videoID), user: true, download: true)
    }

    /// Songs another Mac is downloading right now.
    func ytClaimedElsewhere() -> Set<String> {
        let me = sync.replicaID
        return Set(((try? db.query("SELECT video_id FROM sync_claims WHERE until > ? AND replica != ?", [SyncStore.now(), me])) ?? []).compactMap { $0.string("video_id") })
    }

    func nextYTDownload(maxAttempts: Int = 3) -> YTItem? {
        let elsewhere = ytClaimedElsewhere()
        return ytItems().filter { $0.priority != .skip && $0.status != .deleted && !$0.likelyInLibrary && !elsewhere.contains($0.videoID)
            && ($0.status == .pending || ($0.status == .failed && $0.attempts < maxAttempts)) }
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
        // Into the replicated store: that device's own counter cells, and favorites (newest wins).
        // An iPhone with the old app sends its whole history each time under a new random id, so its
        // counts go into the one "legacy-iPhone" counter (max per song), never a new one per sync.
        let user = up.userID ?? SyncStore.defaultUserID
        let replica = up.deviceID.hasPrefix("web-") ? up.deviceID : (up.userID == nil ? "legacy-iPhone" : up.deviceID)
        try? db.transaction {
            for e in up.entries where e.playCount > 0 || e.skipCount > 0 {
                sync.setCounts(user: user, relPath: e.relPath, replica: replica, plays: e.playCount, skips: e.skipCount, lastPlayed: e.lastPlayed)
            }
        }
        applyRemoteFavorites(up.entries.map { ($0.relPath, $0.favorite, $0.favoriteAt) }, by: up.deviceID)
        refreshCache(up.entries.map(\.relPath))
    }

    /// Legacy per-device backups as replicated counter cells (one-time migration). Older iPhone
    /// apps didn't keep their device id, so one phone shows up under several ids, each a full
    /// snapshot of its counts: those are grouped by device name, taking the highest count per song
    /// (the phone files its own history under the same "legacy-<name>" cell, so nothing doubles).
    /// The web player's id was always stable and stays as is.
    func legacyDeviceCells() -> [SyncStore.PlayCell] {
        let rows = (try? db.query("""
            SELECT s.device_id, COALESCE(d.name, 'iPhone') AS name, s.rel_path, s.play_count, s.skip_count, s.last_played
            FROM device_stats s LEFT JOIN devices d USING (device_id) WHERE s.play_count > 0 OR s.skip_count > 0
            """)) ?? []
        var cells: [String: SyncStore.PlayCell] = [:]
        for r in rows {
            let id = r.string("device_id") ?? ""
            let replica = id.hasPrefix("web-") ? id : "legacy-" + (r.string("name") ?? "iPhone")
            let k = SyncStore.key(r.string("rel_path") ?? "")
            let key = replica + "\u{1}" + k
            var c = cells[key] ?? SyncStore.PlayCell(u: SyncStore.defaultUserID, k: k, r: replica, p: 0, s: 0, l: nil)
            c.p = max(c.p, r.int("play_count") ?? 0)
            c.s = max(c.s, r.int("skip_count") ?? 0)
            if let l = r.double("last_played") { c.l = max(c.l ?? 0, l) }
            cells[key] = c
        }
        return Array(cells.values)
    }

    func legacyMerges() -> [(String, String)] {
        ((try? db.query("SELECT old, keep FROM merged_paths")) ?? []).compactMap { r in r.string("old").flatMap { o in r.string("keep").map { (o, $0) } } }
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
