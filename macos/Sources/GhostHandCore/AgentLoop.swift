import Foundation

// MARK: - AgentRunStatus / AgentRunResult
//
// Port of GhostHand.Core.Agent.AgentRunStatus and AgentRunResult.

public enum AgentRunStatus: String, Sendable {
    case completed = "Completed"
    case needsHumanInput = "NeedsHumanInput"
    case stalled = "Stalled"
    case maxStepsReached = "MaxStepsReached"
    case cancelled = "Cancelled"
    case failed = "Failed"
}

public struct AgentRunResult: Sendable {
    public var status: AgentRunStatus
    public var stepsCompleted: Int
    public var actionHistory: [String]
    public var message: String?

    public static func completed(steps: Int, history: [String]) -> AgentRunResult {
        AgentRunResult(status: .completed, stepsCompleted: steps, actionHistory: history, message: "Goal successfully achieved.")
    }

    public static func needsHumanInput(steps: Int, history: [String], reason: String?) -> AgentRunResult {
        AgentRunResult(status: .needsHumanInput, stepsCompleted: steps, actionHistory: history,
                       message: reason ?? "Human input required.")
    }

    public static func stalled(steps: Int, history: [String], reason: String?) -> AgentRunResult {
        AgentRunResult(status: .stalled, stepsCompleted: steps, actionHistory: history,
                       message: reason ?? "Loop guard tripped: screen state unchanged.")
    }

    public static func maxStepsReached(steps: Int, history: [String]) -> AgentRunResult {
        AgentRunResult(status: .maxStepsReached, stepsCompleted: steps, actionHistory: history,
                       message: "Reached maximum step limit (\(steps)).")
    }

    public static func failed(steps: Int, history: [String], error: String) -> AgentRunResult {
        AgentRunResult(status: .failed, stepsCompleted: steps, actionHistory: history, message: error)
    }

    public static func cancelled(steps: Int, history: [String]) -> AgentRunResult {
        AgentRunResult(status: .cancelled, stepsCompleted: steps, actionHistory: history, message: "Run was cancelled.")
    }
}

// MARK: - AgentLoop
//
// Port of GhostHand.Core.Agent.AgentLoop: observe -> decide -> safety-gate -> execute -> verify.

public final class AgentLoop {
    private let screenReader: ScreenReader
    private let decisionModel: DecisionModel
    private let actionExecutor: ActionExecutorProtocol
    private let options: AgentLoopOptions
    private let riskPolicy: RiskPolicy
    private let confirmationPrompt: ConfirmationPrompt?
    private let auditLog: AuditLog?
    private let windowTracker: WindowTracker?

    public var onStatusChanged: ((String) -> Void)?
    public var onStepCompleted: ((Int, AgentDecision, ActionResult) -> Void)?
    public var onTargetChanged: ((AppTarget) -> Void)?

    public init(
        screenReader: ScreenReader,
        decisionModel: DecisionModel,
        actionExecutor: ActionExecutorProtocol,
        options: AgentLoopOptions,
        riskPolicy: RiskPolicy? = nil,
        confirmationPrompt: ConfirmationPrompt? = nil,
        auditLog: AuditLog? = nil,
        windowTracker: WindowTracker? = nil
    ) {
        self.screenReader = screenReader
        self.decisionModel = decisionModel
        self.actionExecutor = actionExecutor
        self.options = options
        self.riskPolicy = riskPolicy ?? DefaultRiskPolicy()
        self.confirmationPrompt = confirmationPrompt
        self.auditLog = auditLog
        self.windowTracker = windowTracker
    }

    public func run(goal: String, target: AppTarget) async -> AgentRunResult {
        var currentTarget = target
        var history: [String] = []
        let loopGuard = LoopGuard(maxConsecutiveStalls: options.maxConsecutiveStalls)
        var step = 0
        let runId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))

        GhostLog.shared.info("Starting AgentLoop for goal '\(goal)' on target '\(currentTarget.processName)' (DryRun: \(options.dryRun))")

        // Security check 1: strictly prohibited goal (e.g. deletion tasks).
        if let goalProhibitedReason = riskPolicy.isGoalProhibited(goal) {
            GhostLog.shared.warning("Goal prohibited by policy: \(goalProhibitedReason)")
            notifyStatus(goalProhibitedReason)
            if let auditLog {
                await auditLog.log(AuditLogEntry(
                    runId: runId, step: 0, goal: goal, operation: .askUser,
                    appProcess: currentTarget.processName, appTitle: currentTarget.windowTitle,
                    decisionType: "prohibited", reason: goalProhibitedReason))
            }
            return .failed(steps: 0, history: history, error: goalProhibitedReason)
        }

        // Security check 2: deny-listed process (password managers).
        if let denyReason = await denyListRefusal(goal: goal, target: currentTarget, runId: runId, step: 0) {
            return .failed(steps: 0, history: history, error: denyReason)
        }

        do {
            while options.maxSteps <= 0 || step < options.maxSteps {
                try Task.checkCancellation()
                step += 1
                let stepPrefix = options.maxSteps > 0 ? "Step \(step)/\(options.maxSteps)" : "Step \(step)"

                // 0. Auto-sync target window if the active foreground app changed.
                if let windowTracker,
                   let tracked = windowTracker.getActiveTarget(current: currentTarget),
                   tracked.windowHandle != currentTarget.windowHandle || tracked.processId != currentTarget.processId {
                    GhostLog.shared.info("Active target auto-switched to \(tracked.processName) ('\(tracked.windowTitle)')")
                    currentTarget = tracked
                    // Security check: a deny-listed app must never be read or acted on, even when
                    // the foreground window changed on its own.
                    if let denyReason = await denyListRefusal(goal: goal, target: currentTarget, runId: runId, step: step) {
                        return .failed(steps: step, history: history, error: denyReason)
                    }
                    loopGuard.reset()
                    onTargetChanged?(currentTarget)
                    notifyStatus("Target active: \(currentTarget.processName) (\"\(currentTarget.windowTitle)\")")
                }

                // 1. Observe screen elements.
                notifyStatus("\(stepPrefix): Reading screen...")
                var elements = try await screenReader.readElements(target: currentTarget)

                // 2. Stall check: wait and re-read once if the screen has not changed (may be loading).
                if loopGuard.recordObservation(elements) {
                    GhostLog.shared.warning("Stall detected: \(loopGuard.consecutiveStalls) identical consecutive observations.")
                    notifyStatus("Waiting for screen to update... (stall \(loopGuard.consecutiveStalls)/\(options.maxConsecutiveStalls))")
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    elements = try await screenReader.readElements(target: currentTarget)
                    if loopGuard.recordObservation(elements) {
                        GhostLog.shared.warning("Screen still unchanged after retry stall \(loopGuard.consecutiveStalls).")
                        notifyStatus("Screen state did not change — task may be complete or requires manual intervention.")
                        return .stalled(steps: step, history: history,
                                        reason: "Loop guard tripped: screen state did not change across actions.")
                    }
                }

                // 3. Laya call A: next action + goal completion.
                notifyStatus("\(stepPrefix): Choosing next action...")
                let decision = try await decisionModel.decideNextAction(
                    goal: goal, target: currentTarget, elements: elements, history: history)

                // 4. Done? Verify before declaring success.
                if decision.operation == .done {
                    notifyStatus("Verifying goal completion...")
                    if try await decisionModel.verifyCompletion(
                        goal: goal, target: currentTarget, elements: elements, history: history) {
                        notifyStatus("Goal successfully completed!")
                        return .completed(steps: step, history: history)
                    }
                    GhostLog.shared.info("Done operation verification was inconclusive. Continuing loop.")
                }

                // 5. AskUser / low confidence.
                if decision.operation == .askUser {
                    notifyStatus("Guidance needed: \(decision.reason ?? "")")
                    return .needsHumanInput(steps: step, history: history, reason: decision.reason)
                }

                // 6. Locate target element.
                let targetElement = decision.targetId.flatMap { id in
                    elements.first { $0.id == id }
                }

                // 7. Safety invariant: strictly prohibited action (e.g. deletion controls).
                if let actionProhibitedReason = riskPolicy.isActionProhibited(
                    decision: decision, target: targetElement, goal: goal) {
                    GhostLog.shared.warning("Action prohibited by safety policy: \(actionProhibitedReason)")
                    notifyStatus(actionProhibitedReason)
                    if let auditLog {
                        await auditLog.log(AuditLogEntry(
                            runId: runId, step: step, goal: goal, operation: decision.operation,
                            targetId: decision.targetId,
                            targetLabel: targetElement?.displayLabel ?? decision.targetLabel,
                            targetRole: targetElement?.displayRole,
                            appProcess: currentTarget.processName, appTitle: currentTarget.windowTitle,
                            decisionType: "prohibited", reason: actionProhibitedReason))
                    }
                    return .failed(steps: step, history: history, error: actionProhibitedReason)
                }

                // 8. Safety invariants: honour the risk policy's confirmation requirement.
                // Jarvis mode's default policy never requires confirmation (deletion is blocked
                // outright above), but a policy that does require it must actually ask a human
                // and fail closed when no prompt is available.
                if let riskReason = riskPolicy.requiresConfirmation(
                    decision: decision, target: targetElement, appTarget: currentTarget) {
                    guard let confirmationPrompt else {
                        GhostLog.shared.error("Policy requires confirmation but no confirmation prompt is configured. Refusing action.")
                        notifyStatus("Confirmation required but unavailable: \(riskReason)")
                        if let auditLog {
                            await auditLog.log(AuditLogEntry(
                                runId: runId, step: step, goal: goal, operation: decision.operation,
                                targetId: decision.targetId,
                                targetLabel: targetElement?.displayLabel ?? decision.targetLabel,
                                targetRole: targetElement?.displayRole,
                                appProcess: currentTarget.processName, appTitle: currentTarget.windowTitle,
                                decisionType: "denied", reason: riskReason))
                        }
                        return .needsHumanInput(steps: step, history: history, reason: riskReason)
                    }

                    let approved = await confirmationPrompt.requestConfirmation(
                        decision: decision, target: targetElement, appTarget: currentTarget, reason: riskReason)
                    if let auditLog {
                        await auditLog.log(AuditLogEntry(
                            runId: runId, step: step, goal: goal, operation: decision.operation,
                            targetId: decision.targetId,
                            targetLabel: targetElement?.displayLabel ?? decision.targetLabel,
                            targetRole: targetElement?.displayRole,
                            appProcess: currentTarget.processName, appTitle: currentTarget.windowTitle,
                            decisionType: approved ? "confirmed" : "rejected", reason: riskReason))
                    }
                    if !approved {
                        notifyStatus("Action rejected by human.")
                        return .cancelled(steps: step, history: history)
                    }
                } else if let auditLog {
                    await auditLog.log(AuditLogEntry(
                        runId: runId, step: step, goal: goal, operation: decision.operation,
                        targetId: decision.targetId,
                        targetLabel: targetElement?.displayLabel ?? decision.targetLabel,
                        targetRole: targetElement?.displayRole,
                        appProcess: currentTarget.processName, appTitle: currentTarget.windowTitle,
                        decisionType: "auto", reason: "Harmless action allowed by safety policy."))
                }

                // 9. Execute action (dry-run or live).
                let actionLabel = targetElement != nil ? "'\(targetElement!.displayLabel)'" : (decision.targetId ?? "")
                notifyStatus("\(stepPrefix): \(decision.operation.rawValue) on \(actionLabel)")

                let result = try await actionExecutor.execute(decision: decision, targetElement: targetElement)
                let outcome = result.success ? "ok" : (result.error ?? "")
                history.append(
                    "\(decision.operation.rawValue):\(decision.targetId ?? "") "
                        + "(\(decision.targetLabel ?? "")) -> \(outcome)"
                )
                onStepCompleted?(step, decision, result)

                if !result.success {
                    let err = result.errorMessage ?? result.error ?? "Action execution failed."
                    GhostLog.shared.warning("Action execution failed at step \(step): \(err)")
                    return .failed(steps: step, history: history, error: err)
                }

                // Dynamic target transition upon launching an app/URL.
                if let newTarget = result.newTarget {
                    GhostLog.shared.info("Target switched from '\(currentTarget.processName)' to '\(newTarget.processName)'")
                    currentTarget = newTarget
                    // Security check: never adopt a deny-listed app as the new target.
                    if let denyReason = await denyListRefusal(goal: goal, target: currentTarget, runId: runId, step: step) {
                        return .failed(steps: step, history: history, error: denyReason)
                    }
                    loopGuard.reset()
                    onTargetChanged?(currentTarget)
                    notifyStatus("Switched target to \(currentTarget.processName) (\"\(currentTarget.windowTitle)\")")
                }
            }

            notifyStatus("Max steps (\(options.maxSteps)) reached.")
            return .maxStepsReached(steps: step, history: history)
        } catch is CancellationError {
            GhostLog.shared.info("AgentLoop was cancelled.")
            notifyStatus("Run cancelled by user.")
            return .cancelled(steps: step, history: history)
        } catch {
            GhostLog.shared.error("AgentLoop terminated unexpectedly: \(error)")
            notifyStatus("Error: \(error.localizedDescription)")
            return .failed(steps: step, history: history, error: error.localizedDescription)
        }
    }

    /// Checks a target against the app deny-list. When denied, records the refusal in the
    /// audit log and status channel and returns the reason; returns nil when the app is allowed.
    /// Re-run after every target transition so a deny-listed app is never read or acted on.
    private func denyListRefusal(goal: String, target: AppTarget, runId: String, step: Int) async -> String? {
        guard let denyReason = riskPolicy.isAppDenied(target) else { return nil }
        GhostLog.shared.warning("App deny-list triggered: \(denyReason)")
        notifyStatus("Security policy refusal: \(denyReason)")
        if let auditLog {
            await auditLog.log(AuditLogEntry(
                runId: runId, step: step, goal: goal, operation: .askUser,
                appProcess: target.processName, appTitle: target.windowTitle,
                decisionType: "denied", reason: denyReason))
        }
        return denyReason
    }

    private func notifyStatus(_ message: String) {
        GhostLog.shared.debug("[AgentLoop] \(message)")
        onStatusChanged?(message)
    }
}
