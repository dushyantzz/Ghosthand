import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GhostHandCore
import GhostHandPlatform

// GhostHand CLI (macOS) — port of GhostHand.Cli.Program.
// Commands: check | snapshot | ocr | dry-run | run
//
// Top-level code: `await` is permitted in SwiftPM's main.swift.

// Keep URLSession from trying to write a disk cache outside the sandbox.
URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)

let exitCode = await CLIRunner.run(Array(CommandLine.arguments.dropFirst()))
exit(exitCode)

enum CLIRunner {
    static let version = "0.1.0"

    static func run(_ args: [String]) async -> Int32 {
        EnvLoader.load()
        if args.contains("--verbose") {
            GhostLog.shared.minimumLevel = .debug
        }
        Console.bold("GhostHand (macOS) CLI Diagnostic Tool v\(version)")
        print("")

        guard let command = args.first?.lowercased() else {
            printUsage()
            return 0
        }

        switch command {
        case "check": return await runCheck()
        case "snapshot": return await runSnapshot(args)
        case "ocr": return await runOcr(args)
        case "dry-run", "run": return await runAgent(args)
        default:
            Console.red("Unknown command: '\(command)'")
            printUsage()
            return 1
        }
    }

    static func printUsage() {
        print("Usage: ghosthand <command> [options]")
        print("")
        print("Commands:")
        print("  check                 Verify toolchain, Accessibility permission and the local Laya model")
        print("  snapshot [pid|name]   Capture and display the accessibility element tree of the frontmost window")
        print("  ocr [pid|name]        Verify Screen Recording permission and OCR the target window")
        print("  dry-run [goal]        Run a task without executing actions (simulated)")
        print("  run [goal] --live     Run a task with live execution (real input)")
        print("")
        print("Options:")
        print("  --live                Execute actions for real (default is dry-run)")
        print("  --target <name|pid>   Target a specific running application")
        print("  --yes                 Auto-approve any safety confirmation (testing only)")
        print("  --verbose             Enable debug logging (shows OCR capture path, AX walk details)")
    }

    // MARK: - check

    static func runCheck() async -> Int32 {
        print("Running environment checks...")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        print("  OS: macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(architecture))")
        print("  Swift runtime: \(swiftVersion)")

        if AXIsProcessTrusted() {
            Console.green("  Accessibility permission: GRANTED")
        } else {
            Console.yellow("  Accessibility permission: NOT GRANTED")
            Console.yellow("    -> System Settings > Privacy & Security > Accessibility > enable your terminal / GhostHand.app")
        }

        let options = LayaOptions.fromEnvironment()
        if (options.apiKey ?? "").isBlank {
            options.apiKey = KeychainCredentialStore().getApiKey()
        }

        print("\nChecking the local Laya decision model...")
        print("  Laya base URL: \(options.baseUrl)")
        print("  Model: \(options.model.isBlank ? "auto (routed by Laya)" : options.model)")
        print("  Token budget: max_len=\(options.maxLen), head_max_len=\(options.headMaxLen)")

        let manager = LayaServerManager(options: options)
        defer { if manager.startedByUs { manager.stop() } }
        let health: LayaHealth
        do {
            health = try await manager.ensureRunning { message in Console.yellow("  \(message)") }
        } catch {
            Console.red("\n[ERROR] \(error.localizedDescription)")
            Console.yellow("  Start it manually with: macos/Scripts/start-laya.sh")
            return 1
        }

        Console.green("  Server status: \(health.status ?? "?") | device: \(health.device ?? "?")")
        if let loaded = health.loaded, !loaded.isEmpty {
            print("  Checkpoints resident: \(loaded.joined(separator: ", "))")
        }

        // One real forward pass: a yes/no plus a choice question.
        print("\nRunning a test decision through Laya...")
        let client = LayaClient(options: options)
        let request = LayaRequest(
            state: .string(
                "System diagnostic report: Laya is running locally on this Mac, the decision "
                    + "service is healthy, and every check passed. Status: operational."
            ),
            questions: [
                "operational": .noul("Does the report say the status is operational?"),
                "nextStep": .choice(
                    [
                        "type": "Type the query into the address bar",
                        "wait": "Wait for the page to load",
                        "done": "The task is already complete",
                    ],
                    instructions: "Pick the best next step toward searching for Adele."
                ),
            ],
            model: options.model.isBlank ? nil : options.model,
            maxLen: options.maxLen,
            headMaxLen: options.headMaxLen
        )

        let start = Date()
        do {
            let response = try await client.decide(request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            Console.green("\n[SUCCESS] Laya answered in \(latency)ms")
            if let operational = response.tryGetNoul("operational") {
                print("  Answer 'operational': \(operational.isTrue) (P(yes): \(String(format: "%.1f%%", operational.probability * 100)))")
            }
            if let step = response.tryGetChoice("nextStep") {
                print("  nextStep: '\(step.choice)' (confidence: \(String(format: "%.1f%%", step.answerConfidence * 100)))")
            }
            if let routing = response.routing?.objectValue, let model = routing["model"]?.stringValue {
                print("  Routed to checkpoint: \(model)")
            }
            if let usage = response.usage, let tokens = usage.inputTokens {
                print("  Input tokens: \(tokens)")
            }
            print("\nAll diagnostic checks passed. GhostHand is wired to the local Laya model.")
            return 0
        } catch {
            Console.red("\n[ERROR] Laya evaluation failed: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - snapshot

    static func runSnapshot(_ args: [String]) async -> Int32 {
        print("GhostHand Window Snapshot")
        print(String(repeating: "-", count: 80))

        guard let target = await resolveTarget(args) else {
            Console.red("Failed to capture a target window.")
            return 1
        }

        Console.cyan("Target window: \"\(target.windowTitle)\"")
        print("Process: \(target.processName) (PID \(target.processId))")
        print("Bundle: \(target.bundleIdentifier ?? "unknown")")
        print(
            "Bounds: \(Int(target.bounds.width))x\(Int(target.bounds.height)) "
                + "at (\(Int(target.bounds.minX)), \(Int(target.bounds.minY)))"
        )

        print("\nTraversing the accessibility tree...")
        let start = Date()
        let reader = AXScreenReader(options: .default, ocrService: VisionOcrService())

        let elements: [AccessibilityElement]
        do {
            elements = try await reader.readElements(target: target)
        } catch {
            Console.red("Snapshot failed: \(error.localizedDescription)")
            return 1
        }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)

        Console.green("Completed in \(elapsed)ms | Found \(elements.count) elements")
        let ocrCount = elements.filter { $0.source == "ocr" }.count
        let interactiveCount = elements.filter { ElementRanker.isInteractive($0.role) }.count
        print("Interactive controls: \(interactiveCount) | OCR elements: \(ocrCount)")
        print(String(repeating: "-", count: 80))
        print(pad("ID", 5) + " | " + pad("Role", 16) + " | " + pad("State", 10) + " | Label / Text")
        print(String(repeating: "-", count: 80))

        for element in elements {
            let state = element.focused ? "[FOCUSED]" : (element.enabled ? "Enabled" : "Disabled")
            var label = element.displayLabel.isBlank ? "(empty)" : element.displayLabel
            if label.count > 60 { label = String(label.prefix(57)) + "..." }
            let line = pad(element.id, 5) + " | " + pad(element.displayRole, 16) + " | " + pad(state, 10) + " | " + label
            if element.focused {
                Console.yellow(line)
            } else if ElementRanker.isInteractive(element.role) {
                Console.cyan(line)
            } else {
                print(line)
            }
        }
        print(String(repeating: "-", count: 80))
        return 0
    }

    // MARK: - target resolution

    /// Resolves an optional `[pid|name]` argument, falling back to the frontmost window after a
    /// short delay so the user can focus the window they mean.
    private static func resolveTarget(_ args: [String]) async -> AppTarget? {
        var target: AppTarget?
        if args.count > 1, !args[1].isBlank, !args[1].hasPrefix("--") {
            let query = args[1]
            if let pid = Int32(query) {
                target = MacWindowCaptureService.captureWindow(processId: pid)
            } else {
                target = MacWindowCaptureService.captureWindow(processName: query)
            }
            if target == nil {
                Console.yellow("Could not find an active window for '\(query)'. Falling back to the frontmost window.")
            }
        }

        if target == nil {
            print("Focus the window you wish to capture. Capturing in 2 seconds...")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            target = MacWindowCaptureService.captureCurrentForegroundWindow()
        }
        return target
    }

    // MARK: - ocr

    /// Diagnostic for the OCR fallback: verifies Screen Recording permission and runs Vision OCR
    /// over the target window. The fallback only fires when the accessibility tree is sparse, so
    /// without this command the capture path is easy to break unnoticed.
    static func runOcr(_ args: [String]) async -> Int32 {
        print("GhostHand Vision OCR Diagnostic")
        print(String(repeating: "-", count: 80))

        // Screen Recording is a separate TCC grant from Accessibility.
        let granted = CGPreflightScreenCaptureAccess()
        if granted {
            Console.green("Screen Recording permission: GRANTED")
        } else {
            Console.yellow("Screen Recording permission: NOT GRANTED")
            Console.yellow(
                "  -> System Settings > Privacy & Security > Screen Recording > "
                    + "enable your terminal / GhostHand.app"
            )
            // Surfaces the system prompt once; returns immediately either way.
            _ = CGRequestScreenCaptureAccess()
        }

        guard let target = await resolveTarget(args) else {
            Console.red("Failed to capture a target window.")
            return 1
        }
        Console.cyan(
            "Target window: \"\(target.windowTitle)\" "
                + "(\(target.processName), PID \(target.processId))"
        )

        let start = Date()
        let elements = await VisionOcrService().recognizeScreenArea(target.bounds)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)

        guard !elements.isEmpty else {
            Console.yellow("No text recognized in \(elapsed)ms.")
            if !granted {
                Console.yellow("  This is expected until Screen Recording is granted.")
            }
            return granted ? 1 : 2
        }

        Console.green("Recognized \(elements.count) line(s) in \(elapsed)ms")
        for element in elements.prefix(40) {
            print("  \(pad(element.id, 6)) \(element.displayLabel)")
        }
        if elements.count > 40 {
            print("  ... and \(elements.count - 40) more")
        }
        return 0
    }

    // MARK: - agent run

    static func runAgent(_ args: [String]) async -> Int32 {
        let isLive = args.contains { $0.lowercased() == "--live" }
        let autoApprove = args.contains { $0.lowercased() == "--yes" }

        var goalArgs: [String] = []
        var targetName: String?
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg.lowercased() == "--target" || arg.lowercased() == "--process" {
                if index + 1 < args.count { targetName = args[index + 1] }
                index += 2
                continue
            }
            if !arg.hasPrefix("--") { goalArgs.append(arg) }
            index += 1
        }
        let goal = goalArgs.isEmpty ? "search for Adele" : goalArgs.joined(separator: " ")

        // macOS gates accessibility behind an explicit grant. Without it the agent can
        // neither read the screen nor post input, so it would act blind (and could
        // falsely report success). Refuse unless explicitly overridden for diagnostics.
        if !AXIsProcessTrusted(), ProcessInfo.processInfo.environment["GHOSTHAND_ALLOW_NO_AX"] != "1" {
            Console.red("Accessibility permission is not granted, so GhostHand cannot read or control other apps.")
            Console.yellow("Grant it in System Settings > Privacy & Security > Accessibility, then re-run.")
            Console.yellow("(Set GHOSTHAND_ALLOW_NO_AX=1 to run anyway for diagnostics.)")
            return 1
        }

        print(isLive ? "GhostHand Agent Loop — LIVE EXECUTION MODE" : "GhostHand Agent Loop — DRY-RUN MODE")
        print(String(repeating: "-", count: 80))
        print("Goal: \"\(goal)\"")
        if isLive {
            Console.yellow("WARNING: LIVE mode. Physical mouse/keyboard input will be performed. Deletion actions remain blocked.\n")
        } else {
            print("Executing in simulated mode (no physical mouse/keyboard input will be sent).\n")
        }

        var target: AppTarget?
        if let targetName, !targetName.isBlank {
            if let pid = Int32(targetName) {
                target = MacWindowCaptureService.captureWindow(processId: pid)
            } else {
                target = MacWindowCaptureService.captureWindow(processName: targetName)
            }
            if let captured = target {
                print("Found '\(targetName)' (PID \(captured.processId)). Activating...")
                NSRunningApplication(processIdentifier: captured.processId)?.activate()
                try? await Task.sleep(nanoseconds: 500_000_000)
            } else {
                Console.yellow("No running process found matching '\(targetName)'. Falling back to the frontmost window.\n")
            }
        }

        if target == nil {
            print("Click on your target window now (waiting 3 seconds)...")
            for countdown in stride(from: 3, through: 1, by: -1) {
                print("\(countdown)... ", terminator: "")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            print("Capturing!\n")
            target = MacWindowCaptureService.captureCurrentForegroundWindow()
        }

        guard let target else {
            Console.red("Failed to capture a target foreground window.")
            return 1
        }

        Console.cyan("Target window: \"\(target.windowTitle)\" (\(target.processName), PID \(target.processId))\n")

        let options = LayaOptions.fromEnvironment()
        if (options.apiKey ?? "").isBlank { options.apiKey = KeychainCredentialStore().getApiKey() }

        // Make sure the local Laya model is up before the loop starts. Retain the
        // manager for the whole run (the server must outlive this call), and shut the
        // server down afterwards only if this invocation started it.
        let layaManager = LayaServerManager(options: options)
        defer { if layaManager.startedByUs { layaManager.stop() } }
        do {
            _ = try await layaManager.ensureRunning { message in
                Console.yellow("  \(message)")
            }
        } catch {
            Console.red("Cannot reach the local Laya server: \(error.localizedDescription)")
            return 1
        }

        let decisionModel = LayaDecisionModel(client: LayaClient(options: options), options: options)
        let screenReader = AXScreenReader(options: .default, ocrService: VisionOcrService())
        let executor = MacActionExecutor(dryRun: !isLive, appLauncher: MacAppLauncher(), ocrService: nil)
        executor.targetWindowHandle = target.windowHandle
        executor.expectedProcessId = target.processId

        var loopOptions = AgentLoopOptions()
        loopOptions.dryRun = !isLive
        loopOptions.maxSteps = 10
        loopOptions.maxConsecutiveStalls = 3

        let loop = AgentLoop(
            screenReader: screenReader,
            decisionModel: decisionModel,
            actionExecutor: executor,
            options: loopOptions,
            riskPolicy: DefaultRiskPolicy(),
            confirmationPrompt: ConsoleConfirmationPrompt(autoApprove: autoApprove ? true : nil),
            auditLog: JsonlAuditLog(),
            windowTracker: MacWindowCaptureService()
        )

        loop.onStatusChanged = { message in Console.yellow("[STATUS] \(message)") }
        loop.onStepCompleted = { step, decision, result in
            let confidence = String(format: "%.0f%%", decision.confidence * 100)
            Console.green(
                "[STEP \(step)] Decision: \(decision.operation.rawValue) on "
                    + "'\(decision.targetLabel ?? decision.targetId ?? "")' (conf: \(confidence))"
            )
            print("         Result: \(result.success ? "SUCCESS" : "FAIL") — \(result.message ?? result.error ?? "")\n")
        }

        // Ctrl-C kill switch.
        let cancellation = CancellationBox()
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            print("\n[KILL SWITCH] Interrupted by user. Cancelling...")
            cancellation.cancel()
        }
        signalSource.resume()

        let runResult = await loop.run(goal: goal, target: target)
        signalSource.cancel()

        print(String(repeating: "-", count: 80))
        switch runResult.status {
        case .completed: Console.green("Result: COMPLETED (\(runResult.stepsCompleted) steps)")
        case .needsHumanInput: Console.yellow("Result: NEEDS HUMAN INPUT (\(runResult.stepsCompleted) steps)")
        case .stalled: Console.yellow("Result: STALLED (\(runResult.stepsCompleted) steps)")
        default: Console.red("Result: \(runResult.status.rawValue.uppercased()) (\(runResult.stepsCompleted) steps)")
        }
        print("Message: \(runResult.message ?? "")")
        print(String(repeating: "-", count: 80))
        return runResult.status == .completed ? 0 : 1
    }

    // MARK: - helpers

    static func pad(_ text: String, _ width: Int) -> String {
        if text.count >= width { return text }
        return text + String(repeating: " ", count: width - text.count)
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static var swiftVersion: String {
        #if swift(>=6.0)
        return "Swift 6.x"
        #else
        return "Swift 5.x"
        #endif
    }
}

/// Bridges the SIGINT handler to the task's cancellation state.
final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
