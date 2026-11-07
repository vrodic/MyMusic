import SwiftUI
import AppKit

struct TrackTable: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var store: LibraryStore
    let tracks: [Track]
    var title: String = ""
    var defaultSort = true
    /// What the rows depend on besides library growth (search text, folder…): part of the default scroll key.
    var resetKey: String = ""
    /// Which list this is, for remembering its scroll position (default: title + resetKey).
    var scrollKey: String? = nil
    /// The search text: changing it forgets the remembered scroll position.
    var search: String = ""
    /// Set on the list "Show in Songs" / "Show in Folder" should select the song in.
    var revealPlace: RevealRequest.Place? = nil
    /// Set when showing a playlist: adds Remove / Move to Top.
    var playlistID: String? = nil
    var persistSortKey: String? = nil
    @State private var sortOrder: [KeyPathComparator<Track>] = []
    @State private var selection = Set<Track.ID>()
    @State private var confirmFavorite = false
    @State private var confirmDelete = false
    @State private var tracksPendingDelete: [Track] = []
    @Environment(\.typeToSearch) private var typeToSearch

    init(tracks: [Track], title: String = "", defaultSort: Bool = true, resetKey: String = "",
         scrollKey: String? = nil, search: String = "", revealPlace: RevealRequest.Place? = nil,
         playlistID: String? = nil, persistSortKey: String? = nil) {
        self.tracks = tracks
        self.title = title
        self.defaultSort = defaultSort
        self.resetKey = resetKey
        self.scrollKey = scrollKey
        self.search = search
        self.revealPlace = revealPlace
        self.playlistID = playlistID
        self.persistSortKey = persistSortKey
        let initialSort: [KeyPathComparator<Track>]
        if let key = persistSortKey,
           let saved = UserDefaults.standard.string(forKey: key),
           !saved.isEmpty {
            initialSort = [KeyPathComparator<Track>].from(serialized: saved)
        } else {
            initialSort = []
        }
        _sortOrder = State(initialValue: initialSort)
    }

    @State private var sortMemo = SortMemo()

    private var sorted: [Track] {
        sortOrder.isEmpty ? tracks : sortMemo.sorted(tracks, by: sortOrder)
    }

    var body: some View {
        let rows = sorted
        TrackTableView(
            rows: rows, selection: $selection, sortOrder: $sortOrder, currentPath: player.current?.relPath,
            liveTrack: { store.track($0) },
            onToggleFavorite: toggleFavoriteTrack,
            onFavoriteHeaderClicked: { if tracks.count > 25 { confirmFavorite = true } else { toggleAllFavorites() } },
            onPlay: { play($0, in: rows) },
            onDeleteKey: { triggerShortcutDelete(rows: rows) },
            onTypeToSearch: typeToSearch,
            menuItems: { menuItems(for: $0, rows: rows) })
        .rememberScroll(scrollMemoryKey, resetOn: search)
        .onAppear {
            if let key = persistSortKey, let saved = UserDefaults.standard.string(forKey: key) {
                let loaded = [KeyPathComparator<Track>].from(serialized: saved)
                if sortOrder != loaded {
                    sortOrder = loaded
                }
            }
            handleReveal()
            if !selection.isEmpty && model.selectedTrackPaths != selection {
                model.selectedTrackPaths = selection
            }
        }
        .onChange(of: selection) { _, new in
            if model.selectedTrackPaths != new {
                model.selectedTrackPaths = new
            }
        }
        .onChange(of: model.revealRequest) { handleReveal() }
        .navigationTitle(title)
        .navigationSubtitle("\(tracks.count) songs")
        .onChange(of: sortOrder) { _, new in
            if let key = persistSortKey {
                UserDefaults.standard.set(new.serialize(), forKey: key)
            }
        }
        .confirmationDialog(allFavorite ? "Remove all \(tracks.count) songs in this list from favorites?" : "Mark all \(tracks.count) songs in this list as favorites?",
                            isPresented: $confirmFavorite, titleVisibility: .visible) {
            Button(allFavorite ? "Unfavorite All" : "Favorite All") { toggleAllFavorites() }
        }
        .confirmationDialog(
            tracksPendingDelete.count > 1
                ? "Are you sure you want to permanently delete these \(tracksPendingDelete.count) songs from disk and library?"
                : "Are you sure you want to permanently delete “\(tracksPendingDelete.first?.title ?? "this song")” from disk and library?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let toDelete = tracksPendingDelete
                tracksPendingDelete = []
                model.deleteSongs(toDelete)
            }
            Button("Cancel", role: .cancel) {
                tracksPendingDelete = []
            }
        } message: {
            Text("This will permanently remove the audio file from disk.")
        }
        .background {
            Button("") { triggerShortcutDelete(rows: rows) }
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0)
            Button("") { triggerShortcutDelete(rows: rows) }
                .keyboardShortcut(.delete, modifiers: .command)
                .opacity(0)
        }
    }

    private func menuItems(for ids: Set<Track.ID>, rows: [Track]) -> [NSMenuItem] {
        let picked = ids.count == 1 ? ids.compactMap { store.track($0) } : rows.filter { ids.contains($0.id) }
        var items: [NSMenuItem] = [
            ClosureMenuItem("Play") { play(picked.first, in: rows) },
            ClosureMenuItem("Play Next") { picked.reversed().forEach(player.playNext) },
            ClosureMenuItem("Add to Queue") { picked.forEach(player.addToQueue) },
            .separator(),
            ClosureMenuItem("Toggle Favorite") { picked.forEach(model.toggleFavorite) },
        ]
        let paths = picked.map(\.relPath)
        if !paths.isEmpty {
            let allSynced = paths.allSatisfy(model.isSynced)
            items.append(ClosureMenuItem(allSynced ? "Remove from iPhone Sync" : "Add to iPhone Sync",
                                         symbol: allSynced ? "iphone.slash" : "iphone.and.arrow.forward") { model.setSynced(paths, !allSynced) })
        }
        items.append(.separator())

        let playlists = NSMenu()
        for p in model.playlists { playlists.addItem(ClosureMenuItem(p.name) { model.addToPlaylist(p.id, picked) }) }
        if !model.playlists.isEmpty { playlists.addItem(.separator()) }
        playlists.addItem(ClosureMenuItem("New Playlist…") { if let n = Ask.text("New playlist") { model.createPlaylist(n, with: picked) } })
        let addToPlaylist = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        addToPlaylist.submenu = playlists
        items.append(addToPlaylist)

        if let pid = playlistID {
            items.append(ClosureMenuItem("Remove from Playlist") { model.removeFromPlaylist(pid, picked) })
            if let first = picked.first { items.append(ClosureMenuItem("Move to Top") { model.movePlaylistItem(pid, first, toTop: true) }) }
        }
        if let first = picked.first {
            items.append(ClosureMenuItem("Show in Folder") { model.reveal(first, in: .folder) })
            items.append(ClosureMenuItem("Show in Finder") { model.revealInFinder(first) })
        }
        items.append(.separator())
        items.append(ClosureMenuItem(picked.count > 1 ? "Delete \(picked.count) Songs" : "Delete Song") {
            if picked.count == 1 {
                model.deleteSongs(picked)
            } else {
                tracksPendingDelete = picked
                confirmDelete = true
            }
        })
        return items
    }

    private func triggerShortcutDelete(rows: [Track]) {
        let picked = rows.filter { selection.contains($0.id) }
        guard !picked.isEmpty else { return }
        tracksPendingDelete = picked
        confirmDelete = true
    }

    private var allFavorite: Bool { !tracks.isEmpty && tracks.allSatisfy { model.store.track($0.relPath)?.favorite ?? $0.favorite } }

    private func toggleFavoriteTrack(_ t: Track) {
        model.toggleFavorite(t)
    }

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
        // By path: `t` can be a fresher copy than the row (a favorite toggled since it was loaded).
        guard let t, let i = rows.firstIndex(where: { $0.relPath == t.relPath }) else { return }
        player.play(rows, startAt: i)
    }
}

enum TrackSortField: String, CaseIterable {
    case favorite, title, artist, album, time, plays, format, favorited, added, lastPlayed

    static func from(keyPath: AnyKeyPath) -> TrackSortField? {
        if keyPath == \Track.favoriteSort { return .favorite }
        if keyPath == \Track.title { return .title }
        if keyPath == \Track.displayArtist { return .artist }
        if keyPath == \Track.displayAlbum { return .album }
        if keyPath == \Track.durationSort { return .time }
        if keyPath == \Track.playCount { return .plays }
        if keyPath == \Track.fileExtension { return .format }
        if keyPath == \Track.favoritedSort { return .favorited }
        if keyPath == \Track.addedAt { return .added }
        if keyPath == \Track.lastPlayedSort { return .lastPlayed }
        return nil
    }

    func comparator(order: SortOrder) -> KeyPathComparator<Track> {
        switch self {
        case .favorite: return KeyPathComparator(\Track.favoriteSort, order: order)
        case .title: return KeyPathComparator(\Track.title, order: order)
        case .artist: return KeyPathComparator(\Track.displayArtist, order: order)
        case .album: return KeyPathComparator(\Track.displayAlbum, order: order)
        case .time: return KeyPathComparator(\Track.durationSort, order: order)
        case .plays: return KeyPathComparator(\Track.playCount, order: order)
        case .format: return KeyPathComparator(\Track.fileExtension, order: order)
        case .favorited: return KeyPathComparator(\Track.favoritedSort, order: order)
        case .added: return KeyPathComparator(\Track.addedAt, order: order)
        case .lastPlayed: return KeyPathComparator(\Track.lastPlayedSort, order: order)
        }
    }
}

extension Array where Element == KeyPathComparator<Track> {
    static func from(serialized: String) -> [KeyPathComparator<Track>] {
        serialized.split(separator: ",").compactMap { part in
            let pieces = part.split(separator: ":")
            guard pieces.count == 2,
                  let field = TrackSortField(rawValue: String(pieces[0])) else { return nil }
            let order: SortOrder = pieces[1] == "reverse" ? .reverse : .forward
            return field.comparator(order: order)
        }
    }

    func serialize() -> String {
        compactMap { comp in
            guard let field = TrackSortField.from(keyPath: comp.keyPath) else { return nil }
            return "\(field.rawValue):\(comp.order == .reverse ? "reverse" : "forward")"
        }.joined(separator: ",")
    }
}

enum FastDateFormatter {
    @MainActor private static let formatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()
    @MainActor private static var cache: [Int: String] = [:]

    @MainActor static func string(from timestamp: Double) -> String {
        guard timestamp > 0 else { return "" }
        let dayKey = Int(timestamp / 86400)
        if let cached = cache[dayKey] { return cached }
        let str = formatter.string(from: Date(timeIntervalSince1970: timestamp))
        cache[dayKey] = str
        return str
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

/// Keeps the last sort result: `body` runs several times per search and on unrelated updates, and
/// sorting a whole library by title takes far longer than checking that nothing changed.
private final class SortMemo {
    private var input: [Track] = []
    private var order: [KeyPathComparator<Track>] = []
    private var output: [Track] = []

    func sorted(_ tracks: [Track], by order: [KeyPathComparator<Track>]) -> [Track] {
        if order != self.order || tracks != input {
            input = tracks
            self.order = order
            output = tracks.sorted(using: order)
        }
        return output
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
