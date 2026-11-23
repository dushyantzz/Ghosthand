import Foundation

// MARK: - GhostLog
//
// Minimal leveled logger used across the port. Writes to stderr and, when a path is
// configured, appends to a log file. Kept dependency-free so GhostHandCore stays
// platform-independent (the Windows build used Microsoft.Extensions.Logging/Serilog).

/// Severity levels ordered from most verbose (`trace`) through most severe (`error`).
public enum GhostLogLevel: Int, Comparable, Sendable {
    case trace = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4

    /// Orders levels by ascending severity so comparisons such as `level >= minimumLevel` work.
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

/// A leveled logger that writes to stderr and optionally mirrors to stdout or a log file.
public final class GhostLog: @unchecked Sendable {
    public static let shared = GhostLog()

    private let lock = NSLock()
    private let formatter: DateFormatter

    private var storedMinimumLevel: GhostLogLevel = .info
    private var storedFilePath: String?
    private var storedMirrorToStdout = false

    /// Minimum severity that is written; reads and writes take the logger's lock, so it can
    /// be reconfigured at runtime while other threads are logging.
    public var minimumLevel: GhostLogLevel {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedMinimumLevel
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedMinimumLevel = newValue
        }
    }

    /// Destination log file, or nil to disable file logging. Synchronized like `minimumLevel`.
    public var filePath: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedFilePath
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedFilePath = newValue
        }
    }

    /// When true, also mirror to stdout (used by the CLI). Synchronized like `minimumLevel`.
    public var mirrorToStdout: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedMirrorToStdout
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedMirrorToStdout = newValue
        }
    }

    /// Creates a logger with its own timestamp formatter; most callers should use `GhostLog.shared`.
    public init() {
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
    }

    /// Writes one leveled message to stderr and, when configured, to stdout and the log file.
    ///
    /// The configuration snapshot, timestamp formatting and write all happen under a single
    /// lock acquisition, so a concurrent reconfiguration cannot tear the output and the
    /// non-thread-safe `DateFormatter` is never used from two threads at once.
    public func log(_ level: GhostLogLevel, _ message: String, file: String = #fileID, line: Int = #line) {
        lock.lock()
        defer { lock.unlock() }
        guard level >= storedMinimumLevel else { return }
        let timestamp = formatter.string(from: Date())
        let source = (file.split(separator: "/").last.map(String.init) ?? file)
        let lineText = "[\(timestamp)] [\(level.label)] \(source):\(line) \(message)\n"

        FileHandle.standardError.write(Data(lineText.utf8))
        if storedMirrorToStdout { FileHandle.standardOutput.write(Data(lineText.utf8)) }
        if let path = storedFilePath {
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
    }

    /// Logs a message at trace level.
    public func trace(_ message: String, file: String = #fileID, line: Int = #line) { log(.trace, message, file: file, line: line) }
    /// Logs a message at debug level.
    public func debug(_ message: String, file: String = #fileID, line: Int = #line) { log(.debug, message, file: file, line: line) }
    /// Logs a message at info level.
    public func info(_ message: String, file: String = #fileID, line: Int = #line) { log(.info, message, file: file, line: line) }
    /// Logs a message at warning level.
    public func warning(_ message: String, file: String = #fileID, line: Int = #line) { log(.warning, message, file: file, line: line) }
    /// Logs a message at error level.
    public func error(_ message: String, file: String = #fileID, line: Int = #line) { log(.error, message, file: file, line: line) }
}

/// Logs an informational message through the process-wide shared logger.
public func ghostLogInfo(_ message: String) { GhostLog.shared.info(message) }
