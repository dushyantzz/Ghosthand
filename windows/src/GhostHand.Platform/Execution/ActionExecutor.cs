using System.Diagnostics;
using System.Drawing;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Models;
using Microsoft.Extensions.Logging;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace GhostHand.Platform.Execution;

public class ActionExecutor : IActionExecutor, IDisposable
{
    private readonly ILogger<ActionExecutor> _logger;
    private readonly UIA3Automation _automation;
    private readonly IAppLauncher? _appLauncher;
    private bool _disposed;

    public bool DryRun { get; set; } = true;
    public int? ExpectedProcessId { get; set; }
    public IntPtr? TargetWindowHandle { get; set; }

    public ActionExecutor(ILogger<ActionExecutor> logger, bool dryRun = true, IAppLauncher? appLauncher = null)
    {
        _logger = logger;
        DryRun = dryRun;
        _appLauncher = appLauncher;
        _automation = new UIA3Automation();
    }

    public async Task<ActionResult> ExecuteAsync(
        AgentDecision decision,
        AccessibilityElement? targetElement,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (decision.Operation == AgentOperation.Done)
        {
            return ActionResult.SuccessResult("Task completed");
        }

        if (decision.Operation == AgentOperation.AskUser)
        {
            return ActionResult.SuccessResult("User consultation requested");
        }

        if (decision.Operation == AgentOperation.Wait)
        {
            await Task.Delay(1000, cancellationToken);
            return ActionResult.SuccessResult("Waited 1 second");
        }

        // Dry-run mode: plan and verify without injecting hardware input
        if (DryRun)
        {
            _logger.LogInformation("[DRY RUN] Would execute {Operation} on '{Target}' with value '{Value}'",
                decision.Operation, decision.TargetLabel ?? decision.TargetId, decision.TextValue);

            // Simulate tiny execution delay
            await Task.Delay(150, cancellationToken);
            return ActionResult.SuccessResult($"[DRY RUN] Simulated {decision.Operation} on '{decision.TargetLabel ?? decision.TargetId}'");
        }

        // Re-focus target window before physical execution
        if (TargetWindowHandle.HasValue && TargetWindowHandle.Value != IntPtr.Zero)
        {
            var hwnd = (HWND)TargetWindowHandle.Value;
            PInvoke.SetForegroundWindow(hwnd);
            await Task.Delay(60, cancellationToken);

            // Windows refuses focus changes from a process that doesn't have focus (e.g. while an always-on-top
            // panel like Copilot is active). A synthetic Alt press lifts that lock; then retry once.
            if (PInvoke.GetForegroundWindow() != hwnd)
            {
                InputSimulator.SendKey(VIRTUAL_KEY.VK_MENU);
                PInvoke.SetForegroundWindow(hwnd);
                await Task.Delay(80, cancellationToken);
            }
        }

        // Live execution mode: verify foreground process matches expected target (UIPI / safety check)
        // Exempt OpenApp and OpenUrl as they deliberately launch new processes
        if (ExpectedProcessId.HasValue &&
            decision.Operation != AgentOperation.OpenApp &&
            decision.Operation != AgentOperation.OpenUrl)
        {
            uint currentPid = GetForegroundProcessId();

            if (currentPid != (uint)ExpectedProcessId.Value)
            {
                // If the previous expected PID was explorer (the desktop shell) and the current foreground is an active application, migrate ExpectedProcessId
                bool wasDesktop = false;
                try
                {
                    using var prevProc = Process.GetProcessById(ExpectedProcessId.Value);
                    if (prevProc.ProcessName.Equals("explorer", StringComparison.OrdinalIgnoreCase))
                    {
                        wasDesktop = true;
                    }
                }
                catch { }

                if (wasDesktop && currentPid != 0)
                {
                    _logger.LogInformation("Foreground migrated from desktop shell to app (PID {CurrentPid}). Updating ExpectedProcessId.", currentPid);
                    ExpectedProcessId = (int)currentPid;
                }
                else
                {
                    _logger.LogWarning("Foreground process changed mid-action! Expected PID {Expected}, current PID {Current}. Aborting.",
                        ExpectedProcessId.Value, currentPid);

                    return ActionResult.FailureResult(
                        $"Foreground process changed mid-action (expected PID {ExpectedProcessId.Value}, found {currentPid}). Execution aborted.");
                }
            }
        }

        try
        {
            switch (decision.Operation)
            {
                case AgentOperation.OpenApp:
                    if (_appLauncher == null)
                        return ActionResult.FailureResult("AppLauncher is not configured.");
                    var targetApp = decision.TargetId ?? decision.TargetLabel ?? string.Empty;
                    var newAppTarget = await _appLauncher.LaunchAppAsync(targetApp, cancellationToken: cancellationToken);
                    if (newAppTarget != null)
                    {
                        ExpectedProcessId = newAppTarget.ProcessId;
                        TargetWindowHandle = newAppTarget.WindowHandle;
                        return ActionResult.TargetChanged(newAppTarget, $"Launched application '{newAppTarget.ProcessName}'");
                    }
                    return ActionResult.SuccessResult($"Launched application '{targetApp}'");

                case AgentOperation.OpenUrl:
                    if (_appLauncher == null)
                        return ActionResult.FailureResult("AppLauncher is not configured.");
                    var urlString = decision.TextValue ?? decision.TargetId ?? string.Empty;
                    if (Uri.TryCreate(urlString, UriKind.Absolute, out var uri))
                    {
                        var browserTarget = await _appLauncher.LaunchUrlAsync(uri, cancellationToken);
                        if (browserTarget != null)
                        {
                            ExpectedProcessId = browserTarget.ProcessId;
                            TargetWindowHandle = browserTarget.WindowHandle;
                            return ActionResult.TargetChanged(browserTarget, $"Opened URL '{uri}'");
                        }
                        return ActionResult.SuccessResult($"Opened URL '{uri}'");
                    }
                    return ActionResult.FailureResult($"Invalid URL '{urlString}'");

                case AgentOperation.Click:
                    return ExecuteClick(targetElement);

                case AgentOperation.TypeAndEnter:
                    return ExecuteTypeText(targetElement, decision.TextValue ?? string.Empty, submitWithEnter: true);

                case AgentOperation.TypeText:
                    return ExecuteTypeText(targetElement, decision.TextValue ?? string.Empty, submitWithEnter: IsSearchOrAddressBar(targetElement));

                case AgentOperation.TypeKeys:
                    // Esc clears Calculator (and cancels a half-typed entry elsewhere), so earlier button
                    // clicks can't merge with the typed expression ("34" + "3+4" = 343+4)
                    InputSimulator.SendKey(VIRTUAL_KEY.VK_ESCAPE);
                    await Task.Delay(50, cancellationToken);
                    // Type one character at a time: Calculator drops keystrokes from a single batch
                    // SendInput call, and needs VK_MULTIPLY/VK_ADD etc. instead of Unicode for operators
                    InputSimulator.TypeTextSlowly(decision.TextValue ?? string.Empty);
                    await Task.Delay(50, cancellationToken);
                    InputSimulator.SendKey(VIRTUAL_KEY.VK_RETURN);
                    return ActionResult.SuccessResult($"Typed '{decision.TextValue}' on the keyboard and pressed Enter");

                case AgentOperation.PressReturn:
                    InputSimulator.SendKey(VIRTUAL_KEY.VK_RETURN);
                    return ActionResult.SuccessResult("Pressed Enter key");

                case AgentOperation.PressTab:
                    InputSimulator.SendKey(VIRTUAL_KEY.VK_TAB);
                    return ActionResult.SuccessResult("Pressed Tab key");

                case AgentOperation.PressEscape:
                    InputSimulator.SendKey(VIRTUAL_KEY.VK_ESCAPE);
                    return ActionResult.SuccessResult("Pressed Escape key");

                case AgentOperation.PressSpace:
                    InputSimulator.SendKey(VIRTUAL_KEY.VK_SPACE);
                    return ActionResult.SuccessResult("Pressed Space key");

                case AgentOperation.PressMediaPlay:
                    InputSimulator.SendKey((VIRTUAL_KEY)0xB3); // VK_MEDIA_PLAY_PAUSE
                    return ActionResult.SuccessResult("Pressed Media Play/Pause key");

                case AgentOperation.ScrollDown:
                    InputSimulator.Scroll(down: true);
                    return ActionResult.SuccessResult("Scrolled down");

                case AgentOperation.ScrollUp:
                    InputSimulator.Scroll(down: false);
                    return ActionResult.SuccessResult("Scrolled up");

                default:
                    return ActionResult.FailureResult($"Unsupported operation '{decision.Operation}'");
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to execute {Operation} on target {Target}", decision.Operation, decision.TargetId);
            return ActionResult.FailureResult(ex.Message);
        }
    }

    private ActionResult ExecuteClick(AccessibilityElement? targetElement)
    {
        if (targetElement == null || targetElement.Frame.IsEmpty)
        {
            return ActionResult.FailureResult("Cannot click: target element not found or has empty bounding frame.");
        }

        // Try UIA patterns first via element point
        var center = new Point(
            targetElement.Frame.X + targetElement.Frame.Width / 2,
            targetElement.Frame.Y + targetElement.Frame.Height / 2);

        try
        {
            var uiaElement = _automation.FromPoint(center);
            var current = uiaElement;
            int depth = 0;
            while (current != null && depth < 5)
            {
                if (current.Patterns.Invoke.IsSupported)
                {
                    current.Patterns.Invoke.Pattern.Invoke();
                    _logger.LogDebug("Clicked via UIA InvokePattern on {Label}", targetElement.DisplayLabel);
                    return ActionResult.SuccessResult($"Clicked via InvokePattern on '{targetElement.DisplayLabel}'");
                }

                if (current.Patterns.Toggle.IsSupported)
                {
                    current.Patterns.Toggle.Pattern.Toggle();
                    _logger.LogDebug("Toggled via UIA TogglePattern on {Label}", targetElement.DisplayLabel);
                    return ActionResult.SuccessResult($"Toggled via TogglePattern on '{targetElement.DisplayLabel}'");
                }

                if (current.Patterns.SelectionItem.IsSupported)
                {
                    current.Patterns.SelectionItem.Pattern.Select();
                    _logger.LogDebug("Selected via UIA SelectionItemPattern on {Label}", targetElement.DisplayLabel);
                    return ActionResult.SuccessResult($"Selected via SelectionItemPattern on '{targetElement.DisplayLabel}'");
                }

                try
                {
                    current = current.Parent;
                    depth++;
                }
                catch
                {
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "UIA pattern invocation failed; falling back to SendInput mouse click.");
        }

        // Fallback: simulated mouse click at center of element
        InputSimulator.Click(center.X, center.Y);
        _logger.LogDebug("Clicked via SendInput fallback at ({X}, {Y})", center.X, center.Y);
        return ActionResult.SuccessResult($"Clicked via SendInput fallback at ({center.X}, {center.Y})");
    }

    private ActionResult ExecuteTypeText(AccessibilityElement? targetElement, string text, bool submitWithEnter = false)
    {
        if (targetElement == null)
        {
            // Type into currently focused control
            InputSimulator.SelectAllAndClear();
            InputSimulator.TypeText(text);
            if (submitWithEnter)
            {
                Thread.Sleep(60);
                InputSimulator.SendKey(VIRTUAL_KEY.VK_RETURN);
            }
            return ActionResult.SuccessResult($"Typed text into focused element");
        }

        var center = new Point(
            targetElement.Frame.X + targetElement.Frame.Width / 2,
            targetElement.Frame.Y + targetElement.Frame.Height / 2);

        // Try UIA ValuePattern first
        try
        {
            var uiaElement = _automation.FromPoint(center);
            var current = uiaElement;
            int depth = 0;
            while (current != null && depth < 5)
            {
                if (current.Patterns.Value.IsSupported)
                {
                    current.Patterns.Value.Pattern.SetValue(text);
                    _logger.LogDebug("Typed '{Text}' via UIA ValuePattern on {Label}", text, targetElement.DisplayLabel);

                    if (submitWithEnter || IsSearchOrAddressBar(targetElement))
                    {
                        Thread.Sleep(80);
                        InputSimulator.SendKey(VIRTUAL_KEY.VK_RETURN);
                        return ActionResult.SuccessResult($"Typed '{text}' and submitted via Enter on '{targetElement.DisplayLabel}'");
                    }

                    return ActionResult.SuccessResult($"Typed text via ValuePattern on '{targetElement.DisplayLabel}'");
                }

                try
                {
                    current = current.Parent;
                    depth++;
                }
                catch
                {
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "UIA ValuePattern typing failed; falling back to click-and-type.");
        }

        // Fallback: Click to focus, Select All and clear, then SendInput text
        InputSimulator.Click(center.X, center.Y);
        Thread.Sleep(60);
        InputSimulator.SelectAllAndClear();
        Thread.Sleep(30);
        InputSimulator.TypeText(text);

        if (submitWithEnter || IsSearchOrAddressBar(targetElement))
        {
            Thread.Sleep(80);
            InputSimulator.SendKey(VIRTUAL_KEY.VK_RETURN);
            _logger.LogDebug("Auto-pressed Enter after typing into search/address bar '{Label}'", targetElement.DisplayLabel);
            return ActionResult.SuccessResult($"Typed '{text}' and submitted via Enter on '{targetElement.DisplayLabel}'");
        }

        return ActionResult.SuccessResult($"Typed text via SendInput fallback on '{targetElement.DisplayLabel}'");
    }

    private static bool IsSearchOrAddressBar(AccessibilityElement? el)
    {
        if (el == null) return false;
        var label = (el.DisplayLabel ?? string.Empty).ToLowerInvariant();
        return label.Contains("address") || label.Contains("search") || label.Contains("omnibox") ||
               label.Contains("url") || label.Contains("find") || label.Contains("google") ||
               label.Contains("query") || label.Contains("bar");
    }

    private static uint GetForegroundProcessId()
    {
        var fgHwnd = PInvoke.GetForegroundWindow();
        uint currentPid = 0;
        unsafe
        {
            PInvoke.GetWindowThreadProcessId(fgHwnd, &currentPid);
        }
        return currentPid;
    }

    public void Dispose()
    {
        if (!_disposed)
        {
            _disposed = true;
            _automation.Dispose();
        }
    }
}
