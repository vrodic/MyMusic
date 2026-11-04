import SwiftUI

/// Songs on the web player's server that aren't on this iPhone: browse by folder, stream, download.
struct ServerSongsView: View {
    @EnvironmentObject var web: WebLibrary
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var store: LibraryStore   // redraw when downloads land
    let path: String
    @State private var query = ""
    @State private var confirmAll = false

    var body: some View {
        let all = web.notOnPhone
        let root = FolderNode.build(all)
        let node = root.node(at: path) ?? root
        let q = SearchQuery(query)
        let folders = q.isEmpty ? node.subfolders : node.searchFolders(q)
        let tracks = q.isEmpty ? node.tracks : filter(node.allTracks, q)
        let scope = q.isEmpty ? node.allTracks : tracks
        List {
            if !folders.isEmpty {
                Section(q.isEmpty ? "" : "Folders") {
                    ForEach(folders) { f in
                        NavigationLink { ServerSongsView(path: f.path) } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.name)
                                    if !q.isEmpty { Text(f.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                                }
                                Spacer()
                                Text("\(f.totalTracks)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button { player.play(f.allTracks) } label: { Label("Stream", systemImage: "play") }
                            Button { Task { await web.download(f.allTracks) } } label: {
                                Label("Download \(f.totalTracks) Songs", systemImage: "arrow.down.circle")
                            }
                        }
                    }
                }
            }
            if !tracks.isEmpty {
                Section(q.isEmpty ? "" : "Songs") {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                        Button { player.play(tracks, startAt: i) } label: {
                            HStack {
                                TrackRowLabel(track: t, isCurrent: player.current?.relPath == t.relPath)
                                if web.downloading.contains(t.relPath) { ProgressView().controlSize(.small) }
                                else { Image(systemName: "icloud").font(.caption).foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button { Task { await web.download([t]) } } label: { Image(systemName: "arrow.down.circle") }.tint(.blue)
                            Button { player.addToQueue(t) } label: { Image(systemName: "text.append") }.tint(.indigo)
                        }
                        .contextMenu {
                            Button { Task { await web.download([t]) } } label: { Label("Download to iPhone", systemImage: "arrow.down.circle") }
                            Button { player.playNext(t) } label: { Label("Play Next", systemImage: "text.insert") }
                            Button { player.addToQueue(t) } label: { Label("Add to Queue", systemImage: "text.append") }
                            Button { web.setFavorite(t, !t.favorite) } label: {
                                Label(t.favorite ? "Unfavorite" : "Favorite", systemImage: t.favorite ? "heart.slash" : "heart")
                            }
                        }
                    }
                }
            }
            if !web.downloadErrors.isEmpty {
                Section("Download problems") { ForEach(web.downloadErrors.suffix(5), id: \.self) { Text($0).font(.caption) } }
            }
        }
        .navigationTitle(node.path.isEmpty ? "On \(web.name)" : node.name)
        .searchable(text: $query, prompt: "Search songs on \(web.name)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { player.shuffle = false; player.play(scope) } label: { Image(systemName: "play.fill") }.disabled(scope.isEmpty)
                Menu {
                    Button { player.shuffle = true; player.play(scope.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
                    Button { confirmAll = true } label: { Label("Download All \(scope.count)", systemImage: "arrow.down.circle") }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(scope.isEmpty)
            }
        }
        .confirmationDialog("Download \(scope.count) songs (\(ByteCountFormatter.string(fromByteCount: scope.reduce(0) { $0 + $1.size }, countStyle: .file))) to this iPhone?",
                            isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Download") { Task { await web.download(scope) } }
        }
        .overlay {
            if all.isEmpty { ContentUnavailableView("Everything's on your iPhone", systemImage: "checkmark.circle") }
            else if !q.isEmpty && folders.isEmpty && tracks.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .refreshable { await web.refresh(force: true) }
        .safeAreaInset(edge: .bottom) {
            if !web.downloading.isEmpty {
                Label("Downloading \(web.downloading.count)…", systemImage: "arrow.down.circle")
                    .font(.footnote).padding(8).frame(maxWidth: .infinity).background(.thinMaterial)
            }
        }
    }

    private func filter(_ list: [Track], _ q: SearchQuery) -> [Track] {
        list.filter { q.matches($0.searchKey) }
    }
}

/// Library-tab row: how many songs the web player has that this phone doesn't.
struct ServerSection: View {
    @EnvironmentObject var web: WebLibrary
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        if web.info != nil {
            let missing = web.notOnPhone
            Section {
                NavigationLink { ServerSongsView(path: "") } label: {
                    HStack {
                        Label("Not on iPhone", systemImage: "icloud.and.arrow.down")
                        Spacer()
                        Text("\(missing.count)").foregroundStyle(.secondary)
                    }
                }
            } header: { Text("On \(web.name)") } footer: {
                Text("Stream them over Wi-Fi, or download the ones you want to keep on the phone.")
            }
        }
    }
}
