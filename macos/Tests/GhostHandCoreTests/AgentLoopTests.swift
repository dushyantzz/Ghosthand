import CoreGraphics
import Foundation
import XCTest
@testable import GhostHandCore

// MARK: - Small in-memory fakes (no network, no UI, no timers)

private final class FakeScreenReader: ScreenReader {
    var elements: [AccessibilityElement]
    var elementProvider: (() -> [AccessibilityElement])?
    var thrownError: Error?
    var delayNanoseconds: UInt64 = 0
    private(set) var readCount = 0
    private(set) var readTargets: [AppTarget] = []

    /// Creates a fake screen reader returning the given elements or throwing the given error.
    init(elements: [AccessibilityElement] = [], thrownError: Error? = nil) {
        self.elements = elements
        self.thrownError = thrownError
    }

    /// Records the target and returns the provided elements, optionally after a delay.
    func readElements(target: AppTarget) async throws -> [AccessibilityElement] {
        readCount += 1
        readTargets.append(target)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let thrownError { throw thrownError }
        return elementProvider?() ?? elements
    }
}

private final class FakeDecisionModel: DecisionModel {
    var decisions: [AgentDecision]
    var decisionProvider: (() -> AgentDecision)?
    var decisionError: Error?
    var verifyResult = true
    private(set) var decideCount = 0
    private(set) var verifyCount = 0
    private(set) var verifyTargets: [AppTarget] = []
    private(set) var observedElements: [[AccessibilityElement]] = []

    /// Creates a fake decision model with a queued decision list and a verification result.
    init(decisions: [AgentDecision] = [], verifyResult: Bool = true) {
        self.decisions = decisions
        self.verifyResult = verifyResult
    }

    /// Returns the next queued decision, or a done decision when the queue is empty.
    func decideNextAction(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> AgentDecision {
        decideCount += 1
        observedElements.append(elements)
        if let decisionError { throw decisionError }
        if let decisionProvider { return decisionProvider() }
        if decisions.isEmpty { return AgentDecision(operation: .done) }
        return decisions.removeFirst()
    }

    /// Records the verify target and returns the configured verification result.
    func verifyCompletion(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> Bool {
        verifyCount += 1
        verifyTargets.append(target)
        return verifyResult
    }

    /// Always reports the action as harmless.
    func evaluateActionRisk(
        goal: String,
        target: AppTarget,
        decision: AgentDecision,
        targetElement: AccessibilityElement?
    ) async throws -> ActionRiskScore {
        .harmless
    }
}

private final class FakeActionExecutor: ActionExecutorProtocol {
    var result: ActionResult
    var resultProvider: (() -> ActionResult)?
    var onExecute: ((AgentDecision, AccessibilityElement?) -> Void)?
    /// Whether this fake declares itself a simulation; defaults to true because it has no
    /// real side effects. Set to false to model a live executor under a dry-run gate test.
    var simulatesActions: Bool = true
    private(set) var executed: [AgentDecision] = []
    private(set) var executedTargets: [AccessibilityElement?] = []

    /// Creates a fake executor returning the given result by default.
    init(result: ActionResult = .successResult("Executed")) {
        self.result = result
    }

    /// Records the executed decision and target, then returns the configured result.
    func execute(decision: AgentDecision, targetElement: AccessibilityElement?) async throws -> ActionResult {
        executed.append(decision)
        executedTargets.append(targetElement)
        onExecute?(decision, targetElement)
        return resultProvider?() ?? result
    }
}

private final class FakeAuditLog: AuditLog {
    private(set) var entries: [AuditLogEntry] = []

    /// Appends the entry to the in-memory list of recorded audit entries.
    func log(_ entry: AuditLogEntry) async {
        entries.append(entry)
    }
}

private final class FakeConfirmationPrompt: ConfirmationPrompt {
    var approved = true
    private(set) var requestCount = 0

    /// Counts the request and returns the configured approval answer.
    func requestConfirmation(
        decision: AgentDecision,
        target: AccessibilityElement?,
        appTarget: AppTarget,
        reason: String
    ) async -> Bool {
        requestCount += 1
        return approved
    }
}

private final class FakeWindowTracker: WindowTracker {
    var activeTarget: AppTarget?
    private(set) var queryCount = 0

    /// Counts the query and returns the configured active target.
    func getActiveTarget(current: AppTarget) -> AppTarget? {
        queryCount += 1
        return activeTarget
    }
}

// MARK: - AgentLoop tests

/// Port of the pure `AgentLoop` scenarios from `GhostHand.Tests.Agent.AgentLoopTests` and
/// `GhostHand.Tests.Safety.RiskPolicyTests` / `MockJobPageTests`, driven entirely by
/// hand-written in-memory fakes.
final class AgentLoopTests: XCTestCase {
    /// Returns a test app target with a fixed process identifier and window title.
    private func testTarget(processName: String = "TestApp") -> AppTarget {
        AppTarget(processId: 1234, processName: processName, windowTitle: "Test App Window")
    }

    /// Returns loop options with the given step and stall caps.
    private func options(maxSteps: Int = 5, maxConsecutiveStalls: Int = 15) -> AgentLoopOptions {
        var options = AgentLoopOptions()
        options.maxSteps = maxSteps
        options.maxConsecutiveStalls = maxConsecutiveStalls
        return options
    }

    /// Returns an enabled button element with the given identifier, label, and role.
    private func button(
        _ id: String,
        label: String = "Search Button",
        role: String = "Button"
    ) -> AccessibilityElement {
        AccessibilityElement(
            id: id, role: role, label: label, enabled: true,
            frame: CGRect(x: 0, y: 0, width: 100, height: 30))
    }

    // MARK: RS12 — prohibited goal fails immediately, before touching the screen

    /// Verifies that a prohibited goal fails immediately without reading the screen.
    func testRS12_prohibitedGoal_failsImmediately_withoutReadingScreen() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel()
        let executor = FakeActionExecutor()
        let prompt = FakeConfirmationPrompt()
        let audit = FakeAuditLog()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy(),
            confirmationPrompt: prompt,
            auditLog: audit
        )

        let result = await loop.run(goal: "delete my files in notepad", target: testTarget())

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stepsCompleted, 0)
        XCTAssertTrue(result.message?.contains("Prohibited") ?? false, "Message was: \(result.message ?? "")")
        XCTAssertEqual(reader.readCount, 0)
        XCTAssertEqual(model.decideCount, 0)
        XCTAssertEqual(executor.executed.count, 0)
        XCTAssertEqual(prompt.requestCount, 0)
        XCTAssertEqual(audit.entries.count, 1)
        XCTAssertEqual(audit.entries.first?.decisionType, "prohibited")
        XCTAssertTrue(audit.entries.first?.goal.contains("delete") ?? false)
    }

    // MARK: RS09 — deny-listed app refused immediately

    /// Verifies that each deny-listed app fails immediately without reading the screen.
    func testRS09_denyListedApp_failsImmediately_withoutReadingScreen() async {
        let deniedNames = ["1password", "bitwarden", "keepass", "keepassxc", "lastpass", "dashlane"]

        for processName in deniedNames {
            let reader = FakeScreenReader(elements: [button("e1")])
            let model = FakeDecisionModel()
            let executor = FakeActionExecutor()
            let audit = FakeAuditLog()

            let loop = AgentLoop(
                screenReader: reader,
                decisionModel: model,
                actionExecutor: executor,
                options: options(),
                riskPolicy: DefaultRiskPolicy(),
                auditLog: audit
            )

            let target = AppTarget(processId: 9999, processName: processName, windowTitle: "Vault")
            let result = await loop.run(goal: "Copy password", target: target)

            XCTAssertEqual(result.status, .failed, processName)
            XCTAssertEqual(result.stepsCompleted, 0, processName)
            XCTAssertTrue(result.message?.contains("deny-list") ?? false, "Message was: \(result.message ?? "")")
            XCTAssertEqual(reader.readCount, 0, processName)
            XCTAssertEqual(executor.executed.count, 0, processName)
            XCTAssertEqual(audit.entries.count, 1, processName)
            XCTAssertEqual(audit.entries.first?.decisionType, "denied", processName)
            XCTAssertEqual(audit.entries.first?.appProcess, processName)
        }
    }

    // MARK: RS09 — a deny-listed app that becomes the target mid-run is refused

    /// Verifies that a deny-listed app becoming the active target mid-run is refused without reading it.
    func testRS09_denyListedApp_afterWindowTrackerSwitch_failsWithoutReadingScreen() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel()
        let executor = FakeActionExecutor()
        let audit = FakeAuditLog()
        let tracker = FakeWindowTracker()
        tracker.activeTarget = AppTarget(processId: 4242, processName: "1password", windowTitle: "Vault")

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy(),
            auditLog: audit,
            windowTracker: tracker
        )

        let result = await loop.run(goal: "search for Adele", target: testTarget())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("deny-list") ?? false, "Message was: \(result.message ?? "")")
        XCTAssertEqual(reader.readCount, 0, "the denied app must not be read")
        XCTAssertEqual(model.decideCount, 0)
        XCTAssertEqual(executor.executed.count, 0)
        XCTAssertTrue(audit.entries.contains(where: { $0.decisionType == "denied" && $0.appProcess == "1password" }))
    }

    /// Verifies that a deny-listed app launched by the executor fails without further steps.
    func testRS09_denyListedApp_afterExecutorNewTarget_failsWithoutFurtherSteps() async {
        let launched = AppTarget(
            processId: 2000, processName: "bitwarden", windowTitle: "Vault", windowHandle: 0x2000)

        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .openApp, targetId: "vault", confidence: 0.99),
            AgentDecision(operation: .done),
        ])
        let executor = FakeActionExecutor(result: .targetChanged(launched, "Launched Bitwarden"))
        let audit = FakeAuditLog()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy(),
            auditLog: audit
        )

        let result = await loop.run(goal: "open bitwarden", target: testTarget())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("deny-list") ?? false, "Message was: \(result.message ?? "")")
        XCTAssertEqual(executor.executed.count, 1)
        XCTAssertEqual(model.decideCount, 1, "the run must stop before deciding again")
        XCTAssertEqual(reader.readCount, 1, "the denied app must not be read")
        XCTAssertTrue(audit.entries.contains(where: { $0.decisionType == "denied" && $0.appProcess == "bitwarden" }))
    }

    // MARK: RS09 — a launch of a deny-listed app is refused before it executes

    /// Verifies that launching a deny-listed app is refused before it reaches the executor.
    func testRS09_openAppDenyListed_refusedBeforeExecuting() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .openApp, targetId: "1password", targetLabel: "1password"),
        ])
        let executor = FakeActionExecutor()
        let audit = FakeAuditLog()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy(),
            auditLog: audit
        )

        let result = await loop.run(goal: "open 1password", target: testTarget())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("deny-list") ?? false, "Message was: \(result.message ?? "")")
        XCTAssertEqual(executor.executed.count, 0, "a deny-listed launch must never reach the executor")
        XCTAssertTrue(audit.entries.contains { $0.decisionType == "denied" && $0.reason?.contains("deny-list") == true })
    }

    // MARK: RS14 — credential writes require confirmation by default

    /// Verifies that credential typing without a confirmation prompt fails closed.
    func testRS14_credentialTyping_withoutPrompt_failsClosed() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .typeText, targetId: "e1", targetLabel: "Search", textValue: "my password is hunter2"),
        ])
        let executor = FakeActionExecutor()
        let audit = FakeAuditLog()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy(),
            auditLog: audit
        )

        let result = await loop.run(goal: "sign in", target: testTarget())

        XCTAssertEqual(result.status, .needsHumanInput)
        XCTAssertEqual(executor.executed.count, 0, "an unconfirmed credential write must not execute")
        XCTAssertTrue(audit.entries.contains { $0.decisionType == "denied" })
    }

    /// Verifies that credential typing executes when the confirmation prompt approves it.
    func testRS14_credentialTyping_withApprovedPrompt_executes() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .typeText, targetId: "e1", targetLabel: "Search", textValue: "my password is hunter2"),
            AgentDecision(operation: .done),
        ])
        let executor = FakeActionExecutor()
        let prompt = FakeConfirmationPrompt()
        prompt.approved = true
        let audit = FakeAuditLog()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy(),
            confirmationPrompt: prompt,
            auditLog: audit
        )

        let result = await loop.run(goal: "sign in", target: testTarget())

        XCTAssertEqual(prompt.requestCount, 1)
        XCTAssertEqual(executor.executed.count, 1)
        XCTAssertTrue(executor.executed.first?.operation == .typeText)
        XCTAssertTrue(audit.entries.contains { $0.decisionType == "confirmed" })
        XCTAssertNotEqual(result.status, .failed)
    }

    /// Verifies that credential typing is cancelled without executing when the prompt declines.
    func testRS14_credentialTyping_withDeclinedPrompt_cancelsWithoutExecuting() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .typeText, targetId: "e1", targetLabel: "Search", textValue: "my password is hunter2"),
        ])
        let executor = FakeActionExecutor()
        let prompt = FakeConfirmationPrompt()
        prompt.approved = false
        let audit = FakeAuditLog()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy(),
            confirmationPrompt: prompt,
            auditLog: audit
        )

        let result = await loop.run(goal: "sign in", target: testTarget())

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(prompt.requestCount, 1)
        XCTAssertEqual(executor.executed.count, 0)
        XCTAssertTrue(audit.entries.contains { $0.decisionType == "rejected" })
    }

    // MARK: Done + verified => completed

    /// Verifies that a done decision confirmed by verification completes the run.
    func testDoneAndVerified_returnsCompleted() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [AgentDecision(operation: .done)], verifyResult: true)
        let executor = FakeActionExecutor()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(maxSteps: 5),
            riskPolicy: DefaultRiskPolicy()
        )

        let result = await loop.run(goal: "search for Adele", target: testTarget())

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.stepsCompleted, 1)
        XCTAssertEqual(model.verifyCount, 1)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(executor.executed.count, 0)
    }

    /// Verifies that an unverified done decision keeps looping until the max-step cap.
    func testDoneButNotVerified_keepsLoopingUntilMaxSteps() async {
        // A model that always reports Done but never verifies must not be trusted.
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [], verifyResult: false)
        model.decisionProvider = { AgentDecision(operation: .done) }
        let executor = FakeActionExecutor()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(maxSteps: 3),
            riskPolicy: DefaultRiskPolicy()
        )

        let result = await loop.run(goal: "never finishes", target: testTarget())

        XCTAssertEqual(result.status, .maxStepsReached)
        XCTAssertEqual(result.stepsCompleted, 3)
        XCTAssertEqual(model.verifyCount, 3)
    }

    // MARK: askUser => needsHumanInput

    /// Verifies that an ask-user decision returns a needs-human-input result with its message.
    func testAskUser_returnsNeedsHumanInput() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .askUser, reason: "Which report should I open?"),
        ])
        let executor = FakeActionExecutor()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy()
        )

        let result = await loop.run(goal: "organize documents", target: testTarget())

        XCTAssertEqual(result.status, .needsHumanInput)
        XCTAssertEqual(result.stepsCompleted, 1)
        XCTAssertEqual(result.message, "Which report should I open?")
        XCTAssertEqual(executor.executed.count, 0)
    }

    // MARK: EX04 — a failed action fails the run at that step

    /// Verifies that a failed action fails the run at that step and surfaces the message.
    func testFailedAction_returnsFailed() async {
        let reader = FakeScreenReader(elements: [button("e1", label: "Btn")])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .click, targetId: "e1", targetLabel: "Btn"),
        ])
        let executor = FakeActionExecutor(result: .failureResult(
            "Foreground process changed mid-action (expected PID 1234, found 9999). Execution aborted."))

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy()
        )

        let result = await loop.run(goal: "type text", target: testTarget())

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stepsCompleted, 1)
        XCTAssertTrue(result.message?.contains("Foreground process changed mid-action") ?? false)
        XCTAssertEqual(executor.executed.count, 1)
    }

    // MARK: AL05 — executor newTarget switches the active target

    /// Verifies that an executor target change switches the active target and is observed downstream.
    func testExecutorNewTarget_switchesTarget() async {
        let launched = AppTarget(
            processId: 2000, processName: "SystemSettings", windowTitle: "Settings", windowHandle: 0x2000)

        let reader = FakeScreenReader(elements: [])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .openApp, targetId: "settings", confidence: 0.99),
            AgentDecision(operation: .done, reason: "App is opened and goal achieved", confidence: 0.99),
        ])
        let executor = FakeActionExecutor(result: .targetChanged(launched, "Launched SystemSettings"))

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy(),
            windowTracker: nil
        )
        var targetChanges: [AppTarget] = []
        loop.onTargetChanged = { targetChanges.append($0) }

        let initial = AppTarget(processId: 1000, processName: "explorer", windowTitle: "Program Manager")
        let result = await loop.run(goal: "open settings", target: initial)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(executor.executed.first?.operation, .openApp)
        XCTAssertEqual(executor.executed.count, 1) // Done is verified, never executed
        XCTAssertEqual(model.verifyCount, 1)
        XCTAssertEqual(model.verifyTargets.last, launched)
        XCTAssertEqual(targetChanges.last, launched)
        XCTAssertTrue(reader.readTargets.contains(launched))
    }

    // MARK: Cancellation

    /// Verifies that cancelling the running task returns a cancelled result.
    func testCancellation_returnsCancelled() async {
        let reader = FakeScreenReader(elements: [])
        reader.delayNanoseconds = 2_000_000_000 // never actually waited: cancelled immediately

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: FakeDecisionModel(),
            actionExecutor: FakeActionExecutor(),
            options: options(),
            riskPolicy: DefaultRiskPolicy()
        )

        let task = Task { await loop.run(goal: "long running task", target: testTarget()) }
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertTrue(result.message?.contains("cancelled") ?? false)
    }

    /// Verifies a cancellation that lands after the decision is still seen before the executor runs.
    func testCancellationDuringDecision_stopsBeforeExecuting() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel()
        // Cancel the current task from inside the decision, i.e. after the iteration's
        // top-of-loop cancellation check has already passed.
        model.decisionProvider = {
            withUnsafeCurrentTask { $0?.cancel() }
            return AgentDecision(operation: .click, targetId: "e1", targetLabel: "Search Button")
        }
        let executor = FakeActionExecutor()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy()
        )

        let result = await loop.run(goal: "click search", target: testTarget())

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(executor.executed.count, 0, "cancellation must be re-checked at the execution boundary")
    }

    // MARK: RS13 — a prohibited action aborts without executing

    /// Verifies that a prohibited action aborts the run without executing or prompting.
    func testRS13_prohibitedAction_abortsWithoutExecuting() async {
        let deleteButton = AccessibilityElement(
            id: "del_btn", role: "Button", label: "Delete", enabled: true,
            frame: CGRect(x: 0, y: 0, width: 100, height: 30))

        let reader = FakeScreenReader(elements: [deleteButton])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .click, targetId: "del_btn", targetLabel: "Delete"),
        ])
        let executor = FakeActionExecutor()
        let prompt = FakeConfirmationPrompt()
        let audit = FakeAuditLog()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy(),
            confirmationPrompt: prompt,
            auditLog: audit
        )

        let result = await loop.run(goal: "organize documents", target: testTarget())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("Prohibited") ?? false)
        XCTAssertEqual(executor.executed.count, 0)
        XCTAssertEqual(prompt.requestCount, 0)
        XCTAssertEqual(audit.entries.count, 1)
        XCTAssertEqual(audit.entries.first?.decisionType, "prohibited")
        XCTAssertEqual(audit.entries.first?.operation, .click)
    }

    // MARK: RS04 — a safe action executes directly, with no confirmation prompt

    /// Verifies that a safe action executes directly without asking for confirmation.
    func testRS04_safeAction_executedDirectly_withoutPrompt() async {
        let safeElement = button("e1", label: "Submit Application")
        let safeDecision = AgentDecision(operation: .click, targetId: "e1", targetLabel: "Submit Application")

        let reader = FakeScreenReader(elements: [safeElement])
        let model = FakeDecisionModel(decisions: [safeDecision, AgentDecision(operation: .done)])
        let executor = FakeActionExecutor(result: .successResult("Executed"))
        let prompt = FakeConfirmationPrompt()
        let audit = FakeAuditLog()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(),
            riskPolicy: DefaultRiskPolicy(),
            confirmationPrompt: prompt,
            auditLog: audit
        )

        let result = await loop.run(goal: "Fill and submit form", target: testTarget())

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(prompt.requestCount, 0)
        XCTAssertEqual(executor.executed, [safeDecision])
        XCTAssertEqual(executor.executedTargets.first, safeElement)
        // Jarvis mode records the action as auto-approved.
        XCTAssertTrue(audit.entries.contains { $0.decisionType == "auto" && $0.operation == .click })
    }

    // MARK: EX06 — the max-step cap stops the run

    /// Verifies that the maximum step cap stops the run at the configured limit.
    func testEX06_maxStepCap_stopsRun() async {
        var stepCounter = 0
        let reader = FakeScreenReader()
        reader.elementProvider = {
            stepCounter += 1
            return [AccessibilityElement(
                id: "e_\(stepCounter)", role: "Button", label: "Item \(stepCounter)", enabled: true,
                frame: CGRect(x: 0, y: 0, width: 100, height: 30))]
        }

        let model = FakeDecisionModel()
        model.decisionProvider = {
            AgentDecision(operation: .click, targetId: "e_\(stepCounter)", targetLabel: "Next")
        }

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: FakeActionExecutor(result: .successResult("Clicked")),
            options: options(maxSteps: 5, maxConsecutiveStalls: 10),
            riskPolicy: DefaultRiskPolicy()
        )

        let result = await loop.run(goal: "keep going", target: testTarget())

        XCTAssertEqual(result.status, .maxStepsReached)
        XCTAssertEqual(result.stepsCompleted, 5)
        XCTAssertTrue(result.message?.contains("Reached maximum step limit (5)") ?? false)
    }

    // MARK: RS07 — a mock job application is filled and submitted with no prompt

    /// Verifies that a mock job application is filled and submitted fully automatically.
    func testRS07_mockJobApplication_fillsFormAndSubmits_fullyAutomatically() async {
        var executedActions: [AgentDecision] = []

        let reader = FakeScreenReader()
        reader.elementProvider = {
            [
                AccessibilityElement(
                    id: "e1", role: "Edit", label: "Full Name",
                    value: executedActions.first { $0.targetId == "e1" }?.textValue ?? "", enabled: true,
                    frame: CGRect(x: 0, y: 0, width: 200, height: 30)),
                AccessibilityElement(
                    id: "e2", role: "Edit", label: "Email Address",
                    value: executedActions.first { $0.targetId == "e2" }?.textValue ?? "", enabled: true,
                    frame: CGRect(x: 0, y: 40, width: 200, height: 30)),
                AccessibilityElement(
                    id: "e3", role: "Button", label: "Submit Application", enabled: true,
                    frame: CGRect(x: 0, y: 80, width: 200, height: 30)),
            ]
        }

        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .typeText, targetId: "e1", targetLabel: "Full Name", textValue: "Alice Smith"),
            AgentDecision(operation: .typeText, targetId: "e2", targetLabel: "Email Address", textValue: "alice@example.com"),
            AgentDecision(operation: .click, targetId: "e3", targetLabel: "Submit Application"),
            AgentDecision(operation: .done),
        ], verifyResult: true)

        let executor = FakeActionExecutor(result: .successResult("Executed"))
        executor.onExecute = { decision, _ in executedActions.append(decision) }

        let prompt = FakeConfirmationPrompt()
        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(maxSteps: 5),
            riskPolicy: DefaultRiskPolicy(),
            confirmationPrompt: prompt
        )

        let target = AppTarget(
            processId: 8888, processName: "chrome",
            windowTitle: "Apply for Software Engineer - Careers",
            windowHandle: 0x8888, windowBounds: CGRect(x: 50, y: 50, width: 900, height: 700))

        let result = await loop.run(
            goal: "Apply for Software Engineer job with name Alice Smith and email alice@example.com",
            target: target)

        XCTAssertTrue(executedActions.contains { $0.operation == .typeText && $0.targetId == "e1" })
        XCTAssertTrue(executedActions.contains { $0.operation == .typeText && $0.targetId == "e2" })
        XCTAssertTrue(executedActions.contains { $0.operation == .click && $0.targetId == "e3" })
        XCTAssertEqual(prompt.requestCount, 0)
        XCTAssertEqual(result.status, .completed)
    }

    // MARK: Dry-run containment

    /// Verifies that a dry run refuses to execute through an executor that performs real
    /// actions, and records the refusal instead of injecting input.
    func testDryRun_refusesNonSimulatingExecutor_beforeExecuting() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .click, targetId: "e1", targetLabel: "Search Button"),
        ])
        let executor = FakeActionExecutor()
        executor.simulatesActions = false
        let audit = FakeAuditLog()

        var opts = options()
        opts.dryRun = true
        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: opts,
            riskPolicy: DefaultRiskPolicy(),
            auditLog: audit
        )

        let result = await loop.run(goal: "search for Adele", target: testTarget())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message?.contains("Dry run") ?? false, "Message was: \(result.message ?? "")")
        XCTAssertEqual(executor.executed.count, 0, "a live executor must never be driven by a dry run")
        XCTAssertEqual(model.decideCount, 1, "the loop must stop at the dry-run gate, not act")
        XCTAssertTrue(
            audit.entries.contains { $0.decisionType == "denied" && ($0.reason?.contains("Dry run") ?? false) },
            "the refusal must be audited")
    }

    /// Verifies that a dry run through a simulating executor still executes its simulated actions.
    func testDryRun_allowsSimulatingExecutor() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .click, targetId: "e1", targetLabel: "Search Button"),
            AgentDecision(operation: .done),
        ])
        let executor = FakeActionExecutor()
        executor.simulatesActions = true

        var opts = options()
        opts.dryRun = true
        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: opts,
            riskPolicy: DefaultRiskPolicy()
        )

        let result = await loop.run(goal: "search for Adele", target: testTarget())

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(executor.executed.count, 1, "a simulating executor may run during a dry run")
    }

    /// Verifies that a live run (dryRun false) is allowed to drive a non-simulating executor.
    func testLiveRun_allowsNonSimulatingExecutor() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [
            AgentDecision(operation: .click, targetId: "e1", targetLabel: "Search Button"),
            AgentDecision(operation: .done),
        ])
        let executor = FakeActionExecutor()
        executor.simulatesActions = false

        var opts = options()
        opts.dryRun = false
        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: opts,
            riskPolicy: DefaultRiskPolicy()
        )

        let result = await loop.run(goal: "search for Adele", target: testTarget())

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(executor.executed.count, 1, "live mode must not be blocked by the dry-run gate")
    }

    // MARK: AgentLoopOptions (pure, no environment mutation)

    /// Verifies the default values of the agent loop options.
    func testAgentLoopOptionsDefaults() {
        let defaults = AgentLoopOptions()
        XCTAssertEqual(defaults.maxSteps, 0) // 0 = unlimited
        XCTAssertTrue(defaults.dryRun)
        XCTAssertEqual(defaults.maxConsecutiveStalls, 15)
        XCTAssertEqual(defaults.actionTimeoutSeconds, 10)
    }
}
