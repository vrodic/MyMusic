import SwiftUI

enum AppTab: Hashable { case library, folders, search, sync, settings }
enum LibraryRoute: Hashable { case songs }
struct FolderRoute: Hashable { let path: String }

/// Which tab is open and what each navigation stack shows, so other screens (Now Playing) can
/// jump to a song in the Songs list or in its folder.
@MainActor
final class Navigator: ObservableObject {
    @Published var tab: AppTab = .library
    @Published var libraryPath = NavigationPath()
    @Published var folderPath: [FolderRoute] = []
    /// The song just jumped to: its list scrolls to it and highlights it for a moment.
    @Published private(set) var revealed: String?

    func showInSongs(_ t: Track) {
        tab = .library
        libraryPath = NavigationPath([LibraryRoute.songs])
        highlight(t)
    }

    func showInFolder(_ t: Track) {
        tab = .folders
        let parts = t.folder.split(separator: "/").map(String.init)
        folderPath = parts.indices.map { FolderRoute(path: parts[...$0].joined(separator: "/")) }
        highlight(t)
    }

    private func highlight(_ t: Track) {
        let p = t.relPath
        revealed = p
        Task {
            try? await Task.sleep(for: .seconds(3))
            if revealed == p { withAnimation { revealed = nil } }
        }
    }
}

/// A List that scrolls to the song the Navigator just revealed, when that song is in it.
struct RevealingList<Content: View>: View {
    @EnvironmentObject var nav: Navigator
    let ids: [String]
    @ViewBuilder let content: Content

    var body: some View {
        ScrollViewReader { proxy in
            List { content }
                .onAppear { scroll(proxy) }
                .onChange(of: nav.revealed) { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let r = nav.revealed, ids.contains(r) else { return }
        // wait for the sheet to close and the pushed list to lay out; again in case it wasn't ready
        for delay in [0.35, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard nav.revealed == r else { return }
                withAnimation { proxy.scrollTo(r, anchor: .center) }
            }
        }
    }
}
