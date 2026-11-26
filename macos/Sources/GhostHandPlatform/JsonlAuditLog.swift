import Foundation
import GhostHandCore

// MARK: - JsonlAuditLog
//
// macOS port of GhostHand.Platform.Safety.JsonlAuditLog.
//
// Writes one JSON object per line to `audit-YYYY-MM-DD.jsonl` inside
// `~/Library/Application Support/GhostHand/audit` (mirroring the Windows
// `%LOCALAPPDATA%\GhostHand\audit`). Concurrent writes are serialized with a lock,
// `log(_:)` never throws, and any failure is reported through `GhostLog`.
//
// The serialized shape matches the C# `AuditLogEntry` `[JsonPropertyName]` set:
// camelCase keys, `operation` as its PascalCase string, ISO-8601 timestamp, and
// omitted (rather than null) optional fields.

/// Thread-safe, append-only JSONL audit trail.
public final class JsonlAuditLog: AuditLog, @unchecked Sendable {

    /// Directory the daily `.jsonl` files are written to.
    public let directory: URL

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let dayFormatter: DateFormatter

    /// - Parameter directory: Override for the audit directory. Defaults to
    ///   `~/Library/Application Support/GhostHand/audit`.
    public init(directory: URL? = nil) {
        var resolved: URL
        if let directory {
            resolved = directory
        } else if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            resolved = appSupport
                .appendingPathComponent("GhostHand", isDirectory: true)
                .appendingPathComponent("audit", isDirectory: true)
        } else {
            resolved = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/GhostHand/audit", isDirectory: true)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // System.Text.Json does not escape forward slashes; keep URLs readable.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter

        do {
            try FileManager.default.createDirectory(
                at: resolved,
                withIntermediateDirectories: true
            )
        } catch {
            // Degrade gracefully rather than silently dropping the audit trail: fall
            // back to the temporary directory when Application Support is not writable
            // (a restricted sandbox, a read-only home, …).
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("GhostHand/audit", isDirectory: true)
            GhostLog.shared.warning(
                "JsonlAuditLog: cannot use '\(resolved.path)' (\(error.localizedDescription)); falling back to '\(fallback.path)'"
            )
            resolved = fallback
            try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        }
        self.directory = resolved
    }

    // MARK: - AuditLog

    /// Sanitizes the entry, then appends it as one JSON line. Never throws.
    public func log(_ entry: AuditLogEntry) async {
        var sanitized = entry
        sanitized.goal = SecretSanitizer.sanitize(entry.goal, isPassword: false)
        sanitized.targetLabel = entry.targetLabel.map { SecretSanitizer.sanitize($0, isPassword: false) }
        sanitized.reason = entry.reason.map { SecretSanitizer.sanitize($0, isPassword: false) }
        sanitized.appTitle = SecretSanitizer.sanitize(entry.appTitle, isPassword: false)

        // Serialize the actual write in a synchronous helper: NSLock is unavailable from
        // async contexts (an error under Swift 6 language mode).
        writeSynchronously(sanitized)
    }

    private func writeSynchronously(_ entry: AuditLogEntry) {
        let day = dayFormatter.string(from: entry.timestamp)
        let fileURL = directory.appendingPathComponent("audit-\(day).jsonl", isDirectory: false)

        lock.lock()
        defer { lock.unlock() }

        do {
            var line = try encoder.encode(entry)
            line.append(0x0A) // '\n' — one JSON object per line.
            try append(line, to: fileURL)
            GhostLog.shared.debug(
                "JsonlAuditLog: logged \(entry.decisionType) \(entry.operation.rawValue) "
                    + "for '\(entry.targetLabel ?? entry.targetId ?? "")'."
            )
        } catch {
            GhostLog.shared.error(
                "JsonlAuditLog: failed to write audit entry to '\(fileURL.path)': \(error.localizedDescription)"
            )
        }
    }

    // MARK: - File plumbing

    /// Appends `data` to `url`, creating the file (and directory) when missing.
    /// Callers must already hold `lock`.
    private func append(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
