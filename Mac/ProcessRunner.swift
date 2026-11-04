import Foundation

/// Runs an external tool, streaming output lines; cancellable.
final class ProcessRunner: @unchecked Sendable {
    private var process: Process?
    private let lock = NSLock()

    static var searchPath: String {
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.deno/bin", "/usr/bin", "/bin"]
        return (extra + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])).joined(separator: ":")
    }

    static func which(_ tool: String) -> String? {
        for dir in searchPath.split(separator: ":") {
            let p = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    struct Output { var status: Int32; var stdout: Data; var stderr: String }

    func run(_ exe: String, _ args: [String], onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.searchPath
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let collector = Collector()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            collector.appendOut(d)
            if let s = String(data: d, encoding: .utf8) { s.split(whereSeparator: \.isNewline).forEach { onLine(String($0)) } }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            if let s = String(data: d, encoding: .utf8) {
                collector.appendErr(s)
                s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).forEach { onLine(String($0)) }
            }
        }
        lock.withLock { process = p }
        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                // drain remaining
                let restOut = out.fileHandleForReading.readDataToEndOfFile()
                let restErr = err.fileHandleForReading.readDataToEndOfFile()
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(restOut)
                collector.appendErr(String(data: restErr, encoding: .utf8) ?? "")
                cont.resume(returning: Output(status: proc.terminationStatus, stdout: collector.out, stderr: collector.err))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    func cancel() { lock.withLock { process?.terminate() } }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var out = Data()
        private(set) var err = ""
        func appendOut(_ d: Data) { lock.withLock { out.append(d) } }
        func appendErr(_ s: String) { lock.withLock { err += s; if err.count > 20000 { err = String(err.suffix(10000)) } } }
    }
}
