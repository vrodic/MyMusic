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
                                    syncedTrackCount: all.filter(syncFilter()).count))
        case ("GET", "/api/library"):
            let tracks = db.allTracks().filter(syncFilter())
            return .json(LibraryManifest(serverName: name, apiVersion: MyMusicService.apiVersion,
                                         generatedAt: Date().timeIntervalSince1970, tracks: tracks))
        case ("GET", "/api/file"), ("HEAD", "/api/file"):
            guard let root, let rel = req.query["path"], let t = db.track(relPath: rel), syncFilter()(t) else { return .notFound }
            // Only indexed paths get here; reject any ".." without touching the file system.
            guard !rel.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return .notFound }
            return .file(root.appendingPathComponent(rel))
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
    @Published var selection: FolderSelection { didSet { saveSelection(); pushBackend() } }
    @Published var syncFavorites: Bool { didSet { UserDefaults.standard.set(syncFavorites, forKey: "syncFavorites"); pushBackend() } }
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
            URL(fileURLWithPath: UserDefaults.standard.string(forKey: "musicRoot") ?? "/", isDirectory: true).appendingPathComponent(t.relPath)
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
        player.onPlayCounted = { [weak self] t in self?.store.recordPlay(t) }
        player.onSkipped = { [weak self] t in self?.store.recordSkip(t) }
        devices = db.deviceBackups()

        startServer()
        checkRemote()
        yt.start()
        web = WebPeer(model: self)
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
        UserDefaults.standard.set(try? JSONEncoder().encode(selection), forKey: "syncSelection")
    }

    func url(for t: Track) -> URL { (musicRoot ?? URL(fileURLWithPath: "/")).appendingPathComponent(t.relPath) }

    // MARK: root & scanning

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Music Root"
        panel.message = "Pick the root folder of your music collection. YouTube downloads go to <root>/yt."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        musicRoot = url
        UserDefaults.standard.set(url.path, forKey: "musicRoot")
        pushBackend()
        checkRemote()
        Task {
            await rescan()
            if selection.paths.isEmpty {
                selection = FolderSelection(paths: Set(store.folderRoot.subfolders.map(\.path)))
            }
        }
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
        let url = root.appendingPathComponent(rel)
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
                let url = root.appendingPathComponent(rel)
                do {
                    do {
                        try fm.trashItem(at: url, resultingItemURL: nil)
                    } catch {
                        let dest = root.appendingPathComponent(".duplicates").appendingPathComponent(rel)
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

    /// Called after the web player's stats were stored (favorites may have changed).
    func afterWebPull() {
        Task { await store.reloadNow(); player.refreshAll(store.track) }
        devices = db.deviceBackups()
    }

    func toggleFavorite(_ t: Track) {
        defer { web?.syncSoon() }
        let u = store.toggleFavorite(t)
        player.refresh(u)
    }
}
