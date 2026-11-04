import Foundation

extension String {
    /// Lowercased, accent-free form for searching: "Nešto Đorđe Ångström" → "nesto djordje angstrom".
    var searchFolded: String {
        var s = folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        // Letters Unicode doesn't treat as "base letter + accent", so folding leaves them alone.
        if s.unicodeScalars.contains(where: { $0.value > 0x7F }) {
            let map: [Character: String] = ["đ": "dj", "ð": "d", "ł": "l", "ø": "o", "æ": "ae", "œ": "oe", "ß": "ss", "þ": "th", "ı": "i"]
            s = String(s.flatMap { map[$0].map(Array.init) ?? [$0] })
        }
        return s
    }
}

/// A search box query: every word must appear somewhere (any field, any order), ignoring case and accents.
struct SearchQuery {
    let words: [String]

    init(_ text: String) {
        words = text.searchFolded.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isEmpty: Bool { words.isEmpty }

    /// `folded` must already be `searchFolded`.
    func matches(_ folded: String) -> Bool {
        words.allSatisfy { w in
            // "dj" for đ also lets people type the common "d" spelling: "dorde" finds "Đorđe"
            folded.contains(w) || (folded.contains("dj") && folded.replacingOccurrences(of: "dj", with: "d").contains(w))
        }
    }
}

extension Track {
    /// Everything a search looks at, folded.
    var searchKey: String {
        [title, artist ?? "", albumArtist ?? "", album ?? "", relPath].joined(separator: " ").searchFolded
    }
}
