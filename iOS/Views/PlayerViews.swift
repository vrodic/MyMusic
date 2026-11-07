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
                    Text(t.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                        Text("\(live.displayArtist) — \(live.displayAlbum)").foregroundStyle(.secondary).lineLimit(1)
                        Text(live.folder).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Button { model.toggleFavorite(live) } label: {
                        Image(systemName: live.favorite ? "heart.fill" : "heart").font(.title2).foregroundStyle(.pink)
                    }
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
                Button { player.shuffle.toggle() } label: {
                    Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Color.accentColor : .secondary)
                }
                Spacer()
                RoutePicker().frame(width: 36, height: 36)
                Spacer()
                Button { showQueue = true } label: { Image(systemName: "list.bullet") }
                Spacer()
                Button {
                    let all = RepeatMode.allCases
                    player.repeatMode = all[(all.firstIndex(of: player.repeatMode)! + 1) % all.count]
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
                }
            }
            .font(.title3).padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
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
