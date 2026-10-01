import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GhostHandCore

// MARK: - MacActionExecutor
//
// Swift / AppKit port of GhostHand.Platform.Execution.ActionExecutor.
//
// Where the Windows build drives UI Automation patterns found by hit-testing a point
// with `UIA3Automation.FromPoint`, this port resolves the AX element under the target
// center with `AXUIElementCopyElementAtPosition`, tries `AXPress` (clicks) or a
// settable `AXValue` (typing), and falls back to `CGInputSimulator` events.

public final class MacActionExecutor: ActionExecutorProtocol {

    public var dryRun: Bool
    public var expectedProcessId: Int32?
    public var targetWindowHandle: UInt64?

    public let appLauncher: AppLauncherProtocol?
    public let ocrService: OcrService?

    public init(dryRun: Bool, appLauncher: AppLauncherProtocol? = nil, ocrService: OcrService? = nil) {
        self.dryRun = dryRun
        self.appLauncher = appLauncher
        self.ocrService = ocrService
    }

    // MARK: - ActionExecutorProtocol

    public func execute(
        decision: AgentDecision,
        targetElement: AccessibilityElement?
    ) async throws -> ActionResult {
        try Task.checkCancellation()

        // Terminal / non-physical operations never touch the input pipeline.
        switch decision.operation {
        case .done:
            return ActionResult.successResult("Task completed")
        case .askUser:
            return ActionResult.successResult("User consultation requested")
        case .wait:
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return ActionResult.successResult("Waited 1 second")
        default:
            break
        }

        // Dry-run: plan and verify without injecting hardware input.
        if dryRun {
            GhostLog.shared.info(
                "[DRY RUN] Would execute \(decision.operation.displayName) on "
                + "'\(decision.targetLabel ?? decision.targetId ?? "")' "
                + "with value '\(decision.textValue ?? "")'"
            )
            try await Task.sleep(nanoseconds: 150_000_000)
            let target = decision.targetLabel ?? decision.targetId ?? ""
            return ActionResult.successResult("[DRY RUN] Simulated \(decision.operation.displayName) on '\(target)'")
        }

        // Re-focus the target window before physical execution.
        if let windowHandle = targetWindowHandle, windowHandle != 0 {
            refocusTargetWindow(windowHandle)
            try await Task.sleep(nanoseconds: 60_000_000)
        }

        // Live execution safety check: the foreground process must still be the one we
        // were told to drive. OpenApp/OpenUrl deliberately launch new processes.
        if let expected = expectedProcessId,
           decision.operation != .openApp,
           decision.operation != .openUrl {
            let currentPid = Self.foregroundProcessId()
            if currentPid != expected {
                if Self.isDesktopShellProcess(expected), currentPid != 0 {
                    GhostLog.shared.info(
                        "Foreground migrated from desktop shell to app (PID \(currentPid)). "
                        + "Updating ExpectedProcessId."
                    )
                    expectedProcessId = currentPid
                } else {
                    GhostLog.shared.warning(
                        "Foreground process changed mid-action! Expected PID \(expected), "
                        + "current PID \(currentPid). Aborting."
                    )
                    return ActionResult.failureResult(
                        "Foreground process changed mid-action "
                        + "(expected PID \(expected), found \(currentPid)). Execution aborted."
                    )
                }
            }
        }

        do {
            switch decision.operation {
            case .openApp:
                guard let appLauncher else {
                    return ActionResult.failureResult("AppLauncher is not configured.")
                }
                let appName = decision.targetId ?? decision.targetLabel ?? ""
                let newTarget = try await appLauncher.launchApp(name: appName, launchCommand: nil)
                if let newTarget {
                    expectedProcessId = newTarget.processId
                    targetWindowHandle = newTarget.windowHandle
                    return ActionResult.targetChanged(
                        newTarget,
                        "Launched application '\(newTarget.processName)'"
                    )
                }
                return ActionResult.successResult("Launched application '\(appName)'")

            case .openUrl:
                guard let appLauncher else {
                    return ActionResult.failureResult("AppLauncher is not configured.")
                }
                let urlString = decision.textValue ?? decision.targetId ?? ""
                guard let url = URL(string: urlString),
                      let scheme = url.scheme,
                      !scheme.isEmpty else {
                    return ActionResult.failureResult("Invalid URL '\(urlString)'")
                }
                let browserTarget = try await appLauncher.launchUrl(url)
                if let browserTarget {
                    expectedProcessId = browserTarget.processId
                    targetWindowHandle = browserTarget.windowHandle
                    return ActionResult.targetChanged(browserTarget, "Opened URL '\(url)'")
                }
                return ActionResult.successResult("Opened URL '\(url)'")

            case .click:
                return executeClick(targetElement)

            case .typeAndEnter:
                return executeTypeText(
                    targetElement,
                    text: decision.textValue ?? "",
                    submitWithEnter: true
                )

            case .typeText:
                return executeTypeText(
                    targetElement,
                    text: decision.textValue ?? "",
                    submitWithEnter: Self.isSearchOrAddressBar(targetElement)
                )

            case .pressReturn:
                CGInputSimulator.sendKey(CGInputSimulator.returnKey)
                return ActionResult.successResult("Pressed Enter key")

            case .pressTab:
                CGInputSimulator.sendKey(CGInputSimulator.tabKey)
                return ActionResult.successResult("Pressed Tab key")

            case .pressEscape:
                CGInputSimulator.sendKey(CGInputSimulator.escapeKey)
                return ActionResult.successResult("Pressed Escape key")

            case .pressSpace:
                CGInputSimulator.sendKey(CGInputSimulator.spaceKey)
                return ActionResult.successResult("Pressed Space key")

            case .pressMediaPlay:
                CGInputSimulator.pressMediaPlay()
                return ActionResult.successResult("Pressed Media Play/Pause key")

            case .scrollDown:
                CGInputSimulator.scroll(down: true)
                return ActionResult.successResult("Scrolled down")

            case .scrollUp:
                CGInputSimulator.scroll(down: false)
                return ActionResult.successResult("Scrolled up")

            default:
                return ActionResult.failureResult("Unsupported operation '\(decision.operation.displayName)'")
            }
        } catch {
            GhostLog.shared.error(
                "Failed to execute \(decision.operation.displayName) on "
                + "\(decision.targetId ?? decision.targetLabel ?? ""): \(error.localizedDescription)"
            )
            return ActionResult.failureResult(error.localizedDescription)
        }
    }

    // MARK: - Click

    private func executeClick(_ targetElement: AccessibilityElement?) -> ActionResult {
        guard let targetElement, !targetElement.frame.isEmpty else {
            return ActionResult.failureResult(
                "Cannot click: target element not found or has empty bounding frame."
            )
        }

        let center = CGPoint(x: targetElement.frame.midX, y: targetElement.frame.midY)

        // Prefer the accessibility action on (or above) the hit-tested element.
        if let element = Self.axElement(at: center) {
            var current: AXUIElement? = element
            var depth = 0
            while let node = current, depth < 5 {
                if Self.performPress(on: node) {
                    GhostLog.shared.debug("Clicked via AXPress on \(targetElement.displayLabel)")
                    return ActionResult.successResult(
                        "Clicked via AXPress on '\(targetElement.displayLabel)'"
                    )
                }
                current = Self.parent(of: node)
                depth += 1
            }
        }

        // Fallback: synthetic mouse click at the element center.
        let x = Int(center.x.rounded())
        let y = Int(center.y.rounded())
        CGInputSimulator.click(x: x, y: y)
        GhostLog.shared.debug("Clicked via CGEvent fallback at (\(x), \(y))")
        return ActionResult.successResult("Clicked via CGEvent fallback at (\(x), \(y))")
    }

    private static func performPress(on element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else { return false }

        if actions.contains(kAXPressAction) {
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        if actions.contains(kAXConfirmAction) {
            return AXUIElementPerformAction(element, kAXConfirmAction as CFString) == .success
        }
        return false
    }

    // MARK: - Typing

    private func executeTypeText(
        _ targetElement: AccessibilityElement?,
        text: String,
        submitWithEnter: Bool
    ) -> ActionResult {
        // No element: type into whatever currently has focus.
        guard let targetElement else {
            CGInputSimulator.selectAllAndClear()
            CGInputSimulator.typeText(text)
            if submitWithEnter {
                Thread.sleep(forTimeInterval: 0.06)
                CGInputSimulator.sendKey(CGInputSimulator.returnKey)
            }
            return ActionResult.successResult("Typed text into focused element")
        }

        let center = CGPoint(x: targetElement.frame.midX, y: targetElement.frame.midY)

        // Prefer setting AXValue on (or above) the hit-tested element.
        if !targetElement.frame.isEmpty, let element = Self.axElement(at: center) {
            var current: AXUIElement? = element
            var depth = 0
            while let node = current, depth < 5 {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable) == .success,
                   settable.boolValue,
                   AXUIElementSetAttributeValue(node, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
                    GhostLog.shared.debug("Typed via AXValue on \(targetElement.displayLabel)")
                    if submitWithEnter || Self.isSearchOrAddressBar(targetElement) {
                        Thread.sleep(forTimeInterval: 0.08)
                        CGInputSimulator.sendKey(CGInputSimulator.returnKey)
                        return ActionResult.successResult(
                            "Typed '\(text)' and submitted via Enter on '\(targetElement.displayLabel)'"
                        )
                    }
                    return ActionResult.successResult(
                        "Typed text via AXValue on '\(targetElement.displayLabel)'"
                    )
                }
                current = Self.parent(of: node)
                depth += 1
            }
        }

        // Fallback: click to focus, select all, clear, then type via CGEvent.
        CGInputSimulator.click(x: Int(center.x.rounded()), y: Int(center.y.rounded()))
        Thread.sleep(forTimeInterval: 0.06)
        CGInputSimulator.selectAllAndClear()
        Thread.sleep(forTimeInterval: 0.03)
        CGInputSimulator.typeText(text)

        if submitWithEnter || Self.isSearchOrAddressBar(targetElement) {
            Thread.sleep(forTimeInterval: 0.08)
            CGInputSimulator.sendKey(CGInputSimulator.returnKey)
            GhostLog.shared.debug(
                "Auto-pressed Enter after typing into search/address bar '\(targetElement.displayLabel)'"
            )
            return ActionResult.successResult(
                "Typed '\(text)' and submitted via Enter on '\(targetElement.displayLabel)'"
            )
        }

        return ActionResult.successResult(
            "Typed text via CGEvent fallback on '\(targetElement.displayLabel)'"
        )
    }

    /// Port of `ActionExecutor.IsSearchOrAddressBar`.
    public static func isSearchOrAddressBar(_ element: AccessibilityElement?) -> Bool {
        guard let element else { return false }
        let label = element.displayLabel.lowercased()
        let needles = ["address", "search", "omnibox", "url", "find", "google", "query", "bar"]
        return needles.contains { label.contains($0) }
    }

    // MARK: - Window / process helpers

    private func refocusTargetWindow(_ windowHandle: UInt64) {
        let pid = expectedProcessId ?? Self.processId(forWindowHandle: windowHandle)
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }

        app.activate()

        // Raise the app's focused AX window so hit-testing targets the right surfaces.
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
           let windowValue,
           CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            // The CFTypeID check above already validated the dynamic type.
            // swiftlint:disable:next force_cast
            AXUIElementPerformAction(windowValue as! AXUIElement, kAXRaiseAction as CFString)
        }
    }

    private static func processId(forWindowHandle handle: UInt64) -> Int32? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let list = CGWindowListCopyWindowInfo(options, CGWindowID(handle)) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            if let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value {
                return pid
            }
        }
        return nil
    }

    private static func foregroundProcessId() -> Int32 {
        NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }

    private static func isDesktopShellProcess(_ processId: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processId) else { return false }
        let bundle = (app.bundleIdentifier ?? "").lowercased()
        let name = (app.localizedName ?? "").lowercased()
        return bundle == "com.apple.finder" || name == "finder"
    }

    // MARK: - Accessibility element resolution

    private static func axElement(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element
        )
        guard result == .success else { return nil }
        return element
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let parent = value as! AXUIElement
        return parent
    }
}
