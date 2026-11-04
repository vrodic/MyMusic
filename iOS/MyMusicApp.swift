import SwiftUI

@main
struct MyMusicApp: App {
    @StateObject private var model = IOSModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.player)
                .environmentObject(model.browser)
                .environmentObject(model.sync)
                .environmentObject(model.web)
                .onOpenURL { url in Task { await model.importItems([url]) } }
                .onChange(of: phase) { _, p in
                    if p == .active {
                        Task { await model.scanLocal(); await model.web.refresh() }
                        model.sync.startListening(browser: model.browser)
                    } else if p == .background && !model.player.isPlaying && !model.sync.isSyncing {
                        // iOS suspends us anyway; reconnect when we come back
                        model.sync.stopListening()
                    }
                }
                .task { model.sync.startListening(browser: model.browser) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var player: PlayerEngine
    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            NavigationStack { LibraryHome() }.withMiniPlayer($showNowPlaying)
                .tabItem { Label("Library", systemImage: "music.note.house") }
            NavigationStack { FolderView(path: "") }.withMiniPlayer($showNowPlaying)
                .tabItem { Label("Folders", systemImage: "folder") }
            NavigationStack { SearchView() }.withMiniPlayer($showNowPlaying)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { SyncView() }.withMiniPlayer($showNowPlaying)
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
    }
}

extension View {
    func withMiniPlayer(_ show: Binding<Bool>) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer(showNowPlaying: show) }
    }
}
