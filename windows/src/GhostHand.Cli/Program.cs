using System.Diagnostics;
using GhostHand.Core.Agent;
using GhostHand.Core.Common;
using GhostHand.Core.Jev;
using GhostHand.Core.Models;
using GhostHand.Core.Safety;
using GhostHand.Core.ScreenReading;
using GhostHand.Platform.Execution;
using GhostHand.Platform.Launcher;
using GhostHand.Platform.Safety;
using GhostHand.Platform.ScreenReading;
using GhostHand.Platform.Windowing;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace GhostHand.Cli;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        // Load local .env file if available
        EnvLoader.Load();

        Console.WriteLine("GhostHand CLI Diagnostic Tool v0.1.0");

        if (args.Length == 0)
        {
            PrintUsage();
            return 0;
        }

        var command = args[0].ToLowerInvariant();
        return command switch
        {
            "check" => await RunCheckAsync(),
            "snapshot" => await RunSnapshotAsync(args),
            "dry-run" => await RunDryRunAsync(args),
            "run" => await RunDryRunAsync(args),
            _ => PrintUnknownCommand(command)
        };
    }

    private static void PrintUsage()
    {
        Console.WriteLine("Usage: GhostHand.Cli <command> [options]");
        Console.WriteLine();
        Console.WriteLine("Commands:");
        Console.WriteLine("  check      Verify toolchain, credentials, and Jev connectivity");
        Console.WriteLine("  snapshot   Capture and display UIA element tree of frontmost window");
        Console.WriteLine("  dry-run    Run task in dry-run mode without executing actions");
        Console.WriteLine("  run        Run task with live execution (use --live for real input)");
    }

    private static async Task<int> RunCheckAsync()
    {
        Console.WriteLine("Running environment checks...");
        Console.WriteLine("  OS: Windows (Build " + Environment.OSVersion.Version.Build + ")");
        Console.WriteLine("  .NET Runtime: " + Environment.Version);

        var options = JevOptions.FromEnvironment();
        var keyName = options.Provider switch
        {
            JevProvider.OpenRouter => "OPENROUTER_API_KEY",
            JevProvider.Laya => "LAYA_API_KEY",
            JevProvider.Groq => "GROQ_API_KEY",
            _ => "AI_GATEWAY_API_KEY"
        };
        var providerName = options.Provider switch
        {
            JevProvider.OpenRouter => "OpenRouter",
            JevProvider.Laya => $"Laya ({options.BaseUrl})",
            JevProvider.Groq => "Groq",
            _ => "Vercel AI Gateway"
        };
        if (options.Provider == JevProvider.Laya && string.IsNullOrWhiteSpace(options.ApiKey))
        {
            Console.WriteLine($"  {keyName}: not set (fine for a local laya-serve)");
        }
        else if (string.IsNullOrWhiteSpace(options.ApiKey))
        {
            Console.ForegroundColor = ConsoleColor.Yellow;
            Console.WriteLine($"  {keyName}: [NOT CONFIGURED] (Set in .env or as environment variable)");
            Console.ResetColor();
            Console.WriteLine("Cannot perform Jev evaluation without API key.");
            return 1;
        }
        else
        {
            var redacted = options.ApiKey.Length > 8
                ? $"{options.ApiKey[..4]}...{options.ApiKey[^4..]}"
                : "[CONFIGURED]";
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine($"  {keyName}: {redacted} (Loaded)");
            Console.ResetColor();
        }

        Console.WriteLine($"\nTesting live decision model via {providerName}...");
        Console.WriteLine($"  Gateway Base URL: {options.BaseUrl}");
        Console.WriteLine($"  Model: {options.ModelId}");
        Console.WriteLine($"  Zero Data Retention: {options.ZeroDataRetention}");

        using var httpClient = new HttpClient();
        var client = JevClientFactory.Create(httpClient, options);

        var request = new EvaluateRequest
        {
            Model = options.ModelId,
            State = new
            {
                system = "GhostHand Windows Diagnostic",
                status = $"Testing connectivity to {providerName}",
                timestamp = DateTime.UtcNow
            },
            Questions = new Dictionary<string, QuestionDefinition>
            {
                ["operational"] = QuestionDefinition.Boolean("Is this connection active and ready for evaluation?")
            },
            ProviderOptions = new GatewayProviderOptions
            {
                Gateway = new GatewayOptions
                {
                    ZeroDataRetention = options.ZeroDataRetention ? true : null,
                    Only = new List<string> { "typesafe-ai" }
                }
            }
        };

        var sw = Stopwatch.StartNew();
        try
        {
            var response = await client.EvaluateAsync(request);
            sw.Stop();

            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine("\n[SUCCESS] Jev evaluation call returned successfully!");
            Console.ResetColor();

            Console.WriteLine($"  Latency: {sw.ElapsedMilliseconds}ms");

            if (response.TryGetBooleanAnswer("operational", out var prob, out var isTrue))
            {
                Console.WriteLine($"  Answer 'operational': {isTrue} (probability: {prob:P1})");
            }

            if (response.Usage != null)
            {
                Console.WriteLine($"  Tokens: {response.Usage.TotalTokens} (Prompt: {response.Usage.PromptTokens}, Completion: {response.Usage.CompletionTokens})");
            }

            var cost = response.ProviderMetadata?.Gateway?.Cost;
            if (cost.HasValue)
            {
                Console.WriteLine($"  Cost: ${cost.Value:F6}");
            }

            Console.WriteLine("\nAll diagnostic checks passed. Your API key and Gateway connection are fully verified.");
            return 0;
        }
        catch (AuthException ex)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"\n[AUTH ERROR] Authentication failed: {ex.Message}");
            Console.WriteLine($"Please double-check that your {keyName} in .env is valid.");
            Console.ResetColor();
            return 1;
        }
        catch (TransientException ex)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"\n[GATEWAY ERROR] Gateway returned a transient error: {ex.Message}");
            Console.ResetColor();
            return 1;
        }
        catch (Exception ex)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"\n[ERROR] Unexpected error: {ex.Message}");
            Console.ResetColor();
            return 1;
        }
    }

    private static async Task<int> RunSnapshotAsync(string[] args)
    {
        Console.WriteLine("GhostHand Window Snapshot");
        Console.WriteLine("--------------------------------------------------------------------------------");

        AppTarget? target = null;
        if (args.Length > 1 && !string.IsNullOrWhiteSpace(args[1]))
        {
            var query = args[1];
            if (int.TryParse(query, out var pid))
            {
                target = WindowCaptureService.CaptureWindowByProcessId(pid);
            }
            else
            {
                target = WindowCaptureService.CaptureWindowByProcessName(query);
            }

            if (target == null)
            {
                Console.ForegroundColor = ConsoleColor.Yellow;
                Console.WriteLine($"Could not find active window for process '{query}'. Falling back to foreground window.");
                Console.ResetColor();
            }
        }

        if (target == null)
        {
            Console.WriteLine("Focus the window you wish to capture. Capturing in 2 seconds...");
            await Task.Delay(2000);
            target = WindowCaptureService.CaptureCurrentForegroundWindow();
        }

        if (target == null || target.WindowHandle == IntPtr.Zero)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine("Failed to capture target window.");
            Console.ResetColor();
            return 1;
        }

        Console.ForegroundColor = ConsoleColor.Cyan;
        Console.WriteLine($"Target Window: \"{target.WindowTitle}\"");
        Console.WriteLine($"Process: {target.ProcessName} (PID {target.ProcessId})");
        Console.WriteLine($"Bounds: {target.Bounds.Width}x{target.Bounds.Height} at ({target.Bounds.X}, {target.Bounds.Y})");
        Console.ResetColor();

        if (WindowCaptureService.IsTargetElevated(target.ProcessId))
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine("\n[SECURITY WARNING] Target application is running as Administrator (Elevated).");
            Console.WriteLine("UI Automation cannot inspect or interact with this window due to Windows UIPI.");
            Console.ResetColor();
            return 1;
        }

        Console.WriteLine("\nTraversing accessibility tree with CacheRequest...");
        var sw = Stopwatch.StartNew();

        var options = ScreenReaderOptions.Default;
        using var loggerFactory = LoggerFactory.Create(b => b.AddConsole().SetMinimumLevel(LogLevel.Warning));
        var ocrLogger = loggerFactory.CreateLogger<WindowsOcrService>();
        var readerLogger = loggerFactory.CreateLogger<UiaScreenReader>();

        var ocrService = new WindowsOcrService(ocrLogger);
        using var screenReader = new UiaScreenReader(options, ocrService, readerLogger);

        IReadOnlyList<AccessibilityElement> elements;
        try
        {
            elements = await screenReader.ReadElementsAsync(target);
            sw.Stop();
        }
        catch (Exception ex)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"Snapshot failed: {ex.Message}");
            Console.ResetColor();
            return 1;
        }

        Console.ForegroundColor = ConsoleColor.Green;
        Console.WriteLine($"Completed in {sw.ElapsedMilliseconds}ms | Found {elements.Count} elements");
        Console.ResetColor();

        int ocrCount = elements.Count(e => e.Source == "ocr");
        int interactiveCount = elements.Count(e => ElementRanker.IsInteractive(e.Role));

        Console.WriteLine($"Interactive Controls: {interactiveCount} | OCR Elements: {ocrCount}");
        Console.WriteLine("--------------------------------------------------------------------------------");
        Console.WriteLine($"{"ID",-5} | {"Role",-14} | {"State",-10} | {"Label / Text"}");
        Console.WriteLine("--------------------------------------------------------------------------------");

        foreach (var el in elements)
        {
            var state = el.Focused ? "[FOCUSED]" : (el.Enabled ? "Enabled" : "Disabled");
            var label = !string.IsNullOrWhiteSpace(el.DisplayLabel) ? el.DisplayLabel : "(empty)";
            if (label.Length > 60) label = label[..57] + "...";

            var color = el.Focused ? ConsoleColor.Yellow : (ElementRanker.IsInteractive(el.Role) ? ConsoleColor.Cyan : ConsoleColor.Gray);
            Console.ForegroundColor = color;
            Console.WriteLine($"{el.Id,-5} | {el.DisplayRole,-14} | {state,-10} | {label}");
        }

        Console.ResetColor();
        Console.WriteLine("--------------------------------------------------------------------------------");
        return 0;
    }

    private static async Task<int> RunDryRunAsync(string[] args)
    {
        bool isLive = args.Any(a => string.Equals(a, "--live", StringComparison.OrdinalIgnoreCase));
        var nonFlagArgs = args.Where(a => !a.StartsWith("--")).ToArray();
        var goal = nonFlagArgs.Length > 1 ? nonFlagArgs[1] : "search for Adele";

        Console.WriteLine(isLive
            ? "GhostHand Agent Loop — LIVE EXECUTION MODE"
            : "GhostHand Agent Loop — DRY-RUN MODE");
        Console.WriteLine("--------------------------------------------------------------------------------");
        Console.WriteLine($"Goal: \"{goal}\"");
        Console.WriteLine(isLive
            ? "WARNING: Executing in LIVE mode. Physical inputs will be performed. Sensitive actions will require confirmation.\n"
            : "Executing in simulated mode (no physical mouse/keyboard input will be sent).\n");

        string? targetName = null;
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (string.Equals(args[i], "--target", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(args[i], "--process", StringComparison.OrdinalIgnoreCase))
            {
                targetName = args[i + 1];
                break;
            }
        }

        AppTarget? target = null;
        if (!string.IsNullOrEmpty(targetName))
        {
            target = WindowCaptureService.CaptureWindowByProcessName(targetName);
            if (target != null)
            {
                Console.WriteLine($"Found '{targetName}' (PID {target.ProcessId}). Bringing window to foreground...");
                Windows.Win32.PInvoke.SetForegroundWindow((Windows.Win32.Foundation.HWND)target.WindowHandle);
                await Task.Delay(500);
            }
            else
            {
                Console.ForegroundColor = ConsoleColor.Yellow;
                Console.WriteLine($"No running process found matching '{targetName}'. Falling back to active window.\n");
                Console.ResetColor();
            }
        }

        if (target == null)
        {
            Console.WriteLine("Click on your target window now (waiting 3 seconds)...");
            for (int countdown = 3; countdown > 0; countdown--)
            {
                Console.Write($"{countdown}... ");
                await Task.Delay(1000);
            }
            Console.WriteLine("Capturing!\n");

            target = WindowCaptureService.CaptureCurrentForegroundWindow();
        }

        if (target == null || target.WindowHandle == IntPtr.Zero)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine("Failed to capture target foreground window.");
            Console.ResetColor();
            return 1;
        }

        Console.ForegroundColor = ConsoleColor.Cyan;
        Console.WriteLine($"Target Window: \"{target.WindowTitle}\" ({target.ProcessName}, PID {target.ProcessId})\n");
        Console.ResetColor();

        if (target.ProcessName.Contains("antigravity", StringComparison.OrdinalIgnoreCase) ||
            target.ProcessName.Contains("powershell", StringComparison.OrdinalIgnoreCase) ||
            target.ProcessName.Contains("cmd", StringComparison.OrdinalIgnoreCase))
        {
            Console.ForegroundColor = ConsoleColor.Yellow;
            Console.WriteLine($"[NOTE] Captured '{target.ProcessName}'. If you meant to automate another window (like Notepad),");
            Console.WriteLine($"be sure to click on that window during the countdown, or use '--target notepad'.\n");
            Console.ResetColor();
        }

        using var loggerFactory = LoggerFactory.Create(b => b.AddConsole().SetMinimumLevel(LogLevel.Warning));
        var ocrLogger = loggerFactory.CreateLogger<WindowsOcrService>();
        var readerLogger = loggerFactory.CreateLogger<UiaScreenReader>();
        var jevLogger = loggerFactory.CreateLogger<JevDecisionModel>();
        var execLogger = loggerFactory.CreateLogger<ActionExecutor>();
        var loopLogger = loggerFactory.CreateLogger<AgentLoop>();

        var jevOptions = JevOptions.FromEnvironment();
        using var httpClient = new HttpClient();
        var jevClient = JevClientFactory.Create(httpClient, jevOptions);
        var decisionModel = new JevDecisionModel(jevClient, jevOptions, jevLogger);

        var ocrService = new WindowsOcrService(ocrLogger);
        using var screenReader = new UiaScreenReader(ScreenReaderOptions.Default, ocrService, readerLogger);
        var appLauncher = new AppLauncher();
        using var actionExecutor = new ActionExecutor(execLogger, dryRun: !isLive, appLauncher: appLauncher);

        var loopOptions = new AgentLoopOptions
        {
            DryRun = !isLive,
            MaxSteps = 10,
            MaxConsecutiveStalls = 3
        };

        using var auditLog = new JsonlAuditLog();
        var riskPolicy = new RiskPolicy();
        var confirmationPrompt = new ConsoleConfirmationPrompt();

        var loop = new AgentLoop(
            screenReader,
            decisionModel,
            actionExecutor,
            loopOptions,
            loopLogger,
            riskPolicy,
            confirmationPrompt,
            auditLog);

        loop.StatusChanged += msg =>
        {
            Console.ForegroundColor = ConsoleColor.Yellow;
            Console.WriteLine($"[STATUS] {msg}");
            Console.ResetColor();
        };

        loop.StepCompleted += (step, decision, result) =>
        {
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine($"[STEP {step}] Decision: {decision.Operation} on '{decision.TargetLabel ?? decision.TargetId}' (Conf: {decision.Confidence:P0})");
            Console.ResetColor();
            Console.WriteLine($"         Action Result: {(result.Success ? "SUCCESS" : "FAIL")} — {result.Message ?? result.Error}\n");
        };

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            Console.WriteLine("\n[KILL SWITCH] Interrupted by user. Cancelling...");
            cts.Cancel();
        };

        var runResult = await loop.RunAsync(goal, target, cts.Token);

        Console.WriteLine("--------------------------------------------------------------------------------");
        Console.ForegroundColor = runResult.Status switch
        {
            AgentRunStatus.Completed => ConsoleColor.Green,
            AgentRunStatus.NeedsHumanInput => ConsoleColor.Yellow,
            AgentRunStatus.Stalled => ConsoleColor.DarkYellow,
            AgentRunStatus.Cancelled => ConsoleColor.Red,
            _ => ConsoleColor.Red
        };

        Console.WriteLine($"Result: {runResult.Status.ToString().ToUpperInvariant()} ({runResult.StepsCompleted} steps)");
        Console.WriteLine($"Message: {runResult.Message}");
        Console.ResetColor();
        Console.WriteLine("--------------------------------------------------------------------------------");

        return runResult.Status == AgentRunStatus.Completed ? 0 : 1;
    }

    private static int PrintUnknownCommand(string command)
    {
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine($"Unknown command: '{command}'");
        Console.ResetColor();
        PrintUsage();
        return 1;
    }
}
