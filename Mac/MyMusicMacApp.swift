import SwiftUI

@main
struct MyMusicMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MyMusic") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.player)
                .environmentObject(model.yt)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandMenu("Controls") {
                Button("Play/Pause") { model.player.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("Next") { model.player.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous") { model.player.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Rescan Library") { Task { await model.rescan() } }.keyboardShortcut("r", modifiers: .command)
            }
        }
        Settings {
            MacSettingsView().environmentObject(model).environmentObject(model.yt)
        }
    }
}

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case songs = "Songs", folders = "Folders", artists = "Artists", albums = "Albums"
    case favorites = "Favorites", mostPlayed = "Most Played", recentlyPlayed = "Recently Played", recentlyAdded = "Recently Added"
    case youtube = "YouTube Liked", duplicates = "Duplicates", stats = "Statistics", sync = "Sync & Devices"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .songs: "music.note"
        case .folders: "folder"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .favorites: "heart"
        case .mostPlayed: "flame"
        case .recentlyPlayed: "clock"
        case .recentlyAdded: "plus.circle"
        case .youtube: "play.rectangle"
        case .duplicates: "doc.on.doc"
        case .stats: "chart.bar"
        case .sync: "iphone.and.arrow.forward"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: LibraryStore
    @State private var selection: SidebarItem? = .songs
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    ForEach([SidebarItem.songs, .folders, .artists, .albums]) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
                Section("Smart") {
                    ForEach([SidebarItem.favorites, .mostPlayed, .recentlyPlayed, .recentlyAdded]) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
                Section("Manage") {
                    ForEach([SidebarItem.youtube, .duplicates, .stats, .sync]) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    if model.isScanning { ProgressView().controlSize(.small) }
                    Text(model.scanStatus).font(.caption2).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            Group {
                if model.musicRoot == nil {
                    ContentUnavailableView {
                        Label("Choose your music folder", systemImage: "folder.badge.plus")
                    } description: {
                        Text("MyMusic indexes everything under the root folder. YouTube downloads go into <root>/yt.")
                    } actions: {
                        Button("Choose Music Root…") { model.chooseRoot() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    detail
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBar() }
        }
        .searchable(text: $search, placement: .toolbar, prompt: searchPrompt)
        .toolbar {
            ToolbarItem {
                if let p = model.activeSyncs.first {
                    // a sync is running: show its progress, click to open Sync & Devices
                    Button { selection = .sync } label: {
                        HStack(spacing: 6) {
                            if p.total > 0 { ProgressView(value: p.fraction).progressViewStyle(.circular).controlSize(.small) }
                            else { ProgressView().controlSize(.small) }
                            Text(p.total > 0 ? "\(p.done)/\(p.total)" : "Syncing…").monospacedDigit()
                        }
                    }
                    .help("\(p.deviceName): \(p.message)")
                } else if !model.syncRequested.isEmpty {
                    ProgressView().controlSize(.small).help("Waiting for iPhone to start syncing…")
                } else {
                    Button { model.online.forEach { model.requestSync($0.id) } } label: {
                        Label("Sync iPhone", systemImage: "iphone.and.arrow.forward")
                    }
                    .disabled(model.online.isEmpty)
                    .help(model.online.isEmpty ? "Open MyMusic on your iPhone to sync from here" : "Sync " + model.online.map(\.name).joined(separator: ", "))
                }
            }
            ToolbarItem {
                Button { Task { await model.rescan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.isScanning || model.musicRoot == nil)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        // The toolbar search filters whatever section is open (it used to replace it).
        switch selection ?? .songs {
        case .songs: TrackTable(tracks: store.search(search), title: search.isEmpty ? "Songs" : "Songs matching “\(search)”")
        case .folders: FolderBrowser(search: $search)
        case .artists: ArtistBrowser(search: search)
        case .albums: AlbumBrowser(search: search)
        case .favorites:
            TrackTable(tracks: store.filter(store.favorites, search), title: "Favorites")
                .toolbar {
                    ToolbarItem {
                        Toggle(isOn: $model.syncFavorites) { Label("Sync favorites to iPhone", systemImage: "iphone.and.arrow.forward") }
                            .help("Send all favorites to your iPhone, whichever folder they're in")
                    }
                }
        case .mostPlayed: TrackTable(tracks: store.filter(store.mostPlayed, search), title: "Most Played", defaultSort: false)
        case .recentlyPlayed: TrackTable(tracks: store.filter(store.recentlyPlayed, search), title: "Recently Played", defaultSort: false)
        case .recentlyAdded: TrackTable(tracks: store.filter(store.recentlyAdded, search), title: "Recently Added", defaultSort: false)
        case .youtube: YouTubeView(search: search)
        case .duplicates: DuplicatesView(search: search)
        case .stats: StatsView()
        case .sync: SyncView(search: $search)
        }
    }

    private var searchPrompt: String {
        switch selection ?? .songs {
        case .youtube: "Search liked songs"
        case .folders: "Search folders and files"
        case .sync: "Find folders or songs to sync"
        case .artists: "Search artists"
        case .albums: "Search albums"
        case .duplicates: "Search duplicates"
        case .stats: "Search library"
        default: "Search \((selection ?? .songs).rawValue.lowercased())"
        }
    }
}
