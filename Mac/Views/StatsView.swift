import Charts
import SwiftUI

struct StatsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var yt: YouTubeManager

    struct Combined: Identifiable { let track: Track; let plays: Int; var id: String { track.relPath } }
    struct Bucket: Identifiable { let name: String; let count: Int; let bytes: Int64; var id: String { name } }

    struct Summary {
        var tracks: [Track] = []
        var devicePlays: [String: DeviceStatTotal] = [:]
        var combined: [Combined] = []
        var totalBytes: Int64 = 0
        var totalDuration: Double = 0
        var totalPlays = 0
        var formats: [Bucket] = []
        var sources: [Bucket] = []
        var topFolders: [Bucket] = []
        var topTracks: [Combined] = []
        var artistPlays: [(key: String, value: Int)] = []
        var decades: [(decade: Int, count: Int)] = []
        var favorites = 0
        var neverPlayed = 0
    }

    private func bucket(_ name: String, _ ts: [Track]) -> Bucket {
        Bucket(name: name, count: ts.count, bytes: ts.reduce(Int64(0)) { $0 + $1.size })
    }

    private func summarize() -> Summary {
        var s = Summary()
        s.tracks = store.tracks
        s.devicePlays = model.db.devicePlayTotals()
        let dp = s.devicePlays
        s.combined = s.tracks.map { Combined(track: $0, plays: $0.playCount + (dp[$0.relPath]?.plays ?? 0)) }
        s.totalBytes = s.tracks.reduce(Int64(0)) { $0 + $1.size }
        s.totalDuration = s.tracks.reduce(0.0) { $0 + ($1.duration ?? 0) }
        s.totalPlays = s.combined.reduce(0) { $0 + $1.plays }
        let byExt: [String: [Track]] = Dictionary(grouping: s.tracks, by: { $0.fileExtension })
        s.formats = byExt.map { bucket($0.key.uppercased(), $0.value) }.sorted { $0.count > $1.count }
        let bySource: [String: [Track]] = Dictionary(grouping: s.tracks, by: { $0.source.rawValue })
        s.sources = bySource.map { bucket($0.key == "youtube" ? "YouTube" : "Local", $0.value) }
        let byTop: [String: [Track]] = Dictionary(grouping: s.tracks, by: { String($0.relPath.split(separator: "/").first ?? "") })
        s.topFolders = Array(byTop.map { bucket($0.key, $0.value) }.sorted { $0.bytes > $1.bytes }.prefix(12))
        s.topTracks = Array(s.combined.filter { $0.plays > 0 }.sorted { $0.plays > $1.plays }.prefix(15))
        var artist: [String: Int] = [:]
        for c in s.combined where c.plays > 0 { artist[c.track.displayArtist, default: 0] += c.plays }
        s.artistPlays = Array(artist.sorted { $0.value > $1.value }.prefix(10)).map { (key: $0.key, value: $0.value) }
        var dec: [Int: Int] = [:]
        for y in s.tracks.compactMap(\.year) where y > 1900 { dec[y / 10 * 10, default: 0] += 1 }
        s.decades = dec.sorted { $0.key < $1.key }.map { (decade: $0.key, count: $0.value) }
        s.favorites = s.tracks.filter { $0.favorite || (dp[$0.relPath]?.favorite ?? false) }.count
        s.neverPlayed = s.combined.filter { $0.plays == 0 }.count
        return s
    }

    var body: some View {
        let s = summarize()
        let tracks = s.tracks, totalBytes = s.totalBytes, totalDuration = s.totalDuration, totalPlays = s.totalPlays
        let formats = s.formats, sources = s.sources, topFolders = s.topFolders, topTracks = s.topTracks
        let artistPlays = s.artistPlays, decades = s.decades
        let yc = yt.counts

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    StatCard(title: "Tracks", value: tracks.count.formatted())
                    StatCard(title: "Artists", value: store.artists.count.formatted())
                    StatCard(title: "Albums", value: store.albums.count.formatted())
                    StatCard(title: "Library size", value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                    StatCard(title: "Total duration", value: "\(Int(totalDuration / 3600)) h \(Int(totalDuration.truncatingRemainder(dividingBy: 3600) / 60)) min")
                    StatCard(title: "Plays (Mac + devices)", value: totalPlays.formatted())
                    StatCard(title: "Favorites", value: s.favorites.formatted())
                    StatCard(title: "Never played", value: s.neverPlayed.formatted())
                }

                HStack(alignment: .top, spacing: 16) {
                    GroupBox("Formats") {
                        Chart(formats) { f in BarMark(x: .value("Tracks", f.count), y: .value("Format", f.name)).annotation(position: .trailing) { Text("\(f.count)").font(.caption2) } }
                            .frame(height: max(120, CGFloat(formats.count) * 26))
                    }
                    GroupBox("Source") {
                        Chart(sources) { SectorMark(angle: .value("Tracks", $0.count), innerRadius: .ratio(0.55)).foregroundStyle(by: .value("Source", $0.name)) }
                            .frame(height: 160)
                        ForEach(sources) { Text("\($0.name): \($0.count) · \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))").font(.caption) }
                    }
                    GroupBox("YouTube queue") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Liked songs: \(yt.items.count)")
                            Text("Downloaded: \(yc[.done] ?? 0)")
                            Text("Queued: \(yt.items.filter { $0.status == .pending && $0.priority != .skip }.count)")
                            Text("Skipped: \(yt.items.filter { $0.priority == .skip && $0.status != .done }.count)")
                            Text("Failed: \(yc[.failed] ?? 0)")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    GroupBox("Top tracks") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(topTracks) { c in
                                HStack { Text(c.track.title).lineLimit(1); Text(c.track.displayArtist).foregroundStyle(.secondary).lineLimit(1); Spacer(); Text("\(c.plays)").monospacedDigit() }
                            }
                            if topTracks.isEmpty { Text("No plays yet").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Top artists") {
                        Chart(artistPlays, id: \.key) { BarMark(x: .value("Plays", $0.value), y: .value("Artist", $0.key)) }
                            .frame(height: max(120, CGFloat(artistPlays.count) * 24))
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    GroupBox("Largest top-level folders") {
                        Chart(topFolders) { BarMark(x: .value("Size (MB)", Double($0.bytes) / 1_048_576), y: .value("Folder", $0.name)) }
                            .frame(height: max(120, CGFloat(topFolders.count) * 24))
                    }
                    GroupBox("By decade") {
                        Chart(decades, id: \.decade) { BarMark(x: .value("Decade", "\($0.decade)s"), y: .value("Tracks", $0.count)) }
                            .frame(height: 200)
                    }
                }

                GroupBox("Devices") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.devices) { d in
                            HStack { Image(systemName: "iphone"); Text(d.deviceName); Spacer()
                                Text("\(d.entryCount) tracks with stats · last sync \(Date(timeIntervalSince1970: d.lastSync).formatted(.relative(presentation: .named)))").foregroundStyle(.secondary) }
                        }
                        if model.devices.isEmpty { Text("No devices have synced yet").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20)
        }
        .navigationTitle("Statistics")
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
