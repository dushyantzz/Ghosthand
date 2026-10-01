import AppKit
import Foundation
import GhostHandCore

// MARK: - DiagnosticLogging
//
// Controls file logging for the menu-bar app.
//
// The preference is persisted in UserDefaults on purpose: the situation where a log matters most
// is a crash or a hang, and the app is relaunched after it. A toggle that reset on every launch
// would lose exactly the evidence the user is trying to hand over.

public enum DiagnosticLogging {
    public static let defaultsKey = "GhostHandVerboseLogging"

    /// `~/Library/Logs/GhostHand/ghosthand.log` — the conventional macOS location, and easy for a
    /// user to find and attach to a fault report.
    public static var logFileURL: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/GhostHand", isDirectory: true)
            .appendingPathComponent("ghosthand.log")
    }

    /// Whether the user has switched diagnostic logging on.
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Restores the persisted preference. Call once at launch.
    public static func applyPersistedSetting() {
        apply(enabled: isEnabled)
    }

    /// Turns diagnostic logging on or off, persists the choice, and applies it immediately.
    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        apply(enabled: enabled)
    }

    /// Reveals the log file in Finder, or its folder when nothing has been written yet.
    public static func revealInFinder() {
        let url = logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private static func apply(enabled: Bool) {
        guard enabled else {
            GhostLog.shared.filePath = nil
            GhostLog.shared.minimumLevel = .info
            return
        }

        let url = logFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            rotateIfNeeded(url)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        } catch {
            GhostLog.shared.error(
                "DiagnosticLogging: cannot prepare '\(url.path)': \(error.localizedDescription)"
            )
            return
        }

        GhostLog.shared.filePath = url.path
        GhostLog.shared.minimumLevel = .debug
        // A header per session (version + OS) makes an attached log self-describing, and the
        // debug line proves the level is actually debug rather than just requested.
        GhostLog.shared.info(sessionHeader())
        GhostLog.shared.debug("DiagnosticLogging: writing to '\(url.path)' at debug level.")
    }

    /// Single-step rotation so a long session cannot grow the log without bound.
    private static func rotateIfNeeded(_ url: URL) {
        let limitBytes = 5 * 1024 * 1024
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size >= limitBytes else { return }

        let backup = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    private static func sessionHeader() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return "=== GhostHand diagnostic logging enabled — v\(version), macOS \(osText) ==="
    }
}
