using System.Text.RegularExpressions;
using GhostHand.Core.Jev;

namespace GhostHand.Core.Agent;

/// <summary>
/// Watches live (partial) voice transcripts and spots a safe action that can start before the user
/// finishes the sentence: opening / switching to an app. "Open Spotify and play …" launches Spotify as
/// soon as "and" is heard, while the song name is still being spoken. Only app launches qualify —
/// clicks, typing and anything else wait for the complete command. Fires at most once per utterance.
/// </summary>
public sealed class EarlyIntentDetector
{
    // Leading app-launch clause, closed by a connector so we know the app name is complete.
    // "go to" is excluded: it usually names a website, not an app.
    private static readonly Regex LaunchClause = new(
        @"^\s*(?:(?:hey|ok|okay|please|can\s+you|could\s+you|ghosthand)[\s,]+)*(?:open|launch|start|switch\s+to)\s+(.+?)\s*(?:,|\.|\band\b|\bthen\b)",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private bool _fired;

    /// <summary>Start of a new utterance (mic pressed), or retry after a failed early launch.</summary>
    public void Reset() => _fired = false;

    /// <summary>
    /// Returns the app to launch now, or null. <paramref name="currentProcess"/> is the app the user is
    /// already in; asking for it again is a no-op.
    /// </summary>
    public string? TryGetEarlyLaunch(string partialTranscript, string? currentProcess)
    {
        if (_fired || string.IsNullOrWhiteSpace(partialTranscript))
            return null;

        var match = LaunchClause.Match(partialTranscript);
        if (!match.Success)
            return null;

        var rawName = match.Groups[1].Value.Trim();
        if (rawName.Length == 0 || rawName.Contains('.') || rawName.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length > 3)
            return null; // websites ("youtube.com") and run-on phrases aren't app names

        var app = JevDecisionModel.ExtractAppLaunchCandidates($"open {rawName}").FirstOrDefault();
        if (string.IsNullOrWhiteSpace(app))
            return null;

        if (!string.IsNullOrEmpty(currentProcess) &&
            (currentProcess.Contains(app, StringComparison.OrdinalIgnoreCase) || app.Contains(currentProcess, StringComparison.OrdinalIgnoreCase)))
            return null;

        _fired = true;
        return app;
    }
}
