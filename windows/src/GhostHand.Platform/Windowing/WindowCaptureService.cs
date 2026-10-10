using System.Diagnostics;
using System.Drawing;
using GhostHand.Core.Interfaces;
using GhostHand.Core.Models;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace GhostHand.Platform.Windowing;

public interface IWindowCaptureService
{
    AppTarget? CaptureForegroundWindow();
}

public class WindowCaptureService : IWindowCaptureService, IWindowTracker
{
    private static readonly int SelfProcessId = Environment.ProcessId;

    /// <summary>True for GhostHand's own windows (the popup), which must never become the automation target.</summary>
    public static bool IsSelf(AppTarget? target) => target != null && target.ProcessId == SelfProcessId;

    /// <summary>
    /// The foreground window, skipping GhostHand itself: while the popup has focus, the user's app is the
    /// next visible window in z-order. (Targeting the popup made the agent click its own buttons.)
    /// </summary>
    public AppTarget? CaptureForegroundWindow()
    {
        var fg = CaptureWindowByHwnd(PInvoke.GetForegroundWindow());
        return IsSelf(fg) ? CaptureTopmostExternalWindow() : fg;
    }

    /// <summary>Topmost visible, titled top-level window that doesn't belong to GhostHand.</summary>
    /// <summary>
    /// Topmost visible window titled with this app name ("Calculator", "Camera"). Store apps' windows belong to
    /// ApplicationFrameHost, so they can't be found by process name.
    /// </summary>
    public static unsafe AppTarget? CaptureWindowByTitle(string appName)
    {
        if (string.IsNullOrWhiteSpace(appName)) return null;
        var name = appName.Trim();
        AppTarget? found = null;
        PInvoke.EnumWindows((hwnd, _) =>
        {
            if (!PInvoke.IsWindowVisible(hwnd))
                return true;
            var candidate = CaptureWindowByHwnd(hwnd);
            if (candidate == null || IsSelf(candidate) || string.IsNullOrWhiteSpace(candidate.WindowTitle))
                return true;
            var title = candidate.WindowTitle.Trim();
            if (title.Equals(name, StringComparison.OrdinalIgnoreCase) ||
                title.StartsWith(name + " ", StringComparison.OrdinalIgnoreCase) ||
                title.EndsWith(" - " + name, StringComparison.OrdinalIgnoreCase))
            {
                found = candidate;
                return false;
            }
            return true;
        }, 0);
        return found;
    }

    public static unsafe AppTarget? CaptureTopmostExternalWindow()
    {
        AppTarget? found = null;
        PInvoke.EnumWindows((hwnd, _) =>
        {
            if (!PInvoke.IsWindowVisible(hwnd))
                return true;
            var candidate = CaptureWindowByHwnd(hwnd);
            if (candidate == null || IsSelf(candidate) || string.IsNullOrWhiteSpace(candidate.WindowTitle))
                return true;
            found = candidate;
            return false;
        }, 0);
        return found;
    }

    public AppTarget? GetActiveTarget(AppTarget currentTarget) => GetActiveTarget(currentTarget, string.Empty);

    public AppTarget? GetActiveTarget(AppTarget currentTarget, string goal)
    {
        var fg = CaptureForegroundWindow();
        if (fg != null && fg.WindowHandle != IntPtr.Zero)
        {
            // The app the command names ("open notepad and …") came to the front, e.g. launched early while
            // the user was still speaking: adopt it instead of aborting on a foreground mismatch
            if (fg.ProcessId != currentTarget.ProcessId && !string.IsNullOrEmpty(goal) && IsAppNamedInGoal(fg, goal))
            {
                return fg;
            }

            // If current target is the desktop or shell, auto-switch to active application
            if (IsDesktopOrShell(currentTarget) && !IsDesktopOrShell(fg))
            {
                return fg;
            }

            // If foreground window belongs to current target process, track its active window handle
            if (fg.ProcessId == currentTarget.ProcessId && fg.WindowHandle != currentTarget.WindowHandle)
            {
                return fg;
            }
        }
        return currentTarget;
    }

    private static bool IsAppNamedInGoal(AppTarget window, string goal) =>
        GhostHand.Core.Jev.JevDecisionModel.ExtractAppLaunchCandidates(goal).Any(app =>
            window.ProcessName.Contains(app, StringComparison.OrdinalIgnoreCase) ||
            // Store apps (Camera, Photos) run in ApplicationFrameHost, so match their window title too
            window.WindowTitle.StartsWith(app, StringComparison.OrdinalIgnoreCase) ||
            (app.Length >= 4 && app.Contains(window.ProcessName, StringComparison.OrdinalIgnoreCase)));

    public static bool IsDesktopOrShell(AppTarget? target)
    {
        if (target == null) return true;
        if (target.ProcessName.Equals("explorer", StringComparison.OrdinalIgnoreCase))
        {
            if (string.IsNullOrEmpty(target.WindowTitle) ||
                target.WindowTitle.Equals("Program Manager", StringComparison.OrdinalIgnoreCase) ||
                target.WindowTitle.Equals("Desktop", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    public static unsafe AppTarget? CaptureWindowByHwnd(HWND hwnd)
    {
        if (hwnd == HWND.Null)
        {
            return null;
        }

        uint processId = 0;
        unsafe
        {
            PInvoke.GetWindowThreadProcessId(hwnd, &processId);
        }

        if (processId == 0)
        {
            return null;
        }

        string processName = "Unknown";
        string exePath = string.Empty;
        bool isElevated = false;

        try
        {
            using var process = Process.GetProcessById((int)processId);
            processName = process.ProcessName;
            try
            {
                exePath = process.MainModule?.FileName ?? string.Empty;
            }
            catch
            {
                isElevated = true;
            }
        }
        catch
        {
            isElevated = true;
        }

        // Get window title
        string title = string.Empty;
        unsafe
        {
            fixed (char* titleBuffer = new char[512])
            {
                int len = PInvoke.GetWindowText(hwnd, titleBuffer, 512);
                if (len > 0)
                {
                    title = new string(titleBuffer, 0, len);
                }
            }
        }

        // Get window bounds
        var bounds = Rectangle.Empty;
        RECT winRect;
        if (PInvoke.GetWindowRect(hwnd, out winRect))
        {
            bounds = new Rectangle(winRect.left, winRect.top, winRect.right - winRect.left, winRect.bottom - winRect.top);
        }

        if (!isElevated)
        {
            isElevated = CheckElevationByProcessAccess((int)processId);
        }

        return new AppTarget
        {
            ProcessId = (int)processId,
            ProcessName = processName,
            ExecutablePath = exePath,
            WindowTitle = title,
            WindowHandle = (IntPtr)hwnd.Value,
            WindowBounds = bounds,
            IsElevated = isElevated
        };
    }

    public static unsafe AppTarget? CaptureWindowByProcessId(int processId)
    {
        HWND foundHwnd = HWND.Null;
        HWND fallbackHwnd = HWND.Null;

        // Check process MainWindowHandle first
        try
        {
            using var proc = Process.GetProcessById(processId);
            var mainHwnd = (HWND)proc.MainWindowHandle;
            if (mainHwnd != HWND.Null && PInvoke.IsWindowVisible(mainHwnd))
            {
                var mainTarget = CaptureWindowByHwnd(mainHwnd);
                if (mainTarget != null) return mainTarget;
            }
        }
        catch { }

        PInvoke.EnumWindows((hwnd, _) =>
        {
            uint pid = 0;
            PInvoke.GetWindowThreadProcessId(hwnd, &pid);
            if (pid == (uint)processId && PInvoke.IsWindowVisible(hwnd))
            {
                RECT rect;
                if (PInvoke.GetWindowRect(hwnd, out rect))
                {
                    int w = rect.right - rect.left;
                    int h = rect.bottom - rect.top;
                    // Normal window or minimized window (left == -32000)
                    if ((w > 150 && h > 150) || rect.left <= -30000)
                    {
                        foundHwnd = hwnd;
                        return false;
                    }
                }

                if (fallbackHwnd == HWND.Null)
                {
                    fallbackHwnd = hwnd;
                }
            }
            return true;
        }, 0);

        var finalHwnd = foundHwnd != HWND.Null ? foundHwnd : fallbackHwnd;
        return finalHwnd != HWND.Null ? CaptureWindowByHwnd(finalHwnd) : null;
    }

    public static AppTarget? CaptureWindowByProcessName(string processName)
    {
        var processes = Process.GetProcessesByName(processName);
        foreach (var proc in processes)
        {
            using (proc)
            {
                try
                {
                    var target = CaptureWindowByProcessId(proc.Id);
                    if (target != null) return target;
                }
                catch
                {
                    // Ignore inaccessible processes
                }
            }
        }
        return null;
    }

    public static bool IsTargetElevated(int processId) => CheckElevationByProcessAccess(processId);

    public static AppTarget? CaptureCurrentForegroundWindow() => new WindowCaptureService().CaptureForegroundWindow();

    public static bool CheckElevationByProcessAccess(int processId)
    {
        try
        {
            var hProcess = PInvoke.OpenProcess(
                Windows.Win32.System.Threading.PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION,
                false,
                (uint)processId);

            if (hProcess.IsNull)
            {
                // Access denied from standard user indicates elevated target
                return true;
            }

            PInvoke.CloseHandle(hProcess);
            return false;
        }
        catch
        {
            return true;
        }
    }
}
