import SwiftUI

struct DuplicatesView: View {
    var search: String = ""
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerEngine
    @State private var groups: [DuplicateGroup] = []
    @State private var scanning = false
    @State private var progress = ""
    @State private var scanned = false
    @State private var filter: DuplicateGroup.Kind?
    @State private var confirm = false
    @State private var result: String?

    private var visible: [DuplicateGroup] {
        let byKind = filter.map { k in groups.filter { $0.kind == k } } ?? groups
        let q = SearchQuery(search)
        return q.isEmpty ? byKind : byKind.filter { g in g.tracks.contains { q.matches($0.searchKey) } }
    }
    private var toRemove: [Track] { visible.flatMap { g in g.tracks.filter { $0.relPath != g.keep } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { Task { await scan() } } label: { Label(scanned ? "Rescan" : "Find Duplicates", systemImage: "doc.on.doc") }
                    .disabled(scanning || !model.isRootAvailable)
                if scanning { ProgressView().controlSize(.small); Text(progress).foregroundStyle(.secondary) }
                Spacer()
                if !groups.isEmpty {
                    Picker("", selection: $filter) {
                        Text("All (\(groups.count))").tag(DuplicateGroup.Kind?.none)
                        Text("Identical (\(groups.filter { $0.kind == .identical }.count))").tag(DuplicateGroup.Kind?.some(.identical))
                        Text("Same song (\(groups.filter { $0.kind == .sameSong }.count))").tag(DuplicateGroup.Kind?.some(.sameSong))
                    }.pickerStyle(.segmented).frame(width: 380)
                    Button(role: .destructive) { confirm = true } label: {
                        Label("Remove \(toRemove.count) extra copies…", systemImage: "trash")
                    }.disabled(toRemove.isEmpty)
                }
            }
            .padding(10)
            Divider()
            if groups.isEmpty {
                ContentUnavailableView(scanned ? "No duplicates found" : "Find duplicate songs",
                                       systemImage: scanned ? "checkmark.circle" : "doc.on.doc",
                                       description: Text("Finds byte-identical files, and the same song stored twice (e.g. an MP3 and a FLAC, or a YouTube download of a song you already own). You pick which copy stays; the rest go to the Trash and their play counts and favorites move to the copy you keep."))
            } else {
                List {
                    ForEach(visible) { g in
                        Section {
                            ForEach(g.tracks) { t in row(t, group: g) }
                        } header: {
                            HStack {
                                Text(g.tracks[0].title).font(.headline)
                                Text(g.kind.rawValue).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(g.kind == .identical ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: Capsule())
                                Spacer()
                                Button("Not duplicates – ignore") { groups.removeAll { $0.id == g.id } }
                                    .buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
        .confirmationDialog("Move \(toRemove.count) files to the Trash?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Play counts and favorites are merged into the copies you keep. If the volume has no Trash, files are moved into a hidden .duplicates folder in the music root instead. Synced iPhones drop the removed copies on their next sync.")
        }
        .alert(result ?? "", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) { Button("OK") {} }
    }

    private func row(_ t: Track, group g: DuplicateGroup) -> some View {
        let keep = g.keep == t.relPath
        let kbps = (t.duration ?? 0) > 0 ? Int(Double(t.size) * 8 / (t.duration! * 1000)) : 0
        return HStack(spacing: 10) {
            Button { setKeep(g, t.relPath) } label: {
                Image(systemName: keep ? "checkmark.circle.fill" : "trash.circle").font(.title3)
                    .foregroundStyle(keep ? .green : .red)
            }
            .buttonStyle(.plain)
            .help(keep ? "This copy is kept" : "This copy will be removed (click to keep this one instead)")
            VStack(alignment: .leading, spacing: 2) {
                Text(t.relPath).lineLimit(1).truncationMode(.middle).foregroundStyle(keep ? .primary : .secondary)
                Text("\(t.displayArtist) · \(t.fileExtension.uppercased()) · \(kbps) kbps · \(ByteCountFormatter.string(fromByteCount: t.size, countStyle: .file)) · \((t.duration ?? 0).durationString) · \(t.playCount) plays\(t.favorite ? " · ♥" : "")\(t.source == .youtube ? " · YouTube" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { player.play([t]) } label: { Image(systemName: "play.fill") }.buttonStyle(.plain).help("Preview")
            Button { model.revealInFinder(t) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help("Show in Finder")
        }
    }

    private func setKeep(_ g: DuplicateGroup, _ rel: String) {
        if let i = groups.firstIndex(where: { $0.id == g.id }) { groups[i].keep = rel }
    }

    private func scan() async {
        guard model.isRootAvailable, let root = model.musicRoot else { return }
        scanning = true
        let tracks = model.store.tracks
        groups = await Task.detached {
            await DuplicateFinder.find(tracks: tracks, root: root) { p in Task { @MainActor in progress = p } }
        }.value
        scanning = false; scanned = true
    }

    private func remove() async {
        let (removed, failed) = await model.removeDuplicates(visible)
        let removedIDs = Set(visible.map(\.id))
        groups.removeAll { removedIDs.contains($0.id) }
        result = "Removed \(removed) files" + (failed.isEmpty ? "." : ". \(failed.count) failed:\n" + failed.prefix(5).joined(separator: "\n"))
    }
}
