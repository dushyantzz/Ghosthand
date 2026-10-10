using System.Diagnostics;
using System.Net.Http;
using System.Windows;
using GhostHand.App.Windows;
using GhostHand.Core.Agent;
using GhostHand.Core.Common;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Jev;
using GhostHand.Core.Safety;
using GhostHand.Core.ScreenReading;
using GhostHand.Platform.Execution;
using GhostHand.Platform.Hotkey;
using GhostHand.Platform.Launcher;
using GhostHand.Platform.Safety;
using GhostHand.Platform.ScreenReading;
using GhostHand.Platform.Speech;
using GhostHand.Platform.Windowing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace GhostHand.App;

public partial class App : Application
{
    private static Mutex? _singleInstanceMutex;
    private const string MutexName = "Global\\GhostHand_SingleInstance_Mutex_2026";
    private ServiceProvider? _serviceProvider;

    private IHotkeyService? _hotkeyService;
    private IWindowCaptureService? _windowCapture;
    private PromptPopupWindow? _popup;
    private ConfirmationDialog? _confirmationDialog;
    private CancellationTokenSource? _runCts;
    private readonly EarlyIntentDetector _earlyIntent = new();
    private ILogger<App>? _logger;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Load .env variables
        EnvLoader.Load();

        bool createdNew;
        _singleInstanceMutex = new Mutex(true, MutexName, out createdNew);
        if (!createdNew)
        {
            MessageBox.Show(
                "GhostHand is already running in the background.\nPress Ctrl+Win to activate.",
                "GhostHand",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            Shutdown(0);
            return;
        }

        var services = new ServiceCollection();
        ConfigureServices(services);
        _serviceProvider = services.BuildServiceProvider();

        _logger = _serviceProvider.GetRequiredService<ILogger<App>>();
        _windowCapture = _serviceProvider.GetRequiredService<IWindowCaptureService>();
        _hotkeyService = _serviceProvider.GetRequiredService<IHotkeyService>();

        // Check if API key is configured; if not, show first-run setup dialog
        var credentialStore = _serviceProvider.GetRequiredService<ICredentialStore>();
        if (!credentialStore.HasKey())
        {
            _logger.LogInformation("No API key found in environment or Credential Manager. Showing setup dialog.");
            var setupDialog = new ApiKeySetupDialog(credentialStore);
            setupDialog.ShowDialog();
        }

        // Pre-create windows (hidden at startup for instant display)
        _popup = new PromptPopupWindow();
        _popup.SpeechInput = _serviceProvider.GetService<ISpeechInput>();
        if (_popup.SpeechInput is WhisperSpeechService whisper)
            _ = whisper.WarmUpAsync();
        _popup.TaskSubmitted += OnTaskSubmitted;
        _popup.ListeningStarted += () => _earlyIntent.Reset();
        _popup.PartialTranscript += OnPartialTranscript;
        _popup.Cancelled += OnTaskCancelled;

        _confirmationDialog = new ConfirmationDialog();

        _hotkeyService.HotkeyPressed += OnHotkeyPressed;
        _hotkeyService.KillSwitchTriggered += OnKillSwitchTriggered;
        _hotkeyService.Start();

        _logger.LogInformation("GhostHand application started. Press Ctrl+Win to activate.");
    }

    private static void ConfigureServices(IServiceCollection services)
    {
        services.AddLogging(builder =>
        {
            builder.AddConsole();
        });

        services.AddSingleton<ICredentialStore, CredentialStore>();
        services.AddSingleton<IWindowCaptureService, WindowCaptureService>();
        services.AddSingleton<IHotkeyService, LowLevelKeyboardHook>();
        services.AddSingleton<IAppLauncher, AppLauncher>();
        services.AddSingleton<ISpeechInput>(sp =>
        {
            var logger = sp.GetService<ILogger<WhisperSpeechService>>();
            var whisper = new WhisperSpeechService(
                fallbackService: null, // No fallback — WindowsSpeechService requires privacy policy acceptance
                logger: logger);

            // GHOSTHAND_STT=deepgram: Deepgram (via OpenRouter) produces the final transcript; Whisper stays
            // local for the instant live partials that drive early actions
            var cloud = OpenRouterDeepgramTranscriber.FromEnvironment(logger);
            if (cloud != null)
                whisper.CloudTranscriber = cloud.TranscribeAsync;
            return whisper;
        });
    }

    private void OnHotkeyPressed(object? sender, EventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            var target = _windowCapture?.CaptureForegroundWindow();
            _logger?.LogInformation("Trigger received. Foreground target: {ProcessName} ({Title})", 
                target?.ProcessName ?? "None", target?.WindowTitle ?? "None");
            
            _popup?.ShowForTarget(target);
        });
    }

    private void OnKillSwitchTriggered(object? sender, EventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            _logger?.LogInformation("Kill switch triggered. Cancelling active tasks.");
            _runCts?.Cancel();
            _popup?.HidePopup();
            _confirmationDialog?.Hide();
        });
    }

    /// <summary>
    /// Speculative start: while the user is still talking ("open Spotify and play …"), launch/focus the
    /// named app so it's ready when the sentence ends. Only app launches run early; everything else waits
    /// for the full command.
    /// </summary>
    private void OnPartialTranscript(string partial, Core.Models.AppTarget? target)
    {
        var app = _earlyIntent.TryGetEarlyLaunch(partial, target?.ProcessName);
        var launcher = _serviceProvider?.GetService<IAppLauncher>();
        if (app == null || launcher == null)
            return;

        _logger?.LogInformation("Early launch while user is still speaking: {App}", app);
        _popup?.UpdateStatus($"⚡ Opening {app} while you speak…");

        _ = Task.Run(async () =>
        {
            try
            {
                var launched = await launcher.LaunchAppAsync(app);
                if (launched != null && launched.WindowHandle != IntPtr.Zero)
                {
                    _popup?.UpdateTarget(launched);
                    _popup?.UpdateStatus($"⚡ {app} is ready — keep talking…");
                }
                else
                {
                    _earlyIntent.Reset(); // let a later, clearer partial retry
                }
            }
            catch (Exception ex)
            {
                _logger?.LogWarning(ex, "Early launch of {App} failed; the full command will handle it.", app);
                _earlyIntent.Reset();
            }
        });
    }

    private void OnTaskSubmitted(string goal, Core.Models.AppTarget? target)
    {
        _logger?.LogInformation("Goal submitted: '{Goal}' for app '{ProcessName}' (HWND: 0x{Hwnd:X})",
            goal, target?.ProcessName ?? "Unknown", target?.WindowHandle.ToInt64() ?? 0);

        if (target == null || target.WindowHandle == IntPtr.Zero || WindowCaptureService.IsSelf(target))
        {
            target = WindowCaptureService.CaptureCurrentForegroundWindow()
                     ?? WindowCaptureService.CaptureWindowByProcessName("explorer")
                     ?? new Core.Models.AppTarget
                     {
                         ProcessId = Process.GetCurrentProcess().Id,
                         ProcessName = "explorer",
                         WindowTitle = "Desktop",
                         WindowHandle = IntPtr.Zero
                     };
            _logger?.LogInformation("Using fallback target: '{ProcessName}' (HWND: 0x{Hwnd:X})",
                target.ProcessName, target.WindowHandle.ToInt64());
        }

        _runCts?.Cancel();
        _runCts?.Dispose();
        _runCts = new CancellationTokenSource();
        var token = _runCts.Token;

        Task.Run(async () =>
        {
            try
            {
                var credentialStore = _serviceProvider?.GetService<ICredentialStore>() ?? new CredentialStore();
                var jevOptions = JevOptions.FromEnvironment();
                if (string.IsNullOrWhiteSpace(jevOptions.ApiKey) && jevOptions.RequiresApiKey)
                {
                    jevOptions.ApiKey = credentialStore.GetApiKey();
                }

                if (string.IsNullOrWhiteSpace(jevOptions.ApiKey) && jevOptions.RequiresApiKey)
                {
                    _logger?.LogWarning("No API key available for agent loop.");
                    _popup?.OnRunCompleted("API key is not configured. Please set OPENROUTER_API_KEY or AI_GATEWAY_API_KEY.", false);
                    return;
                }

                using var httpClient = new HttpClient();
                var jevClient = JevClientFactory.Create(httpClient, jevOptions);
                var decisionModel = new JevDecisionModel(jevClient, jevOptions, NullLogger<JevDecisionModel>.Instance);

                var ocrService = new WindowsOcrService(NullLogger<WindowsOcrService>.Instance);
                using var screenReader = new UiaScreenReader(ScreenReaderOptions.Default, ocrService, NullLogger<UiaScreenReader>.Instance);
                var appLauncher = _serviceProvider?.GetService<IAppLauncher>() ?? new AppLauncher();
                using var actionExecutor = new ActionExecutor(NullLogger<ActionExecutor>.Instance, dryRun: false, appLauncher: appLauncher)
                {
                    TargetWindowHandle = target.WindowHandle,
                    ExpectedProcessId = target.ProcessId
                };

                if (target.WindowHandle != IntPtr.Zero)
                {
                    global::Windows.Win32.PInvoke.SetForegroundWindow((global::Windows.Win32.Foundation.HWND)target.WindowHandle);
                }

                using var auditLog = new JsonlAuditLog();
                var riskPolicy = new RiskPolicy();

                var loopOptions = new AgentLoopOptions
                {
                    DryRun = false,
                    MaxSteps = 0, // 0 = unlimited; runs until task completed or cancelled
                    MaxConsecutiveStalls = 15
                };

                var windowTracker = _serviceProvider?.GetService<IWindowCaptureService>() as IWindowTracker;

                var loop = new AgentLoop(
                    screenReader,
                    decisionModel,
                    actionExecutor,
                    loopOptions,
                    NullLogger<AgentLoop>.Instance,
                    riskPolicy,
                    _confirmationDialog,
                    auditLog,
                    windowTracker);

                loop.StatusChanged += status =>
                {
                    _popup?.UpdateStatus(status);
                };

                loop.TargetChanged += newTarget =>
                {
                    // Keep the executor's foreground safety check on the same window the loop now targets;
                    // otherwise every action after a switch aborted with "Foreground process changed mid-action"
                    actionExecutor.TargetWindowHandle = newTarget.WindowHandle;
                    actionExecutor.ExpectedProcessId = newTarget.ProcessId;
                    _popup?.UpdateTarget(newTarget);
                };

                var runResult = await loop.RunAsync(goal, target, token);
                _logger?.LogInformation("Agent loop finished with status {Status}: {Message}", runResult.Status, runResult.Message);

                bool isSuccess = runResult.Status == AgentRunStatus.Completed;
                _popup?.OnRunCompleted(runResult.Message ?? runResult.Status.ToString(), isSuccess);
            }
            catch (OperationCanceledException)
            {
                _logger?.LogInformation("Agent loop cancelled by user.");
                _popup?.OnRunCompleted("Cancelled by user", false);
            }
            catch (Exception ex)
            {
                _logger?.LogError(ex, "Agent loop encountered an unexpected error.");
                _popup?.OnRunCompleted(ex.Message, false);
            }
        }, token);
    }

    private void OnTaskCancelled()
    {
        _logger?.LogInformation("Goal input cancelled.");
        _runCts?.Cancel();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _runCts?.Cancel();
        _runCts?.Dispose();
        _hotkeyService?.Stop();
        _hotkeyService?.Dispose();
        _serviceProvider?.Dispose();

        if (_singleInstanceMutex != null)
        {
            try
            {
                _singleInstanceMutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // Mutex wasn't owned
            }
            _singleInstanceMutex.Dispose();
        }

        base.OnExit(e);
    }
}
