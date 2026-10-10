using GhostHand.Core.Models;
using GhostHand.Core.Safety;

namespace GhostHand.Core.Interfaces;

public interface IScreenReader
{
    Task<IReadOnlyList<AccessibilityElement>> ReadElementsAsync(AppTarget target, CancellationToken cancellationToken = default);
}

public interface IDecisionModel
{
    Task<AgentDecision> DecideNextActionAsync(
        string goal,
        AppTarget target,
        IReadOnlyList<AccessibilityElement> elements,
        IReadOnlyList<string> history,
        CancellationToken cancellationToken = default);

    Task<bool> VerifyCompletionAsync(
        string goal,
        AppTarget target,
        IReadOnlyList<AccessibilityElement> elements,
        IReadOnlyList<string> history,
        CancellationToken cancellationToken = default);

    Task<ActionRiskScore> EvaluateActionRiskAsync(
        string goal,
        AppTarget target,
        AgentDecision decision,
        AccessibilityElement? targetElement,
        CancellationToken cancellationToken = default);
}

public interface IActionExecutor
{
    Task<ActionResult> ExecuteAsync(
        AgentDecision decision,
        AccessibilityElement? targetElement,
        CancellationToken cancellationToken = default);
}

public interface IHotkeyService : IDisposable
{
    event EventHandler? HotkeyPressed;
    event EventHandler? KillSwitchTriggered;
    void Start();
    void Stop();
}

public interface IRiskPolicy
{
    bool IsAppDenied(AppTarget appTarget, out string reason);
    bool RequiresConfirmation(AgentDecision decision, AccessibilityElement? target, AppTarget appTarget, out string reason);
    bool IsGoalProhibited(string goal, out string reason);
    bool IsActionProhibited(AgentDecision decision, AccessibilityElement? target, string goal, out string reason);
}

public interface IConfirmationPrompt
{
    Task<bool> RequestConfirmationAsync(
        AgentDecision decision,
        AccessibilityElement? target,
        AppTarget appTarget,
        string reason,
        CancellationToken cancellationToken = default);
}

public interface IAuditLog
{
    Task LogAsync(AuditLogEntry entry, CancellationToken cancellationToken = default);
}

public interface ICredentialStore
{
    string? GetApiKey();
    bool HasKey();
    void SetApiKey(string apiKey);
    void DeleteApiKey();
}

public interface ISpeechInput : IDisposable
{
    /// <summary>Fired with partial/hypothesis text while recording is in progress.</summary>
    event Action<string>? SpeechRecognizing;

    /// <summary>Record audio and return the final transcription.</summary>
    Task<string> TranscribeAsync(CancellationToken cancellationToken = default);

    /// <summary>Finish the current recording early and return what was said so far (cancellation discards it).</summary>
    void RequestStop() { }
}

public interface IClock
{
    DateTimeOffset UtcNow { get; }
    Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken = default);
}

public interface IAppLauncher
{
    bool TryExtractAppLaunch(string goal, out string appName, out string launchCommand);
    bool TryExtractUrlLaunch(string goal, out Uri url);
    Task<AppTarget?> LaunchAppAsync(string appName, string? launchCommand = null, CancellationToken cancellationToken = default);
    Task<AppTarget?> LaunchUrlAsync(Uri url, CancellationToken cancellationToken = default);
}

public interface IWindowTracker
{
    AppTarget? GetActiveTarget(AppTarget currentTarget);

    /// <summary>Like <see cref="GetActiveTarget(AppTarget)"/>, also adopting a foreground app the goal names.</summary>
    AppTarget? GetActiveTarget(AppTarget currentTarget, string goal) => GetActiveTarget(currentTarget);
}

