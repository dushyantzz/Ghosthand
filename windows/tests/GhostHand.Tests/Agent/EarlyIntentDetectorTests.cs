using FluentAssertions;
using GhostHand.Core.Agent;
using Xunit;

namespace GhostHand.Tests.Agent;

public class EarlyIntentDetectorTests
{
    [Theory]
    [InlineData("Open Spotify and", "spotify")]
    [InlineData("Open Spotify and Play Doran", "spotify")]
    [InlineData("open the crome browser and search", "chrome")]
    [InlineData("Please launch notepad, then write", "notepad")]
    [InlineData("Hey, switch to discord and", "discord")]
    [InlineData("Open Spotify.", "spotify")]
    public void EI01_LaunchClause_WithConnector_FiresEarly(string partial, string expectedApp)
    {
        new EarlyIntentDetector().TryGetEarlyLaunch(partial, "explorer").Should().BeEquivalentTo(expectedApp);
    }

    [Theory]
    [InlineData("Open Spoti")]            // app name may still be incomplete
    [InlineData("Open Spotify")]          // no connector yet
    [InlineData("Play Doran Doran on Spotify")] // no launch clause
    [InlineData("go to youtube.com and search")] // websites aren't launched early
    [InlineData("search for open source and")]
    public void EI02_IncompleteOrNonLaunchPhrases_DoNotFire(string partial)
    {
        new EarlyIntentDetector().TryGetEarlyLaunch(partial, "explorer").Should().BeNull();
    }

    [Fact]
    public void EI03_FiresOncePerUtterance_UntilReset()
    {
        var detector = new EarlyIntentDetector();
        detector.TryGetEarlyLaunch("Open Spotify and", "explorer").Should().BeEquivalentTo("spotify");
        detector.TryGetEarlyLaunch("Open Spotify and play Doran Doran", "explorer").Should().BeNull();

        detector.Reset();
        detector.TryGetEarlyLaunch("Open Spotify and", "explorer").Should().BeEquivalentTo("spotify");
    }

    [Fact]
    public void EI04_AlreadyInThatApp_DoesNothing()
    {
        new EarlyIntentDetector().TryGetEarlyLaunch("Open Spotify and play Doran", "Spotify").Should().BeNull();
    }
}
