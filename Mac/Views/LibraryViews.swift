import SwiftUI

struct TrackTable: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var store: LibraryStore
    let tracks: [Track]
    var title: String = ""
    var defaultSort = true
    @State private var sortOrder: [KeyPathComparator<Track>] = []
    @State private var selection = Set<Track.ID>()
    @State private var confirmFavorite = false

    /// Always show the store's current copy, so hearts and play counts update in folder/album lists too.
    private var live: [Track] { tracks.map { store.track($0.relPath) ?? $0 } }
    private var sorted: [Track] { sortOrder.isEmpty ? live : live.sorted(using: sortOrder) }

    var body: some View {
        let rows = sorted
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("♥", value: \.favoriteSort) { t in
                Button { model.toggleFavorite(t) } label: {
                    Image(systemName: t.favorite ? "heart.fill" : "heart").foregroundStyle(t.favorite ? .pink : .secondary)
                }.buttonStyle(.plain)
            }.width(22)
            TableColumn("Title", value: \.title) { t in
                Text(t.title).fontWeight(player.current?.relPath == t.relPath ? .bold : .regular)
            }
            TableColumn("Artist", value: \.displayArtist)
            TableColumn("Album", value: \.displayAlbum)
            TableColumn("Time", value: \.durationSort) { Text(($0.duration ?? 0).durationString).monospacedDigit() }.width(55)
            TableColumn("Plays", value: \.playCount) { Text("\($0.playCount)").monospacedDigit() }.width(45)
            TableColumn("Format", value: \.fileExtension).width(50)
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            let picked = rows.filter { ids.contains($0.id) }
            Button("Play") { play(picked.first, in: rows) }
            Button("Play Next") { picked.reversed().forEach(player.playNext) }
            Button("Add to Queue") { picked.forEach(player.addToQueue) }
            Divider()
            Button("Toggle Favorite") { picked.forEach(model.toggleFavorite) }
            if let first = picked.first { Button("Show in Finder") { model.revealInFinder(first) } }
        } primaryAction: { ids in
            play(rows.first { ids.contains($0.id) }, in: rows)
        }
        .navigationTitle(title)
        .navigationSubtitle("\(tracks.count) songs")
        .onChange(of: sortOrder) { old, new in
            // The ♥ header is a "favorite everything shown" button, not a sort.
            guard new.first?.keyPath == \Track.favoriteSort else { return }
            sortOrder = old.filter { $0.keyPath != \Track.favoriteSort }
            if tracks.count > 25 { confirmFavorite = true } else { toggleAllFavorites() }
        }
        .confirmationDialog(allFavorite ? "Remove all \(tracks.count) songs in this list from favorites?" : "Mark all \(tracks.count) songs in this list as favorites?",
                            isPresented: $confirmFavorite, titleVisibility: .visible) {
            Button(allFavorite ? "Unfavorite All" : "Favorite All") { toggleAllFavorites() }
        }
    }

    private var allFavorite: Bool { !tracks.isEmpty && tracks.allSatisfy { model.store.track($0.relPath)?.favorite ?? $0.favorite } }

    private func toggleAllFavorites() {
        let fav = !allFavorite
        model.store.setFavorite(tracks, fav)
        for t in tracks { if let u = model.store.track(t.relPath) { player.refresh(u) } }
    }

    private func play(_ t: Track?, in rows: [Track]) {
        guard let t, let i = rows.firstIndex(of: t) else { return }
        player.play(rows, startAt: i)
    }
}

extension Track { var durationSort: Double { duration ?? 0 } }

struct FolderBrowser: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @State private var path = ""

    var body: some View {
        let node = store.folderRoot.node(at: path) ?? store.folderRoot
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button("Music") { path = "" }.buttonStyle(.link)
                let comps = path.split(separator: "/").map(String.init)
                ForEach(comps.indices, id: \.self) { i in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    Button(comps[i]) { path = comps[...i].joined(separator: "/") }.buttonStyle(.link)
                }
                Spacer()
                Button { player.play(node.allTracks) } label: { Label("Play All", systemImage: "play.fill") }
                Button { player.shuffle = true; player.play(node.allTracks.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
            }
            .padding(8)
            Divider()
            VSplitView {
                List(node.subfolders) { f in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(f.name)
                        Spacer()
                        Text("\(f.totalTracks)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { path = f.path }
                    .contextMenu {
                        Button("Open") { path = f.path }
                        Button("Play") { player.play(f.allTracks) }
                    }
                }
                .frame(minHeight: node.subfolders.isEmpty ? 0 : 120)
                TrackTable(tracks: node.tracks, title: node.path.isEmpty ? "Folders" : node.name)
                    .frame(minHeight: 150)
            }
        }
    }
}

struct ArtistBrowser: View {
    @EnvironmentObject var store: LibraryStore
    @State private var artist: String?

    var body: some View {
        HSplitView {
            List(store.artists, id: \.self, selection: $artist) { Text($0) }.frame(minWidth: 200, maxWidth: 320)
            if let artist { TrackTable(tracks: store.tracks(artist: artist), title: artist, defaultSort: false) }
            else { ContentUnavailableView("Select an artist", systemImage: "music.mic").frame(maxWidth: .infinity) }
        }
    }
}

struct AlbumBrowser: View {
    @EnvironmentObject var store: LibraryStore
    @State private var album: AlbumKey?

    var body: some View {
        HSplitView {
            List(store.albums, selection: $album) { a in
                VStack(alignment: .leading) { Text(a.album); Text(a.artist).font(.caption).foregroundStyle(.secondary) }.tag(a)
            }.frame(minWidth: 220, maxWidth: 340)
            if let album { TrackTable(tracks: store.tracks(album: album), title: album.album, defaultSort: false) }
            else { ContentUnavailableView("Select an album", systemImage: "square.stack").frame(maxWidth: .infinity) }
        }
    }
}

struct PlayerBar: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var model: AppModel
    @State private var scrub: Double?
    @State private var showQueue = false

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(image: player.artwork, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "Not Playing").font(.headline).lineLimit(1)
                Text(player.current.map { "\($0.displayArtist) — \($0.displayAlbum)" } ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 220, alignment: .leading)
            if let cur = player.current {
                Button { model.toggleFavorite(model.store.track(cur.relPath) ?? cur) } label: {
                    Image(systemName: (model.store.track(cur.relPath)?.favorite ?? false) ? "heart.fill" : "heart")
                }.buttonStyle(.plain).foregroundStyle(.pink)
            }
            Spacer()
            HStack(spacing: 16) {
                Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Color.accentColor : .secondary) }
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30)) }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                Button { cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
                }
            }.buttonStyle(.plain).font(.title3)
            HStack {
                Text((scrub ?? player.currentTime).durationString).font(.caption).monospacedDigit()
                Slider(value: Binding(get: { scrub ?? player.currentTime }, set: { scrub = $0 }),
                       in: 0...max(player.duration, 1)) { editing in
                    if !editing, let s = scrub { player.seek(to: s); scrub = nil }
                }
                Text(player.duration.durationString).font(.caption).monospacedDigit()
            }.frame(minWidth: 220, maxWidth: 360)
            Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1).frame(width: 80)
            Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }.buttonStyle(.plain)
                .popover(isPresented: $showQueue) { QueueView().frame(width: 340, height: 420) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private func cycleRepeat() {
        let all = RepeatMode.allCases
        player.repeatMode = all[(all.firstIndex(of: player.repeatMode)! + 1) % all.count]
    }
}

struct QueueView: View {
    @EnvironmentObject var player: PlayerEngine
    var body: some View {
        List {
            if let cur = player.current { Section("Now Playing") { TrackRowLabel(track: cur, isCurrent: true) } }
            Section("Up Next") {
                ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, t in
                    TrackRowLabel(track: t).onTapGesture(count: 2) { player.jump(to: player.index + 1 + i) }
                }
                .onMove { player.moveInQueue(from: $0, to: $1) }
                .onDelete { player.removeFromQueue(at: $0) }
            }
        }
    }
}
