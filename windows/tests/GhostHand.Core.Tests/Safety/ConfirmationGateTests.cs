using System.Drawing;
using FluentAssertions;
using GhostHand.Core.Agent;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Models;
using GhostHand.Core.Safety;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Xunit;

namespace GhostHand.Core.Tests.Safety;

/// <summary>
/// The default Jarvis policy never asks for confirmation, but when a policy DOES require it the
/// loop must actually prompt a human and fail closed when no prompt is available. These tests pin
/// that contract so a "confirmed" audit entry can never be written without a real approval.
/// </summary>
public class ConfirmationGateTests
{
    private sealed class AlwaysConfirmRiskPolicy : IRiskPolicy
    {
        public bool IsAppDenied(AppTarget appTarget, out string reason)
        {
            reason = string.Empty;
            return false;
        }

        public bool RequiresConfirmation(AgentDecision decision, AccessibilityElement? target, AppTarget appTarget, out string reason)
        {
            reason = "Stub policy requires confirmation.";
            return true;
        }

        public bool IsGoalProhibited(string goal, out string reason)
        {
            reason = string.Empty;
            return false;
        }

        public bool IsActionProhibited(AgentDecision decision, AccessibilityElement? target, string goal, out string reason)
        {
            reason = string.Empty;
            return false;
        }
    }

    private static readonly AppTarget SampleApp = new()
    {
        ProcessId = 42,
        ProcessName = "notepad",
        WindowTitle = "Untitled - Notepad",
        WindowHandle = (IntPtr)0x42,
        WindowBounds = new Rectangle(0, 0, 400, 300)
    };

    private static Mock<IScreenReader> BuildReader()
    {
        var reader = new Mock<IScreenReader>();
        reader
            .Setup(r => r.ReadElementsAsync(It.IsAny<AppTarget>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<AccessibilityElement>
            {
                new() { Id = "e1", Role = "Button", Label = "Submit", Enabled = true }
            });
        return reader;
    }

    private static Mock<IDecisionModel> BuildDecisionModel()
    {
        var calls = 0;
        var model = new Mock<IDecisionModel>();
        model
            .Setup(m => m.DecideNextActionAsync(
                It.IsAny<string>(), It.IsAny<AppTarget>(), It.IsAny<IReadOnlyList<AccessibilityElement>>(),
                It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(() => ++calls == 1
                ? new AgentDecision { Operation = AgentOperation.Click, TargetId = "e1", TargetLabel = "Submit" }
                : new AgentDecision { Operation = AgentOperation.Done });
        model
            .Setup(m => m.VerifyCompletionAsync(
                It.IsAny<string>(), It.IsAny<AppTarget>(), It.IsAny<IReadOnlyList<AccessibilityElement>>(),
                It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(true);
        return model;
    }

    [Fact]
    public async Task ApprovedConfirmation_ExecutesAndAuditsAsConfirmed()
    {
        var prompt = new Mock<IConfirmationPrompt>();
        prompt
            .Setup(p => p.RequestConfirmationAsync(
                It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement?>(), It.IsAny<AppTarget>(),
                It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(true);

        var executor = new Mock<IActionExecutor>();
        executor
            .Setup(e => e.ExecuteAsync(It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement?>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(ActionResult.SuccessResult("Executed"));

        var audit = new Mock<IAuditLog>();

        var loop = new AgentLoop(
            BuildReader().Object,
            BuildDecisionModel().Object,
            executor.Object,
            new AgentLoopOptions { MaxSteps = 5 },
            NullLogger<AgentLoop>.Instance,
            new AlwaysConfirmRiskPolicy(),
            prompt.Object,
            audit.Object);

        var result = await loop.RunAsync("Submit the form", SampleApp);

        result.Status.Should().Be(AgentRunStatus.Completed);
        executor.Verify(
            e => e.ExecuteAsync(It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement?>(), It.IsAny<CancellationToken>()),
            Times.Once);
        audit.Verify(
            a => a.LogAsync(It.Is<AuditLogEntry>(e => e.DecisionType == "confirmed"), It.IsAny<CancellationToken>()),
            Times.Once);
    }

    [Fact]
    public async Task RejectedConfirmation_CancelsWithoutExecuting()
    {
        var prompt = new Mock<IConfirmationPrompt>();
        prompt
            .Setup(p => p.RequestConfirmationAsync(
                It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement?>(), It.IsAny<AppTarget>(),
                It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(false);

        var executor = new Mock<IActionExecutor>();
        var audit = new Mock<IAuditLog>();

        var loop = new AgentLoop(
            BuildReader().Object,
            BuildDecisionModel().Object,
            executor.Object,
            new AgentLoopOptions { MaxSteps = 5 },
            NullLogger<AgentLoop>.Instance,
            new AlwaysConfirmRiskPolicy(),
            prompt.Object,
            audit.Object);

        var result = await loop.RunAsync("Submit the form", SampleApp);

        result.Status.Should().Be(AgentRunStatus.Cancelled);
        executor.Verify(
            e => e.ExecuteAsync(It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement?>(), It.IsAny<CancellationToken>()),
            Times.Never);
        audit.Verify(
            a => a.LogAsync(It.Is<AuditLogEntry>(e => e.DecisionType == "rejected"), It.IsAny<CancellationToken>()),
            Times.Once);
    }

    [Fact]
    public async Task MissingConfirmationPrompt_FailsClosed_NeverAuditsAsConfirmed()
    {
        var executor = new Mock<IActionExecutor>();
        var audit = new Mock<IAuditLog>();

        var loop = new AgentLoop(
            BuildReader().Object,
            BuildDecisionModel().Object,
            executor.Object,
            new AgentLoopOptions { MaxSteps = 5 },
            NullLogger<AgentLoop>.Instance,
            new AlwaysConfirmRiskPolicy(),
            confirmationPrompt: null,
            auditLog: audit.Object);

        var result = await loop.RunAsync("Submit the form", SampleApp);

        result.Status.Should().Be(AgentRunStatus.NeedsHumanInput);
        executor.Verify(
            e => e.ExecuteAsync(It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement?>(), It.IsAny<CancellationToken>()),
            Times.Never);
        audit.Verify(
            a => a.LogAsync(It.Is<AuditLogEntry>(e => e.DecisionType == "confirmed"), It.IsAny<CancellationToken>()),
            Times.Never);
        audit.Verify(
            a => a.LogAsync(It.Is<AuditLogEntry>(e => e.DecisionType == "denied"), It.IsAny<CancellationToken>()),
            Times.Once);
    }
}
