import Foundation
import SwiftUI
import UIKit

@MainActor
final class IOSModel: ObservableObject {
    let db: LibraryDB
    let store: LibraryStore
    let player: PlayerEngine
    let browser = ServerBrowser()
    lazy var sync = SyncManager(model: self)

    @AppStorage("deviceID") var deviceID = UUID().uuidString
    @AppStorage("deviceName") var deviceName = "iPhone"
    @AppStorage("manualServer") var manualServer = ""
    @AppStorage("removeDeletedOnSync") var removeDeleted = true
    @Published var isScanning = false
    @Published var lastMessage: String?

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// Everything synced or imported lives here, mirroring the Mac folder structure. Visible in the Files app.
    static var musicDir: URL { documents.appendingPathComponent("Music", isDirectory: true) }
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMusic", isDirectory: true)
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.musicDir, withIntermediateDirectories: true)
        db = try! LibraryDB(path: Self.supportDir.appendingPathComponent("library.sqlite").path,
                            extraMigrations: [LibraryDB.favoriteAtMigration])
        store = LibraryStore(db: db)
        player = PlayerEngine(urlFor: { IOSModel.musicDir.appendingFile($0.relPath) })
        player.onPlayCounted = { [weak self] t in self?.store.recordPlay(t) }
        player.onSkipped = { [weak self] t in self?.store.recordSkip(t) }
        browser.start()
        Task { await scanLocal() }
    }

    func url(for t: Track) -> URL { Self.musicDir.appendingFile(t.relPath) }

    /// Picks up files added through the Files app / importer and removes rows for files deleted there.
    func scanLocal() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let known = db.fileStamps()
        let result = await AudioScanner.scan(root: Self.musicDir, known: known, origin: .imported)
        let changed = result.changed.map { t -> Track in
            var t = t
            if let existing = db.track(relPath: t.relPath) { t.origin = existing.origin; t.addedAt = existing.addedAt }
            return t
        }
        try? db.upsert(changed)
        try? db.delete(result.removed)
        store.reload()
    }

    func toggleFavorite(_ t: Track) {
        let u = store.toggleFavorite(store.track(t.relPath) ?? t)
        player.refresh(u)
    }

    func deleteFromDevice(_ tracks: [Track]) {
        for t in tracks { try? FileManager.default.removeItem(at: url(for: t)) }
        try? db.delete(tracks.map(\.relPath))
        store.reload()
    }

    // MARK: importing

    /// Copies picked files/folders into Music/Imported, preserving the folder structure.
    func importItems(_ urls: [URL]) async {
        let dest = Self.musicDir.appendingPathComponent("Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var copied = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var target = dest.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    copied += mergeCopy(from: url, to: target); continue
                }
                target = dest.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(Int(Date().timeIntervalSince1970)).\(url.pathExtension)")
            }
            let coordinator = NSFileCoordinator()
            var err: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &err) { readURL in
                if (try? FileManager.default.copyItem(at: readURL, to: target)) != nil { copied += 1 }
            }
        }
        lastMessage = "Imported \(copied) item(s)"
        await scanLocal()
    }

    private func mergeCopy(from src: URL, to dst: URL) -> Int {
        var n = 0
        guard let en = FileManager.default.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        for case let f as URL in en {
            guard let rel = f.relativePath(from: src) else { continue }
            let t = dst.appendingPathComponent(rel)
            if (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
            } else if !FileManager.default.fileExists(atPath: t.path) {
                if (try? FileManager.default.copyItem(at: f, to: t)) != nil { n += 1 }
            }
        }
        return n
    }

    // MARK: backup

    func exportDatabase() -> URL? {
        let dir = Self.documents.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("library-\(Date().formatted(.iso8601.year().month().day())).json")
        let data = try? JSONEncoder().encode(StatsUpload(deviceID: deviceID, deviceName: deviceName, entries: db.statEntries()))
        guard let data, (try? data.write(to: dst)) != nil else { return nil }
        return dst
    }

    func storageUsed() -> Int64 { store.tracks.reduce(0) { $0 + $1.size } }
}
