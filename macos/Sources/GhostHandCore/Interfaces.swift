import Foundation

// MARK: - Core interfaces
//
// Direct port of GhostHand.Core.Interfaces.CoreInterfaces.cs.
// The C# `out string reason` pattern becomes "return nil when allowed, or the reason string".

public protocol ScreenReader: AnyObject {
    func readElements(target: AppTarget) async throws -> [AccessibilityElement]
}

public protocol DecisionModel: AnyObject {
    func decideNextAction(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> AgentDecision

    func verifyCompletion(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> Bool

    func evaluateActionRisk(
        goal: String,
        target: AppTarget,
        decision: AgentDecision,
        targetElement: AccessibilityElement?
    ) async throws -> ActionRiskScore
}

public protocol ActionExecutorProtocol: AnyObject {
    func execute(
        decision: AgentDecision,
        targetElement: AccessibilityElement?
    ) async throws -> ActionResult
}

public protocol HotkeyService: AnyObject {
    /// Fired when the activation chord is completed.
    var onHotkeyPressed: (() -> Void)? { get set }
    /// Fired when the kill-switch chord (or Esc during a run) is triggered.
    var onKillSwitchTriggered: (() -> Void)? { get set }
    func start()
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

public protocol ConfirmationPrompt: AnyObject {
    func requestConfirmation(
        decision: AgentDecision,
        target: AccessibilityElement?,
        appTarget: AppTarget,
        reason: String
    ) async -> Bool
}

public protocol AuditLog: AnyObject {
    func log(_ entry: AuditLogEntry) async
}

public protocol CredentialStore: AnyObject {
    func getApiKey() -> String?
    func hasKey() -> Bool
    func setApiKey(_ apiKey: String) throws
    func deleteApiKey()
}

public protocol SpeechInput: AnyObject {
    /// Fired with partial/hypothesis text while recording is in progress.
    var onRecognizing: ((String) -> Void)? { get set }
    /// Record audio and return the final transcription.
    func transcribe() async throws -> String
}

public protocol Clock: AnyObject {
    var utcNow: Date { get }
    func delay(_ duration: TimeInterval) async throws
}

public protocol AppLauncherProtocol: AnyObject {
    /// Returns (appName, launchCommand) when the goal names a launchable application.
    func tryExtractAppLaunch(goal: String) -> (appName: String, launchCommand: String)?
    /// Returns a validated web URL when the goal names one.
    func tryExtractUrlLaunch(goal: String) -> URL?
    func launchApp(name: String, launchCommand: String?) async throws -> AppTarget?
    func launchUrl(_ url: URL) async throws -> AppTarget?
}

public protocol WindowTracker: AnyObject {
    func getActiveTarget(current: AppTarget) -> AppTarget?
}

/// On-device OCR fallback used when the accessibility tree exposes too little.
public protocol OcrService: AnyObject {
    func recognizeScreenArea(_ bounds: CGRect) async -> [AccessibilityElement]
}
