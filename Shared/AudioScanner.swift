import AVFoundation
import Foundation

/// Walks a folder and reads tags with AVFoundation. Incremental: unchanged files (size + mtime) are skipped.
enum AudioScanner {
    struct Result {
        var changed: [Track]
        var removed: [String]
        var total: Int
    }

    struct FileEntry { let url: URL; let relPath: String; let size: Int64; let mtime: Double }

    static func listAudioFiles(root: URL) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [FileEntry] = []
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in en {
            guard MyMusicService.audioExtensions.contains(url.pathExtension.lowercased()),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let p = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard p.hasPrefix(rootPath + "/") else { continue }
            out.append(FileEntry(url: url, relPath: String(p.dropFirst(rootPath.count + 1)),
                                 size: Int64(v.fileSize ?? 0),
                                 mtime: (v.contentModificationDate ?? .distantPast).timeIntervalSince1970.rounded()))
        }
        return out
    }

    static func scan(root: URL, known: [String: (Int64, Double)], origin: TrackOrigin,
                     progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> Result {
        let files = listAudioFiles(root: root)
        let present = Set(files.map(\.relPath))
        let removed = known.keys.filter { !present.contains($0) }
        let todo = files.filter { f in
            guard let k = known[f.relPath] else { return true }
            return k.0 != f.size || abs(k.1 - f.mtime) > 1
        }
        var changed: [Track] = []
        changed.reserveCapacity(todo.count)
        var done = 0
        await withTaskGroup(of: Track.self) { group in
            var it = todo.makeIterator()
            for _ in 0..<8 { if let f = it.next() { group.addTask { await readTrack(f, origin: origin) } } }
            for await t in group {
                changed.append(t)
                done += 1
                if done % 25 == 0 || done == todo.count { progress(done, todo.count) }
                if let f = it.next() { group.addTask { await readTrack(f, origin: origin) } }
            }
        }
        return Result(changed: changed, removed: removed, total: files.count)
    }

    static func readTrack(_ f: FileEntry, origin: TrackOrigin) async -> Track {
        let fileName = f.url.deletingPathExtension().lastPathComponent
        let parent = f.url.deletingLastPathComponent().lastPathComponent
        let isYT = f.relPath.hasPrefix("yt/")
        var t = Track(relPath: f.relPath, size: f.size, mtime: f.mtime, title: fileName,
                      source: isYT ? .youtube : .local, origin: origin)
        let asset = AVURLAsset(url: f.url)
        if let d = try? await asset.load(.duration), d.isNumeric { t.duration = d.seconds }
        var items: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) { items += common }
        if let all = try? await asset.load(.metadata) { items += all }
        for item in items {
            let key = item.identifier
            let str = try? await item.load(.stringValue)
            switch key {
            case .commonIdentifierTitle?, .id3MetadataTitleDescription?, .iTunesMetadataSongName?:
                if let s = str, !s.isEmpty { t.title = s }
            case .commonIdentifierArtist?, .id3MetadataLeadPerformer?, .iTunesMetadataArtist?:
                if let s = str, !s.isEmpty, t.artist == nil { t.artist = s }
            case .commonIdentifierAlbumName?, .id3MetadataAlbumTitle?, .iTunesMetadataAlbum?:
                if let s = str, !s.isEmpty, t.album == nil { t.album = s }
            case .iTunesMetadataAlbumArtist?, .id3MetadataBand?:
                if let s = str, !s.isEmpty { t.albumArtist = s }
            case .commonIdentifierType?, .id3MetadataContentType?, .iTunesMetadataUserGenre?:
                if let s = str, !s.isEmpty { t.genre = s }
            case .id3MetadataTrackNumber?:
                if let s = str { t.trackNumber = Int(s.split(separator: "/").first ?? "") }
            case .iTunesMetadataTrackNumber?:
                if let data = try? await item.load(.dataValue), data.count >= 4 { t.trackNumber = Int(data[3]) }
            case .iTunesMetadataDiscNumber?:
                if let data = try? await item.load(.dataValue), data.count >= 4 { t.discNumber = Int(data[3]) }
            case .id3MetadataPartOfASet?:
                if let s = str { t.discNumber = Int(s.split(separator: "/").first ?? "") }
            case .commonIdentifierCreationDate?, .id3MetadataYear?, .id3MetadataRecordingTime?, .iTunesMetadataReleaseDate?:
                if let s = str, let y = Int(s.prefix(4)) { t.year = y }
            default: break
            }
        }
        if t.album == nil && !isYT && !parent.isEmpty { t.album = parent }
        if isYT, t.artist == nil, let dash = fileName.range(of: " - ") {
            t.artist = String(fileName[..<dash.lowerBound])
        }
        return t
    }

    static func artwork(url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            if let d = try? await item.load(.dataValue) { return d }
        }
        return nil
    }
}
