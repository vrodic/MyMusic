import SwiftUI

struct TrackTable: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var store: LibraryStore
    let tracks: [Track]
    var title: String = ""
    var defaultSort = true
    /// What the rows depend on besides library growth (search text, folder…). When it changes the
    /// table is rebuilt instead of diffed; a song arriving from a download still updates in place.
    var resetKey: String = ""
    /// Which list this is, for remembering its scroll position (default: title + resetKey).
    var scrollKey: String? = nil
    /// The search text: changing it forgets the remembered scroll position.
    var search: String = ""
    /// Set on the list "Show in Songs" / "Show in Folder" should select the song in.
    var revealPlace: RevealRequest.Place? = nil
    /// Set when showing a playlist: adds Remove / Move to Top.
    var playlistID: String? = nil
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
            TableColumn("Favorited", value: \.favoritedSort) { t in
                if t.favorite, let at = t.favoriteAt {
                    Text(Date(timeIntervalSince1970: at), format: .dateTime.year().month(.abbreviated).day()).monospacedDigit()
                }
            }.width(90)
        }
        // When the rows themselves change (search cleared, other view, re-sort), give SwiftUI a new
        // table instead of letting it diff thousands of rows on the main thread (the beachball).
        // Property changes (hearts, play counts) keep the same identity and update in place.
        .rememberScroll(scrollMemoryKey, resetOn: search)
        .id(TableIdentity.of(resetKey, title, "\(sortOrder)"))
        .onAppear(perform: handleReveal)
        .onChange(of: model.revealRequest) { handleReveal() }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            let picked = rows.filter { ids.contains($0.id) }
            Button("Play") { play(picked.first, in: rows) }
            Button("Play Next") { picked.reversed().forEach(player.playNext) }
            Button("Add to Queue") { picked.forEach(player.addToQueue) }
            Divider()
            Button("Toggle Favorite") { picked.forEach(model.toggleFavorite) }
            SyncMenuItem(paths: picked.map(\.relPath))
            Divider()
            PlaylistMenu(tracks: picked)
            if let pid = playlistID {
                Button("Remove from Playlist") { model.removeFromPlaylist(pid, picked) }
                if let first = picked.first { Button("Move to Top") { model.movePlaylistItem(pid, first, toTop: true) } }
            }
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

    private var scrollMemoryKey: String { "tracks\u{1}" + (scrollKey ?? title + "\u{1}" + resetKey) + "\u{1}\(sortOrder)" }

    private func handleReveal() {
        guard let r = model.revealRequest, r.place == revealPlace,
              let i = sorted.firstIndex(where: { $0.relPath == r.relPath }) else { return }
        selection = [r.relPath]
        ScrollMemory.scrollToRow(i, key: scrollMemoryKey)
        model.revealRequest = nil
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
    @Binding var search: String
    @AppStorage("mac.folderPath") private var path = ""   // reopen in the last folder

    var body: some View {
        let node = store.folderRoot.node(at: path) ?? store.folderRoot
        let query = SearchQuery(search)
        // Searching looks through this folder and everything below it.
        let folders = query.isEmpty ? node.subfolders : node.searchFolders(query)
        let tracks = query.isEmpty ? node.tracks : store.filter(node.allTracks, search)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button("Music") { open("") }.buttonStyle(.link)
                let comps = path.split(separator: "/").map(String.init)
                ForEach(comps.indices, id: \.self) { i in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    Button(comps[i]) { open(comps[...i].joined(separator: "/")) }.buttonStyle(.link)
                }
                if !query.isEmpty {
                    Text("· \(folders.count) folders, \(tracks.count) songs matching “\(search)”").foregroundStyle(.secondary)
                }
                Spacer()
                let playable = query.isEmpty ? node.allTracks : tracks
                Button { player.play(playable) } label: { Label("Play All", systemImage: "play.fill") }.disabled(playable.isEmpty)
                Button { player.shuffle = true; player.play(playable.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }.disabled(playable.isEmpty)
            }
            .padding(8)
            Divider()
            // Own split (not VSplitView): the divider position is remembered while you browse
            // folders and across launches, and the layout doesn't jump in folders without subfolders.
            GeometryReader { geo in
            VStack(spacing: 0) {
                let _ = (path.isEmpty || store.folderRoot.node(at: path) != nil) ? () : DispatchQueue.main.async { path = "" }
                List(folders) { f in
                    HStack {
                        Image(systemName: f.path == "yt" ? "play.rectangle.fill" : "folder.fill").foregroundStyle(f.path == "yt" ? .red : .blue)
                        if query.isEmpty {
                            Text(f.name)
                        } else {
                            // show where a deep match lives
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name)
                                Text(f.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                        Spacer()
                        Text("\(f.totalTracks)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(f.path) }
                    .contextMenu {
                        Button("Open") { open(f.path) }
                        Button("Play") { player.play(f.allTracks) }
                        Divider()
                        SyncMenuItem(paths: [f.path], noun: "Folder")
                    }
                }
                .rememberScroll("folders\u{1}" + path, resetOn: search)
                .frame(height: clampedListHeight(in: geo.size.height))
                .overlay {
                    if !query.isEmpty && folders.isEmpty && tracks.isEmpty { ContentUnavailableView.search(text: search) }
                    else if folders.isEmpty { Text(query.isEmpty ? "No subfolders" : "No matching folders").font(.caption).foregroundStyle(.secondary) }
                }
                SplitDivider(height: $folderListHeight, maxHeight: geo.size.height - 150)
                TrackTable(tracks: tracks, title: node.path.isEmpty ? "Folders" : node.name, resetKey: path + "\u{1}" + search,
                           scrollKey: "folder:" + path, search: search, revealPlace: query.isEmpty ? .folder : nil)
                    .frame(maxHeight: .infinity)
            }
            }
        }
    }

    @AppStorage("mac.folderListHeight") private var folderListHeight: Double = 220

    private func clampedListHeight(in total: CGFloat) -> CGFloat {
        min(max(CGFloat(folderListHeight), 44), max(44, total - 150))
    }

    /// Opening a folder clears the search so you see its contents.
    private func open(_ p: String) { path = p; search = "" }
}

struct ArtistBrowser: View {
    @EnvironmentObject var store: LibraryStore
    var search: String = ""
    @AppStorage("mac.artist") private var savedArtist = ""
    private var artist: Binding<String?> { Binding(get: { savedArtist.isEmpty ? nil : savedArtist }, set: { savedArtist = $0 ?? "" }) }

    var body: some View {
        let q = SearchQuery(search)
        let list = q.isEmpty ? store.artists : store.artists.filter { q.matches($0.searchFolded) }
        HSplitView {
            List(list, id: \.self, selection: artist) { Text($0) }.rememberScroll("artists", resetOn: search).frame(minWidth: 200, maxWidth: 320)
            if let artist = artist.wrappedValue { TrackTable(tracks: store.tracks(artist: artist), title: artist, defaultSort: false, resetKey: artist) }
            else { ContentUnavailableView("Select an artist", systemImage: "music.mic").frame(maxWidth: .infinity) }
        }
    }
}

struct AlbumBrowser: View {
    @EnvironmentObject var store: LibraryStore
    var search: String = ""
    @AppStorage("mac.album") private var savedAlbum = ""   // AlbumKey.id
    private var album: Binding<AlbumKey?> {
        Binding(get: { store.albums.first { $0.id == savedAlbum } }, set: { savedAlbum = $0?.id ?? "" })
    }

    var body: some View {
        let q = SearchQuery(search)
        let list = q.isEmpty ? store.albums : store.albums.filter { q.matches(($0.album + " " + $0.artist).searchFolded) }
        HSplitView {
            List(list, selection: album) { a in
                VStack(alignment: .leading) { Text(a.album); Text(a.artist).font(.caption).foregroundStyle(.secondary) }.tag(a)
            }.rememberScroll("albums", resetOn: search).frame(minWidth: 220, maxWidth: 340)
            if let album = album.wrappedValue { TrackTable(tracks: store.tracks(album: album), title: album.album, defaultSort: false, resetKey: album.id) }
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
            HStack(spacing: 14) {
                ArtworkView(image: player.artwork, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "Not Playing").font(.headline).lineLimit(1)
                    Text(player.current.map { "\($0.displayArtist) — \($0.displayAlbum)" } ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(width: 220, alignment: .leading)
            }
            .contentShape(Rectangle())
            // Double-click the song to find it in Songs; right-click for more.
            .onTapGesture(count: 2) { if let t = currentTrack { model.reveal(t, in: .songs) } }
            .contextMenu {
                if let t = currentTrack {
                    Button("Show in Songs") { model.reveal(t, in: .songs) }
                    Button("Show in Folder") { model.reveal(t, in: .folder) }
                    Divider()
                    Button("Show in Finder") { model.revealInFinder(t) }
                }
            }
            .help(player.current == nil ? "" : "Double-click to show in Songs")
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
            WithPlaybackTime(clock: player.clock) { now in
                HStack {
                    Text((scrub ?? now).durationString).font(.caption).monospacedDigit()
                    Slider(value: Binding(get: { scrub ?? now }, set: { scrub = $0 }),
                           in: 0...max(player.duration, 1)) { editing in
                        if !editing, let s = scrub { player.seek(to: s); scrub = nil }
                    }
                    Text(player.duration.durationString).font(.caption).monospacedDigit()
                }
            }.frame(minWidth: 220, maxWidth: 360)
            Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1).frame(width: 80)
            Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }.buttonStyle(.plain)
                .popover(isPresented: $showQueue) { QueueView().frame(width: 340, height: 420) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private var currentTrack: Track? { player.current.map { model.store.track($0.relPath) ?? $0 } }

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

/// `.id` for a big table: changes when the user changes what the table shows (search, view,
/// folder, sort), so SwiftUI builds it fresh instead of diffing thousands of rows on the main thread.
enum TableIdentity {
    static func of(_ parts: String...) -> Int {
        var h = Hasher()
        parts.forEach { h.combine($0) }
        return h.finalize()
    }
}

/// Horizontal divider you can drag to resize the view above it. Shows the resize cursor on hover.
struct SplitDivider: View {
    @Binding var height: Double
    var minHeight: Double = 44
    var maxHeight: CGFloat
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in inside ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if start == nil { start = height }
                    height = min(max(start! + g.translation.height, minHeight), Double(max(maxHeight, CGFloat(minHeight))))
                }
                .onEnded { _ in start = nil })
    }
}

/// "Add to Sync" / "Remove from Sync" for songs or folders (ticks them in Sync & Devices).
struct SyncMenuItem: View {
    @EnvironmentObject var model: AppModel
    let paths: [String]
    var noun: String = ""

    var body: some View {
        if !paths.isEmpty {
            let allSynced = paths.allSatisfy(model.isSynced)
            Button {
                model.setSynced(paths, !allSynced)
            } label: {
                Label(allSynced ? "Remove \(noun.isEmpty ? "" : noun + " ")from iPhone Sync" : "Add \(noun.isEmpty ? "" : noun + " ")to iPhone Sync",
                      systemImage: allSynced ? "iphone.slash" : "iphone.and.arrow.forward")
            }
        }
    }
}

/// "Add to Playlist ▸" for one or more songs.
struct PlaylistMenu: View {
    @EnvironmentObject var model: AppModel
    let tracks: [Track]

    var body: some View {
        Menu("Add to Playlist") {
            ForEach(model.playlists) { p in Button(p.name) { model.addToPlaylist(p.id, tracks) } }
            if !model.playlists.isEmpty { Divider() }
            Button("New Playlist…") { if let n = Ask.text("New playlist") { model.createPlaylist(n, with: tracks) } }
        }
    }
}
