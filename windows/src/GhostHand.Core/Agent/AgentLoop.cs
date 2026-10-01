using GhostHand.Core.Interfaces;
using GhostHand.Core.Models;
using GhostHand.Core.Safety;
using Microsoft.Extensions.Logging;

namespace GhostHand.Core.Agent;

public enum AgentRunStatus
{
    Completed,
    NeedsHumanInput,
    Stalled,
    MaxStepsReached,
    Cancelled,
    Failed
}

public record AgentRunResult
{
    public required AgentRunStatus Status { get; init; }
    public int StepsCompleted { get; init; }
    public IReadOnlyList<string> ActionHistory { get; init; } = Array.Empty<string>();
    public string? Message { get; init; }

    public static AgentRunResult Completed(int steps, IReadOnlyList<string> history) => new()
    {
        Status = AgentRunStatus.Completed,
        StepsCompleted = steps,
        ActionHistory = history,
        Message = "Goal successfully achieved."
    };

    public static AgentRunResult NeedsHumanInput(int steps, IReadOnlyList<string> history, string? reason) => new()
    {
        Status = AgentRunStatus.NeedsHumanInput,
        StepsCompleted = steps,
        ActionHistory = history,
        Message = reason ?? "Human input required."
    };

    public static AgentRunResult Stalled(int steps, IReadOnlyList<string> history, string? reason) => new()
    {
        Status = AgentRunStatus.Stalled,
        StepsCompleted = steps,
        ActionHistory = history,
        Message = reason ?? "Loop guard tripped: screen state unchanged."
    };

    public static AgentRunResult MaxStepsReached(int steps, IReadOnlyList<string> history) => new()
    {
        Status = AgentRunStatus.MaxStepsReached,
        StepsCompleted = steps,
        ActionHistory = history,
        Message = $"Reached maximum step limit ({steps})."
    };

    public static AgentRunResult Failed(int steps, IReadOnlyList<string> history, string error) => new()
    {
        Status = AgentRunStatus.Failed,
        StepsCompleted = steps,
        ActionHistory = history,
        Message = error
    };

    public static AgentRunResult Cancelled(int steps, IReadOnlyList<string> history) => new()
    {
        Status = AgentRunStatus.Cancelled,
        StepsCompleted = steps,
        ActionHistory = history,
        Message = "Run was cancelled."
    };
}

public class AgentLoop
{
    private readonly IScreenReader _screenReader;
    private readonly IDecisionModel _decisionModel;
    private readonly IActionExecutor _actionExecutor;
    private readonly AgentLoopOptions _options;
    private readonly ILogger<AgentLoop> _logger;
    private readonly IRiskPolicy _riskPolicy;
    private readonly IConfirmationPrompt? _confirmationPrompt;
    private readonly IAuditLog? _auditLog;
    private readonly IWindowTracker? _windowTracker;

    public event Action<string>? StatusChanged;
    public event Action<int, AgentDecision, ActionResult>? StepCompleted;
    public event Action<AppTarget>? TargetChanged;

    public AgentLoop(
        IScreenReader screenReader,
        IDecisionModel decisionModel,
        IActionExecutor actionExecutor,
        AgentLoopOptions options,
        ILogger<AgentLoop> logger,
        IRiskPolicy? riskPolicy = null,
        IConfirmationPrompt? confirmationPrompt = null,
        IAuditLog? auditLog = null,
        IWindowTracker? windowTracker = null)
    {
        _screenReader = screenReader;
        _decisionModel = decisionModel;
        _actionExecutor = actionExecutor;
        _options = options;
        _logger = logger;
        _riskPolicy = riskPolicy ?? new RiskPolicy();
        _confirmationPrompt = confirmationPrompt;
        _auditLog = auditLog;
        _windowTracker = windowTracker;
    }

    public async Task<AgentRunResult> RunAsync(
        string goal,
        AppTarget target,
        CancellationToken cancellationToken = default)
    {
        var currentTarget = target;
        var history = new List<string>();
        var loopGuard = new LoopGuard(_options.MaxConsecutiveStalls);
        int step = 0;
        var runId = Guid.NewGuid().ToString("N")[..12];

        _logger.LogInformation("Starting AgentLoop for goal '{Goal}' on target '{Target}' (DryRun: {DryRun})",
            goal, currentTarget.ProcessName, _options.DryRun);

        // Security check 1: verify if goal is strictly prohibited (e.g. deletion tasks)
        if (_riskPolicy.IsGoalProhibited(goal, out var goalProhibitedReason))
        {
            _logger.LogWarning("Goal prohibited by policy: {Reason}", goalProhibitedReason);
            NotifyStatus(goalProhibitedReason);

            if (_auditLog != null)
            {
                await _auditLog.LogAsync(new AuditLogEntry
                {
                    RunId = runId,
                    Step = 0,
                    Goal = goal,
                    Operation = AgentOperation.AskUser,
                    AppProcess = currentTarget.ProcessName,
                    AppTitle = currentTarget.WindowTitle,
                    DecisionType = "prohibited",
                    Reason = goalProhibitedReason
                }, CancellationToken.None);
            }

            return AgentRunResult.Failed(0, history, goalProhibitedReason);
        }

        // Security check 2: verify if target process is deny-listed
        if (_riskPolicy.IsAppDenied(currentTarget, out var denyReason))
        {
            _logger.LogWarning("App deny-list triggered: {Reason}", denyReason);
            NotifyStatus($"Security policy refusal: {denyReason}");

            if (_auditLog != null)
            {
                await _auditLog.LogAsync(new AuditLogEntry
                {
                    RunId = runId,
                    Step = 0,
                    Goal = goal,
                    Operation = AgentOperation.AskUser,
                    AppProcess = currentTarget.ProcessName,
                    AppTitle = currentTarget.WindowTitle,
                    DecisionType = "denied",
                    Reason = denyReason
                }, CancellationToken.None);
            }

            return AgentRunResult.Failed(0, history, denyReason);
        }

        try
        {
            while (_options.MaxSteps <= 0 || step < _options.MaxSteps)
            {
                cancellationToken.ThrowIfCancellationRequested();
                step++;
                var stepPrefix = _options.MaxSteps > 0 ? $"Step {step}/{_options.MaxSteps}" : $"Step {step}";

                // 0. Auto-sync target window if tracking service indicates active foreground app changed
                if (_windowTracker != null)
                {
                    var trackedTarget = _windowTracker.GetActiveTarget(currentTarget);
                    if (trackedTarget != null && (trackedTarget.WindowHandle != currentTarget.WindowHandle || trackedTarget.ProcessId != currentTarget.ProcessId))
                    {
                        _logger.LogInformation("Active target auto-switched to {Process} ('{Title}')", trackedTarget.ProcessName, trackedTarget.WindowTitle);
                        currentTarget = trackedTarget;
                        loopGuard.Reset();
                        TargetChanged?.Invoke(currentTarget);
                        NotifyStatus($"Target active: {currentTarget.ProcessName} (\"{currentTarget.WindowTitle}\")");
                    }
                }

                // 1. Observe screen elements
                NotifyStatus($"{stepPrefix}: Reading screen...");
                var elements = await _screenReader.ReadElementsAsync(currentTarget, cancellationToken);

                // 2. Loop guard stall check - wait and continue if screen hasn't changed (may be loading)
                if (loopGuard.RecordObservation(elements))
                {
                    _logger.LogWarning("Stall detected: {Count} identical consecutive observations.", loopGuard.ConsecutiveStalls);
                    NotifyStatus($"Waiting for screen to update... (stall {loopGuard.ConsecutiveStalls}/{_options.MaxConsecutiveStalls})");
                    // Wait up to 1.5s for the screen/page to load before re-reading
                    await Task.Delay(1500, cancellationToken);
                    elements = await _screenReader.ReadElementsAsync(currentTarget, cancellationToken);
                    if (loopGuard.RecordObservation(elements))
                    {
                        // Screen truly stuck after retry - give up to avoid infinite spin
                        _logger.LogWarning("Screen still unchanged after retry stall {Count}.", loopGuard.ConsecutiveStalls);
                        if (loopGuard.IsStalled)
                        {
                            NotifyStatus("Screen state did not change — task may be complete or requires manual intervention.");
                            return AgentRunResult.Stalled(step, history, "Loop guard tripped: screen state did not change across actions.");
                        }
                    }
                }

                // 3. Jev Call A: Next action & Goal completion check
                NotifyStatus($"{stepPrefix}: Choosing next action...");
                var decision = await _decisionModel.DecideNextActionAsync(goal, currentTarget, elements, history, cancellationToken);

                // 4. Check if decision is Done
                if (decision.Operation == AgentOperation.Done)
                {
                    NotifyStatus("Verifying goal completion...");
                    var verified = await _decisionModel.VerifyCompletionAsync(goal, currentTarget, elements, history, cancellationToken);
                    if (verified)
                    {
                        NotifyStatus("Goal successfully completed!");
                        return AgentRunResult.Completed(step, history);
                    }

                    _logger.LogInformation("Done operation verification was inconclusive. Continuing loop.");
                }

                // 5. Check if decision is AskUser / Low confidence
                if (decision.Operation == AgentOperation.AskUser)
                {
                    NotifyStatus($"Guidance needed: {decision.Reason}");
                    return AgentRunResult.NeedsHumanInput(step, history, decision.Reason);
                }

                // 6. Locate target element
                var targetElement = !string.IsNullOrEmpty(decision.TargetId)
                    ? elements.FirstOrDefault(e => e.Id == decision.TargetId)
                    : null;

                // Shared audit context for every decision taken on this step.
                AuditLogEntry NewAudit(string decisionType, string? reason) => new()
                {
                    RunId = runId,
                    Step = step,
                    Goal = goal,
                    Operation = decision.Operation,
                    TargetId = decision.TargetId,
                    TargetLabel = targetElement?.DisplayLabel ?? decision.TargetLabel,
                    TargetRole = targetElement?.DisplayRole,
                    AppProcess = currentTarget.ProcessName,
                    AppTitle = currentTarget.WindowTitle,
                    DecisionType = decisionType,
                    Reason = reason
                };

                // 7. Safety Invariant: Check if action is strictly prohibited (e.g. deletion operations/buttons)
                if (_riskPolicy.IsActionProhibited(decision, targetElement, goal, out var actionProhibitedReason))
                {
                    _logger.LogWarning("Action prohibited by safety policy: {Reason}", actionProhibitedReason);
                    NotifyStatus(actionProhibitedReason);

                    if (_auditLog != null)
                    {
                        await _auditLog.LogAsync(NewAudit("prohibited", actionProhibitedReason), cancellationToken);
                    }

                    return AgentRunResult.Failed(step, history, actionProhibitedReason);
                }

                // 8. Safety invariants: honour the risk policy's confirmation requirement.
                // Jarvis mode's default policy never requires confirmation (deletion is blocked
                // outright above), but when a policy does require it we must actually ask a human
                // and fail closed when no prompt is available.
                var requiresConfirmation = _riskPolicy.RequiresConfirmation(decision, targetElement, currentTarget, out var riskReason);
                if (requiresConfirmation)
                {
                    if (_confirmationPrompt == null)
                    {
                        _logger.LogError("Policy requires confirmation but no confirmation prompt is configured. Refusing action.");
                        NotifyStatus($"Confirmation required but unavailable: {riskReason}");
                        if (_auditLog != null)
                        {
                            await _auditLog.LogAsync(NewAudit("denied", riskReason), cancellationToken);
                        }

                        return AgentRunResult.NeedsHumanInput(step, history, riskReason);
                    }

                    var approved = await _confirmationPrompt.RequestConfirmationAsync(
                        decision, targetElement, currentTarget, riskReason, cancellationToken);

                    if (_auditLog != null)
                    {
                        await _auditLog.LogAsync(
                            NewAudit(approved ? "confirmed" : "rejected", riskReason), cancellationToken);
                    }

                    if (!approved)
                    {
                        NotifyStatus("Action rejected by human.");
                        return AgentRunResult.Cancelled(step, history);
                    }
                }
                else if (_auditLog != null)
                {
                    // Auto-approved harmless action
                    await _auditLog.LogAsync(
                        NewAudit("auto", "Harmless action allowed by safety policy."), cancellationToken);
                }

                // 9. Execute action (Dry-run or live)
                var actionLabel = targetElement != null ? $"'{targetElement.DisplayLabel}'" : decision.TargetId;
                NotifyStatus($"{stepPrefix}: {decision.Operation} on {actionLabel}");

                var result = await _actionExecutor.ExecuteAsync(decision, targetElement, cancellationToken);

                var historyEntry = $"{decision.Operation}:{decision.TargetId} ({decision.TargetLabel}) -> {(result.Success ? "ok" : result.Error)}";
                history.Add(historyEntry);

                StepCompleted?.Invoke(step, decision, result);

                if (!result.Success)
                {
                    var err = result.ErrorMessage ?? result.Error ?? "Action execution failed.";
                    _logger.LogWarning("Action execution failed at step {Step}: {Error}", step, err);
                    return AgentRunResult.Failed(step, history, err);
                }

                // Dynamic Target Transition upon launching app/URL
                if (result.NewTarget != null)
                {
                    _logger.LogInformation("Target switched from '{OldTarget}' to '{NewTarget}'",
                        currentTarget.ProcessName, result.NewTarget.ProcessName);
                    currentTarget = result.NewTarget;
                    loopGuard.Reset();
                    TargetChanged?.Invoke(currentTarget);
                    NotifyStatus($"Switched target to {currentTarget.ProcessName} (\"{currentTarget.WindowTitle}\")");
                }
            }

            NotifyStatus($"Max steps ({_options.MaxSteps}) reached.");
            return AgentRunResult.MaxStepsReached(step, history);
        }
        catch (OperationCanceledException)
        {
            _logger.LogInformation("AgentLoop was cancelled.");
            NotifyStatus("Run cancelled by user.");
            return AgentRunResult.Cancelled(step, history);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "AgentLoop terminated unexpectedly.");
            NotifyStatus($"Error: {ex.Message}");
            return AgentRunResult.Failed(step, history, ex.Message);
        }
    }

    private void NotifyStatus(string message)
    {
        _logger.LogDebug("[AgentLoop] {Message}", message);
        StatusChanged?.Invoke(message);
    }
}
