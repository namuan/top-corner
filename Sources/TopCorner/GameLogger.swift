import Foundation

// MARK: - GameLogger

/// File-based logger with rolling log files.
/// Writes to ~/Library/Logs/TopCorner/TopCorner.log
/// Rotates when the current file exceeds 512 KB; keeps the 5 most recent archives.
final class GameLogger {

    static let shared = GameLogger()

    // MARK: Config
    private let maxFileSize: Int = 512 * 1_024   // 512 KB
    private let maxArchives: Int = 4             // keep 4 archives + 1 current = 5 total

    // MARK: Internals
    private let logDir:       URL
    private var fileHandle:   FileHandle?
    private let queue         = DispatchQueue(label: "com.topcorner.logger", qos: .utility)

    private let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private init() {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        logDir = lib.appendingPathComponent("Logs/TopCorner")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        openCurrentFile()
        writeRaw("────────────────────────────────────────────────────────────────────")
        writeRaw("TopCorner launched  \(tsFormatter.string(from: Date()))")
        writeRaw("Log directory: \(logDir.path)")
        writeRaw("────────────────────────────────────────────────────────────────────")
    }

    // MARK: - Public API

    enum Level: String {
        case debug   = "DEBUG"
        case info    = "INFO "
        case warning = "WARN "
        case error   = "ERROR"
    }

    func log(_ message: String,
             level: Level = .info,
             file: String = #file,
             line: Int = #line) {
        queue.async { [weak self] in
            guard let self else { return }
            let ts    = self.tsFormatter.string(from: Date())
            let fname = (file as NSString).lastPathComponent
            let entry = "[\(ts)] [\(level.rawValue)] [\(fname):\(line)] \(message)\n"
            self.checkedWrite(entry)
        }
    }

    // MARK: - Private

    private func currentFileURL() -> URL {
        logDir.appendingPathComponent("TopCorner.log")
    }

    private func openCurrentFile() {
        let url = currentFileURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    private func rotate() {
        fileHandle?.closeFile()
        fileHandle = nil

        let current   = currentFileURL()
        let timestamp = fileFormatter.string(from: Date())
        let archived  = logDir.appendingPathComponent("TopCorner_\(timestamp).log")
        try? FileManager.default.moveItem(at: current, to: archived)

        pruneOldArchives()
        openCurrentFile()
        let ts = tsFormatter.string(from: Date())
        writeRaw("── Log rotated \(ts) ─────────────────────────────────────────────")
    }

    private func pruneOldArchives() {
        guard let all = try? FileManager.default.contentsOfDirectory(
            at: logDir, includingPropertiesForKeys: [.creationDateKey], options: []
        ) else { return }

        let archives = all
            .filter { $0.lastPathComponent.hasPrefix("TopCorner_") && $0.pathExtension == "log" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }

        let excess = archives.count - maxArchives
        guard excess > 0 else { return }
        archives.prefix(excess).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Must be called on `queue`.
    private func checkedWrite(_ entry: String) {
        let url  = currentFileURL()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size >= maxFileSize { rotate() }
        guard let data = entry.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    /// Synchronous raw write — only used during init before the queue is busy.
    private func writeRaw(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        fileHandle?.write(data)
    }
}

// MARK: - Module-level shorthand

@inline(__always)
func gLog(_ message: String,
          _ level: GameLogger.Level = .info,
          file: String = #file,
          line: Int = #line) {
    GameLogger.shared.log(message, level: level, file: file, line: line)
}
