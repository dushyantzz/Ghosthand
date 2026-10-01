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
    /// When true, each read appends an element whose id changes, simulating observable progress.
    /// Tests that expect a run to complete need this, because completion now requires evidence
    /// that the screen actually changed.
    var varyEachRead = false
    private(set) var readCount = 0
    private(set) var readTargets: [AppTarget] = []

    init(elements: [AccessibilityElement] = [], thrownError: Error? = nil) {
        self.elements = elements
        self.thrownError = thrownError
    }

    func readElements(target: AppTarget) async throws -> [AccessibilityElement] {
        readCount += 1
        readTargets.append(target)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let thrownError { throw thrownError }
        var result = elementProvider?() ?? elements
        if varyEachRead {
            result.append(AccessibilityElement(id: "read_\(readCount)", role: "Text", label: "tick"))
        }
        return result
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

    init(decisions: [AgentDecision] = [], verifyResult: Bool = true) {
        self.decisions = decisions
        self.verifyResult = verifyResult
    }

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
    private(set) var executed: [AgentDecision] = []
    private(set) var executedTargets: [AccessibilityElement?] = []

    init(result: ActionResult = .successResult("Executed")) {
        self.result = result
    }

    func execute(decision: AgentDecision, targetElement: AccessibilityElement?) async throws -> ActionResult {
        executed.append(decision)
        executedTargets.append(targetElement)
        onExecute?(decision, targetElement)
        return resultProvider?() ?? result
    }
}

private final class FakeAuditLog: AuditLog {
    private(set) var entries: [AuditLogEntry] = []

    func log(_ entry: AuditLogEntry) async {
        entries.append(entry)
    }
}

private final class FakeConfirmationPrompt: ConfirmationPrompt {
    var approved = true
    private(set) var requestCount = 0

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
    private func testTarget(processName: String = "TestApp") -> AppTarget {
        AppTarget(processId: 1234, processName: processName, windowTitle: "Test App Window")
    }

    private func options(maxSteps: Int = 5, maxConsecutiveStalls: Int = 15) -> AgentLoopOptions {
        var options = AgentLoopOptions()
        options.maxSteps = maxSteps
        options.maxConsecutiveStalls = maxConsecutiveStalls
        return options
    }

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

    // MARK: Done + verified => completed

    func testDoneAndVerifiedAfterEvidence_returnsCompleted() async {
        // Completion now requires evidence that the screen actually changed.
        let reader = FakeScreenReader(elements: [button("e1")])
        reader.varyEachRead = true
        let model = FakeDecisionModel(
            decisions: [
                AgentDecision(operation: .click, targetId: "e1"),
                AgentDecision(operation: .done),
            ],
            verifyResult: true)
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
        XCTAssertEqual(result.stepsCompleted, 2)
        XCTAssertEqual(model.verifyCount, 1)
        XCTAssertEqual(executor.executed.count, 1)
    }

    /// A "done" on the very first step has nothing behind it — no action ran and the screen has
    /// not changed — so it must not be reported as success. This is the run that claimed Completed
    /// on a static Finder window with 318 elements and zero actions.
    func testDoneOnFirstStepWithoutEvidence_isRejected() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(
            decisions: [
                AgentDecision(operation: .done),
                AgentDecision(operation: .done),
                AgentDecision(operation: .done),
            ],
            verifyResult: true)
        let executor = FakeActionExecutor()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(maxSteps: 10),
            riskPolicy: DefaultRiskPolicy()
        )

        let result = await loop.run(goal: "whereis Laya", target: testTarget())

        XCTAssertNotEqual(result.status, .completed)
        XCTAssertEqual(result.status, .needsHumanInput)
        XCTAssertEqual(executor.executed.count, 0)
    }

    func testDoneButNotVerified_stopsAtMaxSteps_whenCapIsLowerThanTheDoneLimit() async {
        // A model that always reports Done but never verifies must not be trusted. When the step
        // cap is reached before the inconclusive-done limit, the run ends as maxStepsReached;
        // the circuit-breaker case is covered by
        // `testDoneWithoutEvidence_isNotExecuted_andAsksTheUserAfterThreeTries`.
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(decisions: [], verifyResult: false)
        model.decisionProvider = { AgentDecision(operation: .done) }
        let executor = FakeActionExecutor()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(maxSteps: 2),
            riskPolicy: DefaultRiskPolicy()
        )

        let result = await loop.run(goal: "never finishes", target: testTarget())

        XCTAssertEqual(result.status, .maxStepsReached)
        XCTAssertEqual(result.stepsCompleted, 2)
        XCTAssertEqual(model.verifyCount, 2)
    }

    // MARK: askUser => needsHumanInput

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

    // MARK: RS13 — a prohibited action aborts without executing

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

    func testRS04_safeAction_executedDirectly_withoutPrompt() async {
        let safeElement = button("e1", label: "Submit Application")
        let safeDecision = AgentDecision(operation: .click, targetId: "e1", targetLabel: "Submit Application")

        let reader = FakeScreenReader(elements: [safeElement])
        // A real click changes the screen; completion requires evidence, so simulate that.
        reader.varyEachRead = true
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

    // MARK: AgentLoopOptions (pure, no environment mutation)

    func testAgentLoopOptionsDefaults() {
        let defaults = AgentLoopOptions()
        XCTAssertEqual(defaults.maxSteps, 0) // 0 = unlimited
        XCTAssertTrue(defaults.dryRun)
        XCTAssertEqual(defaults.maxConsecutiveStalls, 15)
        XCTAssertEqual(defaults.actionTimeoutSeconds, 10)
    }

    // MARK: A "done" without evidence is not an action

    /// Regression for the `whereis Laya` run: the model kept answering "done", verification kept
    /// finding no evidence, and the loop executed each one as a no-op until the stall guard fired
    /// 15 steps later. It must hand back to the user instead.
    func testDoneWithoutEvidence_isNotExecuted_andAsksTheUserAfterThreeTries() async {
        let reader = FakeScreenReader(elements: [button("e1")])
        let model = FakeDecisionModel(
            decisions: [
                AgentDecision(operation: .done),
                AgentDecision(operation: .done),
                AgentDecision(operation: .done),
                AgentDecision(operation: .done),
            ],
            verifyResult: false)
        let executor = FakeActionExecutor()
        let audit = FakeAuditLog()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(maxSteps: 10),
            riskPolicy: DefaultRiskPolicy(),
            auditLog: audit
        )

        let result = await loop.run(goal: "whereis Laya", target: testTarget())

        XCTAssertEqual(result.status, .needsHumanInput)
        XCTAssertTrue(result.message?.contains("confirm the task") ?? false,
                      "Message was: \(result.message ?? "")")
        // A done decision must never reach the executor.
        XCTAssertEqual(executor.executed.count, 0)
        XCTAssertEqual(model.verifyCount, 3)
        XCTAssertTrue(audit.entries.contains { $0.decisionType == "inconclusive" })
    }

    /// Regression for the `whereis Laya` false success: actions were executed, the screen never
    /// changed once, verification still "agreed", and the run reported Completed — which the
    /// overlay then auto-dismissed. Completion must require evidence.
    func testCompletionWithoutAnyScreenChange_isRejected() async {
        let reader = FakeScreenReader(elements: [button("e1")]) // identical on every read
        let model = FakeDecisionModel(
            decisions: [
                AgentDecision(operation: .pressEscape),
                AgentDecision(operation: .pressEscape),
                AgentDecision(operation: .done),
                AgentDecision(operation: .done),
                AgentDecision(operation: .done),
            ],
            verifyResult: true) // the verifier wrongly agrees
        let executor = FakeActionExecutor()
        let audit = FakeAuditLog()

        let loop = AgentLoop(
            screenReader: reader,
            decisionModel: model,
            actionExecutor: executor,
            options: options(maxSteps: 10),
            riskPolicy: DefaultRiskPolicy(),
            auditLog: audit
        )

        let result = await loop.run(goal: "whereis Laya", target: testTarget())

        XCTAssertNotEqual(result.status, .completed, "Must not claim success without evidence")
        XCTAssertEqual(result.status, .needsHumanInput)
        XCTAssertTrue(audit.entries.contains { $0.decisionType == "inconclusive" })
    }
}
