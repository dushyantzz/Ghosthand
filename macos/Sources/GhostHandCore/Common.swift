import Foundation

// MARK: - Environment loader
//
// Port of GhostHand.Core.Common.EnvLoader. Loads KEY=VALUE pairs from the nearest
// `.env` file (walking up to four parent directories) without overwriting variables
// already present in the process environment.

public enum EnvLoader {
    @discardableResult
    public static func load(directoryPath: String? = nil) -> String? {
        var searchDirs: [String] = []
        if let directoryPath, !directoryPath.isEmpty {
            searchDirs.append(directoryPath)
        } else {
            let exeDir = (Bundle.main.executableURL?.deletingLastPathComponent().path)
                ?? FileManager.default.currentDirectoryPath
            searchDirs.append(exeDir)
            let cwd = FileManager.default.currentDirectoryPath
            if cwd != exeDir { searchDirs.append(cwd) }
        }

        var envPath: String?
        for baseDir in searchDirs {
            var dir: String? = baseDir
            for _ in 0..<4 {
                guard let current = dir else { break }
                let candidate = (current as NSString).appendingPathComponent(".env")
                if FileManager.default.fileExists(atPath: candidate) {
                    envPath = candidate
                    break
                }
                let parent = (current as NSString).deletingLastPathComponent
                dir = (parent == current || parent.isEmpty) ? nil : parent
            }
            if envPath != nil { break }
        }

        guard let path = envPath, let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let splitIndex = trimmed.firstIndex(of: "="), splitIndex != trimmed.startIndex else { continue }

            let key = String(trimmed[trimmed.startIndex..<splitIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: splitIndex)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if (ProcessInfo.processInfo.environment[key] ?? "").isEmpty {
                setenv(key, value, 1)
            }
        }
        return path
    }
}

// MARK: - Clock

public final class SystemClock: Clock {
    public init() {}
    public var utcNow: Date { Date() }
    public func delay(_ duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
    }
}

// MARK: - Small string helpers (shared across the ported logic)

extension String {
    public var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Equivalent of C# `Uri.EscapeDataString`: percent-encodes everything except unreserved characters.
    public var escapedForURLQuery: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
