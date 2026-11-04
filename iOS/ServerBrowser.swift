import Foundation
import Network

struct DiscoveredServer: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

/// Finds Macs advertising `_mymusic._tcp` and resolves them to an http base URL.
@MainActor
final class ServerBrowser: ObservableObject {
    @Published private(set) var servers: [DiscoveredServer] = []
    @Published private(set) var state = "Searching…"
    private var browser: NWBrowser?

    func start() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: MyMusicService.bonjourType, domain: nil), using: .tcp)
        b.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                switch s {
                case .ready: self?.state = "Searching…"
                case .failed(let e): self?.state = "Discovery failed: \(e)"
                case .waiting(let e): self?.state = "Waiting: \(e) (allow Local Network access in Settings)"
                default: break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> DiscoveredServer? in
                if case .service(let name, _, _, _) = r.endpoint { return DiscoveredServer(name: name, endpoint: r.endpoint) }
                return nil
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.servers = list }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Resolves a Bonjour endpoint to "http://a.b.c.d:port" by briefly connecting to it (IPv4 preferred).
    nonisolated static func resolve(_ endpoint: NWEndpoint) async -> URL? {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let conn = NWConnection(to: endpoint, using: params)
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var url: URL?
                    if case .hostPort(let host, let port)? = conn.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                        if h.contains(":") { h = "[\(h)]" }
                        url = URL(string: "http://\(h):\(port.rawValue)")
                    }
                    conn.cancel()
                    once.run { cont.resume(returning: url) }
                case .failed, .cancelled:
                    once.run { cont.resume(returning: nil) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { conn.cancel(); once.run { cont.resume(returning: nil) } }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
    }
}
