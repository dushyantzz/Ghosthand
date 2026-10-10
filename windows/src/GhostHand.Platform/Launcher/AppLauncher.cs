using System.Diagnostics;
using GhostHand.Core.Agent;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Jev;
using GhostHand.Core.Models;
using GhostHand.Platform.Windowing;
using Microsoft.Extensions.Logging;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace GhostHand.Platform.Launcher;

public class AppLauncher : IAppLauncher
{
    private readonly ILogger<AppLauncher> _logger;

    private static readonly HashSet<string> DisallowedExecutables = new(StringComparer.OrdinalIgnoreCase)
    {
        "powershell.exe",
        "pwsh.exe",
        "wscript.exe",
        "cscript.exe",
        "mshta.exe",
        "reg.exe",
        "regedit.exe",
        "format.com",
        "diskpart.exe",
        "rundll32.exe"
    };

    public AppLauncher(ILogger<AppLauncher>? logger = null)
    {
        _logger = logger ?? Microsoft.Extensions.Logging.Abstractions.NullLogger<AppLauncher>.Instance;
        StoreAppCatalog.Preload();
    }

    public bool TryExtractAppLaunch(string goal, out string appName, out string launchCommand)
    {
        appName = string.Empty;
        launchCommand = string.Empty;

        var candidates = JevDecisionModel.ExtractAppLaunchCandidates(goal);
        if (candidates.Count == 0) return false;

        foreach (var candidate in candidates)
        {
            if (ResolveLaunchCommand(candidate, out var resolvedCommand))
            {
                appName = candidate;
                launchCommand = resolvedCommand;
                return true;
            }
        }

        // Default to the first candidate as executable if it is safe
        var first = candidates[0];
        if (IsSafeLaunchCommand(first))
        {
            appName = first;
            launchCommand = first.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? first : first + ".exe";
            return true;
        }

        return false;
    }

    public bool TryExtractUrlLaunch(string goal, out Uri url)
    {
        url = null!;
        var urls = UrlLauncherValidator.ExtractWebUrls(goal);
        if (urls.Count > 0)
        {
            url = urls[0];
            return true;
        }
        return false;
    }

    public async Task<AppTarget?> LaunchAppAsync(string appName, string? launchCommand = null, CancellationToken cancellationToken = default)
    {
        var command = launchCommand;
        if (string.IsNullOrEmpty(command))
        {
            if (!ResolveLaunchCommand(appName, out command))
            {
                command = appName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? appName : appName + ".exe";
            }
        }

        // Safety first: a blocked command must never resolve to (and focus) a running process either
        if (!IsSafeLaunchCommand(command))
        {
            _logger.LogWarning("Refusing to launch command '{Command}': safety violation.", command);
            throw new InvalidOperationException($"Launch of '{command}' was blocked by safety policy.");
        }

        // Check if application is already running with an open window -> focus it!
        var runningTarget = FindRunningAppTarget(appName, command);
        if (runningTarget != null && runningTarget.WindowHandle != IntPtr.Zero)
        {
            _logger.LogInformation("Application '{AppName}' is already running ({ProcessName}). Bringing window to foreground.",
                appName, runningTarget.ProcessName);
            BringWindowToForeground(runningTarget);
            return runningTarget;
        }

        _logger.LogInformation("Launching application '{AppName}' via command '{Command}'", appName, command);

        var launchStartedAt = DateTime.Now;
        var previousForeground = IntPtr.Zero;
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = command,
                UseShellExecute = true
            };

            launchStartedAt = DateTime.Now;
            previousForeground = WindowCaptureService.CaptureCurrentForegroundWindow()?.WindowHandle ?? IntPtr.Zero;
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to start process for command '{Command}'", command);
            return null;
        }

        // Wait for window to appear and become foreground
        var expectedProcess = GetExpectedProcessName(appName, command);
        return await WaitForNewForegroundTargetAsync(expectedProcess, cancellationToken, launchStartedAt, previousForeground);
    }

    public async Task<AppTarget?> LaunchUrlAsync(Uri url, CancellationToken cancellationToken = default)
    {
        if (!UrlLauncherValidator.IsValidWebUrl(url.ToString(), out var validatedUri) || validatedUri == null)
        {
            throw new ArgumentException($"Invalid or non-http/https URL '{url}'", nameof(url));
        }

        _logger.LogInformation("Launching URL: {Url}", validatedUri);

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = validatedUri.ToString(),
                UseShellExecute = true
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to open URL '{Url}'", validatedUri);
            return null;
        }

        return await WaitForNewForegroundTargetAsync(null, cancellationToken);
    }

    // Built-in Windows surfaces that have no app entry of their own, or whose name also matches other
    // Start-menu shortcuts ("settings" used to open "WSL Settings")
    private static readonly Dictionary<string, string> WindowsUriAliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["settings"] = "ms-settings:",
        ["windows settings"] = "ms-settings:",
        ["control panel"] = "control",
    };

    private static bool ResolveLaunchCommand(string appName, out string launchCommand)
    {
        var trimmed = appName.Trim();

        if (WindowsUriAliases.TryGetValue(trimmed, out var alias))
        {
            launchCommand = alias;
            return true;
        }

        // 1. Windows App Paths registry lookup (registered desktop apps)
        if (TryFindInAppPathsRegistry(trimmed, out var appPath))
        {
            launchCommand = appPath;
            return true;
        }

        // 2. Windows Start Menu shortcut (.lnk) (installed programs on user's system)
        if (TryFindStartMenuShortcut(trimmed, out var shortcutPath))
        {
            launchCommand = shortcutPath;
            return true;
        }

        // 2b. Microsoft Store apps (Camera, Photos, Clock, Store editions of WhatsApp/Spotify, ...)
        if (StoreAppCatalog.TryFind(trimmed, TimeSpan.FromSeconds(3), out var aumid))
        {
            launchCommand = $@"shell:AppsFolder\{aumid}";
            return true;
        }

        // 3. URI scheme or protocol (e.g. ms-settings:, calculator:, spotify:)
        if (trimmed.EndsWith(':') || (trimmed.Contains(':') && !trimmed.Contains('\\') && !trimmed.Contains('/')))
        {
            launchCommand = trimmed;
            return true;
        }

        // 4. Native Windows shell executable fallback (system binaries in PATH: notepad, calc, explorer, etc.)
        if (IsSafeLaunchCommand(trimmed))
        {
            launchCommand = trimmed;
            return true;
        }

        launchCommand = string.Empty;
        return false;
    }

    private static bool TryFindInAppPathsRegistry(string appName, out string path)
    {
        path = string.Empty;
        var exeName = appName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? appName : appName + ".exe";

        string[] baseKeys = [
            @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths",
            @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths"
        ];

        foreach (var baseKey in baseKeys)
        {
            try
            {
                using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey($@"{baseKey}\{exeName}");
                var val = key?.GetValue(null)?.ToString();
                if (!string.IsNullOrEmpty(val))
                {
                    val = val.Trim('"', ' ');
                    if (File.Exists(val))
                    {
                        path = val;
                        return true;
                    }
                }
            }
            catch { }

            try
            {
                using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey($@"{baseKey}\{exeName}");
                var val = key?.GetValue(null)?.ToString();
                if (!string.IsNullOrEmpty(val))
                {
                    val = val.Trim('"', ' ');
                    if (File.Exists(val))
                    {
                        path = val;
                        return true;
                    }
                }
            }
            catch { }
        }

        return false;
    }

    private static bool TryFindStartMenuShortcut(string appName, out string shortcutPath)
    {
        shortcutPath = string.Empty;
        var searchToken = appName.Trim().ToLowerInvariant();

        var directories = new List<string>();
        var commonStart = Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu);
        if (!string.IsNullOrEmpty(commonStart) && Directory.Exists(commonStart))
            directories.Add(commonStart);

        var userStart = Environment.GetFolderPath(Environment.SpecialFolder.StartMenu);
        if (!string.IsNullOrEmpty(userStart) && Directory.Exists(userStart))
            directories.Add(userStart);

        foreach (var dir in directories)
        {
            try
            {
                var lnkFiles = Directory.EnumerateFiles(dir, "*.lnk", SearchOption.AllDirectories);
                // Exact match first
                foreach (var file in lnkFiles)
                {
                    var nameWithoutExt = Path.GetFileNameWithoutExtension(file);
                    if (nameWithoutExt.Equals(searchToken, StringComparison.OrdinalIgnoreCase))
                    {
                        shortcutPath = file;
                        return true;
                    }
                }

                // Substring match
                foreach (var file in lnkFiles)
                {
                    var nameWithoutExt = Path.GetFileNameWithoutExtension(file);
                    if (nameWithoutExt.Contains(searchToken, StringComparison.OrdinalIgnoreCase))
                    {
                        shortcutPath = file;
                        return true;
                    }
                }
            }
            catch { }
        }

        return false;
    }

    private static AppTarget? FindRunningAppTarget(string appName, string? command)
    {
        var expectedName = !string.IsNullOrEmpty(command) ? GetExpectedProcessName(appName, command) : appName;
        if (string.IsNullOrEmpty(expectedName)) expectedName = appName;

        // 1. Direct match by process name, or by window title for Store apps (hosted by ApplicationFrameHost)
        var target = WindowCaptureService.CaptureWindowByProcessName(expectedName)
                     ?? (command?.StartsWith("shell:AppsFolder", StringComparison.OrdinalIgnoreCase) == true
                         ? WindowCaptureService.CaptureWindowByTitle(expectedName)
                         : null);
        if (target != null && target.WindowHandle != IntPtr.Zero)
            return target;

        // 2. Search processes by process name or main window title
        try
        {
            var processes = Process.GetProcesses();
            foreach (var proc in processes)
            {
                using (proc)
                {
                    try
                    {
                        if (proc.ProcessName.Contains(expectedName, StringComparison.OrdinalIgnoreCase) ||
                            NameTokens(expectedName).Any(t => proc.ProcessName.Contains(t, StringComparison.OrdinalIgnoreCase)) ||
                            (!string.IsNullOrEmpty(proc.MainWindowTitle) && proc.MainWindowTitle.Contains(expectedName, StringComparison.OrdinalIgnoreCase)))
                        {
                            var captured = WindowCaptureService.CaptureWindowByProcessId(proc.Id);
                            if (captured != null && captured.WindowHandle != IntPtr.Zero)
                                return captured;
                        }
                    }
                    catch { }
                }
            }
        }
        catch { }

        return null;
    }

    // Words that appear in many app names and identify none of them
    private static readonly HashSet<string> GenericNameWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "microsoft", "windows", "google", "app", "apps", "desktop", "ide", "browser", "player", "studio", "the", "for",
        "explorer" // explorer.exe is also the desktop/taskbar shell, so "File Explorer" must not match it by word
    };

    /// <summary>Distinctive words of an app name: "Antigravity IDE" → ["Antigravity"], "Task Manager" → ["Task", "Manager"].</summary>
    private static IEnumerable<string> NameTokens(string name) =>
        name.Split(new[] { ' ', '-', '_', '.' }, StringSplitOptions.RemoveEmptyEntries)
            .Where(w => w.Length >= 4 && !GenericNameWords.Contains(w));

    /// <summary>The whole name in the process name or title, or a distinctive word of it in the process name.</summary>
    public static bool NameMatches(string expected, AppTarget window) =>
        window.ProcessName.Contains(expected, StringComparison.OrdinalIgnoreCase) ||
        window.WindowTitle.Contains(expected, StringComparison.OrdinalIgnoreCase) ||
        NameTokens(expected).Any(t => window.ProcessName.Contains(t, StringComparison.OrdinalIgnoreCase));

    private static bool StartedSince(int processId, DateTime since)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            return process.StartTime >= since;
        }
        catch
        {
            return false; // protected or exited process
        }
    }

    private static void BringWindowToForeground(AppTarget target)
    {
        if (target.WindowHandle == IntPtr.Zero) return;
        try
        {
            var hwnd = (HWND)target.WindowHandle;
            PInvoke.ShowWindow(hwnd, SHOW_WINDOW_CMD.SW_RESTORE);
            PInvoke.SetForegroundWindow(hwnd);
        }
        catch { }
    }

    private static bool IsSafeLaunchCommand(string command)
    {
        if (string.IsNullOrWhiteSpace(command)) return false;

        var exeName = Path.GetFileName(command).Trim();
        if (DisallowedExecutables.Contains(exeName)) return false;

        // Block shell command line injection
        if (command.Contains(" -enc ") || command.Contains(" /c ") || command.Contains(" /k ") ||
            command.EndsWith(".bat", StringComparison.OrdinalIgnoreCase) ||
            command.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase) ||
            command.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) ||
            command.EndsWith(".vbs", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return true;
    }

    public static string GetExpectedProcessName(string appName, string? command)
    {
        // Store apps run in ApplicationFrameHost / their own host; match the window by the app's name
        if (!string.IsNullOrEmpty(command) && command.StartsWith("shell:AppsFolder", StringComparison.OrdinalIgnoreCase))
        {
            return appName.Trim();
        }

        if (!string.IsNullOrEmpty(command) && (command.Equals("ms-settings:", StringComparison.OrdinalIgnoreCase) ||
            appName.Contains("settings", StringComparison.OrdinalIgnoreCase)))
        {
            return "SystemSettings";
        }

        if (!string.IsNullOrEmpty(command))
        {
            var fileName = Path.GetFileNameWithoutExtension(command);
            if (!string.IsNullOrEmpty(fileName))
            {
                return fileName;
            }
        }

        return appName.Trim();
    }

    private async Task<AppTarget?> WaitForNewForegroundTargetAsync(
        string? expectedProcessName,
        CancellationToken cancellationToken,
        DateTime? launchStartedAt = null,
        IntPtr previousForeground = default)
    {
        var sw = Stopwatch.StartNew();
        AppTarget? lastCaptured = null;

        while (sw.ElapsedMilliseconds < 5000)
        {
            cancellationToken.ThrowIfCancellationRequested();

            // 1. Actively check if expected process window already exists and can be focused
            if (!string.IsNullOrEmpty(expectedProcessName))
            {
                var byProc = WindowCaptureService.CaptureWindowByProcessName(expectedProcessName)
                             ?? NameTokens(expectedProcessName).Select(WindowCaptureService.CaptureWindowByProcessName).FirstOrDefault(t => t != null)
                             ?? WindowCaptureService.CaptureWindowByTitle(expectedProcessName);
                if (byProc != null && byProc.WindowHandle != IntPtr.Zero)
                {
                    _logger.LogInformation("Captured launched window by process name: {ProcessName} - '{Title}'", byProc.ProcessName, byProc.WindowTitle);
                    BringWindowToForeground(byProc);
                    return byProc;
                }
            }

            // 2. Check if foreground window matches or is a valid newly activated window
            var fg = WindowCaptureService.CaptureCurrentForegroundWindow();
            if (fg != null && fg.WindowHandle != IntPtr.Zero && !WindowCaptureService.IsDesktopOrShell(fg))
            {
                if (!string.IsNullOrEmpty(expectedProcessName))
                {
                    if (NameMatches(expectedProcessName, fg))
                    {
                        _logger.LogInformation("Captured newly launched target window in foreground: {ProcessName} - '{Title}'", fg.ProcessName, fg.WindowTitle);
                        return fg;
                    }

                    // The shortcut name often differs from the program's ("Antigravity IDE" runs as Antigravity.exe,
                    // "VS Code" as Code.exe): a window that just came to the front from a process started by this
                    // launch is the app, whatever it's called. Previously this waited the full 5 s and gave up.
                    if (launchStartedAt.HasValue && fg.WindowHandle != previousForeground && !WindowCaptureService.IsSelf(fg) &&
                        StartedSince(fg.ProcessId, launchStartedAt.Value.AddSeconds(-1)))
                    {
                        _logger.LogInformation("Captured window of newly started process: {ProcessName} - '{Title}'", fg.ProcessName, fg.WindowTitle);
                        return fg;
                    }
                }
                else
                {
                    lastCaptured = fg;
                    return fg;
                }
            }

            await Task.Delay(150, cancellationToken);
        }

        if (!string.IsNullOrEmpty(expectedProcessName))
        {
            var byProc = WindowCaptureService.CaptureWindowByProcessName(expectedProcessName)
                         ?? WindowCaptureService.CaptureWindowByTitle(expectedProcessName);
            if (byProc != null)
            {
                _logger.LogInformation("Captured launched window by process name fallback: {ProcessName} - '{Title}'", byProc.ProcessName, byProc.WindowTitle);
                BringWindowToForeground(byProc);
                return byProc;
            }

            // Don't hand back whatever else is in front (it made an open Copilot window the target of
            // "open the calculator"); the agent loop adopts the app's window once it appears
            _logger.LogWarning("No window found for launched app '{App}'.", expectedProcessName);
            return null;
        }

        return lastCaptured ?? WindowCaptureService.CaptureCurrentForegroundWindow();
    }
}
