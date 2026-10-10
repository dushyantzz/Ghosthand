using System.IO;
using FluentAssertions;
using GhostHand.Core.Agent;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Models;
using GhostHand.Platform.Speech;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Whisper.net;
using Xunit;

namespace GhostHand.Tests.Speech;

public class VoiceInputTests
{
    [Fact]
    public async Task VO_01_NoAudioDevice_FallsBackGracefullyToSecondaryService()
    {
        // Simulates a machine without a microphone; on a machine with one, this would really record for 30s
        if (WhisperSpeechService.HasMicrophone()) return;

        var mockFallback = new Mock<ISpeechInput>();
        mockFallback
            .Setup(f => f.TranscribeAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync("fallback transcript");

        using var whisperService = new WhisperSpeechService(
            fallbackService: mockFallback.Object,
            customModelDir: Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")),
            logger: NullLogger<WhisperSpeechService>.Instance);

        var result = await whisperService.TranscribeAsync(CancellationToken.None);
        result.Should().Be("fallback transcript");
        mockFallback.Verify(f => f.TranscribeAsync(It.IsAny<CancellationToken>()), Times.AtLeastOnce);
    }

    [Fact]
    public async Task VO_01_NoDeviceAndNoFallback_ThrowsDescriptiveExceptionWithoutCrash()
    {
        // Simulates a machine without a microphone; on a machine with one, this would really record for 30s
        if (WhisperSpeechService.HasMicrophone()) return;

        using var whisperService = new WhisperSpeechService(
            fallbackService: null,
            customModelDir: Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")),
            logger: NullLogger<WhisperSpeechService>.Instance);

        var act = async () => await whisperService.TranscribeAsync(CancellationToken.None);
        await act.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("*microphone*");
    }

    [Fact]
    public async Task VO_02_TranscriptFeedsIntoSameLoopAsTypedText()
    {
        var fakeSpeechInput = new Mock<ISpeechInput>();
        fakeSpeechInput
            .Setup(s => s.TranscribeAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync("open calculator");

        var mockScreenReader = new Mock<IScreenReader>();
        mockScreenReader
            .Setup(s => s.ReadElementsAsync(It.IsAny<AppTarget>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(new List<AccessibilityElement>
            {
                new() { Id = "c1", Role = "Button", Label = "Clear", Enabled = true }
            });

        var mockDecisionModel = new Mock<IDecisionModel>();
        mockDecisionModel
            .Setup(d => d.DecideNextActionAsync(
                It.IsAny<string>(),
                It.IsAny<AppTarget>(),
                It.IsAny<IReadOnlyList<AccessibilityElement>>(),
                It.IsAny<IReadOnlyList<string>>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(new AgentDecision
            {
                Operation = AgentOperation.Done,
                TargetId = "c1",
                TargetLabel = "Clear"
            });

        mockDecisionModel
            .Setup(d => d.VerifyCompletionAsync(
                It.IsAny<string>(),
                It.IsAny<AppTarget>(),
                It.IsAny<IReadOnlyList<AccessibilityElement>>(),
                It.IsAny<IReadOnlyList<string>>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(true);

        var mockExecutor = new Mock<IActionExecutor>();
        mockExecutor
            .Setup(e => e.ExecuteAsync(It.IsAny<AgentDecision>(), It.IsAny<AccessibilityElement?>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(ActionResult.SuccessResult("Clicked c1"));

        var loop = new AgentLoop(
            mockScreenReader.Object,
            mockDecisionModel.Object,
            mockExecutor.Object,
            new AgentLoopOptions { MaxSteps = 3, DryRun = true },
            NullLogger<AgentLoop>.Instance);

        var transcript = await fakeSpeechInput.Object.TranscribeAsync();
        transcript.Should().Be("open calculator");

        var target = new AppTarget { ProcessId = 1234, ProcessName = "calc", WindowTitle = "Calculator" };
        var result = await loop.RunAsync(transcript, target, CancellationToken.None);

        result.Status.Should().Be(AgentRunStatus.Completed);
        mockDecisionModel.Verify(d => d.DecideNextActionAsync(
            "open calculator",
            It.IsAny<AppTarget>(),
            It.IsAny<IReadOnlyList<AccessibilityElement>>(),
            It.IsAny<IReadOnlyList<string>>(),
            It.IsAny<CancellationToken>()), Times.AtLeastOnce);
    }

    [Fact]
    public async Task VO_03_MissingWhisperModel_FallsBackGracefully()
    {
        // Simulates a machine without a microphone; on a machine with one, this would really record for 30s
        if (WhisperSpeechService.HasMicrophone()) return;

        var fallbackRecognizer = new Mock<ISpeechInput>();
        fallbackRecognizer
            .Setup(f => f.TranscribeAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync("fallback result");

        var emptyDir = Path.Combine(Path.GetTempPath(), "ghosthand_nonexistent_" + Guid.NewGuid().ToString("N"));

        using var whisperService = new WhisperSpeechService(
            fallbackService: fallbackRecognizer.Object,
            customModelDir: emptyDir,
            logger: NullLogger<WhisperSpeechService>.Instance);

        var result = await whisperService.TranscribeAsync(CancellationToken.None);
        result.Should().Be("fallback result");
    }

    [Theory]
    [InlineData("[BLANK_AUDIO]", "")]
    [InlineData(" play dooron dooron (music) ", "play dooron dooron")]
    [InlineData("open spotify *coughs*  and play", "open spotify and play")]
    [InlineData("Open Chrome and search Open Chrome and search Open Chrome and search", "Open Chrome and search")]
    [InlineData("Open Spotify and play Doron Doron.", "Open Spotify and play Doron Doron.")]
    [InlineData("play dooron dooron dooron", "play dooron dooron dooron")]
    [InlineData("Open the Notepad and write hell. Open the Notepad and write hell. Open the Notepad and write hell.", "Open the Notepad and write hell.")]
    public void VO_05_CleanTranscript_DropsNonSpeechMarkers(string raw, string expected)
    {
        WhisperSpeechService.CleanTranscript(raw).Should().Be(expected);
    }

    [Theory]
    [InlineData("opensp叫 our N doorway.", "opensp our N doorway.")]
    [InlineData("Open Spotify and play Doran Doran.", "Open Spotify and play Doran Doran.")]
    [InlineData("play Beyoncé", "play Beyoncé")]
    public void VO_06_StripNonLatin_KeepsLatinTextOnly(string raw, string expected)
    {
        WhisperSpeechService.StripNonLatin(raw).Should().Be(expected);
    }

    [Fact]
    public void VO_04_WhisperProcessor_LoadsDownloadedModelSuccessfully()
    {
        var modelPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GhostHand", "models", "ggml-tiny.bin");
        if (!File.Exists(modelPath)) return;

        using var factory = WhisperFactory.FromPath(modelPath);
        using var processor = factory.CreateBuilder()
            .WithLanguage("auto")
            .WithNoContext()
            .WithSingleSegment()
            .Build();

        processor.Should().NotBeNull();
    }
}
