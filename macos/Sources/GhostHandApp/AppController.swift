import AppKit
import ApplicationServices
import Foundation
import GhostHandCore
import GhostHandPlatform

// MARK: - AppDelegate
//
// Port of GhostHand.App.App: single-instance guard, first-run API key setup,
// hotkey wiring, and the agent-run orchestrator.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        EnvLoader.load()
        GhostLog.shared.minimumLevel = .info

        // Single-instance guard (equivalent to the Windows named mutex).
        if !SingleInstance.acquire() {
            let alert = NSAlert()
            alert.messageText = "GhostHand is already running"
            alert.informativeText = "GhostHand is already running in the background. Press Control + Option to activate it."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let controller = AppController()
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        SingleInstance.release()
    }
}

// MARK: - SingleInstance

enum SingleInstance {
    private static var handle: FileHandle?

    /// Uses an advisory lock on a lock file in the app-support directory.
    static func acquire() -> Bool {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhostHand", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("ghosthand.lock")

        if !FileManager.default.fileExists(atPath: lockURL.path) {
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: lockURL) else { return true }
        if flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            try? handle.close()
            return false
        }
        self.handle = handle
        return true
    }

    static func release() {
        guard let handle else { return }
        flock(handle.fileDescriptor, LOCK_UN)
        try? handle.close()
        self.handle = nil
    }
}

// MARK: - AppController

@MainActor
final class AppController: NSObject {
    private let credentialStore = KeychainCredentialStore(account: "LAYA_API_KEY")
    private let windowCapture = MacWindowCaptureService()
    private let hotkey = EventTapHotkeyService()
    private let appLauncher = MacAppLauncher()
    private let speech: SpeechInput? = MacSpeechService()
    private let auditLog = JsonlAuditLog()
    private let riskPolicy = DefaultRiskPolicy()

    private var overlay: OverlayPanel?
    private var statusBar: StatusBarController?
    private var apiKeyWindow: ApiKeySetupWindow?
    private var layaManager: LayaServerManager?

    private var runTask: Task<Void, Never>?
    private var isRunActive = false

    /// Laya configuration, with an optional bearer token from the Keychain.
    private func layaOptions() -> LayaOptions {
        let options = LayaOptions.fromEnvironment()
        if (options.apiKey ?? "").isBlank { options.apiKey = credentialStore.getApiKey() }
        return options
    }

    /// Starts (once) and retains the local Laya server manager.
    @discardableResult
    private func ensureLaya(_ options: LayaOptions) async throws -> LayaHealth {
        let manager: LayaServerManager
        if let existing = layaManager {
            manager = existing
        } else {
            let created = LayaServerManager(options: options)
            layaManager = created
            manager = created
        }
        return try await manager.ensureRunning { message in
            GhostLog.shared.info("Laya: \(message)")
        }
    }

    func start() {
        // The local Laya model runs on this machine and needs no credentials; start it
        // in the background so the first prompt is fast.
        Task { [weak self] in
            guard let self else { return }
            do {
                let health = try await self.ensureLaya(self.layaOptions())
                GhostLog.shared.info(
                    "Laya ready: device=\(health.device ?? "?") loaded=\(health.loaded ?? [])")
            } catch {
                GhostLog.shared.error("Laya is unavailable: \(error.localizedDescription)")
            }
        }

        let overlay = OverlayPanel(
            onSubmit: { [weak self] goal in self?.submit(goal: goal) },
            onCancel: { [weak self] in self?.cancelRun() },
            speech: speech
        )
        self.overlay = overlay

        statusBar = StatusBarController(
            onActivate: { [weak self] in self?.activatePrompt() },
            onSetApiKey: { [weak self] in self?.showApiKeySetup() },
            onQuit: { NSApp.terminate(nil) }
        )

        hotkey.onHotkeyPressed = { [weak self] in
            Task { @MainActor in self?.activatePrompt() }
        }
        hotkey.onKillSwitchTriggered = { [weak self] in
            Task { @MainActor in self?.killSwitch() }
        }
        hotkey.start()

        GhostLog.shared.info("GhostHand started (Laya mode). Press Control + Option to activate.")
    }

    func shutdown() {
        runTask?.cancel()
        hotkey.stop()
        overlay?.hide()
        // Stop the Laya server only if this app launched it.
        if let layaManager, layaManager.startedByUs { layaManager.stop() }
        layaManager = nil
    }

    // MARK: - Prompt lifecycle

    func activatePrompt() {
        if isRunActive {
            killSwitch()
            return
        }
        let target = windowCapture.captureForegroundWindow()
        GhostLog.shared.info("Trigger received. Target: \(target?.processName ?? "none") (\(target?.windowTitle ?? "none"))")
        overlay?.show(target: target)
    }

    func killSwitch() {
        GhostLog.shared.info("Kill switch triggered. Cancelling active task.")
        runTask?.cancel()
        overlay?.hide()
        setRunActive(false)
    }

    func cancelRun() {
        runTask?.cancel()
        setRunActive(false)
        overlay?.hide()
    }

    private func setRunActive(_ active: Bool) {
        isRunActive = active
        hotkey.stateMachine.isRunActive = active
        statusBar?.setRunning(active)
    }

    // MARK: - Agent run

    private func submit(goal: String) {
        let options = layaOptions()

        // Accessibility is required to read the screen and post synthetic input.
        if !AXIsProcessTrusted() {
            overlay?.updateStatus(
                "Accessibility permission is required. Enable GhostHand in System Settings › Privacy & Security › Accessibility.",
                isError: true)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        let target = overlay?.currentTarget ?? windowCapture.captureForegroundWindow()
        guard let target else {
            overlay?.updateStatus("No target window captured. Focus an app and try again.", isError: true)
            return
        }

        overlay?.beginRun(goal: goal, target: target)
        setRunActive(true)

        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }

            // Make sure the local Laya model is up before the loop starts.
            do {
                _ = try await self.ensureLaya(options)
            } catch {
                await MainActor.run {
                    self.setRunActive(false)
                    self.overlay?.finishRun(message: error.localizedDescription, success: false)
                }
                return
            }

            let decisionModel = LayaDecisionModel(client: LayaClient(options: options), options: options)
            let screenReader = AXScreenReader(options: .default, ocrService: VisionOcrService())
            let executor = MacActionExecutor(dryRun: false, appLauncher: self.appLauncher, ocrService: nil)
            executor.targetWindowHandle = target.windowHandle
            executor.expectedProcessId = target.processId

            var loopOptions = AgentLoopOptions()
            loopOptions.dryRun = false
            loopOptions.maxSteps = 0
            loopOptions.maxConsecutiveStalls = 15

            let loop = AgentLoop(
                screenReader: screenReader,
                decisionModel: decisionModel,
                actionExecutor: executor,
                options: loopOptions,
                riskPolicy: self.riskPolicy,
                confirmationPrompt: AlertConfirmationPrompt(),
                auditLog: self.auditLog,
                windowTracker: self.windowCapture
            )

            loop.onStatusChanged = { [weak self] message in
                Task { @MainActor in self?.overlay?.updateStatus(message, isError: false) }
            }
            loop.onTargetChanged = { [weak self] newTarget in
                Task { @MainActor in self?.overlay?.updateTarget(newTarget) }
            }

            let result = await loop.run(goal: goal, target: target)

            await MainActor.run {
                self.setRunActive(false)
                let success = result.status == .completed
                self.overlay?.finishRun(message: result.message ?? result.status.rawValue, success: success)
                GhostLog.shared.info("Agent loop finished: \(result.status.rawValue) — \(result.message ?? "")")
            }
        }
    }

    // MARK: - API key setup

    private func showApiKeySetup() {
        let window = ApiKeySetupWindow(credentialStore: credentialStore) { [weak self] in
            self?.apiKeyWindow = nil
        }
        apiKeyWindow = window
        window.show()
    }
}
