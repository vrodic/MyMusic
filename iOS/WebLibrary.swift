import Foundation
import SwiftUI

/// The web player's library as seen from the iPhone: songs on the music server that aren't on
/// this phone, to stream or download. Found on the local network (Bonjour) or by address.
@MainActor
final class WebLibrary: ObservableObject {
    @AppStorage("webPlayerAddress") var manualAddress = ""
    @Published private(set) var base: URL?
    @Published private(set) var info: WebPlayerInfo?
    @Published private(set) var serverTracks: [Track] = []
    @Published private(set) var downloading: Set<String> = []
    @Published private(set) var downloadErrors: [String] = []

    let browser = ServerBrowser(type: MyMusicService.webBonjourType)
    private var lastRefresh = Date.distantPast
    private unowned let model: IOSModel
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()

    init(model: IOSModel) {
        self.model = model
        browser.start()
    }

    var name: String { info?.name ?? "server" }

    /// Server songs this phone doesn't have (matched across accent encodings: the Mac sends
    /// decomposed names, Linux stores composed ones).
    var notOnPhone: [Track] {
        let local = Set(model.store.tracks.map { Self.key($0.relPath) })
        return serverTracks.filter { !local.contains(Self.key($0.relPath)) }
    }

    static func key(_ relPath: String) -> String { relPath.precomposedStringWithCanonicalMapping }

    func refresh(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastRefresh) > 60 else { return }
        lastRefresh = Date()
        if base == nil { base = await findServer() }
        guard let base else { return }
        do {
            let (idata, _) = try await session.data(from: base.appending(path: "api/info"))
            info = try JSONDecoder().decode(WebPlayerInfo.self, from: idata)
            var tc = URLComponents(url: base.appending(path: "api/tracks"), resolvingAgainstBaseURL: false)!
            tc.queryItems = [URLQueryItem(name: "user", value: model.db.currentUser)]
            let (tdata, _) = try await session.data(from: tc.url!)
            let list = try JSONDecoder().decode([WebPlayerTrack].self, from: tdata).map(\.track)
            serverTracks = list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch {
            self.base = nil   // server gone or moved: look again next time
        }
    }

    private func findServer() async -> URL? {
        let manual = manualAddress.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty {
            let s = manual.hasPrefix("http") ? manual : "http://\(manual.contains(":") ? manual : manual + ":47824")"
            return URL(string: s)
        }
        // give Bonjour a moment on first launch
        for _ in 0..<6 where browser.servers.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
        guard let s = browser.servers.first else { return nil }
        return await ServerBrowser.resolve(s.endpoint)
    }

    // MARK: streaming

    func streamURL(_ t: Track) -> URL {
        MyMusicService.webStreamURL(base: base ?? URL(string: "http://invalid")!, relPath: t.relPath)
    }

    /// Plays and favorites of streamed songs are recorded on the web player (→ the Mac on its next sync).
    func reportPlay(_ t: Track) { post("api/played", ["path": t.relPath, "user": model.db.currentUser]) }
    func reportSkip(_ t: Track) { post("api/skipped", ["path": t.relPath, "user": model.db.currentUser]) }

    func setFavorite(_ t: Track, _ fav: Bool) {
        post("api/favorite", ["paths": [t.relPath], "favorite": fav, "user": model.db.currentUser])
        if let i = serverTracks.firstIndex(where: { $0.relPath == t.relPath }) { serverTracks[i].favorite = fav }
    }

    private func post(_ path: String, _ body: [String: Any]) {
        guard let base else { return }
        var r = URLRequest(url: base.appending(path: path))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: r).resume()
    }

    // MARK: downloading

    /// Copy songs to the phone (Music/<same folders>). They stay until you remove them, even if
    /// they're not in the Mac's sync selection.
    func download(_ tracks: [Track]) async {
        for t in tracks where !downloading.contains(t.relPath) {
            downloading.insert(t.relPath)
            defer { downloading.remove(t.relPath) }
            do {
                let (tmp, resp) = try await session.download(from: streamURL(t))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let dest = model.url(for: t)
                let fm = FileManager.default
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: tmp, to: dest)
                try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: t.mtime)], ofItemAtPath: dest.path)
                var local = t
                local.origin = .web
                local.addedAt = Date().timeIntervalSince1970
                local.playCount = 0; local.skipCount = 0; local.lastPlayed = nil   // server-side counts stay on the server
                try model.db.upsert([local])
                if t.favorite { model.db.setFavorite(local.relPath, true) }
            } catch {
                downloadErrors.append("\(t.title): \(error.localizedDescription)")
            }
        }
        await model.store.reloadNow()
    }
}
