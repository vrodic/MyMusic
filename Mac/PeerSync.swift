import Foundation
import SwiftUI

/// Keeps this Mac in step with every other MyMusic device it can reach: other Macs on the
/// network (found over Bonjour) and the web player. Each exchange pulls what the peer has that's
/// new since last time, merges it (see SyncStore), and pushes our own changes back.
@MainActor
final class PeerSync: ObservableObject {
    struct PeerStatus: Identifiable, Hashable {
        var id: String          // replica id
        var name: String
        var kind: String        // "Mac", "web player"
        var lastSync: Date?
        var error: String?
    }

    @Published private(set) var status: [String: PeerStatus] = [:]
    @Published private(set) var isSyncing = false

    private unowned let model: AppModel
    let macs = ServerBrowser()   // other Macs announce _mymusic._tcp, like this one
    private var timer: Timer?
    private var pending: Task<Void, Never>?
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    init(model: AppModel) {
        self.model = model
        macs.start()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.kick(after: 0) }
        }
        kick(after: 8)
    }

    /// Something changed here (a play, a heart, a playlist edit…): tell the others soon.
    func kick(after seconds: Double = 5) {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await self?.syncAll()
            self?.pending = nil
        }
    }

    func syncAll() async {
        guard !isSyncing, model.isRootAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }
        let me = model.db.sync.replicaID
        // other Macs
        for s in macs.servers {
            guard let base = await ServerBrowser.resolve(s.endpoint) else { continue }
            guard let info = try? await fetch(ServerInfo.self, base.appending(path: "api/info")), let id = info.replica, id != me else { continue }
            await exchange(base: base, token: nil, peerID: id, name: info.name, kind: "Mac")
        }
        // the web player (relays changes between Macs that are never on at the same time)
        if model.web.baseURL != nil { await model.web.sync() }
    }

    /// One two-way exchange with a peer.
    func exchange(base: URL, token: String?, peerID: String, name: String, kind: String) async {
        let st = model.db.sync
        var entry = status[peerID] ?? PeerStatus(id: peerID, name: name, kind: kind)
        do {
            // pull
            let known = st.peer(peerID)
            var c = URLComponents(url: base.appending(path: "api/v2/changes"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "since", value: String(known?.pulledSeq ?? 0)), .init(name: "yt", value: "1"),
                            .init(name: "from", value: st.replicaID), .init(name: "name", value: model.serverName)]
            var req = URLRequest(url: c.url!)
            if let token, !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-MyMusic-Token") }
            let (data, resp) = try await session.data(for: req)
            try Self.check(resp, data)
            let incoming = try JSONDecoder().decode(SyncStore.ChangeSet.self, from: data)
            let res = await offMain { st.apply(incoming) }
            st.notePeer(peerID, name: name, pulled: incoming.seq)
            if res.changed > 0 { model.afterSyncApplied(res) }

            // push
            let since = st.peer(peerID)?.pushedSeq ?? 0
            let myName = model.serverName
            let outgoing = await offMain { st.changes(since: since, includeYT: true, name: myName) }
            if !outgoing.isEmpty {
                var p = URLRequest(url: base.appending(path: "api/v2/changes"))
                p.httpMethod = "POST"
                p.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let token, !token.isEmpty { p.setValue(token, forHTTPHeaderField: "X-MyMusic-Token") }
                p.httpBody = try JSONEncoder().encode(outgoing)
                let (pdata, presp) = try await session.data(for: p)
                try Self.check(presp, pdata)
            }
            st.notePeer(peerID, name: name, pushed: outgoing.seq)
            entry.lastSync = Date(); entry.error = nil; entry.name = name
        } catch {
            entry.error = error.localizedDescription
        }
        status[peerID] = entry
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ url: URL) async throws -> T {
        let (data, resp) = try await session.data(from: url)
        try Self.check(resp, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw NSError(domain: "PeerSync", code: 401, userInfo: [NSLocalizedDescriptionKey: "Wrong token"]) }
        guard http.statusCode == 200 else {
            throw NSError(domain: "PeerSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
    }
}
