import Foundation
import SwiftUI
import UIKit

@MainActor
final class SyncManager: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var status = ""
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var bytesDone: Int64 = 0
    @Published private(set) var bytesTotal: Int64 = 0
    @Published private(set) var errors: [String] = []
    @AppStorage("lastSync") var lastSync: Double = 0
    @AppStorage("lastServerName") var lastServerName = ""

    private unowned let model: IOSModel
    private var task: Task<Void, Never>?
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(model: IOSModel) { self.model = model }

    func cancel() { task?.cancel() }

    // MARK: remote commands from the Mac (long-poll)

    private var listenTask: Task<Void, Never>?
    @Published private(set) var listeningTo: String?

    /// While the app runs, keep a request open to the Mac so it can say "sync now".
    func startListening(browser: ServerBrowser) {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            var base: URL?
            var server: DiscoveredServer?
            while !Task.isCancelled {
                guard let self else { return }
                if base == nil {
                    server = browser.servers.first { $0.name == self.lastServerName } ?? (browser.servers.count == 1 ? browser.servers.first : nil)
                    base = await self.baseURL(for: server)
                    self.listeningTo = base == nil ? nil : (server?.name ?? self.model.manualServer)
                    if base == nil { try? await Task.sleep(for: .seconds(5)); continue }
                }
                var comps = URLComponents(url: base!.appendingPathComponent("api/events"), resolvingAgainstBaseURL: false)!
                comps.queryItems = [URLQueryItem(name: "id", value: self.model.deviceID), URLQueryItem(name: "name", value: self.model.deviceName)]
                var req = URLRequest(url: comps.url!)
                req.timeoutInterval = 40
                do {
                    let (data, resp) = try await self.session.data(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    let events = try JSONDecoder().decode(DeviceEvents.self, from: data)
                    if events.commands.contains("sync"), !self.isSyncing { self.sync(server: server) }
                } catch {
                    if Task.isCancelled { break }
                    base = nil   // Mac gone or IP changed: rediscover
                    self.listeningTo = nil
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    func stopListening() { listenTask?.cancel(); listenTask = nil; listeningTo = nil }

    // MARK: server address

    func baseURL(for server: DiscoveredServer?) async -> URL? {
        if let server { return await ServerBrowser.resolve(server.endpoint) }
        let manual = model.manualServer.trimmingCharacters(in: .whitespaces)
        guard !manual.isEmpty else { return nil }
        let withPort = manual.contains(":") ? manual : "\(manual):\(MyMusicService.defaultPort)"
        return URL(string: manual.hasPrefix("http") ? manual : "http://\(withPort)")
    }

    static func fileURL(base: URL, relPath: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let enc = relPath.addingPercentEncoding(withAllowedCharacters: allowed) ?? relPath
        return URL(string: base.absoluteString + "/api/file?path=" + enc)!
    }

    // MARK: progress reporting to the Mac

    private var lastReport: Date = .distantPast

    /// Tells the Mac how the sync is going. Throttled to ~1/s except for phase changes.
    private func report(_ base: URL, _ phase: SyncProgress.Phase, _ message: String, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastReport) > 1 else { return }
        lastReport = Date()
        let p = SyncProgress(deviceID: model.deviceID, deviceName: model.deviceName, phase: phase, message: message,
                             done: done, total: total, bytesDone: bytesDone, bytesTotal: bytesTotal)
        var req = URLRequest(url: base.appendingPathComponent("api/progress"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(p)
        req.timeoutInterval = 10
        session.dataTask(with: req).resume()
    }

    // MARK: sync

    func sync(server: DiscoveredServer?) {
        guard !isSyncing else { return }
        task = Task { await run(server: server) }
    }

    private func run(server: DiscoveredServer?) async {
        isSyncing = true; errors = []; done = 0; total = 0; bytesDone = 0; bytesTotal = 0
        status = "Connecting…"
        UIApplication.shared.isIdleTimerDisabled = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "sync")
        defer {
            isSyncing = false
            UIApplication.shared.isIdleTimerDisabled = false
            UIApplication.shared.endBackgroundTask(bg)
        }
        guard let base = await baseURL(for: server) else { status = "Could not reach the Mac"; return }
        if let server { lastServerName = server.name }
        report(base, .starting, "Backing up stats…", force: true)

        // 1. back up stats to the Mac first, so nothing is lost even if the download part fails
        await uploadStats(base: base)

        // 2. manifest
        status = "Fetching library…"
        let manifest: LibraryManifest
        do {
            let (data, resp) = try await session.data(from: base.appendingPathComponent("api/library"))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { status = "Server error"; return }
            manifest = try JSONDecoder().decode(LibraryManifest.self, from: data)
        } catch {
            status = "Failed: \(error.localizedDescription)"
            report(base, .failed, status, force: true)
            return
        }

        var localRows = model.db.allTracks()
        let byKey = Dictionary(localRows.map { (WebLibrary.key($0.relPath), $0) }, uniquingKeysWith: { a, _ in a })
        let localPaths = Set(localRows.map(\.relPath))
        var adopted = 0
        for t in manifest.tracks where !localPaths.contains(t.relPath) {
            if let same = byKey[WebLibrary.key(t.relPath)], same.relPath != t.relPath {
                // same file (APFS ignores the accent encoding): use the Mac's spelling; a song you
                // downloaded from the web player stays yours (not removed if the Mac drops it)
                model.db.renamePath(same.relPath, to: t.relPath, origin: same.origin == .web ? .web : .server)
                adopted += 1
            }
        }
        if adopted > 0 { localRows = model.db.allTracks() }
        let local = Dictionary(uniqueKeysWithValues: localRows.map { ($0.relPath, $0) })
        let fm = FileManager.default
        let todo = manifest.tracks.filter { t in
            guard let l = local[t.relPath], fm.fileExists(atPath: model.url(for: l).path) else { return true }
            return l.size != t.size || abs(l.mtime - t.mtime) > 1
        }
        total = todo.count
        bytesTotal = todo.reduce(0) { $0 + $1.size }
        report(base, .downloading, todo.isEmpty ? "Up to date" : "\(todo.count) songs to copy", force: true)

        // 3. download one by one (sequential keeps Wi-Fi and the Mac disk happy)
        for t in todo {
            if Task.isCancelled { status = "Cancelled"; break }
            status = t.title
            do {
                try await download(t, base: base)
                var track = t
                track.origin = .server
                track.addedAt = local[t.relPath]?.addedAt ?? Date().timeIntervalSince1970
                try model.db.upsert([track])
            } catch {
                errors.append("\(t.relPath): \(error.localizedDescription)")
            }
            done += 1; bytesDone += t.size
            report(base, .downloading, t.title)
            if done % 20 == 0 { model.store.reload() }
        }

        // 4a. duplicates removed on the Mac / web player: move this phone's plays and favorite to
        //     the kept copy first, so they aren't lost with the deleted file
        for (old, keep) in manifest.merges ?? [:] { model.db.absorbStats(from: old, into: keep) }

        // 4. remove tracks that disappeared on the Mac (never touches local imports)
        var removed = 0
        if !Task.isCancelled && model.removeDeleted {
            let remote = Set(manifest.tracks.map(\.relPath))
            let gone = local.values.filter { $0.origin == .server && !remote.contains($0.relPath) }
            for t in gone { try? fm.removeItem(at: model.url(for: t)) }
            try? model.db.delete(gone.map(\.relPath))
            removed = gone.count
            pruneEmptyFolders()
        }

        applyPendingRestore()
        // Favorites: take the Mac's state where it changed more recently (the Mac already merged ours).
        let favChanges = model.db.applyRemoteFavorites(manifest.tracks.map { ($0.relPath, $0.favorite, $0.favoriteAt) })
        await model.store.reloadNow()
        model.player.refreshAll(model.store.track)
        if !Task.isCancelled {
            lastSync = Date().timeIntervalSince1970
            status = "Synced \(done) new/changed, removed \(removed)" + (favChanges > 0 ? ", \(favChanges) favorites updated" : "") + (errors.isEmpty ? "" : ", \(errors.count) errors")
            report(base, .done, status, force: true)
        } else {
            report(base, .cancelled, "Cancelled on iPhone", force: true)
        }
    }

    private func download(_ t: Track, base: URL) async throws {
        let (tmp, resp) = try await session.download(from: Self.fileURL(base: base, relPath: t.relPath))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let dest = model.url(for: t)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: t.mtime)], ofItemAtPath: dest.path)
    }

    private func pruneEmptyFolders() {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: IOSModel.musicDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let dirs = en.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for d in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            if let c = try? fm.contentsOfDirectory(atPath: d.path), c.filter({ $0 != ".DS_Store" }).isEmpty { try? fm.removeItem(at: d) }
        }
    }

    func uploadStats(base: URL) async {
        status = "Backing up stats…"
        let up = StatsUpload(deviceID: model.deviceID, deviceName: model.deviceName, entries: model.db.statEntries())
        var req = URLRequest(url: base.appendingPathComponent("api/stats"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(up)
        do { _ = try await session.data(for: req) } catch { errors.append("Stats backup failed: \(error.localizedDescription)") }
    }

    // MARK: restore

    static var pendingRestoreURL: URL { IOSModel.supportDir.appendingPathComponent("pending-restore.json") }

    func applyPendingRestore() {
        guard let data = try? Data(contentsOf: Self.pendingRestoreURL),
              let entries = try? JSONDecoder().decode([PlayStatEntry].self, from: data) else { return }
        try? model.db.mergeStats(entries)
        let present = Set(model.db.fileStamps().keys)
        if entries.allSatisfy({ present.contains($0.relPath) }) { try? FileManager.default.removeItem(at: Self.pendingRestoreURL) }
    }

    func fetchBackups(server: DiscoveredServer?) async -> (URL, [DeviceBackup])? {
        guard let base = await baseURL(for: server),
              let (data, _) = try? await session.data(from: base.appendingPathComponent("api/stats/devices")),
              let list = try? JSONDecoder().decode([DeviceBackup].self, from: data) else { return nil }
        return (base, list)
    }

    func restore(base: URL, backup: DeviceBackup, adoptIdentity: Bool) async -> String {
        var comps = URLComponents(url: base.appendingPathComponent("api/stats/device"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "id", value: backup.deviceID)]
        guard let (data, _) = try? await session.data(from: comps.url!),
              let entries = try? JSONDecoder().decode([PlayStatEntry].self, from: data) else { return "Restore failed" }
        do { try model.db.mergeStats(entries) } catch { return "Restore failed: \(error)" }
        // Tracks that aren't on the phone yet get their stats once the next sync downloads them.
        try? JSONEncoder().encode(entries).write(to: Self.pendingRestoreURL)
        applyPendingRestore()
        if adoptIdentity { model.deviceID = backup.deviceID; model.deviceName = backup.deviceName }
        model.store.reload()
        return "Restored stats for \(entries.count) tracks"
    }
}
