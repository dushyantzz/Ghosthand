import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GhostHandCore

// MARK: - MacWindowCaptureService
//
// Swift / AppKit port of GhostHand.Platform.Windowing.WindowCaptureService.
//
// The Windows implementation identifies the foreground window through
// GetForegroundWindow/EnumWindows and derives its bounds from GetWindowRect. On macOS
// the equivalent information comes from `NSWorkspace.shared.frontmostApplication`
// (process identity / bundle) and `CGWindowListCopyWindowInfo` (CGWindowID + bounds),
// with the AX focused window supplying the human-readable title.

public final class MacWindowCaptureService: WindowTracker {

    public init() {}

    // MARK: - WindowTracker

    public func captureForegroundWindow() -> AppTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Self.buildTarget(for: app)
    }

    public func getActiveTarget(current: AppTarget) -> AppTarget? {
        guard let foreground = captureForegroundWindow(), foreground.windowHandle != 0 else {
            return current
        }

        // If the current target is the desktop/shell, auto-switch to the active app.
        if Self.isDesktopOrShell(current) && !Self.isDesktopOrShell(foreground) {
            return foreground
        }

        // If the foreground window belongs to the current target process, track the
        // newly focused window of that process.
        if foreground.processId == current.processId
            && foreground.windowHandle != current.windowHandle {
            return foreground
        }

        return current
    }

    // MARK: - Static capture helpers

    @discardableResult
    public static func captureCurrentForegroundWindow() -> AppTarget? {
        MacWindowCaptureService().captureForegroundWindow()
    }

    @discardableResult
    public static func captureWindow(processId: Int32) -> AppTarget? {
        if let app = NSRunningApplication(processIdentifier: processId) {
            return buildTarget(for: app)
        }

        // The process may be running but not surfaced as an NSRunningApplication
        // (e.g. a helper). Build what we can from the window list.
        guard let window = frontmostWindowInfo(pid: processId) else { return nil }
        let ownerName = windowOwnerName(pid: processId) ?? "Unknown"
        return AppTarget(
            processId: processId,
            processName: ownerName,
            executablePath: "",
            windowTitle: ownerName,
            windowHandle: window.windowId,
            windowBounds: window.bounds,
            isElevated: false,
            bundleIdentifier: nil
        )
    }

    @discardableResult
    public static func captureWindow(processName: String) -> AppTarget? {
        let wanted = processName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }

        let running = NSWorkspace.shared.runningApplications

        // Exact name / bundle-file matches first, then substring matches.
        for app in running where matches(app, wanted: wanted, exact: true) {
            if let target = captureWindow(processId: app.processIdentifier) { return target }
        }
        for app in running where matches(app, wanted: wanted, exact: false) {
            if let target = captureWindow(processId: app.processIdentifier) { return target }
        }
        return nil
    }

    /// The Windows build treats Explorer showing the desktop as the shell. On macOS
    /// the equivalent is Finder with no ordinary window/desktop in front.
    public static func isDesktopOrShell(_ target: AppTarget?) -> Bool {
        guard let target else { return true }

        let name = target.processName.lowercased()
        let bundle = (target.bundleIdentifier ?? "").lowercased()
        let isFinder = name == "finder" || bundle == "com.apple.finder"
        guard isFinder else { return false }

        if target.windowHandle == 0 { return true }

        let title = target.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title.isEmpty || title == "desktop" || title == "finder"
    }

    /// macOS has no UIPI / integrity-level equivalent: a non-root process can already
    /// target any regular application through the Accessibility API. Elevated (root)
    /// targets are simply unreachable, so there is nothing to pre-check here.
    /// Always returns `false`; kept for API parity with the Windows implementation.
    public static func isTargetElevated(_ processId: Int32) -> Bool {
        false
    }

    // MARK: - Target construction

    static func buildTarget(for app: NSRunningApplication) -> AppTarget {
        let pid = app.processIdentifier
        let name = app.localizedName
            ?? app.bundleURL?.lastPathComponent
            ?? "Unknown"
        let bundleIdentifier = app.bundleIdentifier
        let executablePath = app.bundleURL?.path ?? app.executableURL?.path ?? ""

        let window = frontmostWindowInfo(pid: pid)
        let windowTitle = axFocusedWindowTitle(pid: pid) ?? ""

        return AppTarget(
            processId: pid,
            processName: name,
            executablePath: executablePath,
            windowTitle: windowTitle.isEmpty ? name : windowTitle,
            windowHandle: window?.windowId ?? 0,
            windowBounds: window?.bounds ?? .zero,
            isElevated: false,
            bundleIdentifier: bundleIdentifier
        )
    }

    /// First on-screen, layer-0 window owned by `pid` in front-to-back order.
    static func frontmostWindowInfo(pid: Int32) -> (windowId: UInt64, bounds: CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in list {
            guard let ownerPid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPid == pid else { continue }
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0 else {
                continue
            }
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
                continue
            }

            var bounds = CGRect.zero
            if let rawBounds = info[kCGWindowBounds as String],
               CFGetTypeID(rawBounds as AnyObject) == CFDictionaryGetTypeID() {
                CGRectMakeWithDictionaryRepresentation(rawBounds as! CFDictionary, &bounds)
            }
            // Ignore zero-size shadow/helper windows.
            guard bounds.width >= 1, bounds.height >= 1 else { continue }

            return (UInt64(number), bounds)
        }
        return nil
    }

    static func windowOwnerName(pid: Int32) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard let ownerPid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPid == pid else { continue }
            if let name = info[kCGWindowOwnerName as String] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    static func axFocusedWindowTitle(pid: Int32) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1)

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }

        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else { return nil }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func matches(_ app: NSRunningApplication, wanted: String, exact: Bool) -> Bool {
        let candidates = [
            (app.localizedName ?? "").lowercased(),
            (app.bundleURL?.lastPathComponent.lowercased() ?? ""),
            (app.bundleIdentifier ?? "").lowercased(),
        ]
        if exact {
            return candidates.contains(wanted)
        }
        return candidates.contains { !$0.isEmpty && $0.contains(wanted) }
    }
}
