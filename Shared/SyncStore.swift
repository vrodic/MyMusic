import Foundation

/// Peer-to-peer replicated state shared by every MyMusic device (Macs, iPhones, the web player):
/// users, per-user play counts and favorites, playlists, per-user settings, duplicate aliases, and
/// (between Macs) the YouTube queue. Every device keeps a full copy and works offline; peers swap
/// only what changed since they last talked, in any order, and always end up with the same state.
///
/// Merge rules (conflict-free):
///  * plays — one counter cell per (user, song, device); a device only ever raises its own cell,
///    merging takes the max per cell, a song's total is the sum over devices
///  * favorites, users, playlists, settings, YouTube fields — newest change wins (ties: device id)
///  * aliases — "old path → kept path" after a duplicate was removed; stats follow the kept song
///  * YouTube: a downloaded song stays downloaded; download claims stop two Macs fetching one song
///
/// Songs are keyed by their path in Unicode NFC, so the Mac (decomposed names over SMB) and Linux
/// (composed names) agree.
final class SyncStore: @unchecked Sendable {
    let db: SQLiteDB
    static let defaultUserID = "default"

    /// Appended to each app's migration list (numbers differ per app).
    static let migration = """
        CREATE TABLE IF NOT EXISTS sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_users (user_id TEXT PRIMARY KEY, name TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
            ts REAL NOT NULL, by TEXT NOT NULL, seq INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_plays (user_id TEXT NOT NULL, track_key TEXT NOT NULL, replica TEXT NOT NULL,
            plays INTEGER NOT NULL DEFAULT 0, skips INTEGER NOT NULL DEFAULT 0, last_played REAL, seq INTEGER NOT NULL,
            PRIMARY KEY (user_id, track_key, replica));
        CREATE TABLE IF NOT EXISTS sync_favorites (user_id TEXT NOT NULL, track_key TEXT NOT NULL, favorite INTEGER NOT NULL,
            ts REAL NOT NULL, by TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (user_id, track_key));
        CREATE TABLE IF NOT EXISTS sync_aliases (old_key TEXT PRIMARY KEY, keep_key TEXT NOT NULL, ts REAL NOT NULL, by TEXT NOT NULL, seq INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_playlists (playlist_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, name TEXT NOT NULL,
            items TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, ts REAL NOT NULL, by TEXT NOT NULL, seq INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_settings (user_id TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
            ts REAL NOT NULL, by TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (user_id, key));
        CREATE TABLE IF NOT EXISTS sync_yt (video_id TEXT PRIMARY KEY, doc TEXT NOT NULL, user_ts REAL NOT NULL, dl_ts REAL NOT NULL,
            done INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_claims (video_id TEXT PRIMARY KEY, replica TEXT NOT NULL, until REAL NOT NULL, ts REAL NOT NULL, seq INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_peers (replica TEXT PRIMARY KEY, name TEXT NOT NULL, pulled_seq INTEGER NOT NULL DEFAULT 0,
            pushed_seq INTEGER NOT NULL DEFAULT 0, last_sync REAL);
        CREATE INDEX IF NOT EXISTS sync_plays_seq ON sync_plays(seq);
        CREATE INDEX IF NOT EXISTS sync_plays_user ON sync_plays(user_id, track_key);
        """

    init(db: SQLiteDB) { self.db = db }

    // MARK: identity, clock

    /// This device's id in the sync (stable; regenerated after restoring someone else's backup).
    var replicaID: String {
        if let v = meta("replica") { return v }
        let id = UUID().uuidString
        setMeta("replica", id)
        return id
    }

    func setReplicaID(_ id: String) { setMeta("replica", id) }

    /// Local sequence number: every row this device writes or learns gets the next one, so a peer
    /// asking "what changed since N" gets everything new, including what came from third devices.
    var currentSeq: Int { Int(meta("seq") ?? "0") ?? 0 }
    private func nextSeq() -> Int {
        let n = currentSeq + 1
        setMeta("seq", String(n))
        return n
    }

    /// Wall clock, corrected by an offset learned from peers (servers without NTP).
    static var clockOffset: Double = 0
    static func now() -> Double { Date().timeIntervalSince1970 + clockOffset }

    func flag(_ k: String) -> Bool { meta(k) != nil }
    func setFlag(_ k: String) { setMeta(k, "1") }

    private func meta(_ k: String) -> String? { (try? db.query("SELECT value FROM sync_meta WHERE key = ?", [k]))?.first?.string("value") }
    private func setMeta(_ k: String, _ v: String) {
        try? db.execute("INSERT INTO sync_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [k, v])
    }

    static func key(_ relPath: String) -> String { relPath.precomposedStringWithCanonicalMapping }

    // MARK: local changes

    func recordPlay(user: String, relPath: String, at: Double = SyncStore.now()) {
        bump(user: user, key: Self.key(relPath), plays: 1, skips: 0, at: at)
    }

    func recordSkip(user: String, relPath: String) {
        bump(user: user, key: Self.key(relPath), plays: 0, skips: 1, at: nil)
    }

    private func bump(user: String, key: String, plays: Int, skips: Int, at: Double?) {
        try? db.transaction {
            let seq = nextSeq()
            try db.execute("""
                INSERT INTO sync_plays (user_id, track_key, replica, plays, skips, last_played, seq) VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(user_id, track_key, replica) DO UPDATE SET plays = plays + excluded.plays, skips = skips + excluded.skips,
                  last_played = MAX(COALESCE(last_played, 0), COALESCE(excluded.last_played, 0)), seq = excluded.seq
                """, [user, key, replicaID, plays, skips, at, seq])
        }
    }

    /// Absolute counts reported by a device that keeps its own counter (e.g. an older iPhone app).
    func setCounts(user: String, relPath: String, replica: String, plays: Int, skips: Int, lastPlayed: Double?) {
        mergePlay(PlayCell(u: user, k: Self.key(relPath), r: replica, p: plays, s: skips, l: lastPlayed))
    }

    func setFavorite(user: String, relPath: String, _ fav: Bool, at: Double = SyncStore.now()) {
        mergeFavorite(FavCell(u: user, k: Self.key(relPath), f: fav, t: at, b: replicaID))
    }

    func addAlias(old: String, keep: String) {
        mergeAlias(AliasCell(o: Self.key(old), k: Self.key(keep), t: Self.now(), b: replicaID))
    }

    func saveUser(id: String, name: String, deleted: Bool = false) {
        mergeUser(UserCell(id: id, n: name, d: deleted, t: Self.now(), b: replicaID))
    }

    func savePlaylist(_ p: Playlist) {
        mergePlaylist(PlaylistCell(id: p.id, u: p.userID, n: p.name, i: p.items.map(Self.key), d: p.deleted, t: Self.now(), b: replicaID))
    }

    func setSetting(user: String, key: String, value: String) {
        mergeSetting(SettingCell(u: user, k: key, v: value, t: Self.now(), b: replicaID))
    }

    // MARK: queries

    struct User: Identifiable, Hashable { var id: String; var name: String }

    func users() -> [User] {
        var list = ((try? db.query("SELECT user_id, name FROM sync_users WHERE deleted = 0")) ?? [])
            .map { User(id: $0.string("user_id") ?? "", name: $0.string("name") ?? "") }
        if !list.contains(where: { $0.id == Self.defaultUserID }) && meta("defaultDeleted") == nil {
            list.insert(User(id: Self.defaultUserID, name: NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"), at: 0)
        }
        return list.sorted { $0.id == Self.defaultUserID ? true : ($1.id == Self.defaultUserID ? false : $0.name < $1.name) }
    }

    /// old key → kept key, followed through chains.
    func aliases() -> [String: String] {
        var m: [String: String] = [:]
        for r in (try? db.query("SELECT old_key, keep_key FROM sync_aliases")) ?? [] {
            if let o = r.string("old_key"), let k = r.string("keep_key") { m[o] = k }
        }
        func resolve(_ k: String) -> String { var x = k, hops = 0; while let n = m[x], hops < 20 { x = n; hops += 1 }; return x }
        return m.mapValues(resolve)
    }

    struct Totals { var plays = 0; var skips = 0; var lastPlayed: Double? }

    /// Per-song totals for a user (all devices; duplicates folded into the kept song).
    func totals(user: String) -> [String: Totals] {
        let alias = aliases()
        var out: [String: Totals] = [:]
        let rows = (try? db.query("SELECT track_key, SUM(plays) AS p, SUM(skips) AS s, MAX(last_played) AS l FROM sync_plays WHERE user_id = ? GROUP BY track_key", [user])) ?? []
        for r in rows {
            let k = alias[r.string("track_key") ?? ""] ?? (r.string("track_key") ?? "")
            var t = out[k] ?? Totals()
            t.plays += r.int("p") ?? 0
            t.skips += r.int("s") ?? 0
            if let l = r.double("l"), l > 0 { t.lastPlayed = max(t.lastPlayed ?? 0, l) }
            out[k] = t
        }
        return out
    }

    /// Favorite state per song for a user, with when it changed.
    func favorites(user: String) -> [String: (Bool, Double)] {
        let alias = aliases()
        var out: [String: (Bool, Double)] = [:]
        for r in (try? db.query("SELECT track_key, favorite, ts FROM sync_favorites WHERE user_id = ?", [user])) ?? [] {
            let k = alias[r.string("track_key") ?? ""] ?? (r.string("track_key") ?? "")
            let v = (r.bool("favorite"), r.double("ts") ?? 0)
            if let cur = out[k], cur.1 >= v.1 { continue }   // a merged duplicate's older heart doesn't win
            out[k] = v
        }
        return out
    }

    struct Playlist: Identifiable, Hashable {
        var id: String
        var userID: String
        var name: String
        var items: [String]      // song keys (NFC relPaths), in order
        var deleted = false
    }

    func playlists(user: String) -> [Playlist] {
        let alias = aliases()
        return ((try? db.query("SELECT * FROM sync_playlists WHERE user_id = ? AND deleted = 0", [user])) ?? []).map { r in
            let items = (try? JSONDecoder().decode([String].self, from: Data((r.string("items") ?? "[]").utf8))) ?? []
            return Playlist(id: r.string("playlist_id") ?? "", userID: user, name: r.string("name") ?? "",
                            items: items.map { alias[$0] ?? $0 })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setting(user: String, key: String) -> String? {
        (try? db.query("SELECT value FROM sync_settings WHERE user_id = ? AND key = ?", [user, key]))?.first?.string("value")
    }

    // MARK: replication

    struct PlayCell: Codable, Hashable { var u: String; var k: String; var r: String; var p: Int; var s: Int; var l: Double? }
    struct FavCell: Codable, Hashable { var u: String; var k: String; var f: Bool; var t: Double; var b: String }
    struct AliasCell: Codable, Hashable { var o: String; var k: String; var t: Double; var b: String }
    struct UserCell: Codable, Hashable { var id: String; var n: String; var d: Bool; var t: Double; var b: String }
    struct PlaylistCell: Codable, Hashable { var id: String; var u: String; var n: String; var i: [String]; var d: Bool; var t: Double; var b: String }
    struct SettingCell: Codable, Hashable { var u: String; var k: String; var v: String; var t: Double; var b: String }
    /// A liked YouTube song: `doc` is the JSON of its fields; `ut` = when its user fields (priority,
    /// favorite, override) last changed, `dt` = when its download state last changed.
    struct YTCell: Codable, Hashable { var id: String; var doc: String; var ut: Double; var dt: Double; var done: Bool }
    /// A download claim (or its release, `until` in the past); the latest write wins.
    struct ClaimCell: Codable, Hashable { var id: String; var r: String; var until: Double; var t: Double }

    struct ChangeSet: Codable {
        var replica: String
        var name: String?
        var seq: Int                 // the sender's sequence number after these changes
        var now: Double?             // the sender's clock (to correct clock drift)
        var plays: [PlayCell] = []
        var favorites: [FavCell] = []
        var aliases: [AliasCell] = []
        var users: [UserCell] = []
        var playlists: [PlaylistCell] = []
        var settings: [SettingCell] = []
        var yt: [YTCell] = []
        var claims: [ClaimCell] = []
        var isEmpty: Bool { plays.isEmpty && favorites.isEmpty && aliases.isEmpty && users.isEmpty && playlists.isEmpty && settings.isEmpty && yt.isEmpty && claims.isEmpty }
    }

    /// Everything this device has written or learned after `since` (its own sequence numbers).
    func changes(since: Int, includeYT: Bool = true, name: String? = nil) -> ChangeSet {
        var cs = ChangeSet(replica: replicaID, name: name, seq: currentSeq, now: Date().timeIntervalSince1970)
        func q(_ sql: String) -> [SQLRow] { (try? db.query(sql, [since])) ?? [] }
        cs.plays = q("SELECT * FROM sync_plays WHERE seq > ?").map {
            PlayCell(u: $0.string("user_id") ?? "", k: $0.string("track_key") ?? "", r: $0.string("replica") ?? "",
                     p: $0.int("plays") ?? 0, s: $0.int("skips") ?? 0, l: $0.double("last_played"))
        }
        cs.favorites = q("SELECT * FROM sync_favorites WHERE seq > ?").map {
            FavCell(u: $0.string("user_id") ?? "", k: $0.string("track_key") ?? "", f: $0.bool("favorite"), t: $0.double("ts") ?? 0, b: $0.string("by") ?? "")
        }
        cs.aliases = q("SELECT * FROM sync_aliases WHERE seq > ?").map {
            AliasCell(o: $0.string("old_key") ?? "", k: $0.string("keep_key") ?? "", t: $0.double("ts") ?? 0, b: $0.string("by") ?? "")
        }
        cs.users = q("SELECT * FROM sync_users WHERE seq > ?").map {
            UserCell(id: $0.string("user_id") ?? "", n: $0.string("name") ?? "", d: $0.bool("deleted"), t: $0.double("ts") ?? 0, b: $0.string("by") ?? "")
        }
        cs.playlists = q("SELECT * FROM sync_playlists WHERE seq > ?").map {
            PlaylistCell(id: $0.string("playlist_id") ?? "", u: $0.string("user_id") ?? "", n: $0.string("name") ?? "",
                         i: (try? JSONDecoder().decode([String].self, from: Data(($0.string("items") ?? "[]").utf8))) ?? [],
                         d: $0.bool("deleted"), t: $0.double("ts") ?? 0, b: $0.string("by") ?? "")
        }
        cs.settings = q("SELECT * FROM sync_settings WHERE seq > ?").map {
            SettingCell(u: $0.string("user_id") ?? "", k: $0.string("key") ?? "", v: $0.string("value") ?? "", t: $0.double("ts") ?? 0, b: $0.string("by") ?? "")
        }
        if includeYT {
            cs.yt = q("SELECT * FROM sync_yt WHERE seq > ?").map {
                YTCell(id: $0.string("video_id") ?? "", doc: $0.string("doc") ?? "{}", ut: $0.double("user_ts") ?? 0, dt: $0.double("dl_ts") ?? 0, done: $0.bool("done"))
            }
            cs.claims = q("SELECT * FROM sync_claims WHERE seq > ?").map {
                ClaimCell(id: $0.string("video_id") ?? "", r: $0.string("replica") ?? "", until: $0.double("until") ?? 0, t: $0.double("ts") ?? 0)
            }
        }
        return cs
    }

    struct ApplyResult { var changed = 0; var ytChanged: [String] = [] }

    /// Merge a peer's changes. Returns how many rows changed here (and which YouTube songs).
    @discardableResult
    func apply(_ cs: ChangeSet) -> ApplyResult {
        var res = ApplyResult()
        try? db.transaction {
            for c in cs.plays where mergePlay(c) { res.changed += 1 }
            for c in cs.favorites where mergeFavorite(c) { res.changed += 1 }
            for c in cs.aliases where mergeAlias(c) { res.changed += 1 }
            for c in cs.users where mergeUser(c) { res.changed += 1 }
            for c in cs.playlists where mergePlaylist(c) { res.changed += 1 }
            for c in cs.settings where mergeSetting(c) { res.changed += 1 }
            for c in cs.yt where mergeYT(c) { res.changed += 1; res.ytChanged.append(c.id) }
            for c in cs.claims where mergeClaim(c) { res.changed += 1 }
        }
        return res
    }

    /// Newer wins; equal times are decided by device id so every peer picks the same winner.
    private static func newer(_ t: Double, _ b: String, than t2: Double, _ b2: String) -> Bool { t != t2 ? t > t2 : b > b2 }

    @discardableResult func mergePlay(_ c: PlayCell) -> Bool {
        let cur = (try? db.query("SELECT plays, skips, last_played FROM sync_plays WHERE user_id = ? AND track_key = ? AND replica = ?", [c.u, c.k, c.r]))?.first
        let p = max(cur?.int("plays") ?? 0, c.p), s = max(cur?.int("skips") ?? 0, c.s)
        let l = max(cur?.double("last_played") ?? 0, c.l ?? 0)
        if let cur, cur.int("plays") == p, cur.int("skips") == s, (cur.double("last_played") ?? 0) == l { return false }
        try? db.execute("""
            INSERT INTO sync_plays (user_id, track_key, replica, plays, skips, last_played, seq) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(user_id, track_key, replica) DO UPDATE SET plays = excluded.plays, skips = excluded.skips, last_played = excluded.last_played, seq = excluded.seq
            """, [c.u, c.k, c.r, p, s, l > 0 ? l : nil, nextSeq()])
        return true
    }

    @discardableResult func mergeFavorite(_ c: FavCell) -> Bool {
        if let cur = (try? db.query("SELECT ts, by FROM sync_favorites WHERE user_id = ? AND track_key = ?", [c.u, c.k]))?.first,
           !Self.newer(c.t, c.b, than: cur.double("ts") ?? 0, cur.string("by") ?? "") { return false }
        try? db.execute("INSERT INTO sync_favorites VALUES (?,?,?,?,?,?) ON CONFLICT(user_id, track_key) DO UPDATE SET favorite = excluded.favorite, ts = excluded.ts, by = excluded.by, seq = excluded.seq",
                        [c.u, c.k, c.f, c.t, c.b, nextSeq()])
        return true
    }

    @discardableResult func mergeAlias(_ c: AliasCell) -> Bool {
        guard c.o != c.k else { return false }
        if let cur = (try? db.query("SELECT keep_key, ts, by FROM sync_aliases WHERE old_key = ?", [c.o]))?.first,
           cur.string("keep_key") == c.k || !Self.newer(c.t, c.b, than: cur.double("ts") ?? 0, cur.string("by") ?? "") { return false }
        try? db.execute("INSERT INTO sync_aliases VALUES (?,?,?,?,?) ON CONFLICT(old_key) DO UPDATE SET keep_key = excluded.keep_key, ts = excluded.ts, by = excluded.by, seq = excluded.seq",
                        [c.o, c.k, c.t, c.b, nextSeq()])
        return true
    }

    @discardableResult func mergeUser(_ c: UserCell) -> Bool {
        if let cur = (try? db.query("SELECT ts, by FROM sync_users WHERE user_id = ?", [c.id]))?.first,
           !Self.newer(c.t, c.b, than: cur.double("ts") ?? 0, cur.string("by") ?? "") { return false }
        try? db.execute("INSERT INTO sync_users VALUES (?,?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET name = excluded.name, deleted = excluded.deleted, ts = excluded.ts, by = excluded.by, seq = excluded.seq",
                        [c.id, c.n, c.d, c.t, c.b, nextSeq()])
        return true
    }

    @discardableResult func mergePlaylist(_ c: PlaylistCell) -> Bool {
        if let cur = (try? db.query("SELECT ts, by FROM sync_playlists WHERE playlist_id = ?", [c.id]))?.first,
           !Self.newer(c.t, c.b, than: cur.double("ts") ?? 0, cur.string("by") ?? "") { return false }
        let items = String(decoding: (try? JSONEncoder().encode(c.i)) ?? Data("[]".utf8), as: UTF8.self)
        try? db.execute("""
            INSERT INTO sync_playlists VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(playlist_id) DO UPDATE SET user_id = excluded.user_id,
              name = excluded.name, items = excluded.items, deleted = excluded.deleted, ts = excluded.ts, by = excluded.by, seq = excluded.seq
            """, [c.id, c.u, c.n, items, c.d, c.t, c.b, nextSeq()])
        return true
    }

    @discardableResult func mergeSetting(_ c: SettingCell) -> Bool {
        if let cur = (try? db.query("SELECT ts, by FROM sync_settings WHERE user_id = ? AND key = ?", [c.u, c.k]))?.first,
           !Self.newer(c.t, c.b, than: cur.double("ts") ?? 0, cur.string("by") ?? "") { return false }
        try? db.execute("INSERT INTO sync_settings VALUES (?,?,?,?,?,?) ON CONFLICT(user_id, key) DO UPDATE SET value = excluded.value, ts = excluded.ts, by = excluded.by, seq = excluded.seq",
                        [c.u, c.k, c.v, c.t, c.b, nextSeq()])
        return true
    }

    /// YouTube songs: user fields and download fields merge separately (newest each); "done" sticks.
    @discardableResult func mergeYT(_ c: YTCell) -> Bool {
        guard let cur = (try? db.query("SELECT * FROM sync_yt WHERE video_id = ?", [c.id]))?.first else {
            try? db.execute("INSERT INTO sync_yt VALUES (?,?,?,?,?,?)", [c.id, c.doc, c.ut, c.dt, c.done, nextSeq()])
            return true
        }
        var mine = (try? JSONSerialization.jsonObject(with: Data((cur.string("doc") ?? "{}").utf8)) as? [String: Any]) ?? [:]
        let theirs = (try? JSONSerialization.jsonObject(with: Data(c.doc.utf8)) as? [String: Any]) ?? [:]
        let myUT = cur.double("user_ts") ?? 0, myDT = cur.double("dl_ts") ?? 0, myDone = cur.bool("done")
        var changed = false
        if c.ut > myUT { for k in YTDoc.userFields { mine[k] = theirs[k] }; changed = true }
        let takeDL = (c.done && !myDone) || (c.done == myDone && c.dt > myDT)
        if takeDL { for k in YTDoc.downloadFields { mine[k] = theirs[k] }; changed = true }
        for k in YTDoc.infoFields where mine[k] == nil && theirs[k] != nil { mine[k] = theirs[k]; changed = true }
        guard changed else { return false }
        let doc = String(decoding: (try? JSONSerialization.data(withJSONObject: mine, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
        try? db.execute("UPDATE sync_yt SET doc = ?, user_ts = ?, dl_ts = ?, done = ?, seq = ? WHERE video_id = ?",
                        [doc, max(myUT, c.ut), takeDL ? c.dt : myDT, myDone || c.done, nextSeq(), c.id])
        return true
    }

    @discardableResult func mergeClaim(_ c: ClaimCell) -> Bool {
        if let cur = (try? db.query("SELECT replica, ts FROM sync_claims WHERE video_id = ?", [c.id]))?.first,
           !Self.newer(c.t, c.r, than: cur.double("ts") ?? 0, cur.string("replica") ?? "") { return false }
        try? db.execute("INSERT INTO sync_claims VALUES (?,?,?,?,?) ON CONFLICT(video_id) DO UPDATE SET replica = excluded.replica, until = excluded.until, ts = excluded.ts, seq = excluded.seq",
                        [c.id, c.r, c.until, c.t, nextSeq()])
        return true
    }

    // MARK: YouTube (local writes)

    func putYT(id: String, fields: [String: Any], user: Bool, download: Bool, done: Bool) {
        var doc = (try? db.query("SELECT doc FROM sync_yt WHERE video_id = ?", [id]))?.first.flatMap {
            try? JSONSerialization.jsonObject(with: Data(($0.string("doc") ?? "{}").utf8)) as? [String: Any]
        } ?? [:]
        for (k, v) in fields { doc[k] = v }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
        let t = Self.now()
        let cur = (try? db.query("SELECT user_ts, dl_ts, done FROM sync_yt WHERE video_id = ?", [id]))?.first
        try? db.execute("INSERT INTO sync_yt VALUES (?,?,?,?,?,?) ON CONFLICT(video_id) DO UPDATE SET doc = excluded.doc, user_ts = excluded.user_ts, dl_ts = excluded.dl_ts, done = excluded.done, seq = excluded.seq",
                        [id, json, user ? t : (cur?.double("user_ts") ?? 0), download ? t : (cur?.double("dl_ts") ?? 0), done || (cur?.bool("done") ?? false), nextSeq()])
    }

    func ytDocs() -> [(id: String, doc: [String: Any], done: Bool)] {
        ((try? db.query("SELECT video_id, doc, done FROM sync_yt")) ?? []).map {
            ($0.string("video_id") ?? "", (try? JSONSerialization.jsonObject(with: Data(($0.string("doc") ?? "{}").utf8)) as? [String: Any]) ?? [:], $0.bool("done"))
        }
    }

    /// Try to claim a YouTube song for downloading here. False if another device holds a live claim.
    func claim(_ id: String, for seconds: Double = 20 * 60) -> Bool {
        if let cur = (try? db.query("SELECT replica, until FROM sync_claims WHERE video_id = ?", [id]))?.first,
           cur.string("replica") != replicaID, (cur.double("until") ?? 0) > Self.now() { return false }
        let t = Self.now()
        try? db.execute("INSERT INTO sync_claims VALUES (?,?,?,?,?) ON CONFLICT(video_id) DO UPDATE SET replica = excluded.replica, until = excluded.until, ts = excluded.ts, seq = excluded.seq",
                        [id, replicaID, t + seconds, t, nextSeq()])
        return true
    }

    func claimHolder(_ id: String) -> String? {
        guard let cur = (try? db.query("SELECT replica, until FROM sync_claims WHERE video_id = ?", [id]))?.first,
              (cur.double("until") ?? 0) > Self.now() else { return nil }
        return cur.string("replica")
    }

    func releaseClaim(_ id: String) {
        try? db.execute("UPDATE sync_claims SET until = 0, ts = ?, seq = ? WHERE video_id = ? AND replica = ?", [Self.now(), nextSeq(), id, replicaID])
    }

    // MARK: peers

    struct Peer: Identifiable, Hashable { var id: String; var name: String; var pulledSeq: Int; var pushedSeq: Int; var lastSync: Double? }

    func peers() -> [Peer] {
        ((try? db.query("SELECT * FROM sync_peers ORDER BY last_sync DESC")) ?? []).map {
            Peer(id: $0.string("replica") ?? "", name: $0.string("name") ?? "", pulledSeq: $0.int("pulled_seq") ?? 0,
                 pushedSeq: $0.int("pushed_seq") ?? 0, lastSync: $0.double("last_sync"))
        }
    }

    func peer(_ id: String) -> Peer? { peers().first { $0.id == id } }

    func notePeer(_ id: String, name: String, pulled: Int? = nil, pushed: Int? = nil) {
        guard id != replicaID else { return }
        try? db.execute("INSERT INTO sync_peers (replica, name, last_sync) VALUES (?,?,?) ON CONFLICT(replica) DO UPDATE SET name = excluded.name, last_sync = excluded.last_sync",
                        [id, name, Date().timeIntervalSince1970])
        if let pulled { try? db.execute("UPDATE sync_peers SET pulled_seq = ? WHERE replica = ?", [pulled, id]) }
        if let pushed { try? db.execute("UPDATE sync_peers SET pushed_seq = ? WHERE replica = ?", [pushed, id]) }
    }
}

/// Field groups of a replicated YouTube song.
enum YTDoc {
    static let infoFields = ["title", "uploader", "duration", "playlistIndex", "inPlaylist", "addedAt"]
    static let userFields = ["priority", "favorite", "matchOverride"]
    static let downloadFields = ["status", "relPath", "error", "attempts"]
}
