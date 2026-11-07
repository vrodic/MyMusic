import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

enum HTTPResponse {
    case data(status: Int, contentType: String, body: Data)
    case file(URL)
    case redirect(URL)
    case notFound
    case badRequest(String)

    static func json<T: Encodable>(_ v: T) -> HTTPResponse {
        (try? JSONEncoder().encode(v)).map { .data(status: 200, contentType: "application/json", body: $0) }
            ?? .data(status: 500, contentType: "text/plain", body: Data("encode error".utf8))
    }
}

/// Minimal HTTP/1.1 server on Network.framework, advertised over Bonjour.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse
    private let queue = DispatchQueue(label: "mymusic.http", attributes: .concurrent)
    private var listener: NWListener?
    private let handler: Handler
    var onStateChange: (@Sendable (String) -> Void)?
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) { self.handler = handler }

    func start(name: String, port: UInt16 = MyMusicService.defaultPort) {
        stop()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l: NWListener
            if let p = NWEndpoint.Port(rawValue: port), let ll = try? NWListener(using: params, on: p) { l = ll }
            else { l = try NWListener(using: params) }
            l.service = NWListener.Service(name: name, type: MyMusicService.bonjourType)
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = l?.port?.rawValue ?? 0
                    self.onStateChange?("Listening on port \(self.port)")
                case .failed(let e): self.onStateChange?("Failed: \(e)")
                case .cancelled: self.onStateChange?("Stopped")
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
        } catch {
            onStateChange?("Failed: \(error)")
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    var isRunning: Bool { listener != nil }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if err != nil || (done && data == nil) { c.cancel(); return }
            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if buf.count > 64 * 1024 { c.cancel() } else { self.receive(c, buffer: buf) }
                return
            }
            guard var req = Self.parseHead(buf[..<headerEnd.lowerBound]) else { self.sendSimple(c, 400, "bad request"); return }
            let length = Int(req.headers["content-length"] ?? "0") ?? 0
            let bodySoFar = buf[headerEnd.upperBound...]
            if bodySoFar.count < length {
                if length > 64 * 1024 * 1024 { self.sendSimple(c, 413, "too large"); return }
                self.receive(c, buffer: buf)
                return
            }
            req.body = Data(bodySoFar.prefix(length))
            self.respond(c, req)
        }
    }

    private static func parseHead(_ d: Data) -> HTTPRequest? {
        guard let s = String(data: d, encoding: .utf8) else { return nil }
        let lines = s.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let comps = URLComponents(string: String(parts[1]))
        var q: [String: String] = [:]
        comps?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        return HTTPRequest(method: String(parts[0]), path: comps?.path ?? "/", query: q, headers: headers, body: Data())
    }

    private func respond(_ c: NWConnection, _ req: HTTPRequest) {
        switch handler(req) {
        case .data(let status, let type, let body):
            send(c, status: status, headers: ["Content-Type": type, "Content-Length": "\(body.count)"], body: body)
        case .notFound: sendSimple(c, 404, "not found")
        case .badRequest(let m): sendSimple(c, 400, m)
        case .file(let url): sendFile(c, url: url, range: req.headers["range"], headOnly: req.method == "HEAD")
        case .redirect(let url): send(c, status: 302, headers: ["Location": url.absoluteString, "Content-Length": "0"], body: Data())
        }
    }

    private func sendSimple(_ c: NWConnection, _ status: Int, _ msg: String) {
        send(c, status: status, headers: ["Content-Type": "text/plain", "Content-Length": "\(msg.utf8.count)"], body: Data(msg.utf8))
    }

    private func head(_ status: Int, _ headers: [String: String]) -> Data {
        let reason = [200: "OK", 206: "Partial Content", 302: "Found", 400: "Bad Request", 404: "Not Found", 413: "Payload Too Large", 416: "Range Not Satisfiable", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "OK"
        var s = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        return Data((s + "\r\n").utf8)
    }

    private func send(_ c: NWConnection, status: Int, headers: [String: String], body: Data) {
        var d = head(status, headers); d.append(body)
        c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
    }

    private func sendFile(_ c: NWConnection, url: URL, range: String?, headOnly: Bool) {
        guard let fh = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            sendSimple(c, 404, "not found"); return
        }
        var start: Int64 = 0, end: Int64 = size - 1, status = 200
        if let range, range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2 {
                if spec[0].isEmpty, let suffix = Int64(spec[1]) { start = max(0, size - suffix) }
                else { start = Int64(spec[0]) ?? 0; if let e = Int64(spec[1]) { end = min(e, size - 1) } }
                status = 206
            }
            if start > end || start >= size {
                send(c, status: 416, headers: ["Content-Range": "bytes */\(size)", "Content-Length": "0"], body: Data()); return
            }
        }
        var headers = ["Content-Type": Self.mime(url.pathExtension), "Content-Length": "\(end - start + 1)", "Accept-Ranges": "bytes"]
        if status == 206 { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        c.send(content: head(status, headers), completion: .contentProcessed { _ in })
        if headOnly { c.send(content: nil, contentContext: .finalMessage, completion: .contentProcessed { _ in c.cancel() }); return }
        try? fh.seek(toOffset: UInt64(start))
        sendChunk(c, fh: fh, remaining: end - start + 1)
    }

    private func sendChunk(_ c: NWConnection, fh: FileHandle, remaining: Int64) {
        if remaining <= 0 { try? fh.close(); c.send(content: nil, contentContext: .finalMessage, completion: .contentProcessed { _ in c.cancel() }); return }
        let n = Int(min(remaining, 512 * 1024))
        guard let chunk = try? fh.read(upToCount: n), !chunk.isEmpty else { try? fh.close(); c.cancel(); return }
        c.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil { try? fh.close(); c.cancel(); return }
            self?.sendChunk(c, fh: fh, remaining: remaining - Int64(chunk.count))
        })
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": "audio/mpeg"
        case "m4a", "m4b", "alac", "mp4", "aac": "audio/mp4"
        case "flac": "audio/flac"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        default: "application/octet-stream"
        }
    }
}
