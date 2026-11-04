import SwiftUI

/// Library-tab section: the current user's playlists.
struct PlaylistsSection: View {
    @EnvironmentObject var model: IOSModel
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Section {
            ForEach(model.playlists) { p in
                NavigationLink { PlaylistView(playlistID: p.id) } label: {
                    HStack {
                        Label(p.name, systemImage: "music.note.list")
                        Spacer()
                        Text("\(p.items.count)").foregroundStyle(.secondary)
                    }
                }
            }
            Button { name = ""; naming = true } label: { Label("New Playlist", systemImage: "plus") }
        } header: { Text("Playlists") }
        .alert("New Playlist", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Create") { if !name.trimmingCharacters(in: .whitespaces).isEmpty { model.createPlaylist(name) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// A playlist: songs on the phone play from the phone, the rest stream from the web player.
struct PlaylistView: View {
    @EnvironmentObject var model: IOSModel
    @EnvironmentObject var web: WebLibrary
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var store: LibraryStore
    let playlistID: String
    @State private var renaming = false
    @State private var name = ""

    private var playlist: SyncStore.Playlist? { model.playlists.first { $0.id == playlistID } }

    /// In order; local copy if the phone has it, otherwise the server's (streamed).
    private var songs: [Track] {
        guard let p = playlist else { return [] }
        let local = Dictionary(store.tracks.map { (SyncStore.key($0.relPath), $0) }, uniquingKeysWith: { a, _ in a })
        let remote = Dictionary(web.serverTracks.map { (SyncStore.key($0.relPath), $0) }, uniquingKeysWith: { a, _ in a })
        return p.items.compactMap { local[$0] ?? remote[$0] }
    }

    var body: some View {
        let list = songs
        List {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                Button { player.play(list, startAt: i) } label: {
                    HStack {
                        TrackRowLabel(track: t, isCurrent: player.current?.relPath == t.relPath)
                        if t.origin == .remote { Image(systemName: "icloud").font(.caption).foregroundStyle(.secondary) }
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if t.origin == .remote {
                        Button { Task { await web.download([t]) } } label: { Label("Download to iPhone", systemImage: "arrow.down.circle") }
                    } else {
                        TrackMenu(track: t)
                    }
                }
            }
            .onDelete { idx in edit { $0.remove(atOffsets: idx) } }
            .onMove { from, to in edit { $0.move(fromOffsets: from, toOffset: to) } }
            if let p = playlist, list.count < p.items.count {
                Text("\(p.items.count - list.count) songs aren't on this iPhone or the server right now.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { player.shuffle = false; player.play(list) } label: { Image(systemName: "play.fill") }.disabled(list.isEmpty)
                Menu {
                    Button { player.shuffle = true; player.play(list.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
                    let remote = list.filter { $0.origin == .remote }
                    if !remote.isEmpty {
                        Button { Task { await web.download(remote) } } label: { Label("Download \(remote.count) to iPhone", systemImage: "arrow.down.circle") }
                    }
                    Button { name = playlist?.name ?? ""; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { if var p = playlist { p.deleted = true; model.savePlaylist(p) } } label: { Label("Delete Playlist", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
                EditButton()
            }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Save") { if var p = playlist, !name.isEmpty { p.name = name; model.savePlaylist(p) } }
            Button("Cancel", role: .cancel) {}
        }
        .overlay { if list.isEmpty { ContentUnavailableView("Empty playlist", systemImage: "music.note.list", description: Text("Long-press a song → Add to Playlist.")) } }
    }

    private func edit(_ change: (inout [Track]) -> Void) {
        guard var p = playlist else { return }
        var list = songs
        change(&list)
        // songs not available right now keep their place at the end
        let shown = Set(songs.map { SyncStore.key($0.relPath) })
        p.items = list.map { SyncStore.key($0.relPath) } + p.items.filter { !shown.contains($0) }
        model.savePlaylist(p)
    }
}

/// "Add to Playlist" menu for a song (long-press menus).
struct AddToPlaylistMenu: View {
    @EnvironmentObject var model: IOSModel
    let tracks: [Track]
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Menu {
            ForEach(model.playlists) { p in Button(p.name) { model.addToPlaylist(p.id, tracks) } }
            Button { model.createPlaylist(tracks.first.map { "\($0.displayArtist) mix" } ?? "New Playlist", with: tracks) } label: {
                Label("New Playlist", systemImage: "plus")
            }
        } label: { Label("Add to Playlist", systemImage: "music.note.list") }
    }
}
