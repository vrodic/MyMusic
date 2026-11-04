import SwiftUI

struct YouTubeView: View {
    @EnvironmentObject var yt: YouTubeManager
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var store: LibraryStore   // redraw hearts when favorites change
    @State private var selection = Set<YTItem.ID>()
    var search: String = ""
    @AppStorage("mac.ytFilter") private var filter: Filter = .all
    @State private var showLog = false
    @State private var confirmFavorite = false
    @State private var sortOrder: [KeyPathComparator<YTItem>] = [KeyPathComparator(\.playlistIndex)]

    enum Filter: String, CaseIterable { case all = "All", queued = "Queued", done = "Downloaded", failed = "Failed", skipped = "Skipped" }

    private var rows: [YTItem] {
        let f: [YTItem]
        switch filter {
        case .all: f = yt.items
        case .queued: f = yt.items.filter { $0.priority != .skip && ($0.status == .pending || $0.status == .downloading) }
        case .done: f = yt.items.filter { $0.status == .done }
        case .failed: f = yt.items.filter { $0.status == .failed }
        case .skipped: f = yt.items.filter { $0.priority == .skip && $0.status != .done }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        let query = SearchQuery(q)
        let matched = query.isEmpty ? f : f.filter { $0.videoID == q || query.matches(yt.searchKey($0)) }
        return matched.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(10)
            if let err = yt.lastError { errorBanner(err) }
            Divider()
            let rows = rows
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("♥", value: \.favoriteSort) { i in
                    let fav = model.isFavorite(i)
                    Button { model.setYTFavorite([i], !fav) } label: {
                        Image(systemName: fav ? "heart.fill" : "heart").foregroundStyle(fav ? .pink : .secondary)
                    }.buttonStyle(.plain)
                }.width(22)
                TableColumn("#", value: \.playlistIndex) { Text("\($0.playlistIndex + 1)").monospacedDigit().foregroundStyle(.secondary) }.width(40)
                TableColumn("Title", value: \.title) { i in
                    HStack {
                        Text(i.title)
                        if !i.inPlaylist { Text("unliked").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
                    }
                }
                TableColumn("Artist / Channel") { Text($0.uploader ?? "") }
                TableColumn("Time") { Text(($0.duration ?? 0).durationString).monospacedDigit() }.width(55)
                TableColumn("Status") { i in statusView(i) }.width(130)
                TableColumn("Priority", value: \.priority.rawValue) { i in
                    Picker("", selection: Binding(get: { i.priority }, set: { yt.setPriority([i.id], $0) })) {
                        ForEach(YTPriority.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().disabled(i.status == .done)
                }.width(150)
            }
            .id(TableIdentity.of(filter.rawValue, search, "\(sortOrder)"))
            .contextMenu(forSelectionType: YTItem.ID.self) { ids in
                Menu("Priority") {
                    ForEach(YTPriority.allCases.reversed()) { p in Button(p.label) { yt.setPriority(ids, p) } }
                }
                let picked = rows.filter { ids.contains($0.id) }
                let allFav = !picked.isEmpty && picked.allSatisfy(model.isFavorite)
                Button(allFav ? "Remove from Favorites" : "Add to Favorites") { model.setYTFavorite(picked, !allFav) }
                Divider()
                Button("Download Now") { yt.downloadNow(rows.filter { ids.contains($0.id) }.map(\.id)) }
                    .help("Downloads right away, even while paused or throttled")
                Button("Retry Download") { yt.retry(ids) }
                if let id = ids.first, let item = yt.items.first(where: { $0.id == id }), let rel = item.relPath,
                   let t = model.store.track(rel) {
                    Button("Play") { player.play([t]) }
                    Button("Show in Finder") { model.revealInFinder(t) }
                    SyncMenuItem(paths: rows.filter { ids.contains($0.id) }.compactMap(\.relPath))
                }
                Button("Open on YouTube") {
                    if let id = ids.first, let u = URL(string: "https://music.youtube.com/watch?v=\(id)") { NSWorkspace.shared.open(u) }
                }
            } primaryAction: { ids in
                // Double-click: play if downloaded, otherwise download it now (ignores pause and throttling).
                if ids.count == 1, let id = ids.first, let item = yt.items.first(where: { $0.id == id }),
                   item.status == .done, let rel = item.relPath, let t = model.store.track(rel) {
                    player.play([t])
                } else {
                    yt.downloadNow(rows.filter { ids.contains($0.id) }.map(\.id))
                }
            }
        }
        .overlay {
            if !yt.items.isEmpty && !search.isEmpty && !SearchQuery(search).isEmpty && rowsAreEmpty {
                ContentUnavailableView.search(text: search)
            } else if yt.items.isEmpty {
                ContentUnavailableView {
                    Label(yt.isIndexing ? "Indexing your liked music…" : "No liked songs indexed yet", systemImage: "play.rectangle")
                } description: {
                    Text(yt.lastError == nil
                         ? "Uses your YouTube login from \(yt.cookiesBrowser.hasPrefix("file:") ? "a cookies.txt file" : yt.cookiesBrowser.capitalized). Change it in Settings (⌘,)."
                         : "Indexing failed. See the message above.")
                } actions: {
                    Button("Refresh Liked") { Task { await yt.refreshLiked() } }.disabled(yt.isIndexing)
                }
            }
        }
        .onChange(of: sortOrder) { old, new in
            // ♥ header = favorite every song currently listed (respects filter + search)
            guard new.first?.keyPath == \YTItem.favoriteSort else { return }
            sortOrder = old.filter { $0.keyPath != \YTItem.favoriteSort }
            if rows.count > 25 { confirmFavorite = true } else { toggleAllFavorites() }
        }
        .confirmationDialog(confirmFavorite ? (allRowsFavorite ? "Remove all \(rows.count) listed songs from favorites?" : "Mark all \(rows.count) listed songs as favorites?") : "",
                            isPresented: $confirmFavorite, titleVisibility: .visible) {
            Button(allRowsFavorite ? "Unfavorite All" : "Favorite All") { toggleAllFavorites() }
        } message: {
            Text("Songs that aren't downloaded yet get Maximum priority.")
        }
        .navigationTitle("YouTube Liked Music")
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading) {
                ScrollView { Text(yt.log.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Close") { showLog = false }.keyboardShortcut(.defaultAction) }
            }.padding().frame(width: 640, height: 420)
        }
    }

    private var header: some View {
        let c = yt.counts
        return HStack(spacing: 12) {
            Button { Task { await yt.refreshLiked() } } label: { Label("Refresh Liked", systemImage: "arrow.clockwise") }
                .disabled(yt.isIndexing)
            Button { yt.togglePause() } label: {
                Label(yt.paused ? "Resume Downloads" : "Pause Downloads", systemImage: yt.paused ? "play.fill" : "pause.fill")
            }
            if yt.isIndexing { ProgressView().controlSize(.small) }
            if yt.isCoolingDown {
                Button("Resume Now") { yt.endCooldown() }.help("Ignore YouTube's rate limit and continue the queue")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(yt.statusLine.isEmpty ? (yt.waitReason ?? (yt.paused ? "Paused – double-click a song to download it anyway" : "Idle")) : yt.statusLine)
                    .lineLimit(1)
                if !yt.forcedQueue.isEmpty { Text("\(yt.forcedQueue.count) requested").font(.caption).foregroundStyle(.secondary) }
                if yt.currentID != nil { ProgressView(value: yt.currentProgress).frame(width: 240) }
            }
            Spacer()
            Text("\(c[.done] ?? 0) done · \(c[.pending] ?? 0) pending · \(c[.failed] ?? 0) failed").foregroundStyle(.secondary).font(.caption)
            Picker("", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).frame(width: 380)
            Button { showLog = true } label: { Image(systemName: "doc.text.magnifyingglass") }.help("Download log")
        }
    }

    // computed only when actually needed (the dialog), not on every redraw
    private var allRowsFavorite: Bool { let r = rows; return !r.isEmpty && r.allSatisfy(model.isFavorite) }
    private var rowsAreEmpty: Bool { rows.isEmpty }
    private func toggleAllFavorites() { model.setYTFavorite(rows, !allRowsFavorite) }

    private func errorBanner(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(err).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing) {
                Button("Open Full Disk Access…") { NSWorkspace.shared.open(YouTubeManager.fullDiskAccessURL) }
                SettingsLink { Text("Choose Browser…") }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }

    @ViewBuilder private func statusView(_ i: YTItem) -> some View {
        switch i.status {
        case .done: Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading:
            if yt.currentID == i.id { ProgressView(value: yt.currentProgress).help("Downloading") } else { Text("Downloading") }
        case .failed: Label("Failed (\(i.attempts))", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(i.error ?? "")
        case .pending:
            if yt.forcedQueue.contains(i.id) { Label("Up next", systemImage: "arrow.down.circle").foregroundStyle(Color.accentColor) }
            else { Text(i.priority == .skip ? "Skipped" : "Queued").foregroundStyle(.secondary) }
        }
    }
}
