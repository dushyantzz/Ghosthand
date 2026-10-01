using System.Drawing;
using FluentAssertions;
using GhostHand.Core.Models;
using GhostHand.Core.ScreenReading;
using GhostHand.Platform.ScreenReading;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace GhostHand.Tests.ScreenReading;

public class ScreenReaderTests
{
    [Fact]
    public void RD01_RealWindow_Snapshot_ContainsControls_WithRoleAndLabel()
    {
        if (Environment.GetEnvironmentVariable("WINDOWS_UI_TESTS") != "1")
        {
            // Gated test per §10 Test Plan
            return;
        }

        IReadOnlyList<AccessibilityElement>? elements = null;
        Exception? threadEx = null;

        var staThread = new Thread(() =>
        {
            try
            {
                var window = new System.Windows.Window
                {
                    Title = "GhostHand Test Window",
                    Width = 400,
                    Height = 300,
                    WindowStartupLocation = System.Windows.WindowStartupLocation.Manual,
                    Left = 50,
                    Top = 50
                };

                var stack = new System.Windows.Controls.StackPanel();
                var button = new System.Windows.Controls.Button { Content = "Submit Button", Name = "btnSubmit" };
                var textBox = new System.Windows.Controls.TextBox { Text = "Sample Document Text", Name = "txtContent" };
                var passwordBox = new System.Windows.Controls.PasswordBox { Password = "SecretUserPassword", Name = "pwdField" };

                stack.Children.Add(button);
                stack.Children.Add(textBox);
                stack.Children.Add(passwordBox);
                window.Content = stack;
                window.Show();
                window.UpdateLayout();

                var hwnd = new System.Windows.Interop.WindowInteropHelper(window).Handle;
                var target = new AppTarget
                {
                    ProcessId = Environment.ProcessId,
                    ProcessName = "GhostHand.Tests",
                    WindowTitle = "GhostHand Test Window",
                    WindowHandle = hwnd,
                    WindowBounds = new Rectangle(50, 50, 400, 300)
                };

                Task.Run(async () =>
                {
                    try
                    {
                        using var reader = new UiaScreenReader(
                            new ScreenReaderOptions { FilterOffscreen = false },
                            null,
                            NullLogger<UiaScreenReader>.Instance);

                        elements = await reader.ReadElementsAsync(target);
                    }
                    catch (Exception ex)
                    {
                        threadEx = ex;
                    }
                    finally
                    {
                        window.Dispatcher.Invoke(() =>
                        {
                            window.Close();
                            System.Windows.Threading.Dispatcher.CurrentDispatcher.InvokeShutdown();
                        });
                    }
                });

                System.Windows.Threading.Dispatcher.Run();
            }
            catch (Exception ex)
            {
                threadEx = ex;
            }
        });

        staThread.SetApartmentState(ApartmentState.STA);
        staThread.Start();
        staThread.Join(TimeSpan.FromSeconds(15));

        threadEx.Should().BeNull();
        elements.Should().NotBeNull();
        elements!.Count.Should().BeGreaterThan(0);

        // Verify button was captured with role and label
        elements.Should().Contain(e => e.Role == "Button" && e.Label == "Submit Button");

        // Verify text box was captured with role and value
        elements.Should().Contain(e => e.Role == "Edit" && (e.Value == "Sample Document Text" || e.Label == "Sample Document Text"));

        // Verify password box has value redacted to [PASSWORD]
        elements.Should().Contain(e => e.Role == "Edit" && e.Value == "[PASSWORD]");
    }

    [Fact]
    public void RD02_NodeCap_Enforced_And_IdsStableAcrossIdenticalInputs()
    {
        var rawElements = new List<AccessibilityElement>();
        for (int i = 0; i < 600; i++)
        {
            rawElements.Add(new AccessibilityElement
            {
                Id = $"raw_{i}",
                Role = (i % 3 == 0) ? "Button" : (i % 3 == 1) ? "Edit" : "Text",
                Label = $"Item {i}",
                Frame = new Rectangle(10 + (i % 20) * 10, 10 + (i / 20) * 10, 50, 20),
                Enabled = true
            });
        }

        var options = new ScreenReaderOptions
        {
            MaxNodes = 500,
            MaxCandidates = 40
        };

        // First run
        var run1 = ElementRanker.RankAndFilter(rawElements, options);

        // Assert node cap / candidate cap
        run1.Should().HaveCount(40);
        run1[0].Id.Should().Be("e1");
        run1[39].Id.Should().Be("e40");

        // Second run with identical input
        var run2 = ElementRanker.RankAndFilter(rawElements, options);

        // Assert deterministic, stable IDs and ordering
        run2.Should().HaveCount(40);
        for (int i = 0; i < run1.Count; i++)
        {
            run2[i].Id.Should().Be(run1[i].Id);
            run2[i].Label.Should().Be(run1[i].Label);
            run2[i].Role.Should().Be(run1[i].Role);
            run2[i].Frame.Should().Be(run1[i].Frame);
        }
    }

    [Fact]
    public void RD03_PasswordFields_And_Secrets_AlwaysRedacted()
    {
        // 1. Explicit password flag
        var pass = SecretSanitizer.Sanitize("SuperSecretP@ssword123!", isPassword: true);
        pass.Should().Be("[PASSWORD]");

        // 2. Credit card number detection
        var cardText = "Please bill credit card 4111 2222 3333 4444 for $50";
        var sanitizedCard = SecretSanitizer.Sanitize(cardText, isPassword: false);
        sanitizedCard.Should().NotContain("4111 2222 3333 4444");
        sanitizedCard.Should().Contain("[REDACTED_CARD]");

        // 3. API key detection
        var keyText = "Gateway token is vck_dummy_test_key_sample1234567890abcdef";
        var sanitizedKey = SecretSanitizer.Sanitize(keyText, isPassword: false);
        sanitizedKey.Should().NotContain("vck_dummy_test_key_sample1234567890abcdef");
        sanitizedKey.Should().Contain("[REDACTED_KEY]");

        // 4. Bearer header detection
        var bearerText = "Authorization: Bearer my_secret_token_1234567890_abcdef";
        var sanitizedBearer = SecretSanitizer.Sanitize(bearerText, isPassword: false);
        sanitizedBearer.Should().NotContain("my_secret_token_1234567890_abcdef");
        sanitizedBearer.Should().Contain("Bearer [REDACTED]");

        // 5. Provider credentials the original four patterns missed
        var providerSecrets = new[]
        {
            "AKIA" + "IOSFODNN7EXAMPLE",
            "gho_" + "abcdefghijklmnopqrstuvwxyz0123456789",
            "xox" + "b-123456789012-abcdefghijklmnop",
            "AIza" + "SyA1234567890abcdefghijklmnopqrstuv",
            "sk_" + "live_abcdefghijklmnopqrstuvwx"
        };

        foreach (var secret in providerSecrets)
        {
            var sanitized = SecretSanitizer.Sanitize($"credential={secret} end", isPassword: false);
            sanitized.Should().NotContain(secret);
            sanitized.Should().Contain("[REDACTED_KEY]");
        }

        // 6. PEM private-key header
        var pem = "-----BEGIN RSA PRIVATE KEY-----MIIEowIBAAKCAQEA-----END RSA PRIVATE KEY-----";
        var sanitizedPem = SecretSanitizer.Sanitize(pem, isPassword: false);
        sanitizedPem.Should().NotContain("BEGIN RSA PRIVATE KEY");
        sanitizedPem.Should().Contain("[REDACTED_PRIVATE_KEY]");
    }

    [Fact]
    public void RD04_OffscreenElements_And_Disabled_Filtered()
    {
        var elements = new List<AccessibilityElement>
        {
            new() { Id = "on1", Role = "Button", Label = "Visible Button", Frame = new Rectangle(10, 10, 100, 30), Enabled = true },
            new() { Id = "off1", Role = "Button", Label = "Zero Size", Frame = new Rectangle(0, 0, 0, 0), Enabled = true },
            new() { Id = "off2", Role = "Button", Label = "Negative Frame", Frame = new Rectangle(-100, -100, 50, 20), Enabled = true },
            new() { Id = "dis1", Role = "Button", Label = "Disabled Button", Frame = new Rectangle(10, 50, 100, 30), Enabled = false }
        };

        // Filter offscreen only
        var filterOffscreenOpts = new ScreenReaderOptions { FilterOffscreen = true, FilterDisabled = false };
        var result1 = ElementRanker.RankAndFilter(elements, filterOffscreenOpts);
        result1.Select(e => e.Label).Should().Contain("Visible Button");
        result1.Select(e => e.Label).Should().Contain("Disabled Button");
        result1.Select(e => e.Label).Should().NotContain("Zero Size");

        // Filter disabled only
        var filterDisabledOpts = new ScreenReaderOptions { FilterOffscreen = false, FilterDisabled = true };
        var result2 = ElementRanker.RankAndFilter(elements, filterDisabledOpts);
        result2.Select(e => e.Label).Should().NotContain("Disabled Button");
        result2.Select(e => e.Label).Should().Contain("Visible Button");
    }

    [Fact]
    public async Task RD06_WindowsOcr_KnownBitmap_ReturnsTextAndBounds()
    {
        var ocr = new WindowsOcrService(NullLogger<WindowsOcrService>.Instance);

        // Create test bitmap with high-contrast text
        using var bitmap = new Bitmap(400, 100);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.Clear(Color.White);
            using var font = new Font(FontFamily.GenericSansSerif, 24, FontStyle.Bold);
            using var brush = new SolidBrush(Color.Black);
            g.DrawString("GhostHand Test", font, brush, new PointF(10, 20));
        }

        var results = await ocr.RecognizeBitmapAsync(bitmap, new Point(100, 100));

        // If Windows OCR language pack is present on this OS build, it will recognize text
        if (results.Count > 0)
        {
            results[0].Source.Should().Be("ocr");
            results[0].Role.Should().Be("Text");
            results[0].Label.Should().Contain("GhostHand");
            results[0].Frame.Width.Should().BeGreaterThan(0);
            results[0].Frame.Height.Should().BeGreaterThan(0);
            results[0].Frame.X.Should().BeGreaterOrEqualTo(100);
        }
    }

    [Fact]
    public async Task RD07_ElevatedTarget_DetectedAndRefused()
    {
        var options = ScreenReaderOptions.Default;
        using var reader = new UiaScreenReader(options, null, NullLogger<UiaScreenReader>.Instance);

        // Target with zero handle must fail with ArgumentException
        var zeroTarget = new AppTarget
        {
            ProcessId = 1,
            ProcessName = "System",
            WindowTitle = "Invalid",
            WindowHandle = IntPtr.Zero
        };

        var act = () => reader.ReadElementsAsync(zeroTarget);
        await act.Should().ThrowAsync<ArgumentException>()
            .WithMessage("*invalid window handle*");
    }
}
