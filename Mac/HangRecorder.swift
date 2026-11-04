import Foundation

/// Watches the main thread. If it stops responding for more than `threshold`, records a
/// `sample` of this process (what every thread is doing) to ~/Library/Logs/MyMusic/, so an
/// occasional beachball can be diagnosed afterwards. Costs one tiny main-queue hop per 0.25 s.
final class HangRecorder: @unchecked Sendable {
    static let shared = HangRecorder()
    static var logDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MyMusic", isDirectory: true) }

    private let threshold: TimeInterval = 0.5
    private var lastSample = Date.distantPast
    private let lock = NSLock()
    private var answered = true

    func start() {
        try? FileManager.default.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
        let t = Thread { [weak self] in self?.run() }
        t.name = "HangRecorder"
        t.qualityOfService = .utility
        t.start()
    }

    private func run() {
        while true {
            lock.withLock { answered = false }
            let sent = Date()
            DispatchQueue.main.async { [weak self] in self?.lock.withLock { self?.answered = true } }
            Thread.sleep(forTimeInterval: 0.25)
            guard !lock.withLock({ answered }) else { continue }
            // main thread is late: wait until it crosses the threshold, then sample it while still stuck
            var sampled: URL?
            while !lock.withLock({ answered }) {
                if sampled == nil, Date().timeIntervalSince(sent) > threshold, Date().timeIntervalSince(lastSample) > 30 {
                    lastSample = Date()
                    sampled = sample()
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let ms = Int(Date().timeIntervalSince(sent) * 1000)
            if ms > Int(threshold * 1000) { log("main thread blocked \(ms) ms" + (sampled.map { " — sample: \($0.lastPathComponent)" } ?? "")) }
        }
    }

    private func sample() -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Self.logDir.appendingPathComponent("hang-\(f.string(from: Date())).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "2", "-file", url.path]
        let errURL = Self.logDir.appendingPathComponent("sample-errors.log")
        if !FileManager.default.fileExists(atPath: errURL.path) { FileManager.default.createFile(atPath: errURL.path, contents: nil) }
        let err = try? FileHandle(forWritingTo: errURL)
        err?.seekToEndOfFile()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err ?? FileHandle.nullDevice
        try? p.run()   // runs alongside; captures the next 2 s
        return url
    }

    private func log(_ line: String) {
        let url = Self.logDir.appendingPathComponent("hangs.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? Data(text.utf8).write(to: url) }
    }
}
