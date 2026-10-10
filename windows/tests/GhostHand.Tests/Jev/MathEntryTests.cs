using FluentAssertions;
using GhostHand.Core.Jev;
using GhostHand.Core.Models;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Xunit;

namespace GhostHand.Tests.Jev;

public class MathEntryTests
{
    [Theory]
    [InlineData("open the calculator and do 450 + 40", "450+40")]
    [InlineData("open the calculator and do 45 plus 50", "45+50")]
    [InlineData("what is 12 times 8", "12*8")]
    [InlineData("calculate 450 * 12 + 85", "450*12+85")]
    [InlineData("100 divided by 4", "100/4")]
    [InlineData("compute 7x6", "7*6")]
    [InlineData("1,200 minus 350", "1200-350")]
    [InlineData("(3 + 4) * 5", "(3+4)*5")]
    [InlineData("calculate 450 + 430 + 80*20", "450+430+80*20")]
    public void ME01_ExtractsCalculationsAsKeyboardInput(string goal, string expected)
    {
        JevDecisionModel.ExtractMathExpression(goal).Should().Be(expected);
    }

    [Theory]
    [InlineData("open notepad and write hello")]
    [InlineData("search for 2024 election results")]
    [InlineData("play track 2 on spotify")]
    public void ME02_GoalsWithoutCalculation_GiveNothing(string goal)
    {
        JevDecisionModel.ExtractMathExpression(goal).Should().BeNull();
    }

    [Fact]
    public async Task ME03_CalculatorStep_OffersOneKeyboardEntryOption_AndParsesIt()
    {
        EvaluateRequest? captured = null;
        var client = new Mock<IJevClient>();
        client.Setup(c => c.EvaluateAsync(It.IsAny<EvaluateRequest>(), It.IsAny<CancellationToken>()))
            .Callback<EvaluateRequest, CancellationToken>((r, _) => captured ??= r)
            .ReturnsAsync(System.Text.Json.JsonSerializer.Deserialize<EvaluateResponse>(
                """{"answers":{"nextAction":{"choice":"keys:45+50","probabilities":{"keys:45+50":0.95}},"goalAchieved":{"probability":0.01}}}""")!);
        var model = new JevDecisionModel(client.Object, new JevOptions(), NullLogger<JevDecisionModel>.Instance);

        var decision = await model.DecideNextActionAsync("open the calculator and do 45 + 50",
            new AppTarget { ProcessId = 1, ProcessName = "ApplicationFrameHost", WindowTitle = "Calculator" },
            new List<AccessibilityElement>
            {
                new() { Id = "e1", Role = "Text", Label = "Display is 0" },
                new() { Id = "e2", Role = "Button", Label = "Four" },
                new() { Id = "e3", Role = "Button", Label = "Plus" }
            },
            new[] { "OpenApp:calculator (calculator) -> ok" });

        var options = (Dictionary<string, string>)captured!.Questions["nextAction"].Criteria!;
        options.Should().ContainKey("keys:45+50");
        decision.Operation.Should().Be(AgentOperation.TypeKeys);
        decision.TextValue.Should().Be("45+50");
    }

    private static readonly AppTarget Calculator = new() { ProcessId = 1, ProcessName = "ApplicationFrameHost", WindowTitle = "Calculator" };

    private static (JevDecisionModel Model, Func<Dictionary<string, string>?> Options) CapturingModel()
    {
        EvaluateRequest? captured = null;
        var client = new Mock<IJevClient>();
        client.Setup(c => c.EvaluateAsync(It.IsAny<EvaluateRequest>(), It.IsAny<CancellationToken>()))
            .Callback<EvaluateRequest, CancellationToken>((r, _) => captured ??= r)
            .ReturnsAsync(new EvaluateResponse());
        var model = new JevDecisionModel(client.Object, new JevOptions(), NullLogger<JevDecisionModel>.Instance);
        return (model, () => captured?.Questions["nextAction"].Criteria as Dictionary<string, string>);
    }

    private static List<AccessibilityElement> Keypad(string display) => new()
    {
        new() { Id = "e1", Role = "Text", Label = display },
        new() { Id = "e2", Role = "Button", Label = "Three" },
        new() { Id = "e3", Role = "Button", Label = "Four" },
        new() { Id = "e4", Role = "Button", Label = "Plus" },
        new() { Id = "e5", Role = "Button", Label = "Equals" },
        new() { Id = "e6", Role = "Button", Label = "Open history flyout" }
    };

    [Fact]
    public async Task ME04_KeyboardEntry_IsOfferedTwice_ThenNotAgain()
    {
        var (model, options) = CapturingModel();
        await model.DecideNextActionAsync("do 45 + 50", Calculator, Keypad("Display is 7"),
            new[] { "TypeKeys: () -> ok" });
        options()!.Keys.Should().Contain("keys:45+50");

        (model, options) = CapturingModel();
        await model.DecideNextActionAsync("do 45 + 50", Calculator, Keypad("Display is 7"),
            new[] { "TypeKeys: () -> ok", "TypeKeys: () -> ok" });
        options()!.Keys.Should().NotContain(k => k.StartsWith("keys:"));
    }

    [Fact]
    public async Task ME05_KeypadButtons_AreHidden_WhileKeyboardEntryIsAvailable()
    {
        // The failing run: the model clicked "Three", "Four", then typed "3+4" → Calculator computed 343+4
        var (model, options) = CapturingModel();
        await model.DecideNextActionAsync("open the calculator and calculate 3+4", Calculator, Keypad("Display is 0"),
            new[] { "OpenApp:calculator (calculator) -> ok" });

        var keys = options()!.Keys;
        keys.Should().Contain("keys:3+4");
        keys.Should().NotContain(new[] { "click:e2", "click:e3", "click:e4", "click:e5" });
        keys.Should().Contain("click:e6"); // non-keypad buttons stay available
    }

    [Theory]
    [InlineData("calculate 3+4", "Display is 7")]
    [InlineData("calculate 450 * 2 +90", "Display is 990")]
    [InlineData("do 1,200 plus 800", "Display is 2,000")]
    public async Task ME06_ShownResult_AfterTyping_IsDone_WithoutAskingTheModel(string goal, string display)
    {
        var client = new Mock<IJevClient>(MockBehavior.Strict);
        var model = new JevDecisionModel(client.Object, new JevOptions(), NullLogger<JevDecisionModel>.Instance);

        var decision = await model.DecideNextActionAsync(goal, Calculator, Keypad(display), new[] { "TypeKeys: () -> ok" });

        decision.Operation.Should().Be(AgentOperation.Done);
    }

    [Fact]
    public async Task ME07_WrongResult_IsNotDone()
    {
        var (model, options) = CapturingModel();
        var decision = await model.DecideNextActionAsync("calculate 3+4", Calculator, Keypad("Display is 347"),
            new[] { "TypeKeys: () -> ok" });

        decision.Operation.Should().NotBe(AgentOperation.Done);
        options()!.Keys.Should().Contain("keys:3+4"); // a clean retry is still possible
    }

    [Fact]
    public async Task ME08_ScrollingStops_AfterThreeInARow()
    {
        var (model, options) = CapturingModel();
        await model.DecideNextActionAsync("calculate 3+4", Calculator, Keypad("Display is 0"),
            new[] { "ScrollDown: () -> ok", "ScrollDown: () -> ok", "ScrollDown: () -> ok" });

        options()!.Keys.Should().NotContain(new[] { "scroll:down", "scroll:up" });
    }

    [Theory]
    [InlineData("3+4", 7)]
    [InlineData("450*2+90", 990)]
    [InlineData("100/4", 25)]
    [InlineData("(3+4)*5", 35)]
    [InlineData("450+430+80*20", 2480)]
    public void ME09_EvaluateExpression(string expression, double expected)
    {
        JevDecisionModel.EvaluateExpression(expression).Should().Be((decimal)expected);
    }
}
