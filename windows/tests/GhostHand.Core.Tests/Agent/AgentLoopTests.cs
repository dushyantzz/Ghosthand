using FluentAssertions;
using GhostHand.Core.Agent;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Models;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Xunit;

namespace GhostHand.Core.Tests.Agent;

public class AgentLoopTests
{
    private readonly AppTarget _testTarget = new()
    {
        ProcessId = 1234,
        ProcessName = "TestApp",
        WindowTitle = "Test App Window"
    };

    [Fact]
    public async Task EX05_NoChangeAfterAction_LoopGuardStopsRun()
    {
        var screenReaderMock = new Mock<IScreenReader>();
        var decisionModelMock = new Mock<IDecisionModel>();
        var actionExecutorMock = new Mock<IActionExecutor>();

        // Always return the exact same screen state (unchanging elements)
        var staticElements = new List<AccessibilityElement>
        {
            new() { Id = "e1", Role = "Button", Label = "Search Button", Enabled = true }
        };
        screenReaderMock.Setup(r => r.ReadElementsAsync(It.IsAny<AppTarget>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(staticElements);

        decisionModelMock.Setup(d => d.DecideNextActionAsync(
                It.IsAny<string>(), It.IsAny<AppTarget>(), It.IsAny<IReadOnlyList<AccessibilityElement>>(), It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AgentDecision { Operation = AgentOperation.Click, TargetId = "e1", TargetLabel = "Search Button" });

        actionExecutorMock.Setup(a => a.ExecuteAsync(It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(ActionResult.SuccessResult("Clicked e1"));

        var options = new AgentLoopOptions
        {
            MaxSteps = 10,
            MaxConsecutiveStalls = 3,
            DryRun = true
        };

        var loop = new AgentLoop(screenReaderMock.Object, decisionModelMock.Object, actionExecutorMock.Object, options, NullLogger<AgentLoop>.Instance);

        var result = await loop.RunAsync("test goal", _testTarget);

        result.Status.Should().Be(AgentRunStatus.Stalled);
        result.Message.Should().Contain("Loop guard tripped");
        // Must trip on the 3rd unchanged state
        result.StepsCompleted.Should().Be(3);
    }

    [Fact]
    public async Task EX06_MaxStepCap_StopsRun()
    {
        var screenReaderMock = new Mock<IScreenReader>();
        var decisionModelMock = new Mock<IDecisionModel>();
        var actionExecutorMock = new Mock<IActionExecutor>();

        int stepCounter = 0;
        // Return changing screen states each time so loop guard doesn't trip
        screenReaderMock.Setup(r => r.ReadElementsAsync(It.IsAny<AppTarget>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(() => new List<AccessibilityElement>
            {
                new() { Id = $"e_{++stepCounter}", Role = "Button", Label = $"Item {stepCounter}", Enabled = true }
            });

        decisionModelMock.Setup(d => d.DecideNextActionAsync(
                It.IsAny<string>(), It.IsAny<AppTarget>(), It.IsAny<IReadOnlyList<AccessibilityElement>>(), It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(() => new AgentDecision { Operation = AgentOperation.Click, TargetId = $"e_{stepCounter}", TargetLabel = "Next" });

        actionExecutorMock.Setup(a => a.ExecuteAsync(It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(ActionResult.SuccessResult("Clicked"));

        var options = new AgentLoopOptions
        {
            MaxSteps = 5,
            MaxConsecutiveStalls = 10,
            DryRun = true
        };

        var loop = new AgentLoop(screenReaderMock.Object, decisionModelMock.Object, actionExecutorMock.Object, options, NullLogger<AgentLoop>.Instance);

        var result = await loop.RunAsync("keep going", _testTarget);

        result.Status.Should().Be(AgentRunStatus.MaxStepsReached);
        result.StepsCompleted.Should().Be(5);
        result.Message.Should().Contain("Reached maximum step limit (5)");
    }

    [Fact]
    public void EX07_UrlValidator_AcceptsHttpAndHttps_RejectsOthers()
    {
        // Valid web URLs
        UrlLauncherValidator.IsValidWebUrl("https://news.ycombinator.com", out var uri1).Should().BeTrue();
        uri1!.Scheme.Should().Be("https");
        uri1.Host.Should().Be("news.ycombinator.com");

        UrlLauncherValidator.IsValidWebUrl("http://localhost:3000/dashboard", out var uri2).Should().BeTrue();
        uri2!.Scheme.Should().Be("http");

        // Invalid / dangerous non-http protocols
        UrlLauncherValidator.IsValidWebUrl("file:///C:/Windows/System32/cmd.exe", out _).Should().BeFalse();
        UrlLauncherValidator.IsValidWebUrl("javascript:alert(1)", out _).Should().BeFalse();
        UrlLauncherValidator.IsValidWebUrl("cmd.exe /c calc", out _).Should().BeFalse();
        UrlLauncherValidator.IsValidWebUrl("ftp://ftp.example.com", out _).Should().BeFalse();
        UrlLauncherValidator.IsValidWebUrl("data:text/html,<html></html>", out _).Should().BeFalse();
        UrlLauncherValidator.IsValidWebUrl("", out _).Should().BeFalse();

        // Extraction from natural language prompt with punctuation stripping
        var prompt = "Please navigate to https://github.com/dushyantzz/Ghosthand and also check http://example.com/api.";
        var extracted = UrlLauncherValidator.ExtractWebUrls(prompt);
        extracted.Should().HaveCount(2);
        extracted[0].ToString().Should().Be("https://github.com/dushyantzz/Ghosthand");
        extracted[1].ToString().Should().Be("http://example.com/api");
    }

    [Fact]
    public async Task EX04_ProcessMismatch_AbortsMidAction()
    {
        var screenReaderMock = new Mock<IScreenReader>();
        var decisionModelMock = new Mock<IDecisionModel>();
        var actionExecutorMock = new Mock<IActionExecutor>();

        screenReaderMock.Setup(r => r.ReadElementsAsync(It.IsAny<AppTarget>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<AccessibilityElement> { new() { Id = "e1", Role = "Button", Label = "Btn" } });

        decisionModelMock.Setup(d => d.DecideNextActionAsync(
                It.IsAny<string>(), It.IsAny<AppTarget>(), It.IsAny<IReadOnlyList<AccessibilityElement>>(), It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AgentDecision { Operation = AgentOperation.Click, TargetId = "e1", TargetLabel = "Btn" });

        // ActionExecutor reports foreground process switched away
        actionExecutorMock.Setup(a => a.ExecuteAsync(It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(ActionResult.FailureResult("Foreground process changed mid-action (expected PID 1234, found 9999). Execution aborted."));

        var loop = new AgentLoop(
            screenReaderMock.Object,
            decisionModelMock.Object,
            actionExecutorMock.Object,
            new AgentLoopOptions { MaxSteps = 5, DryRun = true },
            NullLogger<AgentLoop>.Instance);

        var result = await loop.RunAsync("type text", _testTarget);

        result.Status.Should().Be(AgentRunStatus.Failed);
        result.Message.Should().Contain("Foreground process changed mid-action");
        result.StepsCompleted.Should().Be(1);
    }
}
