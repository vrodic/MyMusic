import CryptoKit
import Foundation

struct DuplicateGroup: Identifiable, Hashable {
    enum Kind: String { case identical = "Identical files", sameSong = "Same song" }
    let id: String
    let kind: Kind
    let tracks: [Track]          // sorted best-first
    var keep: String             // relPath of the copy to keep
}

/// Finds byte-identical files and the same song stored more than once (other format, YouTube copy, …).
enum DuplicateFinder {
    static func find(tracks: [Track], root: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) async -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        var grouped = Set<String>()

        // 1. Identical: same size, then same fingerprint (head + tail + size).
        progress("Comparing file contents…")
        let bySize = Dictionary(grouping: tracks, by: \.size).values.filter { $0.count > 1 }
        for candidates in bySize {
            var byHash: [String: [Track]] = [:]
            for t in candidates {
                if let h = fingerprint(root.appendingFile(t.relPath), size: t.size) { byHash[h, default: []].append(t) }
            }
            for (h, ts) in byHash where ts.count > 1 {
                let sorted = ts.sorted(by: better)
                groups.append(DuplicateGroup(id: "id-" + h, kind: .identical, tracks: sorted, keep: sorted[0].relPath))
                ts.forEach { grouped.insert($0.relPath) }
            }
        }

        // 2. Same song: normalized artist + title, durations within 4 s.
        progress("Matching titles…")
        var byKey: [String: [Track]] = [:]
        for t in tracks where !grouped.contains(t.relPath) {
            for k in keys(for: t) { byKey[k, default: []].append(t) }
        }
        var seen = Set<String>()
        for (k, ts) in byKey.sorted(by: { $0.key < $1.key }) where ts.count > 1 {
            // split into clusters of similar duration
            var clusters: [[Track]] = []
            for t in ts.sorted(by: { ($0.duration ?? 0) < ($1.duration ?? 0) }) where !seen.contains(t.relPath) {
                if let last = clusters.last?.last, abs((last.duration ?? 0) - (t.duration ?? 0)) <= 4 || last.duration == nil || t.duration == nil {
                    clusters[clusters.count - 1].append(t)
                } else {
                    clusters.append([t])
                }
            }
            for c in clusters where c.count > 1 && Set(c.map(\.relPath)).count > 1 {
                let sorted = Array(Set(c)).sorted(by: better)
                sorted.forEach { seen.insert($0.relPath) }
                groups.append(DuplicateGroup(id: "song-\(k)-\(sorted[0].relPath)", kind: .sameSong, tracks: sorted, keep: sorted[0].relPath))
            }
        }
        return groups.sorted { ($0.kind == .identical ? 0 : 1, $0.tracks[0].title) < ($1.kind == .identical ? 0 : 1, $1.tracks[0].title) }
    }

    /// Size + SHA-256 of the first and last 256 KB. Cheap even on network volumes.
    static func fingerprint(_ url: URL, size: Int64) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let chunk = 256 * 1024
        var hasher = SHA256()
        withUnsafeBytes(of: size) { hasher.update(bufferPointer: $0) }
        guard let head = try? fh.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if size > Int64(chunk * 2) {
            try? fh.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let tail = try? fh.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bracketed text that doesn't change which recording it is.
    static let noiseWords = ["official", "video", "audio", "lyric", "visuali", "hd", "hq", "4k", "remaster", "explicit", "clean", "mv", "full song", "free download"]

    static func normalize(_ input: String) -> String {
        var s = input.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        s = s.replacingOccurrences(of: "_", with: " ")
        // Drop bracketed noise like (Official Video) or [HD], but keep (Radio Edit), (Time Lock Rmx), (Live) …
        let bracket = try! NSRegularExpression(pattern: #"[\(\[\{]([^\)\]\}]*)[\)\]\}]"#)
        for m in bracket.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s), let inner = Range(m.range(at: 1), in: s) else { continue }
            let content = String(s[inner])
            s.replaceSubrange(r, with: noiseWords.contains(where: content.contains) ? " " : " \(content) ")
        }
        for noise in ["official music video", "official video", "official audio", "lyric video", "+ lyrics", "hq audio"] {
            s = s.replacingOccurrences(of: noise, with: " ")
        }
        s = s.replacingOccurrences(of: #"\b(feat|ft|featuring)\.?\s.*$"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*\d{1,3}[\s\.\-]+"#, with: "", options: .regularExpression)   // leading track numbers
        s = s.replacingOccurrences(of: "&", with: "and")
        return s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func keys(for t: Track) -> [String] {
        let title = normalize(t.title)
        // Generic titles ("Track 04", "01") say nothing about the song.
        guard title.count > 2, title.range(of: #"^(track|piste|titel|untitled)?\d*$"#, options: .regularExpression) == nil else { return [] }
        var out: [String] = []
        if let a = t.artist ?? t.albumArtist { out.append(normalize(a) + "|" + title) }
        // YouTube-style "Artist - Title" titles
        if let r = t.title.range(of: " - ") {
            let a = normalize(String(t.title[..<r.lowerBound])), ti = normalize(String(t.title[r.upperBound...]))
            if !a.isEmpty && !ti.isEmpty { out.append(a + "|" + ti) }
        }
        return Array(Set(out))
    }

    static let lossless: Set<String> = ["flac", "wav", "aif", "aiff", "alac"]

    /// Rough quality score: lossless first, then bitrate.
    static func quality(_ t: Track) -> Double {
        let kbps = (t.duration ?? 0) > 0 ? Double(t.size) * 8 / (t.duration! * 1000) : 0
        return (lossless.contains(t.fileExtension) ? 10_000 : 0) + kbps
    }

    /// Best copy first: quality, then non-YouTube, then most played, then shorter path.
    static func better(_ a: Track, _ b: Track) -> Bool {
        let qa = quality(a), qb = quality(b)
        if abs(qa - qb) > 16 { return qa > qb }
        if a.source != b.source { return a.source == .local }
        if a.playCount != b.playCount { return a.playCount > b.playCount }
        return a.relPath.count < b.relPath.count
    }
}

extension LibraryDB {
    /// Move a removed duplicate's stats onto the copy that's kept: the Mac's own counts, every
    /// device's backed-up counts, the YouTube link, and a merge record for iPhones / web player.
    func mergeStats(from removed: Track, into keep: String) {
        absorbStats(from: removed.relPath, into: keep)
        moveDeviceStats(from: removed.relPath, to: keep)
        try? db.execute("UPDATE yt_items SET rel_path = ? WHERE rel_path = ?", [keep, removed.relPath])
        recordMerge(old: removed.relPath, keep: keep)
    }

    /// Device stats for `old` are added to `keep` (creating the row where a device had none).
    func moveDeviceStats(from old: String, to keep: String) {
        try? db.transaction {
            try db.execute("""
                UPDATE device_stats SET
                  play_count = play_count + (SELECT o.play_count FROM device_stats o WHERE o.device_id = device_stats.device_id AND o.rel_path = ?),
                  skip_count = skip_count + (SELECT o.skip_count FROM device_stats o WHERE o.device_id = device_stats.device_id AND o.rel_path = ?),
                  favorite = MAX(favorite, (SELECT o.favorite FROM device_stats o WHERE o.device_id = device_stats.device_id AND o.rel_path = ?))
                WHERE rel_path = ? AND EXISTS (SELECT 1 FROM device_stats o WHERE o.device_id = device_stats.device_id AND o.rel_path = ?)
                """, [old, old, old, keep, old])
            try db.execute("UPDATE device_stats SET rel_path = ? WHERE rel_path = ? AND NOT EXISTS (SELECT 1 FROM device_stats k WHERE k.device_id = device_stats.device_id AND k.rel_path = ?)",
                           [keep, old, keep])
            try db.execute("DELETE FROM device_stats WHERE rel_path = ?", [old])
        }
    }
}
