import AppKit
import Foundation
import SwiftUI

/// Thread-safe state the HTTP server reads from its own queue.
final class ServerBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var _root: URL?
    private var _selection = FolderSelection()
    private var _syncFavorites = false
    let db: LibraryDB
    var name: String
    var onStatsUploaded: (@Sendable () -> Void)?
    var onPresenceChanged: (@Sendable () -> Void)?
    var onProgress: (@Sendable (SyncProgress) -> Void)?
    var onSyncApplied: (@Sendable (SyncStore.ApplyResult) -> Void)?

    // MARK: device presence + commands (long-poll)
    struct Presence { var name: String; var lastSeen: Date; var waiting: Int }
    private let presenceLock = NSCondition()
    private var presence: [String: Presence] = [:]
    private var pending: [String: [String]] = [:]

    /// Devices with the app open right now (a long-poll is waiting, or one ended moments ago).
    var onlineDevices: [(id: String, name: String)] {
        presenceLock.lock(); defer { presenceLock.unlock() }
        return presence.filter { $0.value.waiting > 0 || Date().timeIntervalSince($0.value.lastSeen) < 40 }
            .map { ($0.key, $0.value.name) }.sorted { $0.name < $1.name }
    }

    func send(_ command: String, to deviceID: String) {
        presenceLock.lock()
        pending[deviceID, default: []].append(command)
        presenceLock.broadcast()
        presenceLock.unlock()
    }

    /// Blocks (on the server's concurrent queue) for up to 25 s until a command arrives for this device.
    private func waitForCommands(device id: String, name: String) -> [String] {
        presenceLock.lock()
        presence[id, default: Presence(name: name, lastSeen: Date(), waiting: 0)].waiting += 1
        presence[id]?.name = name
        presence[id]?.lastSeen = Date()
        presenceLock.unlock()
        onPresenceChanged?()

        presenceLock.lock()
        let deadline = Date().addingTimeInterval(25)
        while (pending[id] ?? []).isEmpty && presenceLock.wait(until: deadline) {}
        let cmds = pending.removeValue(forKey: id) ?? []
        presence[id]?.waiting -= 1
        presence[id]?.lastSeen = Date()
        presenceLock.unlock()
        onPresenceChanged?()
        return cmds
    }

    init(db: LibraryDB, name: String) { self.db = db; self.name = name }

    func update(root: URL?, selection: FolderSelection, syncFavorites: Bool) {
        lock.withLock { _root = root; _selection = selection; _syncFavorites = syncFavorites }
    }
    private var snapshot: (URL?, FolderSelection, Bool) { lock.withLock { (_root, _selection, _syncFavorites) } }

    /// What an iPhone of `user` gets: that user's ticked folders, plus (if they chose so) their
    /// favorites, plus the songs in their playlists.
    func syncFilter(user: String) -> (Track) -> Bool {
        let st = db.sync
        let sel = st.setting(user: user, key: "syncSelection").flatMap { try? JSONDecoder().decode(FolderSelection.self, from: Data($0.utf8)) } ?? FolderSelection()
        let favsOn = st.setting(user: user, key: "syncFavorites") == "1"
        let playlistsOn = st.setting(user: user, key: "syncPlaylists") != "0"
        let alias = st.aliases()
        let favs = favsOn ? Set(st.favorites(user: user).filter { $0.value.0 }.keys) : []
        let inPlaylists = playlistsOn ? Set(st.playlists(user: user).flatMap(\.items)) : []
        return { t in
            if sel.contains(relPath: t.relPath) { return true }
            let k0 = SyncStore.key(t.relPath), k = alias[k0] ?? k0
            return favs.contains(k) || inPlaylists.contains(k)
        }
    }

    /// A track goes to devices if its folder is ticked, or it's a favorite (Mac or any device) and "sync favorites" is on.
    func syncFilter() -> (Track) -> Bool {
        let (_, selection, favs) = snapshot
        // iPhone favorites are merged into the Mac's own favorites on upload, so t.favorite covers both.
        return { t in selection.contains(relPath: t.relPath) || (favs && t.favorite) }
    }

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        let (root, _, _) = snapshot
        switch (req.method, req.path) {
        case ("GET", "/api/info"):
            let all = db.allTracks()
            return .json(ServerInfo(name: name, apiVersion: MyMusicService.apiVersion, trackCount: all.count,
                                    syncedTrackCount: all.filter(syncFilter()).count, replica: db.sync.replicaID))
        case ("GET", "/api/library"):
            let filter = req.query["user"].map { syncFilter(user: $0) } ?? syncFilter()
            let tracks = db.allTracks().filter(filter)
            return .json(LibraryManifest(serverName: name, apiVersion: MyMusicService.apiVersion,
                                         generatedAt: Date().timeIntervalSince1970, tracks: tracks, merges: db.recentMerges()))
        case ("GET", "/api/file"), ("HEAD", "/api/file"):
            // any song in the library (other users' playlists and streaming need more than this Mac's selection)
            guard let root, let rel = req.query["path"], db.track(relPath: rel) != nil else { return .notFound }
            // Only indexed paths get here; reject any ".." without touching the file system.
            guard !rel.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return .notFound }
            return .file(root.appendingFile(rel))
        case ("POST", "/api/stats"):
            guard let up = try? JSONDecoder().decode(StatsUpload.self, from: req.body) else { return .badRequest("bad json") }
            do { try db.storeDeviceStats(up) } catch { return .data(status: 500, contentType: "text/plain", body: Data("\(error)".utf8)) }
            onStatsUploaded?()
            return .json(["ok": true])
        case ("POST", "/api/progress"):
            guard var p = try? JSONDecoder().decode(SyncProgress.self, from: req.body) else { return .badRequest("bad json") }
            p.updatedAt = Date().timeIntervalSince1970   // Mac clock, so staleness checks work
            onProgress?(p)
            return .json(["ok": true])
        case ("GET", "/api/events"):
            guard let id = req.query["id"] else { return .badRequest("id required") }
            return .json(DeviceEvents(commands: waitForCommands(device: id, name: req.query["name"] ?? "iPhone")))
        // MARK: peer sync (Macs, iPhones, the web player)
        case ("GET", "/api/v2/changes"):
            let since = Int(req.query["since"] ?? "0") ?? 0
            if let from = req.query["from"] { db.sync.notePeer(from, name: req.query["name"] ?? "device") }
            return .json(db.sync.changes(since: since, includeYT: req.query["yt"] == "1", name: name))
        case ("POST", "/api/v2/changes"):
            guard let cs = try? JSONDecoder().decode(SyncStore.ChangeSet.self, from: req.body) else { return .badRequest("bad json") }
            let res = db.sync.apply(cs)
            db.sync.notePeer(cs.replica, name: cs.name ?? "device")
            if res.changed > 0 { onSyncApplied?(res) }
            return .json(["seq": db.sync.currentSeq, "changed": res.changed])
        case ("GET", "/api/stats/devices"):
            // iPhones restore from these; the web player isn't an iPhone backup
            return .json(db.deviceBackups().filter { !$0.deviceID.hasPrefix("web-") })
        case ("GET", "/api/stats/device"):
            guard let id = req.query["id"] else { return .badRequest("id required") }
            return .json(db.deviceStats(id))
        default:
            return .notFound
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var musicRoot: URL?
    /// Music root is on SMB/AFP/NFS: avoid optional file-system calls.
    @Published private(set) var rootIsRemote = false
    // Sync choices belong to the current user (and replicate to the other Macs).
    @Published var selection: FolderSelection { didSet { if !loadingUser { saveSelection() }; pushBackend() } }
    @Published var syncFavorites: Bool { didSet { if !loadingUser { saveUserSetting("syncFavorites", syncFavorites ? "1" : "0") }; pushBackend() } }
    @Published var syncPlaylists: Bool = true { didSet { if !loadingUser { saveUserSetting("syncPlaylists", syncPlaylists ? "1" : "0") } } }
    @Published private(set) var users: [SyncStore.User] = []
    @Published private(set) var currentUser = SyncStore.defaultUserID
    @Published private(set) var playlists: [SyncStore.Playlist] = []
    private var loadingUser = false
    private(set) var peers: PeerSync!
    /// For background work that needs the name without hopping to the main thread.
    nonisolated(unsafe) var serverNameSnapshot = ""
    @Published private(set) var scanStatus = ""
    @Published private(set) var isScanning = false
    @Published private(set) var serverStatus = "Stopped"
    @Published private(set) var devices: [DeviceBackup] = []
    @Published private(set) var online: [(id: String, name: String)] = []
    @Published private(set) var syncRequested: Set<String> = []
    /// Latest progress report per device (kept after it finishes, to show the result).
    @Published private(set) var syncProgress: [String: SyncProgress] = [:]
    private var activeSyncIDs: Set<String> = []
    var activeSyncs: [SyncProgress] { syncProgress.values.filter(\.isActive).sorted { $0.deviceName < $1.deviceName } }
    @AppStorage("server.name") var serverName = Host.current().localizedName ?? "My Mac"

    let db: LibraryDB
    let store: LibraryStore
    let player: PlayerEngine
    let backend: ServerBackend
    let server: HTTPServer
    private(set) var yt: YouTubeManager!
    private(set) var web: WebPeer!

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMusic", isDirectory: true)
    }

    init() {
        let db = try! LibraryDB(path: Self.supportDir.appendingPathComponent("library.sqlite").path, extraMigrations: LibraryDB.macMigrations)
        db.currentUser = UserDefaults.standard.string(forKey: "currentUser") ?? SyncStore.defaultUserID
        if !db.sync.flag("legacyMigrated") {
            db.migrateLegacyStats(otherDevices: db.legacyDeviceCells(), aliases: db.legacyMerges())
            // this Mac's sync choices become the default user's (they follow the user now)
            if let sel = UserDefaults.standard.data(forKey: "syncSelection") {
                db.sync.setSetting(user: SyncStore.defaultUserID, key: "syncSelection", value: String(decoding: sel, as: UTF8.self))
            }
            db.sync.setSetting(user: SyncStore.defaultUserID, key: "syncFavorites", value: UserDefaults.standard.bool(forKey: "syncFavorites") ? "1" : "0")
        }
        self.db = db
        store = LibraryStore(db: db)
        let rootPath = UserDefaults.standard.string(forKey: "musicRoot")
        let root = rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        musicRoot = root
        selection = (UserDefaults.standard.data(forKey: "syncSelection")).flatMap { try? JSONDecoder().decode(FolderSelection.self, from: $0) } ?? FolderSelection()
        syncFavorites = UserDefaults.standard.bool(forKey: "syncFavorites")
        backend = ServerBackend(db: db, name: UserDefaults.standard.string(forKey: "server.name") ?? Host.current().localizedName ?? "My Mac")
        server = HTTPServer(handler: { [backend] in backend.handle($0) })
        player = PlayerEngine(urlFor: { t in
            URL(fileURLWithPath: UserDefaults.standard.string(forKey: "musicRoot") ?? "/", isDirectory: true).appendingFile(t.relPath)
        })
        yt = YouTubeManager(db: db, root: { [weak self] in self?.musicRoot }, rootIsRemote: { [weak self] in self?.rootIsRemote ?? false }, onDownloaded: { [weak self] rel in await self?.indexFile(rel) })

        pushBackend()
        backend.onStatsUploaded = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.devices = self.db.deviceBackups()
                self.store.reload()   // favorites from the iPhone were merged in
                self.web?.syncSoon()   // pass iPhone plays/favorites on to the web player
                // a stats upload is the first step of a sync, so the request was picked up
                self.syncRequested.removeAll()
            }
        }
        backend.onPresenceChanged = { [weak self] in Task { @MainActor in self?.refreshOnline() } }
        backend.onProgress = { [weak self] p in
            Task { @MainActor in
                self?.syncRequested.remove(p.deviceID)
                self?.syncProgress[p.deviceID] = p
            }
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshOnline()
                // redraw only when a sync just went stale (not every 10 s forever)
                guard let self else { return }
                let active = Set(self.syncProgress.filter { $0.value.isActive }.keys)
                if active != self.activeSyncIDs { self.activeSyncIDs = active; self.objectWillChange.send() }
            }
        }
        server.onStateChange = { [weak self] s in Task { @MainActor in self?.serverStatus = s } }
        player.onPlayCounted = { [weak self] t in self?.store.recordPlay(t); self?.peers?.kick(after: 20) }
        player.onSkipped = { [weak self] t in self?.store.recordSkip(t) }
        devices = db.deviceBackups()

        yt.libraryProvider = { [weak self] in self?.store.tracks ?? [] }
        yt.onSharedChange = { [weak self] in self?.peers?.kick(after: 2) }
        if !db.sync.flag("ytPublished") {
            // first run with peer sync: share the whole queue once
            db.publishYT(db.ytItems().map(\.videoID), user: true, download: true, info: true)
            db.sync.setFlag("ytPublished")
        }
        startServer()
        checkRemote()
        yt.start()
        web = WebPeer(model: self)
        currentUser = db.currentUser
        serverNameSnapshot = serverName
        if !db.sync.flag("defaultUserNamed") {
            // give the default user a real name once, so every device shows the same one
            let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
            if (try? db.db.query("SELECT 1 FROM sync_users WHERE user_id = ?", [SyncStore.defaultUserID]))?.isEmpty ?? true {
                db.sync.saveUser(id: SyncStore.defaultUserID, name: first)
            }
            db.sync.setFlag("defaultUserNamed")
        }
        loadUser()
        peers = PeerSync(model: self)
        backend.onSyncApplied = { [weak self] res in Task { @MainActor in self?.afterSyncApplied(res) } }
        if musicRoot != nil { Task { await rescan() } }
    }

    private func refreshOnline() {
        let now = backend.onlineDevices
        if now.map(\.id) != online.map(\.id) || now.map(\.name) != online.map(\.name) { online = now }
    }

    /// Ask an iPhone that has MyMusic open to sync now.
    func requestSync(_ deviceID: String) {
        syncRequested.insert(deviceID)
        backend.send("sync", to: deviceID)
        // if the phone never picks it up (app got suspended), stop showing "waiting"
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.syncRequested.remove(deviceID) }
    }

    func startServer() {
        backend.name = serverName
        server.start(name: serverName)
    }

    private func checkRemote() {
        guard let root = musicRoot else { rootIsRemote = false; return }
        Task { rootIsRemote = await offMain { root.isOnNetworkVolume } }
    }

    private func pushBackend() { backend.update(root: musicRoot, selection: selection, syncFavorites: syncFavorites) }

    /// Is this song or folder ticked for iPhone sync (directly or through a folder above it)?
    func isSynced(_ path: String) -> Bool { selection.contains(relPath: path) }

    /// Tick or untick songs/folders for iPhone sync, as the checkboxes in Sync & Devices do.
    func setSynced(_ paths: [String], _ on: Bool) {
        var sel = selection
        for p in paths where sel.contains(relPath: p) != on { sel.toggle(path: p, root: store.folderRoot) }
        selection = sel
    }

    /// Tracks that will go to devices (same rule the server uses).
    var syncedTracks: [Track] { store.tracks.filter(backend.syncFilter()) }

    private func saveSelection() {
        let data = (try? JSONEncoder().encode(selection)) ?? Data()
        UserDefaults.standard.set(data, forKey: "syncSelection")
        saveUserSetting("syncSelection", String(decoding: data, as: UTF8.self))
    }

    private func saveUserSetting(_ key: String, _ value: String) {
        db.sync.setSetting(user: currentUser, key: key, value: value)
        peers?.kick()
    }

    // MARK: users

    /// Load the current user's sync choices and playlists.
    func loadUser() {
        loadingUser = true
        defer { loadingUser = false }
        let st = db.sync
        users = st.users()
        if let json = st.setting(user: currentUser, key: "syncSelection"), let sel = try? JSONDecoder().decode(FolderSelection.self, from: Data(json.utf8)) {
            selection = sel
        } else if currentUser != SyncStore.defaultUserID {
            selection = FolderSelection()
        }
        if let v = st.setting(user: currentUser, key: "syncFavorites") { syncFavorites = v == "1" }
        syncPlaylists = st.setting(user: currentUser, key: "syncPlaylists") != "0"
        playlists = st.playlists(user: currentUser)
    }

    func switchUser(_ id: String) {
        guard id != currentUser else { return }
        currentUser = id
        db.currentUser = id
        UserDefaults.standard.set(id, forKey: "currentUser")
        loadUser()
        Task {
            await offMain { [db] in db.refreshCache() }
            await store.reloadNow()
            player.refreshAll(store.track)
        }
    }

    @discardableResult
    func addUser(_ name: String) -> String {
        let id = UUID().uuidString
        db.sync.saveUser(id: id, name: name)
        users = db.sync.users()
        peers?.kick()
        return id
    }

    func renameUser(_ id: String, _ name: String) {
        db.sync.saveUser(id: id, name: name)
        users = db.sync.users()
        peers?.kick()
    }

    func deleteUser(_ id: String) {
        guard id != SyncStore.defaultUserID else { return }
        let name = users.first { $0.id == id }?.name ?? ""
        db.sync.saveUser(id: id, name: name, deleted: true)
        if currentUser == id { switchUser(SyncStore.defaultUserID) }
        users = db.sync.users()
        peers?.kick()
    }

    // MARK: playlists (per user)

    @discardableResult
    func createPlaylist(_ name: String, with tracks: [Track] = []) -> String {
        let p = SyncStore.Playlist(id: UUID().uuidString, userID: currentUser, name: name, items: tracks.map(\.relPath))
        db.sync.savePlaylist(p)
        playlistsChanged()
        return p.id
    }

    func addToPlaylist(_ id: String, _ tracks: [Track]) {
        guard var p = playlists.first(where: { $0.id == id }) else { return }
        let have = Set(p.items)
        p.items += tracks.map { SyncStore.key($0.relPath) }.filter { !have.contains($0) }
        db.sync.savePlaylist(p)
        playlistsChanged()
    }

    func removeFromPlaylist(_ id: String, _ tracks: [Track]) {
        guard var p = playlists.first(where: { $0.id == id }) else { return }
        let drop = Set(tracks.map { SyncStore.key($0.relPath) })
        p.items.removeAll { drop.contains($0) }
        db.sync.savePlaylist(p)
        playlistsChanged()
    }

    func movePlaylistItem(_ id: String, _ track: Track, toTop: Bool) {
        guard var p = playlists.first(where: { $0.id == id }) else { return }
        let k = SyncStore.key(track.relPath)
        guard let i = p.items.firstIndex(of: k) else { return }
        p.items.remove(at: i)
        if toTop { p.items.insert(k, at: 0) } else { p.items.append(k) }
        db.sync.savePlaylist(p)
        playlistsChanged()
    }

    func renamePlaylist(_ id: String, _ name: String) {
        guard var p = playlists.first(where: { $0.id == id }) else { return }
        p.name = name
        db.sync.savePlaylist(p)
        playlistsChanged()
    }

    func deletePlaylist(_ id: String) {
        guard var p = playlists.first(where: { $0.id == id }) else { return }
        p.deleted = true
        db.sync.savePlaylist(p)
        playlistsChanged()
    }

    /// The songs of a playlist, in order (songs not in this library are skipped).
    func tracks(in p: SyncStore.Playlist) -> [Track] {
        let byKey = Dictionary(store.tracks.map { (SyncStore.key($0.relPath), $0) }, uniquingKeysWith: { a, _ in a })
        return p.items.compactMap { byKey[$0] }
    }

    private func playlistsChanged() {
        playlists = db.sync.playlists(user: currentUser)
        peers?.kick()
    }

    /// Changes arrived from another device: refresh what this Mac shows.
    func afterSyncApplied(_ res: SyncStore.ApplyResult) {
        loadUser()
        yt.applySync(res.ytChanged)
        Task {
            await offMain { [db] in db.refreshCache() }
            await store.reloadNow()
            player.refreshAll(store.track)
        }
    }

    func url(for t: Track) -> URL { (musicRoot ?? URL(fileURLWithPath: "/", isDirectory: true)).appendingFile(t.relPath) }

    // MARK: root & scanning

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Music Root"
        panel.message = "Pick the root folder of your music collection. YouTube downloads go to <root>/yt."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await setRoot(url) }
    }

    /// Use `url` as the music root: save it, point the server at it, and scan.
    func setRoot(_ url: URL) async {
        musicRoot = url
        UserDefaults.standard.set(url.path, forKey: "musicRoot")
        pushBackend()
        checkRemote()
        await rescan()
        if selection.paths.isEmpty && !syncFavorites {
            selection = FolderSelection(paths: Set(store.folderRoot.subfolders.map(\.path)))
        }
    }

    /// Replace this Mac's library with a backup (first-time setup from the web player): songs,
    /// play counts, iPhone backups, favorites, the YouTube queue and sync settings.
    func restoreLibrary(from path: String) throws {
        try db.restore(from: path)
        db.restoreSettingsFromBackup()
        selection = (UserDefaults.standard.data(forKey: "syncSelection")).flatMap { try? JSONDecoder().decode(FolderSelection.self, from: $0) } ?? FolderSelection()
        syncFavorites = UserDefaults.standard.bool(forKey: "syncFavorites")
        devices = db.deviceBackups()
        db.refreshCache()
        loadUser()
        yt.reload()
        store.reload()
    }

    func rescan() async {
        guard let root = musicRoot, !isScanning else { return }
        isScanning = true; scanStatus = "Scanning…"
        let known = db.fileStamps()
        let result = await AudioScanner.scan(root: root, known: known, origin: .server) { done, total in
            Task { @MainActor [weak self] in self?.scanStatus = "Reading tags \(done)/\(total)" }
        }
        try? db.upsert(result.changed)
        try? db.delete(result.removed)
        await store.reloadNow()
        isScanning = false
        Task { await yt.checkLibraryMatches() }
        web?.syncSoon()
        scanStatus = "\(result.total) tracks · \(result.changed.count) updated · \(result.removed.count) removed"
    }

    /// Favorite liked YouTube songs. Downloaded ones favorite their track; the rest remember it and
    /// jump to Maximum priority so they arrive soon (and reach the iPhone with "sync favorites").
    func setYTFavorite(_ items: [YTItem], _ fav: Bool) {
        db.setYTFavorite(items.map(\.videoID), fav)
        let tracks = items.compactMap { $0.relPath.flatMap(store.track) }
        store.setFavorite(tracks, fav)
        tracks.compactMap { store.track($0.relPath) }.forEach(player.refresh)
        if fav {
            let waiting = items.filter { $0.status != .done && $0.priority != .maximum }
            if !waiting.isEmpty { yt.setPriority(Set(waiting.map(\.videoID)), .maximum) }
        }
        yt.reload()
    }

    func isFavorite(_ item: YTItem) -> Bool {
        item.relPath.flatMap(store.track)?.favorite ?? item.favorite
    }

    func indexFile(_ rel: String) async {
        guard let root = musicRoot else { return }
        let url = root.appendingFile(rel)
        let stamp = await offMain { () -> (Int64, Double)? in
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (Int64(v.fileSize ?? 0), (v.contentModificationDate ?? Date()).timeIntervalSince1970.rounded())
        }
        guard let stamp else { return }
        let t = await AudioScanner.readTrack(.init(url: url, relPath: rel, size: stamp.0, mtime: stamp.1), origin: .server)
        try? db.upsert([t])
        if let item = db.ytItems().first(where: { $0.relPath == rel }), item.favorite { db.setFavorite(rel, true) }
        store.reload()
        web?.syncSoon(after: 60)
    }

    /// Moves every non-kept copy to the Trash (or <root>/.duplicates when the volume has no Trash), merging stats into the keeper.
    func removeDuplicates(_ groups: [DuplicateGroup]) async -> (removed: Int, failed: [String]) {
        guard let root = musicRoot else { return (0, ["No music root"]) }
        // File moves happen off the main thread (each one is several SMB round trips).
        let jobs = groups.flatMap { g in g.tracks.filter { $0.relPath != g.keep }.map { (track: $0, keep: g.keep) } }
        let paths = jobs.map(\.track.relPath)
        let outcome = await offMain { () -> [String: String?] in   // relPath -> error (nil = moved)
            let fm = FileManager.default
            var out: [String: String?] = [:]
            for rel in paths {
                let url = root.appendingFile(rel)
                do {
                    do {
                        try fm.trashItem(at: url, resultingItemURL: nil)
                    } catch {
                        let dest = root.appendingPathComponent(".duplicates", isDirectory: true).appendingFile(rel)
                        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                        try fm.moveItem(at: url, to: dest)
                    }
                    out[rel] = .some(nil)
                } catch {
                    out[rel] = .some(error.localizedDescription)
                }
            }
            return out
        }
        var removed = 0
        var failed: [String] = []
        for job in jobs {
            if let err = outcome[job.track.relPath] ?? "not attempted" {
                failed.append("\(job.track.relPath): \(err)")
                continue
            }
            db.mergeStats(from: job.track, into: job.keep)
            try? db.delete([job.track.relPath])
            if player.current?.relPath == job.track.relPath { player.stop() }
            removed += 1
        }
        store.reload()
        yt.reload()
        return (removed, failed)
    }

    func revealInFinder(_ t: Track) { NSWorkspace.shared.activateFileViewerSelecting([url(for: t)]) }

    /// Duplicates removed on the web player: fold each into its kept copy here (the file is already
    /// gone from the share), so this Mac, the iPhones and the next push all agree.
    func applyWebRemovals(_ list: [WebRemoval]) {
        for r in list {
            if let t = db.track(relPath: r.path) {
                db.mergeStats(from: t, into: r.keep)
            } else {
                // already dropped (e.g. by a rescan): still move device counts and remember the merge
                db.moveDeviceStats(from: r.path, to: r.keep)
                db.recordMerge(old: r.path, keep: r.keep)
            }
            try? db.delete([r.path])
            if player.current?.relPath == r.path { player.stop() }
        }
        if !list.isEmpty { store.reload(); yt.reload() }
    }

    /// Called after the web player's stats were stored (favorites may have changed).
    func afterWebPull() {
        Task { await store.reloadNow(); player.refreshAll(store.track) }
        devices = db.deviceBackups()
    }

    func toggleFavorite(_ t: Track) {
        defer { peers?.kick() }
        defer { web?.syncSoon() }
        let u = store.toggleFavorite(t)
        player.refresh(u)
    }
}
