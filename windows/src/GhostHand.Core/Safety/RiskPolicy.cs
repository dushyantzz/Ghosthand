using System.Text;
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
    /// Matching is case-insensitive and substring-based (mirroring the macOS port) so that
    /// renamed or suffixed binaries such as "1password-beta" or "KeePassXC" are still caught.
    /// </summary>
    public bool IsAppDenied(AppTarget appTarget, out string reason)
    {
        var processName = appTarget.ProcessName?.Trim() ?? string.Empty;
        var executablePath = appTarget.ExecutablePath?.Trim() ?? string.Empty;

        foreach (var denied in _options.DenyListedProcesses)
        {
            if (denied.Length == 0)
                continue;

            if (processName.Contains(denied, StringComparison.OrdinalIgnoreCase)
                || executablePath.Contains(denied, StringComparison.OrdinalIgnoreCase))
            {
                reason = $"Application process '{appTarget.ProcessName}' is on the security deny-list.";
                _logger.LogWarning("Security deny-list triggered: {Reason}", reason);
                return true;
            }
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

        var match = _prohibitedRegex.Match(NormalizeForMatch(goal));
        if (match.Success)
        {
            reason = $"Prohibited by safety policy: Deletion tasks (matching '{match.Value}') are strictly prohibited.";
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
        if (decision.Operation == AgentOperation.TypeText && !string.IsNullOrWhiteSpace(decision.TextValue))
        {
            textToInspect.Add(decision.TextValue);
        }

        // Use regex to find any deletion term in the text
        foreach (var text in textToInspect)
        {
            var match = _prohibitedRegex.Match(NormalizeForMatch(text));
            if (match.Success)
            {
                reason = $"Prohibited by safety policy: Action '{decision.Operation}' on '{target?.DisplayLabel ?? decision.TargetLabel}' matches deletion term '{match.Value}'.";
                _logger.LogWarning("Action prohibited by policy: {Reason}", reason);
                return true;
            }
        }

        reason = string.Empty;
        return false;
    }

    /// <summary>
    /// Normalises text before deletion-term matching: strips zero-width / bidirectional
    /// control characters that could smuggle a prohibited word past the regex
    /// (e.g. "del\u200Bete"), then applies Unicode NFC so decomposed forms also match.
    /// </summary>
    private static string NormalizeForMatch(string text)
    {
        var filtered = new StringBuilder(text.Length);
        foreach (var ch in text)
        {
            switch (ch)
            {
                case '\u200B': // zero-width space
                case '\u200C': // zero-width non-joiner
                case '\u200D': // zero-width joiner
                case '\u2060': // word joiner
                case '\uFEFF': // zero-width no-break space
                case '\u202A': // bidi embedding/override controls
                case '\u202B':
                case '\u202C':
                case '\u202D':
                case '\u202E':
                    continue;
                default:
                    filtered.Append(ch);
                    break;
            }
        }

        var filteredText = filtered.ToString();

        // String.Normalize throws ArgumentException on malformed Unicode (unpaired surrogates).
        // A hostile label must not be able to turn the guard into a crash, so fall back to the
        // filtered text — the control characters are already gone either way.
        try
        {
            return filteredText.Normalize(NormalizationForm.FormC);
        }
        catch (ArgumentException)
        {
            return filteredText;
        }
    }
}
