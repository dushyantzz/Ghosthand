using FluentAssertions;
using GhostHand.Core.Agent;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Jev;
using GhostHand.Core.Models;
using GhostHand.Platform.Launcher;
using Moq;
using Xunit;

namespace GhostHand.Tests.Launcher;

public class AppLauncherTests
{
    private readonly AppLauncher _launcher = new();

    [Theory]
    [InlineData("launch notepad", "notepad")]
    [InlineData("start calculator and calculate 5 + 5", "calculator")]
    [InlineData("open chrome and search for Adele", "chrome")]
    [InlineData("open file explorer", "file explorer")]
    [InlineData("open task manager", "task manager")]
    [InlineData("open blender and render", "blender")]
    [InlineData("switch to discord and send message", "discord")]
    public void AL01_TryExtractAppLaunch_RecognizesValidAppsWithoutHardcoding(string goal, string expectedApp)
    {
        bool success = _launcher.TryExtractAppLaunch(goal, out var appName, out _);

        success.Should().BeTrue();
        appName.ToLowerInvariant().Should().Be(expectedApp.ToLowerInvariant());
    }

    [Theory]
    [InlineData("powershell.exe -enc dGVzdA==")]
    [InlineData("cmd.exe /c del *.*")]
    [InlineData("rundll32.exe")]
    [InlineData("format.com")]
    public async Task AL02_MaliciousCommands_AreBlockedBySafetyPolicy(string dangerousCommand)
    {
        var act = async () => await _launcher.LaunchAppAsync("malicious", dangerousCommand);

        await act.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("*safety policy*");
    }

    [Fact]
    public void AL03_TryExtractUrlLaunch_ExtractsHttpAndHttpsUrls()
    {
        bool success = _launcher.TryExtractUrlLaunch("open https://github.com/dushyantzz/Ghosthand to check release", out var url);

        success.Should().BeTrue();
        url.ToString().Should().Be("https://github.com/dushyantzz/Ghosthand");
    }

    [Fact]
    public void AL04_CandidateChoices_IncludeOpenAppAndOpenUrl_WhenPresentInGoal()
    {
        var candidates = JevDecisionModel.ExtractAppLaunchCandidates("open obsidian");
        candidates.Should().Contain(c => c.Equals("obsidian", StringComparison.OrdinalIgnoreCase));

        var urlCandidates = UrlLauncherValidator.ExtractWebUrls("open https://news.ycombinator.com");
        urlCandidates.Should().NotBeEmpty();
        urlCandidates[0].Host.Should().Be("news.ycombinator.com");
    }

    [Theory]
    [InlineData("open the crome browser and play dhoondta hoon on spotify", "chrome")]
    [InlineData("open the crome browser and play dhoondta hoon on spotify", "spotify")]
    [InlineData("open microsoft edge", "msedge")]
    [InlineData("launch the spotify app", "spotify")]
    [InlineData("play aditya rikhari on spotify", "spotify")]
    public void AL04b_AppCandidates_NormalizeArticlesSuffixesAndMisspellings(string goal, string expectedApp)
    {
        JevDecisionModel.ExtractAppLaunchCandidates(goal)
            .Should().Contain(c => c.Equals(expectedApp, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task AL05_AgentLoop_TransitionsTargetWindow_WhenAppIsLaunched()
    {
        // Arrange
        var mockScreenReader = new Mock<IScreenReader>();
        var mockDecisionModel = new Mock<IDecisionModel>();
        var mockActionExecutor = new Mock<IActionExecutor>();

        var initialTarget = new AppTarget
        {
            ProcessId = 1000,
            ProcessName = "explorer",
            WindowTitle = "Program Manager",
            WindowHandle = new IntPtr(0x1000)
        };

        var launchedTarget = new AppTarget
        {
            ProcessId = 2000,
            ProcessName = "SystemSettings",
            WindowTitle = "Settings",
            WindowHandle = new IntPtr(0x2000)
        };

        mockScreenReader.Setup(r => r.ReadElementsAsync(It.IsAny<AppTarget>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<AccessibilityElement>());

        // Jev makes every decision: Step 1 = OpenApp, Step 2 = Done
        mockDecisionModel.SetupSequence(d => d.DecideNextActionAsync(It.IsAny<string>(), It.IsAny<AppTarget>(), It.IsAny<IReadOnlyList<AccessibilityElement>>(), It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AgentDecision
            {
                Operation = AgentOperation.OpenApp,
                TargetId = "settings",
                Confidence = 0.99
            })
            .ReturnsAsync(new AgentDecision
            {
                Operation = AgentOperation.Done,
                Reason = "App is opened and goal achieved",
                Confidence = 0.99
            });

        mockDecisionModel.Setup(d => d.VerifyCompletionAsync(It.IsAny<string>(), It.IsAny<AppTarget>(), It.IsAny<IReadOnlyList<AccessibilityElement>>(), It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(true);

        // Executor returns NewTarget on OpenApp
        mockActionExecutor.Setup(e => e.ExecuteAsync(It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement?>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(ActionResult.TargetChanged(launchedTarget, "Launched SystemSettings"));

        var loop = new AgentLoop(
            mockScreenReader.Object,
            mockDecisionModel.Object,
            mockActionExecutor.Object,
            new AgentLoopOptions { MaxSteps = 5, DryRun = false },
            Microsoft.Extensions.Logging.Abstractions.NullLogger<AgentLoop>.Instance);

        // Act
        var result = await loop.RunAsync("open settings", initialTarget);

        // Assert: Jev decided OpenApp, then Jev decided Done
        result.Status.Should().Be(AgentRunStatus.Completed);
        mockActionExecutor.Verify(e => e.ExecuteAsync(It.Is<AgentDecision>(d => d.Operation == AgentOperation.OpenApp), null, It.IsAny<CancellationToken>()), Times.Once);
        mockDecisionModel.Verify(d => d.VerifyCompletionAsync(It.IsAny<string>(), launchedTarget, It.IsAny<IReadOnlyList<AccessibilityElement>>(), It.IsAny<IReadOnlyList<string>>(), It.IsAny<CancellationToken>()), Times.Once);
    }

    [Theory]
    [InlineData("search for Adele on youtube", "youtube.com", "Adele")]
    [InlineData("search for quantum computing on google", "google.com", "quantum")]
    [InlineData("google current weather", "google.com", "weather")]
    [InlineData("open brave and search lion", "google.com", "lion")]
    [InlineData("search about lion", "google.com", "lion")]
    [InlineData("search lion in brave", "google.com", "lion")]
    [InlineData("open github.com", "github.com", "")]
    [InlineData("visit wikipedia.org", "wikipedia.org", "")]
    public void AL06_TryExtractUrlLaunch_SynthesizesWebSearchesAndSites(string goal, string expectedHost, string expectedQueryFragment)
    {
        bool success = _launcher.TryExtractUrlLaunch(goal, out var url);

        success.Should().BeTrue();
        url.Host.Should().Contain(expectedHost);
        if (!string.IsNullOrEmpty(expectedQueryFragment))
        {
            url.Query.Should().Contain(expectedQueryFragment);
        }
    }

    [Theory]
    [InlineData("switch to discord", "discord")]
    [InlineData("start spotify", "spotify")]
    [InlineData("open vlc", "vlc")]
    [InlineData("launch blender", "blender")]
    public void AL07_TryExtractAppLaunch_SupportsUniversalApps(string goal, string expectedApp)
    {
        bool success = _launcher.TryExtractAppLaunch(goal, out var appName, out _);

        success.Should().BeTrue();
        appName.ToLowerInvariant().Should().Be(expectedApp.ToLowerInvariant());
    }

    [Theory]
    [InlineData("open brave and search lion", "lion")]
    [InlineData("search about lion", "lion")]
    [InlineData("open chrome and search for weather", "weather")]
    [InlineData("write hello into notepad", "hello")]
    [InlineData("open spotify and play any song of aditya rikhari", "aditya rikhari")]
    [InlineData("play aditya rikhari on spotify", "aditya rikhari")]
    [InlineData("listen to Bohemian Rhapsody", "Bohemian Rhapsody")]
    [InlineData("Open the notepad and write, hello. How are you today?", "hello")]
    [InlineData("Open Chrome and search: weather forecast.", "weather forecast")]
    public void AL08_ExtractCandidatePhrases_ExtractsSearchAndWriteTerms(string goal, string expectedPhrase)
    {
        var candidates = JevDecisionModel.ExtractCandidatePhrases(goal);
        candidates.Should().Contain(expectedPhrase);
    }

    [Theory]
    [InlineData("spotify", @"C:\Users\User\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Spotify.lnk", "Spotify")]
    [InlineData("notepad", @"C:\Windows\System32\notepad.exe", "notepad")]
    [InlineData("settings", "ms-settings:", "SystemSettings")]
    [InlineData("calculator", null, "calculator")]
    public void AL09_GetExpectedProcessName_ResolvesValidProcessName(string appName, string? command, string expectedProc)
    {
        var proc = AppLauncher.GetExpectedProcessName(appName, command);
        proc.Should().BeEquivalentTo(expectedProc);
    }

    [Fact]
    public void AL10_ExtractWebUrls_SynthesizesSpotifySearchUrl_ForMusicIntent()
    {
        var urls = UrlLauncherValidator.ExtractWebUrls("open spotify and play any song of aditya rikhari");
        urls.Should().NotBeEmpty();
        urls.Should().Contain(u => u.Host.Contains("spotify.com") && u.AbsolutePath.Contains("search"));
    }

    [Fact]
    public void AL11_ExtractWebUrls_SynthesizesChainedPlatformSearchUrl()
    {
        var urls = UrlLauncherValidator.ExtractWebUrls("open brave and search for youtube and search honey singh songs");
        urls.Should().NotBeEmpty();
        urls.Should().Contain(u => u.Host.Contains("youtube.com") && u.Query.Contains("honey"));
    }
}
