import AppKit
import Foundation
import GhostHandCore

// MARK: - MacAppLauncher
//
// macOS port of GhostHand.Platform.Launcher.AppLauncher.
//
// Behavioural mapping from Windows to macOS:
//   * App Paths registry / Start Menu shortcuts -> `/Applications` style bundle lookup
//     and `NSWorkspace.urlForApplication(withBundleIdentifier:)`.
//   * Process.Start(UseShellExecute) -> `NSWorkspace.openApplication(at:)`, with an
//     `/usr/bin/open -a <Name>` fallback (arguments only; no shell).
//   * "bring running window to foreground" -> `NSRunningApplication.activate()`.
//
// The Windows safety policy (refuse shells/script hosts and `-enc`/`/c`/`/k` style
// injection) is preserved with a macOS-appropriate disallowed list. Commands are never
// passed through a shell.

/// Errors thrown by ``MacAppLauncher``.
public enum MacAppLauncherError: Error, LocalizedError, Equatable {
    /// The app name or launch command tripped the safety policy.
    case blocked(String)
    /// `launchUrl` received a non-http(s) or malformed URL.
    case invalidURL(String)
    /// The operating system refused to launch/open the target.
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .blocked(reason):
            return "Launch was blocked by safety policy: \(reason)"
        case let .invalidURL(url):
            return "Invalid or non-http/https URL '\(url)'."
        case let .launchFailed(reason):
            return "Failed to launch application: \(reason)"
        }
    }
}

/// Extracts app/URL launch intents from a goal and opens them on macOS.
public final class MacAppLauncher: AppLauncherProtocol, @unchecked Sendable {

    /// Script hosts, shells and destructive system tools that must never be launched.
    private static let disallowedExecutables: Set<String> = [
        "terminal", "iterm", "iterm2", "osascript", "sh", "bash", "zsh", "csh", "tcsh",
        "ksh", "dash", "fish", "python", "python3", "perl", "ruby", "expect", "env",
        "xargs", "sudo", "su", "launchctl", "screencapture", "defaults", "nvram",
        "spctl", "csrutil", "diskutil", "dd", "rm", "kill", "killall",
    ]

    /// Extensions that denote executable scripts rather than apps.
    private static let disallowedExtensions: Set<String> = [
        "sh", "bash", "zsh", "command", "scpt", "applescript", "py", "rb", "pl", "ps1",
        "bat", "cmd", "vbs",
    ]

    /// Shell metacharacters never allowed in a name/command.
    private static let shellMetacharacters = CharacterSet(charactersIn: ";&|`$()<>\\\"'\n\r\t")

    /// Injection flags seen on Windows shells that must never be forwarded.
    private static let injectionTokens = ["-enc", "-encodedcommand", "-e", "-c", "-k", "/c", "/k"]

    public init() {}

    // MARK: - Intent extraction

    /// Returns `(appName, launchCommand)` for the first safe, resolvable app named in `goal`.
    public func tryExtractAppLaunch(goal: String) -> (appName: String, launchCommand: String)? {
        let candidates = LayaDecisionModel.extractAppLaunchCandidates(goal)
        for candidate in candidates {
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, Self.isSafeName(name) else { continue }
            if let url = Self.resolveApplicationURL(named: name) {
                return (appName: name, launchCommand: url.path)
            }
            // Fall back to `open -a <Name>` semantics.
            return (appName: name, launchCommand: name)
        }
        return nil
    }

    /// Returns the first validated web URL named in `goal`.
    public func tryExtractUrlLaunch(goal: String) -> URL? {
        UrlLauncherValidator.extractWebURLs(from: goal).first
    }

    // MARK: - Launching

    /// Focuses an already-running app when possible, otherwise launches it, then waits
    /// up to ~5s for a window to appear.
    public func launchApp(name: String, launchCommand: String?) async throws -> AppTarget? {
        let appName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeName(appName) else {
            throw MacAppLauncherError.blocked("unsafe application name '\(name)'.")
        }

        let command = normalizedCommand(launchCommand)
        if let command, !Self.isSafeCommand(command) {
            throw MacAppLauncherError.blocked("unsafe launch command '\(command)'.")
        }

        let resolvedURL = Self.resolveApplicationURL(named: command ?? appName)
            ?? Self.resolveApplicationURL(named: appName)
        let expectedProcess = Self.expectedProcessName(appURL: resolvedURL, fallback: appName)

        // 1. Already running -> focus it (mirrors FindRunningAppTarget + BringWindowToForeground).
        if let running = Self.findRunningApplication(name: appName, appURL: resolvedURL, command: command) {
            GhostLog.shared.info(
                "MacAppLauncher: '\(appName)' is already running (pid \(running.processIdentifier)); activating."
            )
            running.activate()
            if let target = await waitForWindow(
                processName: expectedProcess,
                processId: running.processIdentifier,
                timeout: 3.0
            ) {
                return target
            }
        }

        // 2. Launch it.
        if let resolvedURL {
            try await Self.openApplication(at: resolvedURL)
        } else {
            try Self.openWithLaunchServices(appName: appName)
        }

        // 3. Wait for the window to appear and become foreground.
        return await waitForWindow(processName: expectedProcess, processId: nil, timeout: 5.0)
    }

    /// Validates and opens a web URL, then waits up to ~5s for a browser window.
    public func launchUrl(_ url: URL) async throws -> AppTarget? {
        let raw = url.absoluteString
        guard let validated = UrlLauncherValidator.isValidWebURL(raw) else {
            throw MacAppLauncherError.invalidURL(raw)
        }
        GhostLog.shared.info("MacAppLauncher: opening URL \(validated.absoluteString)")
        guard NSWorkspace.shared.open(validated) else {
            throw MacAppLauncherError.launchFailed("NSWorkspace refused to open '\(validated.absoluteString)'.")
        }
        return await waitForWindow(processName: nil, processId: nil, timeout: 5.0)
    }

    // MARK: - Window waiting

    /// Polls for a target window; returns the best capture found within `timeout`.
    private func waitForWindow(
        processName: String?,
        processId: Int32?,
        timeout: TimeInterval
    ) async -> AppTarget? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastForeground: AppTarget?

        while Date() < deadline {
            if Task.isCancelled { break }

            if let processId, let target = MacWindowCaptureService.captureWindow(processId: processId) {
                return target
            }
            if let processName, !processName.isEmpty,
               let target = MacWindowCaptureService.captureWindow(processName: processName),
               !MacWindowCaptureService.isDesktopOrShell(target) {
                return target
            }
            if let foreground = MacWindowCaptureService.captureCurrentForegroundWindow(),
               !MacWindowCaptureService.isDesktopOrShell(foreground) {
                if let processName, !processName.isEmpty {
                    if Self.target(foreground, matches: processName) {
                        return foreground
                    }
                    lastForeground = foreground
                } else {
                    return foreground
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        // Final fallback captures (mirrors WaitForNewForegroundTargetAsync).
        if let processId, let target = MacWindowCaptureService.captureWindow(processId: processId) {
            return target
        }
        if let processName, !processName.isEmpty,
           let target = MacWindowCaptureService.captureWindow(processName: processName) {
            return target
        }
        return lastForeground ?? MacWindowCaptureService.captureCurrentForegroundWindow()
    }

    private static func target(_ target: AppTarget, matches processName: String) -> Bool {
        let wanted = processName.lowercased()
        let actual = target.processName.lowercased()
        if actual == wanted || actual.contains(wanted) || wanted.contains(actual) {
            return true
        }
        if target.windowTitle.lowercased().contains(wanted) {
            return true
        }
        if let bundle = target.bundleIdentifier?.lowercased(), bundle.contains(wanted) {
            return true
        }
        return false
    }

    // MARK: - Running-app lookup

    private static func findRunningApplication(
        name: String,
        appURL: URL?,
        command: String?
    ) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        let targetBundleId = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }

        if let targetBundleId,
           let match = running.first(where: { $0.bundleIdentifier == targetBundleId }) {
            return match
        }

        let lowered = name.lowercased()
        if let match = running.first(where: { ($0.localizedName ?? "").lowercased() == lowered }) {
            return match
        }

        // Substring match, mirroring the C# Contains-based fallback.
        return running.first(where: { app in
            guard app.activationPolicy != .prohibited else { return false }
            let localized = (app.localizedName ?? "").lowercased()
            guard !localized.isEmpty else { return false }
            return localized.contains(lowered) || lowered.contains(localized)
        })
    }

    // MARK: - Resolution

    /// Resolves an app name (or path, or bundle identifier) to a `.app` bundle URL.
    private static func resolveApplicationURL(named rawName: String) -> URL? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !name.isEmpty else { return nil }

        let fileManager = FileManager.default

        // Direct path.
        if name.contains("/") {
            if fileManager.fileExists(atPath: name) {
                return URL(fileURLWithPath: name)
            }
            let withExtension = name.hasSuffix(".app") ? name : name + ".app"
            if fileManager.fileExists(atPath: withExtension) {
                return URL(fileURLWithPath: withExtension)
            }
        }

        // Literal `<Name>.app` on disk, then in the standard app directories.
        if name.lowercased().hasSuffix(".app") {
            if fileManager.fileExists(atPath: name) {
                return URL(fileURLWithPath: name)
            }
            for directory in appSearchDirectories() {
                let candidate = directory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        // Bundle identifier (e.g. "com.apple.Safari").
        if name.contains("."), !name.contains(" "), !name.contains("/") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
                return url
            }
        }

        // Case-insensitive scan of the standard application directories.
        let wanted = name.lowercased()
        let wantedWithExtension = wanted.hasSuffix(".app") ? wanted : wanted + ".app"
        let directories = appSearchDirectories()

        for directory in directories {
            for entry in appBundles(in: directory) {
                let filename = entry.lastPathComponent.lowercased()
                let stem = entry.deletingPathExtension().lastPathComponent.lowercased()
                if filename == wantedWithExtension || stem == wanted {
                    return entry
                }
            }
        }

        // Last resort: substring match (mirrors the Start Menu substring fallback).
        for directory in directories {
            for entry in appBundles(in: directory)
            where entry.lastPathComponent.lowercased().contains(wanted) {
                return entry
            }
        }

        return nil
    }

    private static func appBundles(in directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.filter { $0.pathExtension.lowercased() == "app" }
    }

    private static func appSearchDirectories() -> [URL] {
        var directories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
        ]
        directories.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        )
        return directories
    }

    private static func expectedProcessName(appURL: URL?, fallback: String) -> String {
        if let appURL {
            let stem = appURL.deletingPathExtension().lastPathComponent
            if !stem.isEmpty { return stem }
        }
        return fallback
    }

    private func normalizedCommand(_ launchCommand: String?) -> String? {
        guard let launchCommand else { return nil }
        let trimmed = launchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Opening

    private static func openApplication(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(
                        throwing: MacAppLauncherError.launchFailed(error.localizedDescription)
                    )
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// `open -a <Name>` semantics without a shell: `/usr/bin/open` receives the name as
    /// a single argument, so no metacharacter can be interpreted.
    private static func openWithLaunchServices(appName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName]
        do {
            try process.run()
        } catch {
            throw MacAppLauncherError.launchFailed(error.localizedDescription)
        }
    }

    // MARK: - Safety policy

    private static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard name.rangeOfCharacter(from: shellMetacharacters) == nil else { return false }
        guard !name.lowercased().hasSuffix(".app/") else { return false }

        let stem = baseName(name)
        guard !disallowedExecutables.contains(stem) else { return false }
        guard !disallowedExtensions.contains(extensionOf(name)) else { return false }
        return true
    }

    private static func isSafeCommand(_ command: String) -> Bool {
        guard !command.isEmpty else { return false }
        guard command.rangeOfCharacter(from: shellMetacharacters) == nil else { return false }

        let stem = baseName(command)
        if disallowedExecutables.contains(stem) { return false }
        if disallowedExtensions.contains(extensionOf(command)) { return false }

        let lowered = " " + command.lowercased() + " "
        for token in injectionTokens
        where lowered.contains(" \(token) ") || lowered.contains(" \(token)=") {
            return false
        }
        return true
    }

    private static func baseName(_ value: String) -> String {
        var name = (value as NSString).lastPathComponent.lowercased()
        for suffix in [".app", ".exe"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    private static func extensionOf(_ value: String) -> String {
        (value as NSString).pathExtension.lowercased()
    }
}
