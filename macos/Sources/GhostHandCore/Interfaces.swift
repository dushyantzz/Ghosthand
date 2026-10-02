import Foundation

// MARK: - Core interfaces
//
// Direct port of GhostHand.Core.Interfaces.CoreInterfaces.cs.
// The C# `out string reason` pattern becomes "return nil when allowed, or the reason string".

/// Reads the accessibility tree of an application window.
public protocol ScreenReader: AnyObject {
    /// Reads the current accessibility elements for the given target.
    func readElements(target: AppTarget) async throws -> [AccessibilityElement]
}

/// Chooses the next action and verifies goal completion using a language model.
public protocol DecisionModel: AnyObject {
    /// Asks the model to choose the next action toward the goal given the screen and history.
    func decideNextAction(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> AgentDecision

    /// Asks the model to confirm whether the goal has actually been achieved.
    func verifyCompletion(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> Bool

    /// Asks the model to score the risk of the proposed decision against the target.
    func evaluateActionRisk(
        goal: String,
        target: AppTarget,
        decision: AgentDecision,
        targetElement: AccessibilityElement?
    ) async throws -> ActionRiskScore
}

/// Performs a single decided action against the target application.
public protocol ActionExecutorProtocol: AnyObject {
    /// Whether this executor only simulates actions instead of performing them for real.
    ///
    /// `AgentLoop` refuses to run a dry run (`AgentLoopOptions.dryRun == true`) through an
    /// executor that reports `false` here, so a caller who asked for a simulation can never
    /// accidentally drive a live executor that injects real input. The default is `false`
    /// (fail closed): only an executor that explicitly declares simulation is treated as safe
    /// for a dry run.
    var simulatesActions: Bool { get }

    /// Executes the decision, optionally against a located element, and returns the outcome.
    func execute(
        decision: AgentDecision,
        targetElement: AccessibilityElement?
    ) async throws -> ActionResult
}

public extension ActionExecutorProtocol {
    /// Conservative default: an executor that does not declare simulation is treated as live,
    /// so `AgentLoopOptions.dryRun` refuses to drive it rather than trusting it to simulate.
    var simulatesActions: Bool { false }
}

/// Registers the activation and kill-switch keyboard chords.
public protocol HotkeyService: AnyObject {
    /// Fired when the activation chord is completed.
    var onHotkeyPressed: (() -> Void)? { get set }
    /// Fired when the kill-switch chord (or Esc during a run) is triggered.
    var onKillSwitchTriggered: (() -> Void)? { get set }
    /// Starts listening for the activation and kill-switch chords.
    func start()
    /// Stops listening for hotkeys and releases the registered chords.
    func stop()
}

public protocol RiskPolicy: AnyObject {
    /// Returns nil if the app may be automated, otherwise the refusal reason.
    func isAppDenied(_ appTarget: AppTarget) -> String?
    /// Returns nil when no human confirmation is required, otherwise the reason.
    func requiresConfirmation(
        decision: AgentDecision,
        target: AccessibilityElement?,
        appTarget: AppTarget
    ) -> String?
    /// Returns nil when the goal is allowed, otherwise the refusal reason.
    func isGoalProhibited(_ goal: String) -> String?
    /// Returns nil when the action is allowed, otherwise the refusal reason.
    func isActionProhibited(
        decision: AgentDecision,
        target: AccessibilityElement?,
        goal: String
    ) -> String?
}

/// Asks a human to approve a risky action before it is executed.
public protocol ConfirmationPrompt: AnyObject {
    /// Asks the human to approve or reject the decision, returning true when approved.
    func requestConfirmation(
        decision: AgentDecision,
        target: AccessibilityElement?,
        appTarget: AppTarget,
        reason: String
    ) async -> Bool
}

/// Persists a record of every executed or refused decision.
public protocol AuditLog: AnyObject {
    /// Appends an entry to the audit trail.
    func log(_ entry: AuditLogEntry) async
}

/// Stores and retrieves the API key used by the decision model.
public protocol CredentialStore: AnyObject {
    /// Returns the stored API key, or nil when none has been saved.
    func getApiKey() -> String?
    /// Returns true when an API key is currently stored.
    func hasKey() -> Bool
    /// Stores the supplied API key, replacing any existing one.
    func setApiKey(_ apiKey: String) throws
    /// Removes the stored API key.
    func deleteApiKey()
}

/// Captures speech and produces a final transcription.
public protocol SpeechInput: AnyObject {
    /// Fired with partial/hypothesis text while recording is in progress.
    var onRecognizing: ((String) -> Void)? { get set }
    /// Record audio and return the final transcription.
    func transcribe() async throws -> String
}

/// Supplies the current time and cancellable delays.
public protocol Clock: AnyObject {
    var utcNow: Date { get }
    /// Suspends for the given duration, throwing if the wait is cancelled.
    func delay(_ duration: TimeInterval) async throws
}

/// Extracts and performs app or URL launches requested by a goal.
public protocol AppLauncherProtocol: AnyObject {
    /// Returns (appName, launchCommand) when the goal names a launchable application.
    func tryExtractAppLaunch(goal: String) -> (appName: String, launchCommand: String)?
    /// Returns a validated web URL when the goal names one.
    func tryExtractUrlLaunch(goal: String) -> URL?
    /// Launches the named application and returns the resulting target, or nil on failure.
    func launchApp(name: String, launchCommand: String?) async throws -> AppTarget?
    /// Opens the URL and returns the resulting target, or nil on failure.
    func launchUrl(_ url: URL) async throws -> AppTarget?
}

/// Watches the foreground window and reports when the active target changes.
public protocol WindowTracker: AnyObject {
    /// Returns the current foreground target when it differs from `current`, otherwise nil.
    func getActiveTarget(current: AppTarget) -> AppTarget?
}

/// On-device OCR fallback used when the accessibility tree exposes too little.
public protocol OcrService: AnyObject {
    /// Recognizes text within the given screen rectangle and returns it as accessibility elements.
    func recognizeScreenArea(_ bounds: CGRect) async -> [AccessibilityElement]
}
