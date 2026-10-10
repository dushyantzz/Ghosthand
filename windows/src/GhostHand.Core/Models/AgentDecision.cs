namespace GhostHand.Core.Models;

public enum AgentOperation
{
    Click,
    TypeText,
    TypeAndEnter,
    ClickText,
    ScrollUp,
    ScrollDown,
    PressReturn,
    PressTab,
    PressEscape,
    Wait,
    OpenApp,
    OpenUrl,
    PressSpace,
    PressMediaPlay,
    Done,
    Blocked,
    AskUser,
    /// <summary>Type text on the keyboard into whatever has focus, then press Enter (no target element).
    /// For apps without a text box, e.g. Calculator: "450+40" + Enter.</summary>
    TypeKeys
}

/// <summary>
/// A concrete decision made by Jev or the deterministic fallback.
/// </summary>
public record AgentDecision
{
    public required AgentOperation Operation { get; init; }
    public string? TargetId { get; init; }
    public string? TargetLabel { get; init; }
    public string? TextValue { get; init; }
    public int? X { get; init; }
    public int? Y { get; init; }
    public string? Reason { get; init; }
    public double Confidence { get; init; } = 1.0;

    public bool RequiresConfirmation { get; init; }
}
