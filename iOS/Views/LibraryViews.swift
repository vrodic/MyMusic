import SwiftUI
import UniformTypeIdentifiers

struct LibraryHome: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var model: IOSModel
    @State private var importing = false

    var body: some View {
        List {
            Section {
                NavigationLink { TrackListView(title: "Songs", tracks: store.tracks) } label: { Label("Songs", systemImage: "music.note") }
                NavigationLink { FolderView(path: "") } label: { Label("Folders", systemImage: "folder") }
                NavigationLink { ArtistsView() } label: { Label("Artists", systemImage: "music.mic") }
                NavigationLink { AlbumsView() } label: { Label("Albums", systemImage: "square.stack") }
            }
            Section("Smart lists") {
                NavigationLink { TrackListView(title: "Favorites", tracks: store.favorites) } label: { Label("Favorites", systemImage: "heart") }
                NavigationLink { TrackListView(title: "Most Played", tracks: store.mostPlayed, showPlays: true) } label: { Label("Most Played", systemImage: "flame") }
                NavigationLink { TrackListView(title: "Recently Played", tracks: store.recentlyPlayed) } label: { Label("Recently Played", systemImage: "clock") }
                NavigationLink { TrackListView(title: "Recently Added", tracks: store.recentlyAdded) } label: { Label("Recently Added", systemImage: "plus.circle") }
                NavigationLink { TrackListView(title: "YouTube", tracks: store.tracks.filter { $0.source == .youtube }) } label: { Label("YouTube Likes", systemImage: "play.rectangle") }
            }
            Section {
                let d = store.tracks.reduce(0.0) { $0 + ($1.duration ?? 0) }
                Text("\(store.tracks.count) songs · \(store.artists.count) artists · \(Int(d / 3600)) h · \(ByteCountFormatter.string(fromByteCount: model.storageUsed(), countStyle: .file))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem {
                Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .audio], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { Task { await model.importItems(urls) } }
        }
        .refreshable { await model.scanLocal() }
        .overlay(alignment: .top) {
            if model.isScanning { ProgressView().padding(6).background(.thinMaterial, in: Capsule()) }
        }
    }
}

struct FolderView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    let path: String
    @State private var query = ""

    var body: some View {
        let node = store.folderRoot.node(at: path)
        let q = SearchQuery(query)
        // Searching covers this folder and everything below it.
        let folders = node.map { q.isEmpty ? $0.subfolders : $0.searchFolders(q) } ?? []
        let tracks = node.map { q.isEmpty ? $0.tracks : store.filter($0.allTracks, query) } ?? []
        List {
            if node != nil {
                if !folders.isEmpty {
                    Section(q.isEmpty ? "" : "Folders") {
                        ForEach(folders) { f in
                            NavigationLink { FolderView(path: f.path) } label: {
                                HStack {
                                    Image(systemName: f.path == "yt" ? "play.rectangle.fill" : "folder.fill")
                                        .foregroundStyle(f.path == "yt" ? .red : .blue)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(f.name)
                                        if !q.isEmpty { Text(f.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                                    }
                                    Spacer()
                                    Text("\(f.totalTracks)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contextMenu {
                                Button { player.play(f.allTracks) } label: { Label("Play", systemImage: "play") }
                                Button { player.play(f.allTracks.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
                            }
                        }
                    }
                }
                if !tracks.isEmpty {
                    Section(q.isEmpty ? "" : "Songs") { TrackRows(tracks: tracks) }
                }
            } else {
                ContentUnavailableView("Folder not found", systemImage: "folder")
            }
        }
        .navigationTitle(node?.path.isEmpty ?? true ? "Folders" : node!.name)
        .searchable(text: $query, prompt: node?.path.isEmpty ?? true ? "Search folders and songs" : "Search in \(node!.name)")
        .toolbar { PlayShuffleToolbar(tracks: q.isEmpty ? (node?.allTracks ?? []) : tracks) }
        .overlay {
            if store.tracks.isEmpty { ContentUnavailableView("No music yet", systemImage: "music.note", description: Text("Sync from your Mac, or drop folders into On My iPhone → MyMusic → Music in the Files app.")) }
            else if !q.isEmpty && folders.isEmpty && tracks.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }
}

struct TrackListView: View {
    @EnvironmentObject var store: LibraryStore
    let title: String
    let tracks: [Track]
    var showPlays = false

    @State private var query = ""

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = store.filter(tracks, q)
        List { TrackRows(tracks: shown) }
            .navigationTitle(title)
            .searchable(text: $query, prompt: "Search \(title)")
            .toolbar { PlayShuffleToolbar(tracks: shown) }
            .overlay {
                if tracks.isEmpty { ContentUnavailableView("Nothing here yet", systemImage: "music.note") }
                else if shown.isEmpty { ContentUnavailableView.search(text: q) }
            }
    }
}

struct PlayShuffleToolbar: ToolbarContent {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var store: LibraryStore
    let tracks: [Track]
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let allFav = !tracks.isEmpty && tracks.allSatisfy { store.track($0.relPath)?.favorite ?? $0.favorite }
            Menu {
                Button { store.setFavorite(tracks, !allFav); tracks.compactMap { store.track($0.relPath) }.forEach(player.refresh) } label: {
                    Label(allFav ? "Unfavorite All \(tracks.count)" : "Favorite All \(tracks.count)", systemImage: allFav ? "heart.slash" : "heart")
                }
                Button { tracks.forEach(player.addToQueue) } label: { Label("Add All to Queue", systemImage: "text.append") }
            } label: { Image(systemName: "ellipsis.circle") }
                .disabled(tracks.isEmpty)
            Button { player.shuffle = false; player.play(tracks) } label: { Image(systemName: "play.fill") }.disabled(tracks.isEmpty)
            Button { player.shuffle = true; player.play(tracks, startAt: Int.random(in: 0..<max(tracks.count, 1))) } label: { Image(systemName: "shuffle") }.disabled(tracks.isEmpty)
        }
    }
}

struct TrackRows: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var model: IOSModel
    @EnvironmentObject var store: LibraryStore
    let tracks: [Track]

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t0 in
            let t = store.track(t0.relPath) ?? t0
            Button { player.play(tracks, startAt: i) } label: {
                TrackRowLabel(track: t, isCurrent: player.current?.relPath == t.relPath).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .leading) {
                Button { model.toggleFavorite(t) } label: { Image(systemName: t.favorite ? "heart.slash" : "heart") }.tint(.pink)
            }
            .swipeActions(edge: .trailing) {
                Button { player.playNext(t) } label: { Image(systemName: "text.insert") }.tint(.orange)
                Button { player.addToQueue(t) } label: { Image(systemName: "text.append") }.tint(.indigo)
            }
            .contextMenu { TrackMenu(track: t) }
        }
    }
}

struct TrackMenu: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var model: IOSModel
    let track: Track
    var body: some View {
        Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
        Button { player.addToQueue(track) } label: { Label("Add to Queue", systemImage: "text.append") }
        Button { model.toggleFavorite(track) } label: { Label(track.favorite ? "Unfavorite" : "Favorite", systemImage: track.favorite ? "heart.slash" : "heart") }
        ShareLink(item: model.url(for: track)) { Label("Share / Open In…", systemImage: "square.and.arrow.up") }
        Section("\(track.playCount) plays · \(track.fileExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: track.size, countStyle: .file))") {
            Button(role: .destructive) { model.deleteFromDevice([track]) } label: { Label("Remove from iPhone", systemImage: "trash") }
        }
    }
}

struct ArtistsView: View {
    @EnvironmentObject var store: LibraryStore
    var body: some View {
        List(store.artists, id: \.self) { a in
            NavigationLink(a) { TrackListView(title: a, tracks: store.tracks(artist: a)) }
        }
        .navigationTitle("Artists")
    }
}

struct AlbumsView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var model: IOSModel
    var body: some View {
        List(store.albums) { a in
            NavigationLink { TrackListView(title: a.album, tracks: store.tracks(album: a)) } label: {
                HStack {
                    if let first = store.tracks(album: a).first { TrackArtwork(url: model.url(for: first), size: 44) }
                    VStack(alignment: .leading) { Text(a.album).lineLimit(1); Text(a.artist).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Albums")
    }
}

struct SearchView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var query = ""
    var body: some View {
        let results = query.isEmpty ? [] : store.search(query)
        List { TrackRows(tracks: Array(results.prefix(500))) }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums, folders")
            .navigationTitle("Search")
            .overlay { if !query.isEmpty && results.isEmpty { ContentUnavailableView.search(text: query) } }
    }
}
