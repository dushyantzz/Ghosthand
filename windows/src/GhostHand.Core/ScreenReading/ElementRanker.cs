using GhostHand.Core.Models;

namespace GhostHand.Core.ScreenReading;

public static class ElementRanker
{
    private static readonly HashSet<string> InteractiveRoles = new(StringComparer.OrdinalIgnoreCase)
    {
        "Button", "MenuItem", "TabItem", "Hyperlink", "CheckBox",
        "RadioButton", "ComboBox", "ListItem", "Edit", "Document", "SplitButton"
    };

    /// <summary>Slots kept for labelled status/result text, so buttons can't crowd it out.</summary>
    public const int ReservedEvidenceSlots = 8;

    public static IReadOnlyList<AccessibilityElement> RankAndFilter(
        IEnumerable<AccessibilityElement> elements,
        ScreenReaderOptions options)
    {
        var filtered = elements
            .Where(e => !options.FilterOffscreen || IsOnScreen(e))
            .Where(e => !options.FilterDisabled || e.Enabled)
            .Take(options.MaxNodes)
            .ToList();

        // Sort by priority:
        // 1. Focused element first
        // 2. Interactive elements
        // 3. Elements with meaningful labels/values
        // 4. Outcome evidence / status elements
        // 5. Visual order (top-to-bottom, then left-to-right)
        var sorted = filtered
            .OrderByDescending(e => e.Focused)
            // Media transport controls usually sit at the bottom of the window and would be cut
            // by MaxCandidates, yet they're the only evidence that "play X" has succeeded
            .ThenByDescending(e => IsPlaybackControl(e))
            .ThenByDescending(e => IsInteractive(e.Role))
            .ThenByDescending(e => !string.IsNullOrWhiteSpace(e.DisplayLabel))
            .ThenByDescending(e => e.IsOutcomeEvidence)
            .ThenBy(e => e.Frame.Y)
            .ThenBy(e => e.Frame.X)
            .ToList();

        // Cap to MaxCandidates, but reserve room for labelled status text. Interactive controls rank first, so a
        // button-heavy window (Calculator: 40+ buttons) used to push out its only result ("Display is 95"),
        // leaving the model no way to see that an action worked or that the task is done.
        var evidence = sorted
            .Where(e => e.IsOutcomeEvidence && !IsInteractive(e.Role) && !string.IsNullOrWhiteSpace(e.DisplayLabel))
            .OrderBy(e => e.Frame.Y).ThenBy(e => e.Frame.X)
            .Take(Math.Min(ReservedEvidenceSlots, options.MaxCandidates / 4))
            .ToHashSet(ReferenceEqualityComparer.Instance);
        var others = sorted.Where(e => !evidence.Contains(e)).Take(options.MaxCandidates - evidence.Count)
            .ToHashSet(ReferenceEqualityComparer.Instance);
        var candidateList = sorted.Where(e => evidence.Contains(e) || others.Contains(e)).ToList();

        // Assign stable sequential IDs: e1, e2, e3...
        var result = new List<AccessibilityElement>(candidateList.Count);
        for (int i = 0; i < candidateList.Count; i++)
        {
            var el = candidateList[i];
            result.Add(el with
            {
                Id = $"e{i + 1}"
            });
        }

        return result;
    }

    public static bool IsInteractive(string role) =>
        InteractiveRoles.Contains(role) ||
        (role.StartsWith("AX", StringComparison.OrdinalIgnoreCase) && InteractiveRoles.Contains(role[2..]));

    public static bool IsPlaybackControl(AccessibilityElement element) =>
        System.Text.RegularExpressions.Regex.IsMatch(
            element.DisplayLabel ?? string.Empty,
            @"^(?:pause|play|resume|now playing|next|previous|skip)\b",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    private static bool IsOnScreen(AccessibilityElement element)
    {
        // Must have non-zero dimension and non-negative coordinates
        return element.Frame.Width > 0 && element.Frame.Height > 0;
    }
}
