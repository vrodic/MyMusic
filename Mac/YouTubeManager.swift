import AppKit
import Foundation
import SwiftUI

/// Indexes YouTube "Liked music" with yt-dlp and downloads items one at a time, by priority.
@MainActor
final class YouTubeManager: ObservableObject {
    @AppStorage("yt.playlistURL") var playlistURL = "https://music.youtube.com/playlist?list=LM"
    @AppStorage("yt.cookiesBrowser") var cookiesBrowser = YouTubeManager.systemDefaultBrowser()   // or "file:/path/cookies.txt"
    @AppStorage("yt.browserDetected") private var browserDetected = false
    @AppStorage("yt.ytdlpPath") var ytdlpPath = ""
    @AppStorage("yt.autoRefreshHours") var autoRefreshHours = 6
    @AppStorage("yt.defaultPriority") var defaultPriorityRaw = YTPriority.normal.rawValue
    @AppStorage("yt.paused") var paused = false { didSet { objectWillChange.send() } }
    @AppStorage("yt.lastRefresh") private var lastRefresh: Double = 0

    @Published private(set) var items: [YTItem] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var currentID: String?
    @Published private(set) var currentProgress: Double = 0
    @Published private(set) var statusLine = ""
    @Published private(set) var log: [String] = []
    /// Human-readable reason the last index attempt failed (shown in the YouTube view).
    @Published private(set) var lastError: String?
    private var lastAttempt: Double = 0

    private let db: LibraryDB
    private let rootProvider: () -> URL?
    private let onDownloaded: (String) async -> Void
    private var worker: Task<Void, Never>?
    private var downloadRunner: ProcessRunner?
    private var poked = false
    private var defaultsObserver: NSObjectProtocol?
    private var lastSettingsSnapshot = ""
    private var settingsSnapshot: String {
        let d = UserDefaults.standard
        return d.dictionaryRepresentation().filter { $0.key.hasPrefix("yt.") && $0.key != "yt.lastRefresh" }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
    }

    private let rootIsRemote: () -> Bool
    /// Your own (non-YouTube) songs, for "already in library?" matching.
    var libraryProvider: () -> [Track] = { [] }
    /// Tell the other Macs soon (claims and finished downloads matter quickly).
    var onSharedChange: () -> Void = {}

    /// Another Mac changed the shared queue: take it over, and index files it downloaded.
    func applySync(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let downloaded = db.applySyncedYT(ids)
        reload()
        if let cur = currentID, ids.contains(cur), db.ytClaimedElsewhere().contains(cur), !currentForced {
            appendLog("another Mac is downloading the current song; stopping here")
            cancelCurrent()
        }
        for rel in downloaded { Task { await onDownloaded(rel) } }
        if !downloaded.isEmpty { appendLog("\(downloaded.count) songs downloaded by another Mac") }
        poke()
    }
    @Published private(set) var isMatching = false

    init(db: LibraryDB, root: @escaping () -> URL?, rootIsRemote: @escaping () -> Bool, onDownloaded: @escaping (String) async -> Void) {
        self.db = db
        self.rootProvider = root
        self.rootIsRemote = rootIsRemote
        self.onDownloaded = onDownloaded
        db.resetStuckDownloads()
        // @AppStorage doesn't publish from an ObservableObject; forward settings changes to SwiftUI.
        // Only when one of *our* settings changed: macOS also writes defaults for window and
        // split-view sizes while you click around, and each redraw of the YouTube table is costly.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let snap = self.settingsSnapshot
                if snap != self.lastSettingsSnapshot { self.lastSettingsSnapshot = snap; self.objectWillChange.send() }
            }
        }
        // One-time: earlier builds defaulted to Chrome; switch to the browser macOS actually uses.
        if !browserDetected {
            if cookiesBrowser == "chrome" { cookiesBrowser = Self.systemDefaultBrowser() }
            browserDetected = true
        }
        reload()
    }

    /// yt-dlp browser name of the system default browser.
    static func systemDefaultBrowser() -> String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://youtube.com")!),
              let id = Bundle(url: app)?.bundleIdentifier?.lowercased() else { return "chrome" }
        let map: [(String, String)] = [("firefox", "firefox"), ("chrome", "chrome"), ("safari", "safari"), ("brave", "brave"),
                                       ("edgemac", "edge"), ("vivaldi", "vivaldi"), ("opera", "opera"), ("chromium", "chromium")]
        return map.first { id.contains($0.0) }?.1 ?? "chrome"
    }

    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Turns yt-dlp's stderr into an actionable message.
    private func explain(_ stderr: String) -> String {
        let browser = cookiesBrowser.hasPrefix("file:") ? "the cookies file" : cookiesBrowser.capitalized
        let errLine = stderr.split(whereSeparator: \.isNewline).last { $0.contains("ERROR") }.map(String.init) ?? String(stderr.suffix(300))
        let lower = stderr.lowercased()
        if lower.contains("cookies database") || lower.contains("operation not permitted") || lower.contains("permissionerror") {
            return "macOS blocked access to \(browser)'s cookies. Give MyMusic Full Disk Access (System Settings → Privacy & Security → Full Disk Access), then press Refresh Liked. Also check the right browser is picked in Settings (⌘,).\n\n\(errLine)"
        }
        if lower.contains("sign in") || lower.contains("login") || lower.contains("does not exist") || lower.contains("private") {
            return "YouTube didn't accept the login from \(browser). Sign in to music.youtube.com in \(browser), or pick another browser in Settings (⌘,).\n\n\(errLine)"
        }
        return errLine.isEmpty ? "yt-dlp failed with no output" : errLine
    }
    var resolvedYtdlp: String? {
        if !ytdlpPath.isEmpty, FileManager.default.isExecutableFile(atPath: ytdlpPath) { return ytdlpPath }
        return ProcessRunner.which("yt-dlp")
    }

    func reload() {
        items = db.ytItems()
        searchKeys = Dictionary(uniqueKeysWithValues: items.map { ($0.videoID, Self.key(for: $0)) })
    }

    /// Folded "title artist path" per liked song, for accent-insensitive search.
    private var searchKeys: [String: String] = [:]
    private static func key(for i: YTItem) -> String { [i.title, i.uploader ?? "", i.relPath ?? ""].joined(separator: " ").searchFolded }
    func searchKey(_ i: YTItem) -> String { searchKeys[i.videoID] ?? Self.key(for: i) }

    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.loop() }
    }

    private func poke() { poked = true }

    private func cookieArgs() -> [String] {
        if cookiesBrowser.hasPrefix("file:") { return ["--cookies", String(cookiesBrowser.dropFirst(5))] }
        if cookiesBrowser.isEmpty || cookiesBrowser == "none" { return [] }
        return ["--cookies-from-browser", cookiesBrowser]
    }

    private func appendLog(_ s: String) {
        log.append("[\(Date().formatted(date: .omitted, time: .standard))] \(s)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: indexing

    func refreshLiked() async {
        guard !isIndexing, let ytdlp = resolvedYtdlp else {
            if resolvedYtdlp == nil { statusLine = "yt-dlp not found – brew install yt-dlp" }
            return
        }
        isIndexing = true; statusLine = "Indexing liked music…"
        lastAttempt = Date().timeIntervalSince1970
        defer { isIndexing = false }
        do {
            let out = try await ProcessRunner().run(ytdlp, ["--flat-playlist", "-J", "--no-warnings"] + cookieArgs() + [playlistURL])
            guard out.status == 0,
                  let json = try JSONSerialization.jsonObject(with: out.stdout) as? [String: Any],
                  let entries = json["entries"] as? [[String: Any]] else {
                statusLine = "Indexing failed"
                lastError = explain(out.stderr)
                if Self.isRateLimited(out.stderr) {
                    cooldownUntil = Date().timeIntervalSince1970 + Double(max(cooldownHours, 1)) * 3600
                }
                appendLog("index failed: \(out.stderr.suffix(800))")
                return
            }
            let parsed = entries.compactMap { e -> (id: String, title: String, uploader: String?, duration: Double?)? in
                guard let id = e["id"] as? String else { return nil }
                let artists = (e["artists"] as? [String])?.joined(separator: ", ")
                return (id, (e["title"] as? String) ?? id,
                        artists ?? (e["uploader"] as? String) ?? (e["channel"] as? String),
                        (e["duration"] as? NSNumber)?.doubleValue)
            }
            try db.syncYTPlaylist(parsed, defaultPriority: YTPriority(rawValue: defaultPriorityRaw) ?? .normal)
            lastRefresh = Date().timeIntervalSince1970
            lastError = nil
            reload()
            await checkLibraryMatches()
            statusLine = "Indexed \(parsed.count) liked songs"
            appendLog(statusLine)
            poke()
        } catch {
            statusLine = "Indexing failed"
            lastError = error.localizedDescription
        }
    }

    // MARK: throttling settings

    @AppStorage("yt.delaySeconds") var delaySeconds = 20            // base wait between downloads (±50 % jitter)
    @AppStorage("yt.maxPerHour") var maxPerHour = 40                // 0 = unlimited
    @AppStorage("yt.maxPerDay") var maxPerDay = 300                 // 0 = unlimited
    @AppStorage("yt.rateLimit") var rateLimit = ""                  // yt-dlp --limit-rate, e.g. "2M"
    @AppStorage("yt.sleepRequests") var sleepRequests = true        // yt-dlp --sleep-requests 1
    @AppStorage("yt.cooldownHours") var cooldownHours = 6           // pause after YouTube rate-limits us
    @AppStorage("yt.cooldownUntil") var cooldownUntil: Double = 0

    /// Songs the user asked for explicitly (double-click / Download Now): skip pause and throttling.
    @Published private(set) var forcedQueue: [String] = []
    @Published private(set) var waitReason: String?
    private var cancelRequested = false
    private var currentForced = false
    private var lastDownloadEnd: Double = 0
    private var nextDelay: Double = 0

    var isCoolingDown: Bool { cooldownUntil > Date().timeIntervalSince1970 }

    // MARK: already in the library?

    /// Fuzzy-match every liked song that isn't downloaded yet against your own songs. Likely
    /// matches stop being downloaded; manual "in library" marks (score 1 with no path) are kept.
    func checkLibraryMatches() async {
        guard !isMatching else { return }
        isMatching = true
        defer { isMatching = false }
        let library = libraryProvider().filter { $0.source != .youtube }
        let pending = items.filter { $0.status != .done && !($0.matchScore == 1 && $0.libraryMatch == "") }
        let results = await offMain { () -> [String: YTLibraryMatcher.Match?] in
            let index = YTLibraryMatcher.Index(library: library)
            var out: [String: YTLibraryMatcher.Match?] = [:]
            for it in pending {
                out[it.videoID] = index.bestMatch(title: it.title, uploader: it.uploader, duration: it.duration,
                                                  threshold: YTLibraryMatcher.possibleThreshold)
            }
            return out
        }
        db.setYTLibraryMatches(results)
        reload()
        let likely = items.filter(\.likelyInLibrary).count
        appendLog("library check: \(likely) liked songs look like they're already in your library")
        poke()
    }

    func downloadAnyway(_ ids: Set<String>) { db.setYTMatchOverride(Array(ids), true); reload(); poke() }
    func markInLibrary(_ ids: Set<String>) {
        db.markYTInLibrary(Array(ids))
        if let cur = currentID, ids.contains(cur), !currentForced { cancelCurrent() }
        reload()
    }

    // MARK: priorities

    func setPriority(_ ids: Set<String>, _ p: YTPriority) {
        db.setYTPriority(Array(ids), p)
        if p == .skip, let cur = currentID, ids.contains(cur), !currentForced { cancelCurrent() }
        reload(); poke()
    }

    func retry(_ ids: Set<String>) { db.resetYT(Array(ids)); reload(); poke() }

    func togglePause() {
        paused.toggle()
        if paused { if !currentForced { cancelCurrent() } } else { poke() }
    }

    func endCooldown() { cooldownUntil = 0; lastError = nil; poke() }

    /// Download these right away, even while paused or throttled.
    func downloadNow(_ ids: [String]) {
        for id in ids {
            guard let item = db.ytItem(id), item.status != .done, item.status != .downloading, !forcedQueue.contains(id) else { continue }
            if item.status == .failed { db.resetYT([id]) }
            forcedQueue.append(id)
        }
        reload(); poke()
    }

    private func cancelCurrent() { cancelRequested = true; downloadRunner?.cancel() }

    // MARK: worker

    /// Why the next queued (non-forced) download has to wait, and for how long.
    private func throttle() -> (seconds: Double, reason: String)? {
        let now = Date().timeIntervalSince1970
        func at(_ t: Double) -> String { Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened) }
        if cooldownUntil > now {
            return (cooldownUntil - now, "YouTube rate-limited us – downloads resume at \(at(cooldownUntil))")
        }
        if maxPerDay > 0 {
            let day = db.ytAttempts(within: 86400)
            if day.count >= maxPerDay, let first = day.first {
                return (first + 86400 - now, "Daily limit (\(maxPerDay)) reached – next at \(at(first + 86400))")
            }
        }
        if maxPerHour > 0 {
            let hour = db.ytAttempts(within: 3600)
            if hour.count >= maxPerHour, let first = hour.first {
                return (first + 3600 - now, "Hourly limit (\(maxPerHour)) reached – next at \(at(first + 3600))")
            }
        }
        let wait = lastDownloadEnd + nextDelay - now
        if wait > 0 { return (wait, "Waiting \(Int(wait.rounded(.up))) s between downloads") }
        return nil
    }

    private func loop() async {
        while !Task.isCancelled {
            let now = Date().timeIntervalSince1970
            if autoRefreshHours > 0, now - lastRefresh > Double(autoRefreshHours) * 3600,
               now - lastAttempt > 1800, !isCoolingDown, rootProvider() != nil {   // after a failure, retry at most every 30 min
                await refreshLiked()
            }
            guard let root = rootProvider(), let ytdlp = resolvedYtdlp else { await idle(60); continue }

            // 1. explicit requests first, no throttling
            if let id = forcedQueue.first {
                forcedQueue.removeFirst()
                if let item = db.ytItem(id), item.status != .done {
                    waitReason = nil
                    _ = db.sync.claim(item.videoID)   // you asked for it here: download even if claimed elsewhere
                    onSharedChange()
                    await download(item, root: root, ytdlp: ytdlp, forced: true)
                    db.sync.releaseClaim(item.videoID)
                    onSharedChange()
                }
                continue
            }
            // 2. the regular queue, by priority, throttled
            if !paused, let next = db.nextYTDownload() {
                if let t = throttle() {
                    waitReason = t.reason
                    await idle(min(t.seconds, 60))
                    continue
                }
                waitReason = nil
                // claim it so another Mac doesn't fetch the same song; give the claim a moment to spread
                guard db.sync.claim(next.videoID) else { continue }
                onSharedChange()
                await download(next, root: root, ytdlp: ytdlp, forced: false)
                db.sync.releaseClaim(next.videoID)
                onSharedChange()
                continue
            }
            waitReason = nil
            await idle(60)
        }
    }

    /// Sleep up to `seconds`, waking early when poked (new request, resume, priority change).
    private func idle(_ seconds: Double) async {
        poked = false
        var left = max(1, seconds)
        while left > 0, !poked, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(min(1, left)))
            left -= 1
        }
    }

    private static func isRateLimited(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("http error 429") || s.contains("too many requests") || s.contains("not a bot")
            || s.contains("rate-limit") || s.contains("rate limit") || s.contains("this content isn't available, try again later")
    }

    private func download(_ item: YTItem, root: URL, ytdlp: String, forced: Bool) async {
        let ytDir = root.appendingPathComponent("yt", isDirectory: true)
        await offMain { try? FileManager.default.createDirectory(at: ytDir, withIntermediateDirectories: true) }
        currentID = item.videoID; currentProgress = 0; currentForced = forced; cancelRequested = false
        statusLine = "Downloading \(item.title)"
        db.setYTStatus(item.videoID, .downloading)
        db.markYTAttempt(item.videoID)
        reload()

        var output = await runDownload(videoID: item.videoID, ytDir: ytDir, ytdlp: ytdlp)
        // The liked video itself can be gone or blocked here while YouTube Music still plays the
        // song from another upload: find that copy (same title, artist, length) and fetch it.
        if output?.status != 0, !cancelRequested, Self.isUnavailable(output?.stderr ?? "") {
            statusLine = "\(item.title): liked video unavailable, looking for another copy…"
            if let alt = await findAlternative(for: item, ytdlp: ytdlp) {
                appendLog("↪ \(item.title): liked video \(item.videoID) is unavailable, using \(alt)")
                statusLine = "Downloading \(item.title) (from \(alt))"
                output = await runDownload(videoID: alt, ytDir: ytDir, ytdlp: ytdlp)
            } else {
                appendLog("✗ \(item.title): liked video is unavailable and no other copy was found")
            }
        }
        downloadRunner = nil
        currentID = nil
        currentForced = false
        lastDownloadEnd = Date().timeIntervalSince1970
        nextDelay = Double(delaySeconds) * Double.random(in: 0.5...1.5)

        let printed = output.flatMap { String(data: $0.stdout, encoding: .utf8) }?
            .split(whereSeparator: \.isNewline).map(String.init).last { $0.hasPrefix("/") }
        let stderr = output?.stderr ?? ""
        let succeeded = output?.status == 0
        let videoID = item.videoID
        let trustPrinted = rootIsRemote()
        // Locate the file off the main thread. On a network volume, trust yt-dlp's printed path
        // instead of stat-ing it (yt-dlp only prints after the final move succeeded).
        let rel: String? = succeeded ? await offMain {
            if let printed, trustPrinted { return URL(fileURLWithPath: printed).relativePath(from: root) }
            guard let file = printed.map({ URL(fileURLWithPath: $0) }) ?? Self.findDownloaded(id: videoID, in: ytDir),
                  FileManager.default.fileExists(atPath: file.path) else { return nil }
            return file.relativePath(from: root)
        } : nil

        if let rel {
            db.setYTStatus(item.videoID, .done, relPath: rel)
            appendLog("✓ \(item.title)")
            await onDownloaded(rel)
        } else if cancelRequested {
            db.setYTStatus(item.videoID, .pending)
            appendLog("⏸ \(item.title)")
        } else if Self.isRateLimited(stderr) {
            // Don't burn retry attempts; back off for a while instead.
            db.setYTStatus(item.videoID, .pending)
            cooldownUntil = Date().timeIntervalSince1970 + Double(max(cooldownHours, 1)) * 3600
            lastError = "YouTube is rate-limiting downloads, so the queue is paused until \(Date(timeIntervalSince1970: cooldownUntil).formatted(date: .omitted, time: .shortened)). Double-clicking a song still downloads it. Consider a longer wait between downloads in Settings (⌘,).\n\n\(stderr.split(whereSeparator: \.isNewline).last { $0.contains("ERROR") } ?? "")"
            appendLog("⛔ rate-limited on \(item.title) – cooling down \(cooldownHours) h")
        } else {
            let err = stderr.split(whereSeparator: \.isNewline).last { $0.contains("ERROR") }.map(String.init) ?? "unknown error"
            db.setYTStatus(item.videoID, .failed, error: err)
            appendLog("✗ \(item.title): \(err)")
        }
        cancelRequested = false
        statusLine = ""
        reload()
    }

    /// yt-dlp arguments: audio only; AAC/m4a when YouTube has it, otherwise the original audio
    /// (usually Opus) copied untouched into an .m4a (no re-encoding, no quality loss; Apple's players
    /// handle Opus in MP4). Tags and a square cover are embedded either way.
    private func downloadArgs(videoID: String, ytDir: URL) -> [String] {
        var args = [
            "-f", "bestaudio[ext=m4a]/bestaudio", "-x", "--audio-format", "m4a",
            // copy the audio stream into a plain MP4 container ("ipod" .m4a refuses Opus)
            "--ppa", "ExtractAudio+ffmpeg_o:-c:a copy -f mp4",
            "--ppa", "Metadata+ffmpeg_o:-f mp4",
            "--ppa", "EmbedThumbnail+ffmpeg_o:-f mp4",
            "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg",
            "--ppa", "ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\"",
            "--no-playlist", "--no-overwrites", "--newline", "--progress", "--trim-filenames", "180",
            "--print", "after_move:filepath",
            "-o", ytDir.path + "/%(artist,uploader,channel|Unknown)s - %(title)s [%(id)s].%(ext)s",
        ]
        let limit = rateLimit.trimmingCharacters(in: .whitespaces)
        if !limit.isEmpty { args += ["--limit-rate", limit] }
        if sleepRequests { args += ["--sleep-requests", "1"] }
        return args + cookieArgs() + ["https://music.youtube.com/watch?v=\(videoID)"]
    }

    private func runDownload(videoID: String, ytDir: URL, ytdlp: String) async -> ProcessRunner.Output? {
        let runner = ProcessRunner()
        downloadRunner = runner
        return try? await runner.run(ytdlp, downloadArgs(videoID: videoID, ytDir: ytDir)) { line in
            guard line.contains("[download]"), let pct = line.split(separator: " ").first(where: { $0.hasSuffix("%") }),
                  let v = Double(pct.dropLast()) else { return }
            // yt-dlp prints many progress lines per second; redraw the (big) table only per 2 %
            Task { @MainActor [weak self] in
                guard let self, v >= 100 || abs(v / 100 - self.currentProgress) >= 0.02 else { return }
                self.currentProgress = v / 100
            }
        }
    }

    static func isUnavailable(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("video unavailable") || s.contains("is not available") || s.contains("has been removed")
            || s.contains("private video") || s.contains("account associated with this video has been terminated")
            || s.contains("not made this video available in your country")
    }

    /// Another upload of the same song on YouTube Music: the song results for "artist title" are
    /// checked (without downloading) and the first one with a matching title, an overlapping artist
    /// and a length within 10 s of the liked video wins.
    private func findAlternative(for item: YTItem, ytdlp: String) async -> String? {
        let artist = YTLibraryMatcher.cleanChannel(item.uploader ?? "")
        let query = "\(artist) \(item.title)".trimmingCharacters(in: .whitespaces)
        guard var c = URLComponents(string: "https://music.youtube.com/search") else { return nil }
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = c.url?.absoluteString else { return nil }
        guard let search = try? await ProcessRunner().run(ytdlp, ["--flat-playlist", "-J", "--playlist-items", "1:5", "--no-warnings"]
                                                       + cookieArgs() + [url + "#songs"]),
              search.status == 0,
              let json = try? JSONSerialization.jsonObject(with: search.stdout) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return nil }
        let wantTitle = YTLibraryMatcher.words(item.title)
        let wantArtist = YTLibraryMatcher.words(artist)
        for e in entries.prefix(5) {
            guard let id = e["id"] as? String, id != item.videoID, let title = e["title"] as? String else { continue }
            let tw = YTLibraryMatcher.words(title)
            guard max(YTLibraryMatcher.overlap(wantTitle, tw), YTLibraryMatcher.charSimilarity(wantTitle, tw)) >= 0.8 else { continue }
            // check the candidate: is it available, who is it by, how long is it?
            guard let probe = try? await ProcessRunner().run(ytdlp, ["--skip-download", "--no-playlist", "--no-warnings", "-J"]
                                                          + cookieArgs() + ["https://music.youtube.com/watch?v=\(id)"]),
                  probe.status == 0,
                  let info = try? JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any] else { continue }
            let names = ((info["artists"] as? [String]) ?? []) + [info["artist"] as? String, info["uploader"] as? String, info["channel"] as? String].compactMap { $0 }
            let aw = YTLibraryMatcher.words(names.map(YTLibraryMatcher.cleanChannel).joined(separator: " "))
            if !wantArtist.isEmpty, YTLibraryMatcher.containment(wantArtist, aw) < 0.5 { continue }
            if let want = item.duration, let got = (info["duration"] as? NSNumber)?.doubleValue, abs(want - got) > 10 { continue }
            return id
        }
        return nil
    }

    nonisolated private static func findDownloaded(id: String, in dir: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.contains("[\(id)]") && $0.pathExtension == "m4a" }
    }

    var counts: [YTStatus: Int] { Dictionary(grouping: items, by: \.status).mapValues(\.count) }
}
