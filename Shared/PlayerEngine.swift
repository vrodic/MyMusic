import AVFoundation
import Combine
import SwiftUI
import MediaPlayer
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

enum RepeatMode: String, CaseIterable { case off, all, one }

/// Playback position, published separately (2×/s) so only the time label / slider redraw —
/// not every view that observes the player (e.g. a 3,000-row song table).
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var time: Double = 0
}

/// Gives `content` the live playback time while observing only the clock.
struct WithPlaybackTime<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    @ViewBuilder let content: (Double) -> Content
    var body: some View { content(clock.time) }
}

@MainActor
final class PlayerEngine: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    let clock = PlaybackClock()
    var currentTime: Double { clock.time }
    @Published private(set) var duration: Double = 0
    @Published private(set) var artwork: PlatformImage?
    @Published var shuffle = false { didSet { applyShuffle() } }
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Float = 1 { didSet { player.volume = volume } }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: ArraySlice<Track> { queue.indices.contains(index + 1) ? queue[(index + 1)...] : [] }

    private let player = AVPlayer()
    private var originalQueue: [Track] = []
    private var timeObserver: Any?
    private var endObserver: AnyCancellable?
    private var counted = false
    private let urlFor: (Track) -> URL
    var onPlayCounted: (Track) -> Void = { _ in }
    var onSkipped: (Track) -> Void = { _ in }

    init(urlFor: @escaping (Track) -> URL) {
        self.urlFor = urlFor
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        endObserver = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                    self.trackEnded()
                }
            }
        setupRemoteCommands()
    }

    // MARK: queue control

    func play(_ tracks: [Track], startAt: Int = 0) {
        guard !tracks.isEmpty else { return }
        originalQueue = tracks
        if shuffle {
            var rest = tracks; let first = rest.remove(at: min(startAt, tracks.count - 1))
            queue = [first] + rest.shuffled(); index = 0
        } else {
            queue = tracks; index = min(startAt, tracks.count - 1)
        }
        load(autoplay: true)
    }

    func playNext(_ t: Track) {
        if queue.isEmpty { play([t]); return }
        queue.insert(t, at: index + 1); originalQueue.append(t)
    }

    func addToQueue(_ t: Track) {
        if queue.isEmpty { play([t]); return }
        queue.append(t); originalQueue.append(t)
    }

    func removeFromQueue(at offsets: IndexSet) {
        // offsets are relative to upNext
        let absolute = IndexSet(offsets.map { $0 + index + 1 })
        queue.remove(atOffsets: absolute)
    }

    func moveInQueue(from: IndexSet, to: Int) {
        var rest = Array(upNext)
        rest.move(fromOffsets: from, toOffset: to)
        queue = Array(queue[...index]) + rest
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        maybeSkip(); index = i; load(autoplay: true)
    }

    func togglePlay() { isPlaying ? pause() : resume() }

    func pause() { player.pause(); isPlaying = false; updateNowPlaying() }

    func resume() {
        if player.currentItem == nil { load(autoplay: true); return }
        activateSession(); player.play(); isPlaying = true; updateNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        maybeSkip()
        if index + 1 < queue.count { index += 1 }
        else if repeatMode == .all { index = 0 }
        else { pause(); seek(to: 0); return }
        load(autoplay: true)
    }

    func previous() {
        if currentTime > 3 || index == 0 { seek(to: 0); return }
        index -= 1; load(autoplay: true)
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        clock.time = seconds; updateNowPlaying()
    }

    func stop() {
        player.replaceCurrentItem(with: nil); queue = []; originalQueue = []; index = 0
        isPlaying = false; clock.time = 0; duration = 0; artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Update a track in the queue (e.g. favorite toggled) without interrupting playback.
    func refresh(_ t: Track) {
        for i in queue.indices where queue[i].relPath == t.relPath { queue[i] = t }
    }

    /// Re-read every queued track (e.g. after favorites changed in bulk).
    func refreshAll(_ lookup: (String) -> Track?) {
        for i in queue.indices { if let t = lookup(queue[i].relPath) { queue[i] = t } }
        for i in originalQueue.indices { if let t = lookup(originalQueue[i].relPath) { originalQueue[i] = t } }
    }

    // MARK: internals

    private func applyShuffle() {
        guard let cur = current else { return }
        if shuffle {
            var rest = queue; rest.remove(at: index)
            queue = [cur] + rest.shuffled(); index = 0
        } else {
            queue = originalQueue
            index = originalQueue.firstIndex(where: { $0.relPath == cur.relPath }) ?? 0
        }
    }

    private func load(autoplay: Bool) {
        guard let t = current else { return }
        counted = false
        clock.time = 0
        duration = t.duration ?? 0
        player.replaceCurrentItem(with: AVPlayerItem(url: urlFor(t)))
        artwork = nil
        if autoplay { activateSession(); player.play(); isPlaying = true }
        updateNowPlaying()
        let url = urlFor(t)
        Task { [weak self] in
            let data = await AudioScanner.artwork(url: url)
            guard let self, self.current?.relPath == t.relPath else { return }
            self.artwork = data.flatMap { PlatformImage(data: $0) }
            self.updateNowPlaying()
        }
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        clock.time = t
        // assign only when it changes: every @Published write redraws all observers
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.01 { duration = d }
        if !counted, duration > 0, t >= min(duration * 0.5, 240), let cur = current {
            counted = true
            onPlayCounted(cur)
        }
    }

    private func maybeSkip() {
        if !counted, let cur = current, currentTime > 0 { onSkipped(cur) }
    }

    private func trackEnded() {
        if !counted, let cur = current { counted = true; onPlayCounted(cur) }
        if repeatMode == .one { seek(to: 0); player.play(); counted = false; return }
        counted = true // don't count the end as a skip
        next()
    }

    private func activateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    // MARK: Now Playing / remote commands

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlay() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { MainActor.assumeIsolated { self?.seek(to: e.positionTime) } }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.displayArtist,
            MPMediaItemPropertyAlbumTitle: t.displayAlbum,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let art = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }
}
