import SwiftUI

struct ArtworkView: View {
    var image: PlatformImage?
    var size: CGFloat

    var body: some View {
        Group {
            if let image {
                #if canImport(UIKit)
                Image(uiImage: image).resizable().scaledToFill()
                #else
                Image(nsImage: image).resizable().scaledToFill()
                #endif
            } else {
                ZStack {
                    LinearGradient(colors: [.purple.opacity(0.6), .blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
    }
}

/// Loads embedded artwork lazily for list rows, with a shared cache.
struct TrackArtwork: View {
    let url: URL
    var size: CGFloat = 40
    @State private var image: PlatformImage?

    private static let cache = NSCache<NSURL, PlatformImage>()

    var body: some View {
        ArtworkView(image: image, size: size)
            .task(id: url) {
                if let c = Self.cache.object(forKey: url as NSURL) { image = c; return }
                if let d = await AudioScanner.artwork(url: url), let img = PlatformImage(data: d) {
                    Self.cache.setObject(img, forKey: url as NSURL)
                    image = img
                }
            }
    }
}

struct TrackRowLabel: View {
    let track: Track
    var isCurrent = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Text("\(track.displayArtist) · \(track.displayAlbum)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            #if os(macOS)
            // on iPhone the heart is noise in every row; favorites are a swipe / long-press away
            if track.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
            #endif
            if track.playCount > 0 { Text("\(track.playCount)▶").font(.caption2).foregroundStyle(.secondary) }
            Text((track.duration ?? 0).durationString).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
