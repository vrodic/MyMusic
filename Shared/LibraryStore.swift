import Foundation
import SwiftUI

struct AlbumKey: Hashable, Identifiable {
    let artist: String
    let album: String
    var id: String { artist + "\u{1}" + album }
}

/// In-memory, observable view of the `tracks` table used by both apps' UIs.
@MainActor
final class LibraryStore: ObservableObject {
    let db: LibraryDB
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var folderRoot = FolderNode(path: "", name: "Music")
    @Published private(set) var artists: [String] = []
    @Published private(set) var albums: [AlbumKey] = []
    private var byPath: [String: Int] = [:]

    init(db: LibraryDB) {
        self.db = db
        reload()
    }

    func reload() {
        let all = db.allTracks().sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        tracks = all
        byPath = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.relPath, $0) })
        folderRoot = FolderNode.build(all)
        artists = Set(all.map(\.displayArtist)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        albums = Set(all.map { AlbumKey(artist: $0.albumArtist ?? $0.displayArtist, album: $0.displayAlbum) })
            .sorted { $0.album.localizedStandardCompare($1.album) == .orderedAscending }
    }

    func track(_ relPath: String) -> Track? { byPath[relPath].map { tracks[$0] } }

    func tracks(artist: String) -> [Track] {
        tracks.filter { $0.displayArtist == artist || $0.albumArtist == artist }.sorted(by: Self.albumOrder)
    }

    func tracks(album: AlbumKey) -> [Track] {
        tracks.filter { $0.displayAlbum == album.album && ($0.albumArtist ?? $0.displayArtist) == album.artist }
            .sorted(by: Self.albumOrder)
    }

    var favorites: [Track] { tracks.filter(\.favorite) }
    var mostPlayed: [Track] { tracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(200).map { $0 } }
    var recentlyPlayed: [Track] { tracks.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? 0) > ($1.lastPlayed ?? 0) }.prefix(200).map { $0 } }
    var recentlyAdded: [Track] { tracks.sorted { $0.addedAt > $1.addedAt }.prefix(200).map { $0 } }

    func search(_ q: String) -> [Track] {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.artist?.localizedCaseInsensitiveContains(q) ?? false)
                || ($0.album?.localizedCaseInsensitiveContains(q) ?? false) || $0.relPath.localizedCaseInsensitiveContains(q)
        }
    }

    @discardableResult
    func toggleFavorite(_ t: Track) -> Track {
        db.setFavorite(t.relPath, !t.favorite)
        var u = t; u.favorite.toggle(); u.favoriteAt = Date().timeIntervalSince1970
        replace(u)
        return u
    }

    /// Favorite / unfavorite many tracks at once.
    func setFavorite(_ list: [Track], _ fav: Bool) {
        db.setFavorite(list.map(\.relPath), fav)
        let now = Date().timeIntervalSince1970
        for t in list { if var u = track(t.relPath) { u.favorite = fav; u.favoriteAt = now; replace(u) } }
    }

    func recordPlay(_ t: Track) {
        db.recordPlay(t.relPath)
        var u = track(t.relPath) ?? t
        u.playCount += 1; u.lastPlayed = Date().timeIntervalSince1970
        replace(u)
    }

    func recordSkip(_ t: Track) {
        db.recordSkip(t.relPath)
        if var u = track(t.relPath) { u.skipCount += 1; replace(u) }
    }

    private func replace(_ t: Track) {
        if let i = byPath[t.relPath] { tracks[i] = t }
    }

    static func albumOrder(_ a: Track, _ b: Track) -> Bool {
        if a.displayAlbum != b.displayAlbum { return a.displayAlbum.localizedStandardCompare(b.displayAlbum) == .orderedAscending }
        if (a.discNumber ?? 0) != (b.discNumber ?? 0) { return (a.discNumber ?? 0) < (b.discNumber ?? 0) }
        if (a.trackNumber ?? 0) != (b.trackNumber ?? 0) { return (a.trackNumber ?? 0) < (b.trackNumber ?? 0) }
        return a.relPath.localizedStandardCompare(b.relPath) == .orderedAscending
    }
}
