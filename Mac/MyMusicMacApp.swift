import SwiftUI

@main
struct MyMusicMacApp: App {
    @StateObject private var model = AppModel()

    init() { HangRecorder.shared.start() }

    var body: some Scene {
        WindowGroup("MyMusic") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.player)
                .environmentObject(model.yt)
                .environmentObject(model.web)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MyMusic") {
                    showAboutBox()
                }
            }
            CommandMenu("Controls") {
                Button("Play/Pause") { model.player.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                    .disabled(!model.isRootAvailable)
                Button("Next") { model.player.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(!model.isRootAvailable)
                Button("Previous") { model.player.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!model.isRootAvailable)
                Divider()
                Button("Rescan Library") { Task { await model.rescan() } }.keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isRootAvailable || model.isScanning)
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
    // remembered across launches: reopen in the section you last used
    @AppStorage("mac.section") private var savedSection = SidebarItem.songs.rawValue
    /// Sidebar selection: a SidebarItem's raw value, or "pl:<playlist id>".
    @State private var selectionKey: String?
    @State private var search = ""
    @AppStorage("mac.folderPath") private var folderPath = ""   // FolderBrowser's open folder

    private var selection: SidebarItem? {
        get { selectionKey.flatMap(SidebarItem.init(rawValue:)) }
        nonmutating set { selectionKey = newValue?.rawValue }
    }
    private var selectedPlaylist: SyncStore.Playlist? {
        guard let k = selectionKey, k.hasPrefix("pl:") else { return nil }
        return model.playlists.first { $0.id == String(k.dropFirst(3)) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectionKey) {
                Section("Library") {
                    ForEach([SidebarItem.songs, .folders, .artists, .albums]) { Label($0.rawValue, systemImage: $0.icon).tag($0.rawValue) }
                }
                Section("Smart") {
                    ForEach([SidebarItem.favorites, .mostPlayed, .recentlyPlayed, .recentlyAdded]) { Label($0.rawValue, systemImage: $0.icon).tag($0.rawValue) }
                }
                Section {
                    ForEach(model.playlists) { p in
                        Label(p.name, systemImage: "music.note.list").tag("pl:" + p.id)
                            .contextMenu {
                                Button("Rename…") { if let n = Ask.text("Rename playlist", initial: p.name) { model.renamePlaylist(p.id, n) } }
                                Button("Delete", role: .destructive) { model.deletePlaylist(p.id) }
                            }
                    }
                } header: {
                    HStack {
                        Text("Playlists")
                        Spacer()
                        Button { if let n = Ask.text("New playlist") { selectionKey = "pl:" + model.createPlaylist(n) } } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).help("New playlist")
                    }
                }
                Section("Manage") {
                    ForEach([SidebarItem.youtube, .duplicates, .stats, .sync]) { Label($0.rawValue, systemImage: $0.icon).tag($0.rawValue) }
                }
            }
            .disabled(!model.isRootAvailable)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    if model.isScanning { ProgressView().controlSize(.small) }
                    Text(model.scanStatus).font(.caption2).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            Group {
                if model.musicRoot == nil || !model.isRootAvailable {
                    WelcomeView()
                } else {
                    detail
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.isRootAvailable {
                    PlayerBar()
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: searchPrompt)
        .onAppear { if selectionKey == nil { selectionKey = savedSection.hasPrefix("pl:") || SidebarItem(rawValue: savedSection) != nil ? savedSection : SidebarItem.songs.rawValue } }
        .onChange(of: selectionKey) { _, new in if let new { savedSection = new } }
        .onChange(of: model.revealRequest) { _, r in
            // Navigate; the target TrackTable selects and scrolls once it shows the song.
            guard let r else { return }
            search = ""
            switch r.place {
            case .songs: selectionKey = SidebarItem.songs.rawValue
            case .folder:
                folderPath = (r.relPath as NSString).deletingLastPathComponent
                selectionKey = SidebarItem.folders.rawValue
            }
        }
        .toolbar {
            ToolbarItem { UserMenu() }
            ToolbarItem {
                if let p = model.activeSyncs.first {
                    // a sync is running: show its progress, click to open Sync & Devices
                    Button { selectionKey = SidebarItem.sync.rawValue } label: {
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
                    .disabled(!model.isRootAvailable || model.online.isEmpty)
                    .help(model.online.isEmpty ? "Open MyMusic on your iPhone to sync from here" : "Sync " + model.online.map(\.name).joined(separator: ", "))
                }
            }
            ToolbarItem {
                Button { Task { await model.rescan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.isScanning || !model.isRootAvailable)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let p = selectedPlaylist {
            TrackTable(tracks: store.filter(model.tracks(in: p), search), title: p.name, defaultSort: false,
                       resetKey: p.id + "\u{1}" + search, scrollKey: "pl:" + p.id, search: search, playlistID: p.id)
        } else {
            sectionDetail
        }
    }

    @ViewBuilder private var sectionDetail: some View {
        // The toolbar search filters whatever section is open (it used to replace it).
        switch selection ?? .songs {
        case .songs: TrackTable(tracks: store.search(search), title: search.isEmpty ? "Songs" : "Songs matching “\(search)”", resetKey: search,
                               scrollKey: "songs", search: search, revealPlace: search.isEmpty ? .songs : nil)
        case .folders: FolderBrowser(search: $search)
        case .artists: ArtistBrowser(search: search)
        case .albums: AlbumBrowser(search: search)
        case .favorites:
            TrackTable(tracks: store.filter(store.favorites, search), title: "Favorites", resetKey: search, scrollKey: "favorites", search: search)
                .toolbar {
                    ToolbarItem {
                        Toggle(isOn: $model.syncFavorites) { Label("Sync favorites to iPhone", systemImage: "iphone.and.arrow.forward") }
                            .help("Send all favorites to your iPhone, whichever folder they're in")
                    }
                }
        case .mostPlayed: TrackTable(tracks: store.filter(store.mostPlayed, search), title: "Most Played", defaultSort: false, resetKey: search, scrollKey: "mostPlayed", search: search)
        case .recentlyPlayed: TrackTable(tracks: store.filter(store.recentlyPlayed, search), title: "Recently Played", defaultSort: false, resetKey: search, scrollKey: "recentlyPlayed", search: search)
        case .recentlyAdded: TrackTable(tracks: store.filter(store.recentlyAdded, search), title: "Recently Added", defaultSort: false, resetKey: search, scrollKey: "recentlyAdded", search: search)
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

/// Toolbar menu: whose plays, favorites and playlists this Mac shows.
struct UserMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let current = model.users.first { $0.id == model.currentUser }
        Menu {
            ForEach(model.users) { u in
                Button { model.switchUser(u.id) } label: {
                    if u.id == model.currentUser { Label(u.name, systemImage: "checkmark") } else { Text(u.name) }
                }
            }
            Divider()
            Button("New User…") { if let n = Ask.text("New user", message: "Each user has their own favorites, play counts and playlists, on every device.") { model.switchUser(model.addUser(n)) } }
            if let c = current {
                Button("Rename \(c.name)…") { if let n = Ask.text("Rename user", initial: c.name) { model.renameUser(c.id, n) } }
                if c.id != SyncStore.defaultUserID {
                    Button("Remove \(c.name)", role: .destructive) { model.deleteUser(c.id) }
                }
            }
        } label: {
            Label(current?.name ?? "User", systemImage: "person.crop.circle")
        }
        .help("Whose favorites, play counts and playlists")
    }
}

private func showAboutBox() {
    var buildInfo = ""
    if let execURL = Bundle.main.executableURL,
       let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
       let date = attrs[.modificationDate] as? Date {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        buildInfo = "Build date: " + formatter.string(from: date)
    } else if let bundleURL = Bundle.main.bundleURL as URL?,
              let attrs = try? FileManager.default.attributesOfItem(atPath: bundleURL.path),
              let date = attrs[.creationDate] as? Date ?? attrs[.modificationDate] as? Date {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        buildInfo = "Build date: " + formatter.string(from: date)
    }

    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
    if !buildInfo.isEmpty {
        let credits = NSAttributedString(
            string: buildInfo,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        options[.credits] = credits
    }
    NSApplication.shared.orderFrontStandardAboutPanel(options: options)
}

/// Small modal text prompts (names for users and playlists).
enum Ask {
    @MainActor static func text(_ title: String, message: String = "", initial: String = "") -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = initial
        a.accessoryView = f
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = f.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}
