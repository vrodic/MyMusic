import Foundation

/// Fuzzy match between a liked YouTube song and the songs you already own, to avoid downloading
/// something that's in the library under another file name or tag spelling.
///
/// Both sides are read as (artist, title) in every plausible way: tags, "Artist - Title" in a
/// title or file name, the channel name minus "- Topic"/VEVO, and folder names for untagged files.
/// Score (0…1) = 0.6 × title similarity + 0.4 × artist similarity, then:
///  * length within 3 s: bonus; different lengths: small penalty (usually another edit you own)
///  * version words (remix, live, acoustic, edit…) on one side only: penalty
///  * a clearly different, known artist: capped below the threshold (it's a cover)
/// Accents, case, "(Official Video)", feat., track numbers and word order are ignored.
enum YTLibraryMatcher {
    struct Match: Hashable {
        var relPath: String
        var score: Double
    }

    /// Scores at or above this are treated as "already in your library" and not downloaded.
    static let likelyThreshold = 0.8
    /// Scores from here up to `likelyThreshold` are shown as a possible match (still downloads).
    static let possibleThreshold = 0.6

    static let stopWords: Set<String> = ["the", "a", "an", "and", "of", "official", "video", "audio", "lyrics", "lyric",
                                         "music", "hd", "hq", "4k", "remastered", "remaster", "topic", "vevo", "feat", "ft",
                                         "featuring", "mv", "clip", "original", "mp3"]
    static let versionWords: Set<String> = ["remix", "rmx", "mix", "live", "acoustic", "edit", "instrumental", "karaoke",
                                            "cover", "slowed", "reverb", "sped", "nightcore", "extended", "dub", "version",
                                            "demo", "unplugged", "xtd"]

    /// Lowercase, accent-free words with noise removed.
    static func words(_ s: String) -> [String] {
        var t = s.searchFolded.replacingOccurrences(of: "_", with: " ")
        t = t.replacingOccurrences(of: #"[\(\[\{][^\)\]\}]*(official|video|audio|lyric|visuali|hd|hq|4k|remaster|explicit)[^\)\]\}]*[\)\]\}]"#,
                                   with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(feat|ft|featuring)\.?\s.*$"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*[a-z]?\d{1,3}[\s\.\-_]+"#, with: "", options: .regularExpression)   // "03 - ", "B09 - "
        t = t.replacingOccurrences(of: "&", with: " and ")
        return t.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !stopWords.contains($0) }
    }

    /// "Artist - Title" (also –, —, a one-sided dash, or "Artist-Title" between words) split in two.
    static func splitArtistTitle(_ s: String) -> (String, String)? {
        for sep in [" - ", " – ", " — ", " -", "- "] {
            if let r = s.range(of: sep) {
                let a = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces), b = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !a.isEmpty, !b.isEmpty { return (a, b) }
            }
        }
        if let r = s.range(of: #"(?<=\p{L})-(?=\p{L})"#, options: .regularExpression) {
            let a = String(s[..<r.lowerBound]), b = String(s[r.upperBound...])
            if b.split(separator: " ").count >= 2 { return (a, b) }
        }
        return nil
    }

    static func cleanChannel(_ s: String) -> String {
        var c = s.trimmingCharacters(in: .whitespaces)
        for suffix in [" - Topic", " CROREC OFFICIAL", "VEVO", "Vevo", " OFFICIAL", " Official", " official", "Official"] where c.hasSuffix(suffix) {
            c = String(c.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return c
    }

    static func hasLetters(_ w: [String]) -> Bool { w.contains { $0.contains { $0.isLetter } } }

    static func overlap(_ a: [String], _ b: [String]) -> Double {
        let A = Set(a), B = Set(b)
        guard !A.isEmpty, !B.isEmpty else { return 0 }
        return Double(A.intersection(B).count) / Double(max(A.count, B.count))
    }

    static func containment(_ a: [String], _ b: [String]) -> Double {
        let A = Set(a), B = Set(b)
        guard !A.isEmpty, !B.isEmpty else { return 0 }
        return Double(A.intersection(B).count) / Double(min(A.count, B.count))
    }

    /// 1 − edit distance / length, on the words joined in sorted order (so order doesn't matter).
    static func charSimilarity(_ a: [String], _ b: [String]) -> Double {
        let x = Array(a.sorted().joined(separator: " ")), y = Array(b.sorted().joined(separator: " "))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if abs(x.count - y.count) > max(x.count, y.count) / 2 { return 0 }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    struct Reading { var artist: [String]; var title: [String] }

    /// The video's possible (artist, title) readings.
    static func videoReadings(title: String, uploader: String?) -> [Reading] {
        let channel = words(cleanChannel(uploader ?? ""))
        if let (a, t) = splitArtistTitle(title) {
            let tw = words(t)
            return [Reading(artist: words(a), title: tw), Reading(artist: channel, title: tw)]
        }
        return [Reading(artist: channel, title: words(title))]
    }

    struct Indexed {
        let track: Track
        let titles: [[String]]          // tag title, and the title part of "Artist - Title" titles / file names
        let artists: [[String]]         // tag artists and the artist part of such titles / file names
        let folders: [Set<String>]      // parent folder names, for untagged files
        var knowsArtist: Bool { !artists.isEmpty }
    }

    final class Index {
        let items: [Indexed]
        private var byWord: [String: [Int]] = [:]

        init(library: [Track]) {
            items = library.map { t in
                var titles: [[String]] = [], artists: [[String]] = []
                for a in [t.artist, t.albumArtist].compactMap({ $0 }) where a.lowercased() != "unknown artist" {
                    let w = words(a); if hasLetters(w) { artists.append(w) }
                }
                let fileName = ((t.relPath as NSString).lastPathComponent as NSString).deletingPathExtension
                for s in Set([t.title, fileName]) {
                    if let (a, b) = splitArtistTitle(s) {
                        let aw = words(a), bw = words(b)
                        if hasLetters(aw) { artists.append(aw); titles.append(bw) } else { titles.append(words(s)) }
                    } else {
                        titles.append(words(s))
                    }
                }
                let folders = t.relPath.split(separator: "/").dropLast().map { Set(words(String($0))) }.filter { !$0.isEmpty }
                return Indexed(track: t, titles: titles.filter { !$0.isEmpty }, artists: artists, folders: Array(folders))
            }
            for (i, it) in items.enumerated() {
                for w in Set(it.titles.joined()) where w.count > 1 { byWord[w, default: []].append(i) }
            }
        }

        /// Best library match for a video, if any scores at least `threshold`.
        func bestMatch(title: String, uploader: String?, duration: Double?, threshold: Double) -> Match? {
            var best: Match?
            let fullWords = Set(words(title))
            for r in videoReadings(title: title, uploader: uploader) where !r.title.isEmpty {
                // candidates share a title word; the rarest words keep this fast
                let keys = Set(r.title.filter { $0.count > 1 }).sorted { (byWord[$0]?.count ?? 0) < (byWord[$1]?.count ?? 0) }
                var cand = Set<Int>()
                for k in keys.prefix(3) { cand.formUnion(byWord[k] ?? []) }
                for i in cand {
                    let s = score(r, fullWords: fullWords, duration: duration, against: items[i])
                    if s >= threshold, s > (best?.score ?? 0) { best = Match(relPath: items[i].track.relPath, score: s) }
                }
            }
            return best
        }

        private func score(_ r: Reading, fullWords: Set<String>, duration: Double?, against it: Indexed) -> Double {
            var titleSim = 0.0, bestTitle: [String] = []
            for lw in it.titles {
                let sim = max(overlap(r.title, lw), charSimilarity(r.title, lw))
                if sim > titleSim { titleSim = sim; bestTitle = lw }
            }
            guard titleSim >= 0.6 else { return 0 }

            // artist: whole-word matches (also one name inside the other), or near-identical spelling
            var wordSim = 0.0, charSim = 0.0
            for la in it.artists where !r.artist.isEmpty {
                wordSim = max(wordSim, overlap(r.artist, la), 0.9 * containment(r.artist, la))
                charSim = max(charSim, charSimilarity(r.artist, la))
            }
            var artistSim = max(wordSim, charSim >= 0.75 ? charSim : 0)
            // the artist is often only a folder name for untagged files
            if !r.artist.isEmpty, artistSim < 0.9, it.folders.contains(where: { Set(r.artist).isSubset(of: $0) }) { artistSim = 0.9 }
            // or the whole video title has both the library artist and title ("Mišo Kovač Proplakat će zora")
            if artistSim < 0.9, it.artists.contains(where: { !$0.isEmpty && Set($0 + bestTitle).isSubset(of: fullWords) }) { artistSim = 0.9 }

            var s = 0.6 * titleSim + 0.4 * artistSim
            let vA = Set(r.title).intersection(versionWords), vB = Set(bestTitle).intersection(versionWords)
            if vA != vB { s -= 0.2 }
            if let d1 = duration, let d2 = it.track.duration, d1 > 0, d2 > 0 {
                let diff = abs(d1 - d2)
                if diff <= 3 { s += 0.1 } else if diff > 90 { s -= 0.3 } else if diff > 30 { s -= 0.15 } else if diff > 10 { s -= 0.08 }
            }
            // same title, different known artist: a cover, not your recording
            if it.knowsArtist && artistSim < 0.3 { s = min(s, 0.55) }
            return min(max(s, 0), 1)
        }
    }
}
