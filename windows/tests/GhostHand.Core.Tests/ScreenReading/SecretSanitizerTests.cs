using FluentAssertions;
using GhostHand.Core.ScreenReading;
using Xunit;

namespace GhostHand.Core.Tests.ScreenReading;

/// <summary>
/// Cross-platform counterpart to the macOS <c>SecretSanitizerTests</c>: covers every pattern the
/// sanitizer recognises, including the cloud/provider credentials added to close the earlier gap.
/// </summary>
public class SecretSanitizerTests
{
    [Fact]
    public void PasswordFields_AlwaysBecomePasswordPlaceholder()
    {
        SecretSanitizer.Sanitize("SuperSecretP@ssword123!", isPassword: true).Should().Be("[PASSWORD]");
        SecretSanitizer.Sanitize(string.Empty, isPassword: true).Should().Be("[PASSWORD]");
        SecretSanitizer.Sanitize(null, isPassword: true).Should().Be("[PASSWORD]");
    }

    [Fact]
    public void CreditCardNumbers_AreRedacted()
    {
        var separated = "Please bill credit card 4111 2222 3333 4444 for $50";
        var dashed = "card=4532-0150-1234-5678";
        var compact = "4111222233334444";

        SecretSanitizer.Sanitize(separated).Should().NotContain("4111 2222 3333 4444").And
            .Contain("[REDACTED_CARD]");
        SecretSanitizer.Sanitize(dashed).Should().NotContain("4532-0150-1234-5678").And
            .Contain("[REDACTED_CARD]");
        SecretSanitizer.Sanitize(compact).Should().Be("[REDACTED_CARD]");
    }

    [Fact]
    public void ApiKeys_AreRedacted()
    {
        // Fixtures are assembled at runtime so the source never contains a contiguous
        // provider-token literal; GitHub secret scanning flags those as exposed secrets.
        var samples = new[]
        {
            "vck_dummy_test_key_sample1234567890abcdef",
            "sk-" + "abcdefghijklmnopqrstuvwxyz0123456789",
            "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789"
        };

        foreach (var secret in samples)
        {
            var sanitized = SecretSanitizer.Sanitize($"Gateway token is {secret} ok");
            sanitized.Should().NotContain(secret);
            sanitized.Should().Contain("[REDACTED_KEY]");
        }
    }

    [Fact]
    public void ProviderAndPrivateKeys_AreRedacted()
    {
        // Slack and Stripe fixtures are assembled at runtime so the source file never contains a
        // contiguous provider-token literal — GitHub push protection blocks those as secrets.
        var samples = new[]
        {
            "AKIA" + "IOSFODNN7EXAMPLE",                     // AWS access key
            "gho_" + "abcdefghijklmnopqrstuvwxyz0123456789", // GitHub OAuth token
            "xox" + "b-123456789012-abcdefghijklmnop",       // Slack bot token
            "AIza" + "SyA1234567890abcdefghijklmnopqrstuv",  // Google API key
            "sk_" + "live_abcdefghijklmnopqrstuvwx"          // Stripe secret key
        };

        foreach (var secret in samples)
        {
            var sanitized = SecretSanitizer.Sanitize($"credential={secret} end");
            sanitized.Should().NotContain(secret);
            sanitized.Should().Contain("[REDACTED_KEY]");
        }

        var pem = "-----BEGIN RSA PRIVATE KEY-----MIIEowIBAAKCAQEA-----END RSA PRIVATE KEY-----";
        var sanitizedPem = SecretSanitizer.Sanitize(pem);
        sanitizedPem.Should().NotContain("BEGIN RSA PRIVATE KEY");
        sanitizedPem.Should().Contain("[REDACTED_PRIVATE_KEY]");
    }

    [Fact]
    public void Jwt_IsRedacted()
    {
        var jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
        var sanitized = SecretSanitizer.Sanitize($"auth={jwt}");

        sanitized.Should().NotContain(jwt);
        sanitized.Should().Contain("[REDACTED_KEY]");
    }

    [Fact]
    public void BearerTokens_AreRedacted_KeepingTheScheme()
    {
        var token = "my_secret_token_1234567890_abcdef";
        var sanitized = SecretSanitizer.Sanitize($"Authorization: Bearer {token}");

        sanitized.Should().NotContain(token);
        sanitized.Should().Contain("Bearer [REDACTED]");
    }

    [Fact]
    public void OrdinaryText_IsUntouched()
    {
        const string text = "Submit Application Form for Alice Smith";
        SecretSanitizer.Sanitize(text).Should().Be(text);
    }

    [Fact]
    public void NilAndEmptyText_ReturnEmptyString()
    {
        SecretSanitizer.Sanitize(null).Should().BeEmpty();
        SecretSanitizer.Sanitize(string.Empty).Should().BeEmpty();
    }
}
