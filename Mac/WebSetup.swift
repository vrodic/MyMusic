import Foundation
import NetFS
import SwiftUI

/// First run on a Mac: find the web player on the network, mount its music share over SMB and
/// restore the library backup the main Mac keeps there.
@MainActor
final class WebSetup: ObservableObject {
    struct Candidate: Identifiable, Hashable {
        let server: DiscoveredServer
        let base: URL
        let info: WebPlayerInfo
        var id: String { server.id }
    }

    let browser = ServerBrowser(type: MyMusicService.webBonjourType)
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var step: String?
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    private var resolving = Set<String>()
    private var watcher: Task<Void, Never>?

    func start() {
        browser.start()
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.resolveNew()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() { watcher?.cancel(); watcher = nil }

    private func resolveNew() async {
        for s in browser.servers where !resolving.contains(s.id) && !candidates.contains(where: { $0.id == s.id }) {
            resolving.insert(s.id)
            guard let base = await ServerBrowser.resolve(s.endpoint),
                  let (data, _) = try? await URLSession.shared.data(from: base.appending(path: "api/info")),
                  let info = try? JSONDecoder().decode(WebPlayerInfo.self, from: data) else {
                resolving.remove(s.id)   // try again later
                continue
            }
            candidates.append(Candidate(server: s, base: base, info: info))
        }
    }

    /// Mount the share, restore the backup, and switch the app to that library.
    func setUp(_ c: Candidate, token: String, model: AppModel) async {
        isRunning = true; error = nil
        defer { isRunning = false; step = nil }
        do {
            // 1. library backup (also checks the token)
            step = "Downloading the library from \(c.info.name)…"
            var req = URLRequest(url: c.base.appending(path: "api/peer/backup"))
            if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-MyMusic-Token") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { throw SetupError("Wrong token. It's MYMUSIC_TOKEN in ~/.config/mymusic-web.env on \(c.info.name).") }
            let backup: Data? = status == 200 ? data : nil

            // 2. music share
            guard let smb = c.info.smbURL, let url = URL(string: smb), let host = url.host else {
                throw SetupError("\(c.info.name) doesn't say where its music is shared. Set MYMUSIC_SMB_URL (e.g. smb://\(c.base.host ?? "server")/share/path/to/music) in its settings.")
            }
            let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
            guard let share = parts.first else { throw SetupError("The SMB address \(smb) has no share name.") }
            let subpath = parts.dropFirst().joined(separator: "/")
            step = "Connecting to \(host) (macOS may ask for your username and password)…"
            let mounted = await offMain { SMBMount.mountOrFind(host: host, share: share, user: url.user) }
            guard case .success(let volume) = mounted else {
                if case .failure(let e) = mounted { throw e }
                return
            }
            let root = subpath.isEmpty ? volume : volume.appending(path: subpath, directoryHint: .isDirectory)
            let exists = await offMain { FileManager.default.fileExists(atPath: root.path) }
            guard exists else { throw SetupError("Mounted \(volume.path), but \(subpath) isn't there.") }

            // 3. restore the library (if the main Mac has uploaded one) and switch to it
            if let backup {
                step = "Restoring the library…"
                let tmp = FileManager.default.temporaryDirectory.appending(path: "mymusic-restore-\(UUID().uuidString).sqlite")
                try backup.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }
                try model.restoreLibrary(from: tmp.path)
            }
            model.web.url = c.base.absoluteString
            model.web.token = token
            step = "Scanning your music…"
            await model.setRoot(root)
            model.web.syncSoon(after: 2)
            stop()
        } catch {
            self.error = (error as? SetupError)?.message ?? error.localizedDescription
        }
    }

    struct SetupError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

enum SMBMount {
    /// The share's mount point: an existing mount of host/share, or a new one. macOS shows its own
    /// login prompt (and offers to save the password in the keychain) when it needs credentials.
    static func mountOrFind(host: String, share: String, user: String?) -> Result<URL, Error> {
        if let v = existing(host: host, share: share) { return .success(v) }
        var comps = URLComponents()
        comps.scheme = "smb"; comps.host = host; comps.user = user; comps.path = "/" + share
        guard let url = comps.url else { return .failure(WebSetup.SetupError("Bad SMB address")) }
        let open = NSMutableDictionary()
        open["UIOption"] = "AllowUI"   // kNAUIOptionKey = kNAUIOptionAllowUI: let macOS ask for credentials
        var mountpoints: Unmanaged<CFArray>?
        let rc = NetFSMountURLSync(url as CFURL, nil, nil, nil, open, nil, &mountpoints)
        if rc == 0, let list = mountpoints?.takeRetainedValue() as? [String], let p = list.first {
            return .success(URL(fileURLWithPath: p, isDirectory: true))
        }
        if rc == EEXIST, let v = existing(host: host, share: share) { return .success(v) }
        if rc == ECANCELED || rc == -128 { return .failure(WebSetup.SetupError("Connecting to \(host) was cancelled.")) }
        return .failure(WebSetup.SetupError("Couldn't connect to smb://\(host)/\(share) (error \(rc)). Check the username and password, or mount it in Finder (⌘K) and try again."))
    }

    static func existing(host: String, share: String) -> URL? {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let remote = try? v.resourceValues(forKeys: Set(keys)).volumeURLForRemounting,
                  remote.scheme?.lowercased() == "smb", remote.host?.lowercased() == host.lowercased() else { continue }
            let remoteShare = remote.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if remoteShare.lowercased() == share.lowercased() { return v }
        }
        return nil
    }
}
