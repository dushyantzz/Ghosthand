import Foundation

// MARK: - AgentRunStatus / AgentRunResult
//
// Port of GhostHand.Core.Agent.AgentRunStatus and AgentRunResult.

/// Outcome category reported at the end of an agent run.
public enum AgentRunStatus: String, Sendable {
    case completed = "Completed"
    case needsHumanInput = "NeedsHumanInput"
    case stalled = "Stalled"
    case maxStepsReached = "MaxStepsReached"
    case cancelled = "Cancelled"
    case failed = "Failed"
}

/// Final outcome of an agent run, including the steps taken and a human-readable message.
public struct AgentRunResult: Sendable {
    public var status: AgentRunStatus
    public var stepsCompleted: Int
    public var actionHistory: [String]
    public var message: String?

    /// Creates a result indicating the goal was achieved, with a success message.
    public static func completed(steps: Int, history: [String]) -> AgentRunResult {
        AgentRunResult(status: .completed, stepsCompleted: steps, actionHistory: history, message: "Goal successfully achieved.")
    }

    /// Creates a result asking for human guidance, using the supplied reason when present.
    public static func needsHumanInput(steps: Int, history: [String], reason: String?) -> AgentRunResult {
        AgentRunResult(status: .needsHumanInput, stepsCompleted: steps, actionHistory: history,
                       message: reason ?? "Human input required.")
    }

    /// Creates a result for a stalled loop, using the supplied reason or a default explanation.
    public static func stalled(steps: Int, history: [String], reason: String?) -> AgentRunResult {
        AgentRunResult(status: .stalled, stepsCompleted: steps, actionHistory: history,
                       message: reason ?? "Loop guard tripped: screen state unchanged.")
    }

    /// Creates a result stating that the run reached its configured step limit.
    public static func maxStepsReached(steps: Int, history: [String]) -> AgentRunResult {
        AgentRunResult(status: .maxStepsReached, stepsCompleted: steps, actionHistory: history,
                       message: "Reached maximum step limit (\(steps)).")
    }

    /// Creates a failed result carrying the supplied error message.
    public static func failed(steps: Int, history: [String], error: String) -> AgentRunResult {
        AgentRunResult(status: .failed, stepsCompleted: steps, actionHistory: history, message: error)
    }

    /// Creates a result indicating the run was cancelled before completion.
    public static func cancelled(steps: Int, history: [String]) -> AgentRunResult {
        AgentRunResult(status: .cancelled, stepsCompleted: steps, actionHistory: history, message: "Run was cancelled.")
    }
}

// MARK: - AgentLoop
//
// Port of GhostHand.Core.Agent.AgentLoop: observe -> decide -> safety-gate -> execute -> verify.

/// Drives the observe-decide-gate-execute agent loop against a target application.
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

    /// Creates a loop with the collaborators and options needed to observe, decide, and act.
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

    /// Runs the observe-decide-gate-execute loop for `goal` on `target` until a terminal
    /// result is reached, re-checking security policy before every observation and action and
    /// refusing to drive a live executor when the run was asked to simulate (`options.dryRun`).
    public func run(goal: String, target: AppTarget) async -> AgentRunResult {
        var currentTarget = target
        var history: [String] = []
        let loopGuard = LoopGuard(maxConsecutiveStalls: options.maxConsecutiveStalls)
        var step = 0

        GhostLog.shared.info("Starting AgentLoop for goal '\(goal)' on target '\(currentTarget.processName)' (DryRun: \(options.dryRun))")

        // Security check 1: strictly prohibited goal (e.g. deletion tasks).
        if let goalProhibitedReason = riskPolicy.isGoalProhibited(goal) {
            GhostLog.shared.warning("Goal prohibited by policy: \(goalProhibitedReason)")
            notifyStatus(goalProhibitedReason)
            if let auditLog {
                await auditLog.log(AuditLogEntry(
                    goal: goal, operation: .askUser,
                    appProcess: currentTarget.processName, appTitle: currentTarget.windowTitle,
                    decisionType: "prohibited", reason: goalProhibitedReason))
            }
            return .failed(steps: 0, history: history, error: goalProhibitedReason)
        }

        // Security check 2: deny-listed process (password managers).
        if let denyReason = await denyListRefusal(goal: goal, target: currentTarget) {
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
                    if let denyReason = await denyListRefusal(goal: goal, target: currentTarget) {
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
                            goal: goal, operation: decision.operation,
                            targetId: decision.targetId,
                            targetLabel: targetElement?.displayLabel ?? decision.targetLabel,
                            targetRole: targetElement?.displayRole,
                            appProcess: currentTarget.processName, appTitle: currentTarget.windowTitle,
                            decisionType: "prohibited", reason: actionProhibitedReason))
                    }
                    return .failed(steps: step, history: history, error: actionProhibitedReason)
                }

                // 8. Safety invariants: honour the risk policy's confirmation requirement.
                // The default policy auto-executes safe actions but requires confirmation for
                // credential writes, so this gate is live by default. It fails closed: a
                // required confirmation with no prompt available refuses the action instead
                // of pretending a human approved it.
                if let riskReason = riskPolicy.requiresConfirmation(
                    decision: decision, target: targetElement, appTarget: currentTarget) {
                    guard let confirmationPrompt else {
                        GhostLog.shared.error("Policy requires confirmation but no confirmation prompt is configured. Refusing action.")
                        notifyStatus("Confirmation required but unavailable: \(riskReason)")
                        if let auditLog {
                            await auditLog.log(AuditLogEntry(
                                goal: goal, operation: decision.operation,
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
                            goal: goal, operation: decision.operation,
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
                        goal: goal, operation: decision.operation,
                        targetId: decision.targetId,
                        targetLabel: targetElement?.displayLabel ?? decision.targetLabel,
                        targetRole: targetElement?.displayRole,
                        appProcess: currentTarget.processName, appTitle: currentTarget.windowTitle,
                        decisionType: "auto", reason: "Harmless action allowed by safety policy."))
                }

                // 9. Continuous authorization: the deny-list is an invariant, not an entry
                // check. Re-validate the current target immediately before acting, and refuse
                // a launch whose application is deny-listed *before* it can open.
                if let denyReason = await denyListRefusal(goal: goal, target: currentTarget) {
                    return .failed(steps: step, history: history, error: denyReason)
                }
                if let launchReason = riskPolicy.launchDenial(for: decision) {
                    GhostLog.shared.warning("Launch refused by app deny-list: \(launchReason)")
                    notifyStatus("Security policy refusal: \(launchReason)")
                    if let auditLog {
                        await auditLog.log(AuditLogEntry(
                            goal: goal, operation: decision.operation,
                            targetId: decision.targetId,
                            targetLabel: decision.targetLabel,
                            appProcess: currentTarget.processName, appTitle: currentTarget.windowTitle,
                            decisionType: "denied", reason: launchReason))
                    }
                    return .failed(steps: step, history: history, error: launchReason)
                }

                // 10. Execute action (dry-run or live).
                // Re-check cancellation at the execution boundary: a cancellation that
                // arrived while we were reading, deciding or confirming must stop the run
                // before the side effect, not after it.
                try Task.checkCancellation()

                // Dry-run containment: a run that was asked to simulate must never reach a
                // live executor. The loop cannot simulate platform actions itself, so it
                // refuses to execute when the executor does not declare that it simulates.
                // This fails closed rather than trusting the executor to honour a flag it
                // never received.
                if options.dryRun, !actionExecutor.simulatesActions {
                    let message = "Dry run requested but the action executor performs real actions. Refusing to execute."
                    GhostLog.shared.error(message)
                    notifyStatus(message)
                    if let auditLog {
                        await auditLog.log(AuditLogEntry(
                            goal: goal, operation: decision.operation,
                            targetId: decision.targetId,
                            targetLabel: targetElement?.displayLabel ?? decision.targetLabel,
                            targetRole: targetElement?.displayRole,
                            appProcess: currentTarget.processName, appTitle: currentTarget.windowTitle,
                            decisionType: "denied", reason: message))
                    }
                    return .failed(steps: step, history: history, error: message)
                }

                let actionLabel = targetElement != nil ? "'\(targetElement!.displayLabel)'" : (decision.targetId ?? "")
                notifyStatus("\(stepPrefix): \(decision.operation.rawValue) on \(actionLabel)")

                let result = try await actionExecutor.execute(decision: decision, targetElement: targetElement)
                history.append("\(decision.operation.rawValue):\(decision.targetId ?? "") (\(decision.targetLabel ?? "")) -> \(result.success ? "ok" : (result.error ?? ""))")
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
                    if let denyReason = await denyListRefusal(goal: goal, target: currentTarget) {
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
    private func denyListRefusal(goal: String, target: AppTarget) async -> String? {
        guard let denyReason = riskPolicy.isAppDenied(target) else { return nil }
        GhostLog.shared.warning("App deny-list triggered: \(denyReason)")
        notifyStatus("Security policy refusal: \(denyReason)")
        if let auditLog {
            await auditLog.log(AuditLogEntry(
                goal: goal, operation: .askUser,
                appProcess: target.processName, appTitle: target.windowTitle,
                decisionType: "denied", reason: denyReason))
        }
        return denyReason
    }

    /// Logs a status message and forwards it to the `onStatusChanged` callback.
    private func notifyStatus(_ message: String) {
        GhostLog.shared.debug("[AgentLoop] \(message)")
        onStatusChanged?(message)
    }
}
