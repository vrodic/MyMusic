import Foundation

extension String {
    /// Lowercased, accent-free form for searching: "Nešto Đorđe Ångström" → "nesto djordje angstrom".
    var searchFolded: String {
        var s = folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        // Letters Unicode doesn't treat as "base letter + accent", so folding leaves them alone.
        if s.unicodeScalars.contains(where: { $0.value > 0x7F }) {
            let map: [Character: String] = ["đ": "dj", "ð": "d", "ł": "l", "ø": "o", "æ": "ae", "œ": "oe", "ß": "ss", "þ": "th", "ı": "i"]
            s = String(s.flatMap { map[$0].map(Array.init) ?? [$0] })
            // `matches` compares bytes, so marks that survive folding (Hangul, kana) and filenames
            // stored decomposed must share one normal form.
            s = s.precomposedStringWithCanonicalMapping
        }
        return s
    }
}

/// A search box query: every word must appear somewhere (any field, any order), ignoring case and accents.
struct SearchQuery {
    let words: [String]
    private let needles: [[UInt8]]

    init(_ text: String) {
        words = text.searchFolded.split(whereSeparator: \.isWhitespace).map(String.init)
        needles = words.map { Array($0.utf8) }
    }

    var isEmpty: Bool { words.isEmpty }

    /// `folded` must already be `searchFolded`. Compares UTF-8 bytes: this runs for every song on
    /// every search, and character-by-character `String.contains` is about 10× slower.
    func matches(_ folded: String) -> Bool {
        var key = folded
        return key.withUTF8 { hay in
            needles.allSatisfy { w in
                Self.contains(hay, w) || (Self.contains(hay, Self.dj) && Self.containsCollapsingDJ(hay, w))
            }
        }
    }

    private static let dj = Array("dj".utf8)

    private static func contains(_ hay: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBytes { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil }
    }

    /// "dj" for đ also lets people type the common "d" spelling: "dorde" finds "Đorđe".
    private static func containsCollapsingDJ(_ hay: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        var collapsed = [UInt8]()
        collapsed.reserveCapacity(hay.count)
        var i = 0
        while i < hay.count {
            collapsed.append(hay[i])
            i += hay[i] == UInt8(ascii: "d") && i + 1 < hay.count && hay[i + 1] == UInt8(ascii: "j") ? 2 : 1
        }
        return collapsed.withUnsafeBufferPointer { contains($0, needle) }
    }
}

extension Track {
    /// Everything a search looks at, folded.
    var searchKey: String {
        [title, artist ?? "", albumArtist ?? "", album ?? "", relPath].joined(separator: " ").searchFolded
    }
}
