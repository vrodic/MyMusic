import Foundation
import SwiftUI

/// Keeps the Go web player (web/, running on the music server) in step with this Mac.
/// The Mac stays the main app; the web player is a peer that keeps working on its own:
///  1. pull: the web player's plays + favorite changes → stored like an iPhone's stats
///     (so they count in totals) and favorites merged newest-change-wins
///  2. push: the Mac's library with Mac-side play totals (Mac + iPhones, not the web
///     player's own plays, so nothing is counted twice) and the merged favorites
@MainActor
final class WebPeer: ObservableObject {
    @AppStorage("web.url") var url = ""          // e.g. http://192.168.100.7:47824
    @AppStorage("web.token") var token = ""
    @Published private(set) var isSyncing = false
    @Published private(set) var lastResult: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var webDeviceName: String?

    private unowned let model: AppModel
    private var pending: Task<Void, Never>?
    private var timer: Timer?
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        return URLSession(configuration: c)
    }()

    init(model: AppModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon(after: 0) }
        }
        syncSoon(after: 10)
    }

    var baseURL: URL? {
        let s = url.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return URL(string: s.hasPrefix("http") ? s : "http://\(s)")
    }

    private var scheduledFor: Date?

    /// Batches many small changes (favorites, downloads) into one sync. A new request can only
    /// bring the sync *earlier*: postponing on every change would starve it while YouTube
    /// downloads keep arriving.
    func syncSoon(after seconds: Double = 15) {
        guard baseURL != nil else { return }
        let due = Date().addingTimeInterval(seconds)
        if let s = scheduledFor, s <= due { return }
        scheduledFor = due
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.scheduledFor = nil
            await self.sync()
        }
    }

    private func request(_ path: String) -> URLRequest? {
        guard let base = baseURL else { return nil }
        var r = URLRequest(url: base.appendingPathComponent(path))
        if !token.isEmpty { r.setValue(token, forHTTPHeaderField: "X-MyMusic-Token") }
        return r
    }

    func sync() async {
        guard !isSyncing, var pull = request("api/peer/stats"), var push = request("api/peer/library") else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            // 1. pull web plays + favorites
            pull.httpMethod = "GET"
            let (data, resp) = try await session.data(for: pull)
            try check(resp, data)
            let web = try JSONDecoder().decode(StatsUpload.self, from: data)
            try model.db.storeDeviceStats(web)
            webDeviceName = web.deviceName
            model.afterWebPull()

            // 2. duplicates removed on the web player (before pushing, or the push would re-add them)
            var removedHere = 0
            if var rq = request("api/peer/removals") {
                rq.httpMethod = "GET"
                let (rdata, rresp) = try await session.data(for: rq)
                try check(rresp, rdata)
                let removals = try JSONDecoder().decode([WebRemoval].self, from: rdata)
                if !removals.isEmpty {
                    model.applyWebRemovals(removals)
                    removedHere = removals.count
                    if var ack = request("api/peer/removals/ack") {
                        ack.httpMethod = "POST"
                        ack.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        ack.httpBody = try JSONEncoder().encode(["ids": removals.map(\.id)])
                        let (adata, aresp) = try await session.data(for: ack)
                        try check(aresp, adata)
                    }
                }
            }

            // 3. push library with Mac-side totals (excluding the web player's own plays)
            let others = model.db.devicePlayTotals(excluding: web.deviceID)
            let tracks = model.db.allTracks().map { t -> Track in
                var t = t
                t.playCount += others[t.relPath]?.plays ?? 0
                return t
            }
            let manifest = LibraryManifest(serverName: model.serverName, apiVersion: MyMusicService.apiVersion,
                                           generatedAt: Date().timeIntervalSince1970, tracks: tracks, merges: model.db.recentMerges())
            push.httpMethod = "POST"
            push.setValue("application/json", forHTTPHeaderField: "Content-Type")
            push.httpBody = try JSONEncoder().encode(manifest)
            let (rdata, rresp) = try await session.data(for: push)
            try check(rresp, rdata)
            let r = (try? JSONSerialization.jsonObject(with: rdata) as? [String: Int]) ?? [:]
            lastResult = "\(r["tracks"] ?? tracks.count) songs · \(r["added"] ?? 0) added · \(r["removed"] ?? 0) removed"
                + ((r["favoritesChanged"] ?? 0) > 0 ? " · \(r["favoritesChanged"]!) favorites" : "")
                + " · \(web.entries.filter { $0.playCount > 0 }.count) songs played on the web"
                + (removedHere > 0 ? " · \(removedHere) duplicates removed on the web" : "")
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = (error as? URLError)?.code == .cannotConnectToHost || (error as? URLError)?.code == .timedOut
                ? "Web player is offline" : error.localizedDescription
        }
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw NSError(domain: "WebPeer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Wrong token"]) }
        guard http.statusCode == 200 else {
            throw NSError(domain: "WebPeer", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(String(data: data.prefix(200), encoding: .utf8) ?? "")"])
        }
    }
}

/// A duplicate removed on the web player (paths in this Mac's spelling).
struct WebRemoval: Codable {
    var id: Int64
    var path: String
    var keep: String
    var basePlays: Int
    var favorite: Bool
    var removedAt: Double
}
