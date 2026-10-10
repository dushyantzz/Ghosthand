using FluentAssertions;
using GhostHand.Core.Agent;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Jev;
using GhostHand.Core.Models;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Xunit;

namespace GhostHand.Tests.Agent;

public class UnverifiedDoneTests
{
    [Fact]
    public async Task UD01_RepeatedUnverifiedDone_FinishesInsteadOfTrippingLoopGuard()
    {
        var reader = new Mock<IScreenReader>();
        reader.Setup(r => r.ReadElementsAsync(It.IsAny<AppTarget>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<AccessibilityElement> { new() { Id = "e1", Role = "Edit", Label = "Search" } });

        var histories = new List<string[]>();
        var model = new Mock<IDecisionModel>();
        model.Setup(d => d.DecideNextActionAsync(It.IsAny<string>(), It.IsAny<AppTarget>(),
                It.IsAny<IReadOnlyList<AccessibilityElement>>(), It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()))
            .Callback<string, AppTarget, IReadOnlyList<AccessibilityElement>, IReadOnlyList<string>, CancellationToken>((_, _, _, h, _) => histories.Add(h.ToArray()))
            .ReturnsAsync(new AgentDecision { Operation = AgentOperation.Done });
        model.Setup(d => d.VerifyCompletionAsync(It.IsAny<string>(), It.IsAny<AppTarget>(),
                It.IsAny<IReadOnlyList<AccessibilityElement>>(), It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(false);

        var executor = new Mock<IActionExecutor>();
        var loop = new AgentLoop(reader.Object, model.Object, executor.Object,
            new AgentLoopOptions { MaxSteps = 20, DryRun = true, MaxConsecutiveStalls = 15 },
            NullLogger<AgentLoop>.Instance);

        var result = await loop.RunAsync("search for arijit singh songs",
            new AppTarget { ProcessId = 1, ProcessName = "chrome", WindowTitle = "YouTube" }, CancellationToken.None);

        result.Status.Should().Be(AgentRunStatus.Completed);
        histories.Should().HaveCount(2);
        histories[1].Should().ContainSingle(h => h.StartsWith("Done:"), "the model is told its first done wasn't verified");
        executor.Verify(e => e.ExecuteAsync(It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement?>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task UD03_AppNamedInGoalComesToFront_LoopAdoptsItAsTarget()
    {
        var chrome = new AppTarget { ProcessId = 10, ProcessName = "chrome", WindowTitle = "New Tab", WindowHandle = (IntPtr)0x10 };
        var notepad = new AppTarget { ProcessId = 20, ProcessName = "Notepad", WindowTitle = "Untitled", WindowHandle = (IntPtr)0x20 };

        var tracker = new Mock<IWindowTracker>();
        tracker.Setup(t => t.GetActiveTarget(It.IsAny<AppTarget>(), "open notepad and write hello")).Returns(notepad);

        var reader = new Mock<IScreenReader>();
        reader.Setup(r => r.ReadElementsAsync(It.IsAny<AppTarget>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<AccessibilityElement>());
        var model = new Mock<IDecisionModel>();
        model.Setup(d => d.DecideNextActionAsync(It.IsAny<string>(), It.IsAny<AppTarget>(),
                It.IsAny<IReadOnlyList<AccessibilityElement>>(), It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AgentDecision { Operation = AgentOperation.Done });
        model.Setup(d => d.VerifyCompletionAsync(It.IsAny<string>(), It.IsAny<AppTarget>(),
                It.IsAny<IReadOnlyList<AccessibilityElement>>(), It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(true);

        var loop = new AgentLoop(reader.Object, model.Object, new Mock<IActionExecutor>().Object,
            new AgentLoopOptions { MaxSteps = 3, DryRun = true }, NullLogger<AgentLoop>.Instance,
            windowTracker: tracker.Object);
        AppTarget? switchedTo = null;
        loop.TargetChanged += t => switchedTo = t;

        await loop.RunAsync("open notepad and write hello", chrome, CancellationToken.None);

        switchedTo.Should().Be(notepad);
        reader.Verify(r => r.ReadElementsAsync(notepad, It.IsAny<CancellationToken>()), Times.AtLeastOnce);
    }

    [Fact]
    public async Task UD04_TakePhoto_IsOfferedOnlyOncePerTask()
    {
        EvaluateRequest? captured = null;
        var client = new Mock<IJevClient>();
        client.Setup(c => c.EvaluateAsync(It.IsAny<EvaluateRequest>(), It.IsAny<CancellationToken>()))
            .Callback<EvaluateRequest, CancellationToken>((r, _) => captured ??= r)
            .ReturnsAsync(new EvaluateResponse());
        var model = new JevDecisionModel(client.Object, new JevOptions(), NullLogger<JevDecisionModel>.Instance);

        await model.DecideNextActionAsync("open the camera and take a picture of me",
            new AppTarget { ProcessId = 1, ProcessName = "ApplicationFrameHost", WindowTitle = "Camera" },
            new List<AccessibilityElement>
            {
                new() { Id = "e1", Role = "Button", Label = "Take photo" },
                new() { Id = "e2", Role = "Button", Label = "Settings" }
            },
            new[] { "Click:e9 (Take photo) -> ok", "Click:e2 (Settings) -> ok" });

        var options = (Dictionary<string, string>)captured!.Questions["nextAction"].Criteria!;
        options.Keys.Should().NotContain("click:e1", "a second click would take a second photo");
        options.Keys.Should().Contain("click:e2", "ordinary buttons may still be clicked twice");
    }

    [Fact]
    public async Task UD02_AfterFailedDone_DoneIsWithheldForOneStep()
    {
        EvaluateRequest? captured = null;
        var client = new Mock<IJevClient>();
        client.Setup(c => c.EvaluateAsync(It.IsAny<EvaluateRequest>(), It.IsAny<CancellationToken>()))
            .Callback<EvaluateRequest, CancellationToken>((r, _) => captured ??= r)
            .ReturnsAsync(new EvaluateResponse());
        var model = new JevDecisionModel(client.Object, new JevOptions(), NullLogger<JevDecisionModel>.Instance);

        await model.DecideNextActionAsync("search for arijit singh songs",
            new AppTarget { ProcessId = 1, ProcessName = "chrome", WindowTitle = "YouTube" },
            new List<AccessibilityElement> { new() { Id = "e1", Role = "Edit", Label = "Search" } },
            new[] { "Done: () -> not verified" });

        var options = (Dictionary<string, string>)captured!.Questions["nextAction"].Criteria!;
        options.Keys.Should().NotContain("done");
        options.Keys.Should().Contain(k => k.StartsWith("type_and_enter:e1:"));
    }
}
