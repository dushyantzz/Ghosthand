import Foundation
import GhostHandCore

// MARK: - LayaServerManager
//
// Makes the LOCAL Laya decision model available on demand. If nothing is listening on
// the configured loopback port, it launches `laya_serve.py` with the checkpoints
// already on this machine (through the bundled resource or the repository copy) and
// waits until `/health` answers.
//
// Nothing here downloads anything: the checkpoints are read from disk and every cache
// is redirected into the app-support directory.

public final class LayaServerManager: @unchecked Sendable {
    private let options: LayaOptions
    private let lock = NSLock()
    private var process: Process?

    public init(options: LayaOptions) {
        self.options = options
    }

    // NOTE: no `deinit { stop() }` — the server is a long-lived local daemon, and a
    // temporary manager (as used by the CLI and the app's startup probe) must not
    // terminate a server the agent loop is about to use. Call `stop()` explicitly.

    /// True only when this manager launched the process (not when Laya was already running).
    public var startedByUs: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    // MARK: Public API

    /// Returns the server's health, starting it first if necessary.
    @discardableResult
    public func ensureRunning(report: ((String) -> Void)? = nil) async throws -> LayaHealth {
        let client = LayaClient(options: options)
        if let health = await client.health(), health.isOK {
            report?("Laya is already running (\(describe(health)))")
            return health
        }

        guard options.autoStartServer else {
            throw LayaError.serverUnavailable(
                "nothing is listening at \(options.baseUrl) and automatic start is disabled (LAYA_AUTOSTART=false)")
        }

        report?("Starting the local Laya server…")
        try start()

        let deadline = Date().addingTimeInterval(TimeInterval(max(10, options.startupTimeoutSeconds)))
        var lastError: String?
        while Date() < deadline {
            try Task.checkCancellation()
            if let health = await client.health(timeout: 3), health.isOK {
                report?("Laya ready (\(describe(health)))")
                return health
            }
            if let process, !process.isRunning {
                lastError = "the Laya server process exited during startup; see \(logFileURL.path)"
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw LayaError.serverUnavailable(
            lastError ?? "Laya did not become healthy within \(options.startupTimeoutSeconds)s (see \(logFileURL.path))")
    }

    /// Launch the server process. Safe to call repeatedly.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if let process, process.isRunning { return }

        let python = try resolvePython()
        let script = try resolveScript()
        let home = resolveHome()
        let modelsRoot = resolveModelsRoot(home: home)

        guard FileManager.default.fileExists(atPath: modelsRoot) else {
            throw LayaError.serverUnavailable(
                "no Laya checkpoints at '\(modelsRoot)'; set LAYA_MODELS_ROOT to the directory "
                    + "holding laya, laya-multilingual and laya-typed-decisions"
            )
        }

        let cacheRoot = Self.cacheRoot()
        for sub in ["hf", "torch", "xdg", "mpl", "pycache"] {
            try? FileManager.default.createDirectory(
                at: cacheRoot.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let (host, port) = Self.hostAndPort(from: options.baseUrl)

        var environment = ProcessInfo.processInfo.environment
        environment["LAYA_MODELS_ROOT"] = modelsRoot
        environment["LAYA_HOST"] = host
        environment["LAYA_PORT"] = String(port)
        environment["LAYA_DEVICE"] = environment["LAYA_DEVICE"] ?? "cpu"
        environment["LAYA_PRELOAD_MODELS"] = environment["LAYA_PRELOAD_MODELS"] ?? "english"
        environment["LAYA_THREADS"] = environment["LAYA_THREADS"] ?? "16"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["HF_HOME"] = cacheRoot.appendingPathComponent("hf").path
        environment["TRANSFORMERS_CACHE"] = cacheRoot.appendingPathComponent("hf").path
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["TORCH_HOME"] = cacheRoot.appendingPathComponent("torch").path
        environment["XDG_CACHE_HOME"] = cacheRoot.appendingPathComponent("xdg").path
        environment["MPLCONFIGDIR"] = cacheRoot.appendingPathComponent("mpl").path
        environment["PYTHONPYCACHEPREFIX"] = cacheRoot.appendingPathComponent("pycache").path
        // Prefer the canonical checkout over any vendored copy inside the interpreter.
        let pythonPath = [home, environment["PYTHONPATH"]].compactMap { $0 }.filter { !$0.isEmpty }
        environment["PYTHONPATH"] = pythonPath.joined(separator: ":")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script]
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.environment = environment
        if let handle = try? Self.openLogHandle(at: logFileURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
        } catch {
            throw LayaError.serverUnavailable("failed to launch \(python) \(script): \(error.localizedDescription)")
        }
        self.process = process
        GhostLog.shared.info("Started Laya server: \(python) \(script) (pid \(process.processIdentifier))")
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { self.process = nil; return }
        process.terminate()
        self.process = nil
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public var logFileURL: URL {
        Self.cacheRoot().appendingPathComponent("logs/laya-server.log")
    }

    // MARK: Resolution

    private func resolvePython() throws -> String {
        if !options.pythonPath.isBlank { return options.pythonPath }
        for candidate in Self.pythonCandidates() where FileManager.default.isExecutableFile(atPath: candidate) {
            if Self.pythonHasServeDependencies(candidate) { return candidate }
        }
        // Fall back to a bare python3 and let the failure explain itself in the log.
        for candidate in ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw LayaError.serverUnavailable(
            "no Python with Laya's serve extras (fastapi, uvicorn) and torch was found; set LAYA_PYTHON")
    }

    private func resolveScript() throws -> String {
        var candidates: [String] = []
        // NOTE: `Bundle.module` is deliberately not used. SwiftPM generates it as a
        // forced unwrap that traps when the resource bundle is missing, which would
        // abort before any fallback could run. Every location is probed explicitly.
        //
        // 1. Explicit override.
        if !options.serveScript.isBlank { candidates.append(options.serveScript) }

        // 2. Copies shipped inside the .app (Resources and next to the executable).
        if let resources = Bundle.main.resourceURL?.path {
            candidates.append(resources + "/laya_serve.py")
        }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent().path {
            candidates.append(executable + "/laya_serve.py")
        }

        // 3. Repository checkout (development runs from `macos/`).
        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(cwd + "/Scripts/laya_serve.py")
        candidates.append(cwd + "/macos/Scripts/laya_serve.py")

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        throw LayaError.serverUnavailable(
            "laya_serve.py was not found; set LAYA_SERVE_SCRIPT to its path")
    }

    private func resolveHome() -> String {
        if !options.home.isBlank { return options.home }
        for candidate in Self.homeCandidates() where FileManager.default.fileExists(atPath: candidate + "/laya") {
            return candidate
        }
        return Self.homeCandidates().first ?? ""
    }

    private func resolveModelsRoot(home: String) -> String {
        if !options.modelsRoot.isBlank { return options.modelsRoot }
        let candidates = [home + "/models", "/Users/threaded/projects/Laya-RAG/laya-rag/models"]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return home + "/models"
    }

    private static func pythonCandidates() -> [String] {
        [
            "/Users/threaded/projects/Laya-RAG/laya-rag/.venv/bin/python",
            "/Users/threaded/projects/Laya/laya/.venv/bin/python",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ]
    }

    private static func homeCandidates() -> [String] {
        [
            "/Users/threaded/projects/Laya/laya",
            "/Users/threaded/projects/Laya-RAG/laya-rag/vendor/laya",
        ]
    }

    private static func pythonHasServeDependencies(_ python: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import fastapi, uvicorn, torch, transformers"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: Helpers

    private static func cacheRoot() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("GhostHand/laya", isDirectory: true)
    }

    private static func openLogHandle(at url: URL) throws -> FileHandle {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        return handle
    }

    private static func hostAndPort(from baseUrl: String) -> (String, Int) {
        guard let url = URL(string: baseUrl), let host = url.host else { return ("127.0.0.1", 8000) }
        return (host, url.port ?? 8000)
    }

    private func describe(_ health: LayaHealth) -> String {
        let device = health.device ?? "unknown"
        let loaded = (health.loaded ?? []).joined(separator: ", ")
        return "device=\(device)\(loaded.isEmpty ? "" : " loaded=[\(loaded)]")"
    }
}
