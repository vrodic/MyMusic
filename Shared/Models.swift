import Foundation

enum MyMusicService {
    static let bonjourType = "_mymusic._tcp"
    /// The Go web player (web/) on the music server.
    static let webBonjourType = "_mymusic-web._tcp"
    static let defaultPort: UInt16 = 47823
    static let apiVersion = 1
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "alac", "m4b", "mp4"]
}

enum TrackSource: String, Codable { case local, youtube }
/// Where a file on the device came from.
/// server = synced from the Mac · imported = added on the phone · web = downloaded from the web
/// player (kept until removed) · remote = not on the phone, streamed from the web player.
enum TrackOrigin: String, Codable { case server, imported, web, remote }

struct Track: Codable, Hashable, Identifiable {
    var relPath: String
    var size: Int64
    var mtime: Double
    var title: String
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?
    var duration: Double?
    var genre: String?
    var year: Int?
    var source: TrackSource = .local
    var origin: TrackOrigin = .server
    var addedAt: Double = Date().timeIntervalSince1970
    // stats
    var playCount: Int = 0
    var skipCount: Int = 0
    var lastPlayed: Double?
    var favorite: Bool = false
    var favoriteAt: Double?

    var id: String { relPath }
    /// Sort key for the ♥ column (clicking that header favorites the whole list instead of sorting).
    var favoriteSort: Int { favorite ? 1 : 0 }
    var displayArtist: String { artist ?? albumArtist ?? "Unknown Artist" }
    var displayAlbum: String { album ?? "Unknown Album" }
    var folder: String { (relPath as NSString).deletingLastPathComponent }
    var fileExtension: String { (relPath as NSString).pathExtension.lowercased() }
}

struct LibraryManifest: Codable {
    var serverName: String
    var apiVersion: Int
    var generatedAt: Double
    var tracks: [Track]
    /// Songs removed as duplicates: old path → the copy that was kept. Receivers move their own
    /// plays/favorites for the old path onto the kept copy before deleting it.
    var merges: [String: String]? = nil
}

struct ServerInfo: Codable {
    var name: String
    var apiVersion: Int
    var trackCount: Int
    var syncedTrackCount: Int
    var replica: String? = nil     // the Mac's sync id (so Macs can tell each other apart)
}

struct PlayStatEntry: Codable, Hashable {
    var relPath: String
    var playCount: Int
    var skipCount: Int
    var lastPlayed: Double?
    var favorite: Bool
    var favoriteAt: Double? = nil
}

struct StatsUpload: Codable {
    var deviceID: String
    var deviceName: String
    var entries: [PlayStatEntry]
    var userID: String? = nil
}

/// The iPhone's sync progress, posted to the Mac while it syncs.
struct SyncProgress: Codable, Hashable {
    enum Phase: String, Codable { case starting, downloading, removing, done, failed, cancelled }
    var deviceID: String
    var deviceName: String
    var phase: Phase
    var message: String
    var done: Int
    var total: Int
    var bytesDone: Int64
    var bytesTotal: Int64
    var updatedAt: Double = Date().timeIntervalSince1970

    var isActive: Bool { [.starting, .downloading, .removing].contains(phase) && Date().timeIntervalSince1970 - updatedAt < 90 }
    var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : (total > 0 ? Double(done) / Double(total) : 0) }
}

/// Reply to the iPhone's long-poll (GET /api/events).
struct DeviceEvents: Codable { var commands: [String] }

/// GET /api/info from the web player.
struct WebPlayerInfo: Codable, Hashable {
    var name: String
    var trackCount: Int
    var smbURL: String?
    var tokenRequired: Bool?
    var macBackupAt: String?
    var lastMacSync: String?
    var macName: String?
    var replica: String? = nil
}

struct DeviceBackup: Codable, Identifiable, Hashable {
    var deviceID: String
    var deviceName: String
    var lastSync: Double
    var entryCount: Int
    var id: String { deviceID }
}

extension Double {
    var durationString: String {
        guard isFinite, self > 0 else { return "--:--" }
        let s = Int(self.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension URL {
    /// relPath of `self` beneath `root`, or nil if outside it.
    /// Pure string work first (no file-system calls, which are slow on SMB); symlinks are
    /// only resolved as a fallback when the plain paths don't line up.
    func relativePath(from root: URL) -> String? {
        let r = root.standardizedFileURL.path, p = standardizedFileURL.path
        if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
        let rr = root.standardizedFileURL.resolvingSymlinksInPath().path
        let pr = standardizedFileURL.resolvingSymlinksInPath().path
        guard pr.hasPrefix(rr + "/") else { return nil }
        return String(pr.dropFirst(rr.count + 1))
    }

    /// `self` + relative path to a *file*, without the disk check `appendingPathComponent(_:)`
    /// does to see whether the result is a folder (one stat per call — slow on SMB, and it
    /// froze the UI when the player built the next song's URL).
    func appendingFile(_ relPath: String) -> URL {
        appending(path: relPath, directoryHint: .notDirectory)
    }

    /// Whether this file lives on a network volume (SMB/AFP/NFS). One stat; call off the main thread.
    var isOnNetworkVolume: Bool {
        (try? resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false
    }
}

/// Run blocking work (file system, especially SMB) off the main thread.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .utility) { work() }.value
}
