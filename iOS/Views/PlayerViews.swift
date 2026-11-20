import AVKit
import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerEngine
    @Binding var showNowPlaying: Bool

    var body: some View {
        if let t = player.current {
            HStack(spacing: 12) {
                ArtworkView(image: player.artwork, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    if let error = player.playbackError {
                        Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
                    } else {
                        Text(t.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3) }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                WithPlaybackTime(clock: player.clock) { now in
                    GeometryReader { g in
                        Rectangle().fill(Color.accentColor).frame(width: g.size.width * (player.duration > 0 ? now / player.duration : 0), height: 2)
                    }
                }.frame(height: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture { showNowPlaying = true }
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var model: IOSModel
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var nav: Navigator
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?
    @State private var showQueue = false

    var body: some View {
        // A plain page when it fits. Only a long title that makes it too tall needs scrolling.
        ViewThatFits(in: .vertical) {
            page
            ScrollView { page.containerRelativeFrame(.horizontal) }
        }
        .sheet(isPresented: $showQueue) { NavigationStack { QueueView() } }
        .presentationDragIndicator(.hidden)
    }

    private var page: some View {
        VStack(spacing: 22) {
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 8)
            Spacer(minLength: 0)
            ArtworkView(image: player.artwork, size: 300).shadow(radius: 16)
            if let t = player.current {
                let live = store.track(t.relPath) ?? t
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(live.title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                        if let error = player.playbackError {
                            Text(error).foregroundStyle(.orange).lineLimit(1)
                        } else {
                            Text("\(live.displayArtist) — \(live.displayAlbum)").foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(live.folder).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Button { model.toggleFavorite(live) } label: {
                        Image(systemName: live.favorite ? "heart.fill" : "heart").font(.title2).foregroundStyle(.pink)
                    }
                    songMenu(live)
                }
            }
            WithPlaybackTime(clock: player.clock) { now in
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { scrub ?? now }, set: { scrub = $0 }), in: 0...max(player.duration, 1)) { editing in
                        if !editing, let s = scrub { player.seek(to: s); scrub = nil }
                    }
                    HStack {
                        Text((scrub ?? now).durationString)
                        Spacer()
                        Text("-" + max(0, player.duration - (scrub ?? now)).durationString)
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 40) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 68)) }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
            }
            .font(.largeTitle).buttonStyle(.plain)
            HStack {
                PlaybackModeMenu()
                Spacer()
                RoutePicker().frame(width: 36, height: 36)
                Button { showQueue = true } label: { Image(systemName: "list.bullet") }.padding(.leading, 12)
            }
            .font(.title3).padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }
}

extension NowPlayingView {
    /// Find the playing song in the library. Streamed songs (not on this iPhone) aren't in it.
    private func songMenu(_ t: Track) -> some View {
        let onDevice = store.track(t.relPath) != nil
        return Menu {
            Button { dismiss(); nav.showInSongs(t) } label: { Label("Show in Songs", systemImage: "music.note.list") }
                .disabled(!onDevice)
            Button { dismiss(); nav.showInFolder(t) } label: { Label("Show in Folder", systemImage: "folder") }
                .disabled(!onDevice)
            AddToPlaylistMenu(tracks: [t])
        } label: {
            Image(systemName: "ellipsis.circle").font(.title2).padding(.leading, 8)
        }
        .menuOrder(.fixed)
    }
}

/// Shuffle and repeat in one menu that says, in words, what happens next.
struct PlaybackModeMenu: View {
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        Menu {
            Section("Order") {
                option("In Order", "arrow.right", !player.shuffle) { player.shuffle = false }
                option("Shuffle", "shuffle", player.shuffle) { player.shuffle = true }
            }
            Section("When a song ends") {
                option("Play Next, Stop at End", "forward.end", player.repeatMode == .off) { player.repeatMode = .off }
                option("Play Next, Repeat All", "repeat", player.repeatMode == .all) { player.repeatMode = .all }
                option("Repeat This Song", "repeat.1", player.repeatMode == .one) { player.repeatMode = .one }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(summary).font(.subheadline.weight(.medium)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(isDefault ? Color.primary : Color.accentColor)
            .background(.secondary.opacity(0.15), in: Capsule())
        }
        .menuOrder(.fixed)
    }

    /// A checkmarked menu row (a Toggle), so the section titles stay visible.
    private func option(_ title: String, _ icon: String, _ on: Bool, _ select: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { if $0 { select() } })) { Label(title, systemImage: icon) }
    }

    private var isDefault: Bool { !player.shuffle && player.repeatMode == .off }
    private var icon: String {
        switch player.repeatMode {
        case .one: "repeat.1"
        case .all: player.shuffle ? "shuffle" : "repeat"
        case .off: player.shuffle ? "shuffle" : "arrow.right"
        }
    }
    private var summary: String {
        switch player.repeatMode {
        case .one: "Repeat This Song"
        case .all: player.shuffle ? "Shuffle · Repeat All" : "In Order · Repeat All"
        case .off: player.shuffle ? "Shuffle" : "In Order"
        }
    }
}

struct QueueView: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) var dismiss
    var body: some View {
        List {
            if let cur = player.current { Section("Now Playing") { TrackRowLabel(track: cur, isCurrent: true) } }
            Section("Up Next") {
                ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, t in
                    Button { player.jump(to: player.index + 1 + i) } label: { TrackRowLabel(track: t) }.buttonStyle(.plain)
                }
                .onMove { player.moveInQueue(from: $0, to: $1) }
                .onDelete { player.removeFromQueue(at: $0) }
            }
        }
        .toolbar { EditButton(); Button("Done") { dismiss() } }
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
