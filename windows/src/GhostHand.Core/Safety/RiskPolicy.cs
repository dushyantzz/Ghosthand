using System.Text.RegularExpressions;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Models;
using Microsoft.Extensions.Logging;

namespace GhostHand.Core.Safety;

/// <summary>
/// Jarvis-mode risk policy: execute ALL tasks automatically.
/// The ONLY restriction is deletion operations — these are permanently prohibited.
/// No confirmation dialogs for anything else.
/// </summary>
public class RiskPolicy : IRiskPolicy
{
    private readonly RiskPolicyOptions _options;
    private readonly ILogger<RiskPolicy> _logger;
    private readonly Regex _prohibitedRegex;

    public RiskPolicy(RiskPolicyOptions? options = null, ILogger<RiskPolicy>? logger = null)
    {
        _options = options ?? new RiskPolicyOptions();
        _logger = logger ?? Microsoft.Extensions.Logging.Abstractions.NullLogger<RiskPolicy>.Instance;

        // Build word-boundary regex for deletion terms only
        if (_options.ProhibitedTerms.Count > 0)
        {
            var prohibitedPatterns = _options.ProhibitedTerms.Select(Regex.Escape);
            _prohibitedRegex = new Regex(
                $@"\b({string.Join("|", prohibitedPatterns)})\b",
                RegexOptions.IgnoreCase | RegexOptions.Compiled);
        }
        else
        {
            _prohibitedRegex = new Regex(@"^$", RegexOptions.Compiled); // never matches
        }
    }

    /// <summary>
    /// Checks if the target application process is on the deny-list (e.g. password managers).
    /// </summary>
    public bool IsAppDenied(AppTarget appTarget, out string reason)
    {
        if (_options.DenyListedProcesses.Contains(appTarget.ProcessName))
        {
            reason = $"Application process '{appTarget.ProcessName}' is on the security deny-list.";
            _logger.LogWarning("Security deny-list triggered: {Reason}", reason);
            return true;
        }

        reason = string.Empty;
        return false;
    }

    /// <summary>
    /// Jarvis mode: NEVER requires human confirmation.
    /// All safe actions are auto-executed. Only deletion goals are blocked (via IsGoalProhibited / IsActionProhibited).
    /// </summary>
    public bool RequiresConfirmation(
        AgentDecision decision,
        AccessibilityElement? target,
        AppTarget appTarget,
        out string reason)
    {
        // Jarvis mode: zero confirmation dialogs — always auto-execute
        reason = string.Empty;
        return false;
    }

    /// <summary>
    /// Checks if the user''s goal contains deletion instructions. If so, block the entire task.
    /// </summary>
    public bool IsGoalProhibited(string goal, out string reason)
    {
        if (string.IsNullOrWhiteSpace(goal))
        {
            reason = string.Empty;
            return false;
        }

        var match = _prohibitedRegex.Match(goal);
        if (match.Success)
        {
            reason = $"Prohibited by safety policy: Deletion tasks (matching ''{match.Value}'') are strictly prohibited.";
            _logger.LogWarning("Goal prohibited by policy: {Reason}", reason);
            return true;
        }

        reason = string.Empty;
        return false;
    }

    /// <summary>
    /// Checks if a specific action targets a deletion operation. If so, block it mid-task.
    /// Uses regex to match deletion terms in element labels and typed text.
    /// </summary>
    public bool IsActionProhibited(AgentDecision decision, AccessibilityElement? target, string goal, out string reason)
    {
        // Collect all text to inspect
        var textToInspect = new List<string>(4);
        if (!string.IsNullOrWhiteSpace(decision.TargetLabel)) textToInspect.Add(decision.TargetLabel);
        if (target != null)
        {
            if (!string.IsNullOrWhiteSpace(target.Label)) textToInspect.Add(target.Label);
            if (!string.IsNullOrWhiteSpace(target.Value)) textToInspect.Add(target.Value);
        }
        if (decision.Operation is AgentOperation.TypeText or AgentOperation.TypeAndEnter or AgentOperation.TypeKeys &&
            !string.IsNullOrWhiteSpace(decision.TextValue))
        {
            textToInspect.Add(decision.TextValue);
        }

        // Use regex to find any deletion term in the text
        foreach (var text in textToInspect)
        {
            var match = _prohibitedRegex.Match(text);
            if (match.Success)
            {
                reason = $"Prohibited by safety policy: Action ''{decision.Operation}'' on ''{target?.DisplayLabel ?? decision.TargetLabel}'' matches deletion term ''{match.Value}''.";
                _logger.LogWarning("Action prohibited by policy: {Reason}", reason);
                return true;
            }
        }

        reason = string.Empty;
        return false;
    }
}
