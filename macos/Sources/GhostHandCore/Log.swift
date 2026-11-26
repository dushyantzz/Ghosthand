import Foundation

// MARK: - GhostLog
//
// Minimal leveled logger used across the port. Writes to stderr and, when a path is
// configured, appends to a log file. Kept dependency-free so GhostHandCore stays
// platform-independent (the Windows build used Microsoft.Extensions.Logging/Serilog).

public enum GhostLogLevel: Int, Comparable, Sendable {
    case trace = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4

    public static func < (lhs: GhostLogLevel, rhs: GhostLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

public final class GhostLog: @unchecked Sendable {
    public static let shared = GhostLog()

    public var minimumLevel: GhostLogLevel = .info
    public var filePath: String?
    /// When true, also mirror to stdout (used by the CLI).
    public var mirrorToStdout = false

    private let lock = NSLock()
    private let formatter: DateFormatter

    public init() {
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
    }

    public func log(_ level: GhostLogLevel, _ message: String, file: String = #fileID, line: Int = #line) {
        guard level >= minimumLevel else { return }
        let timestamp = formatter.string(from: Date())
        let source = (file.split(separator: "/").last.map(String.init) ?? file)
        let lineText = "[\(timestamp)] [\(level.label)] \(source):\(line) \(message)\n"

        lock.lock()
        FileHandle.standardError.write(Data(lineText.utf8))
        if mirrorToStdout { FileHandle.standardOutput.write(Data(lineText.utf8)) }
        if let path = filePath {
            // Create the file if it is missing, then always append through a handle so a
            // failed open can never truncate lines already written.
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(lineText.utf8))
                try? handle.close()
            }
        }
        lock.unlock()
    }

    public func trace(_ message: String, file: String = #fileID, line: Int = #line) { log(.trace, message, file: file, line: line) }
    public func debug(_ message: String, file: String = #fileID, line: Int = #line) { log(.debug, message, file: file, line: line) }
    public func info(_ message: String, file: String = #fileID, line: Int = #line) { log(.info, message, file: file, line: line) }
    public func warning(_ message: String, file: String = #fileID, line: Int = #line) { log(.warning, message, file: file, line: line) }
    public func error(_ message: String, file: String = #fileID, line: Int = #line) { log(.error, message, file: file, line: line) }
}

public func ghostLogInfo(_ message: String) { GhostLog.shared.info(message) }
