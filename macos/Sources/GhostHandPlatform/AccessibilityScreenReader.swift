import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GhostHandCore

// MARK: - AXScreenReader
//
// Swift / AppKit port of GhostHand.Platform.ScreenReading.UiaScreenReader.
//
// The Windows implementation attaches to an HWND through UI Automation and relies on
// a CacheRequest to batch-prefetch element properties. macOS has no CacheRequest, so
// this walker uses `AXUIElementCopyMultipleAttributeValues` once per node plus a hard
// wall-clock budget, a depth cap and a visited-node cap to stay bounded.
//
// Every label/value is routed through `SecretSanitizer`; secure text fields never
// expose their contents (`kAXSecureTextField` subrole / role is treated as a password).

public final class AXScreenReader: ScreenReader {

    /// Total wall-clock budget for a single accessibility walk.
    public static let walkTimeBudget: TimeInterval = 0.8
    /// Hard cap on tree depth.
    public static let maxWalkDepth = 30
    /// Absolute cap on visited nodes, independent of `ScreenReaderOptions.maxNodes`.
    public static let maxVisitedNodes = 3000

    private let options: ScreenReaderOptions
    private let ocrService: OcrService?

    public init(options: ScreenReaderOptions = .default, ocrService: OcrService? = nil) {
        self.options = options
        self.ocrService = ocrService
    }

    // MARK: - ScreenReader

    public func readElements(target: AppTarget) async throws -> [AccessibilityElement] {
        var rawElements = walk(target: target)

        // OCR fallback when the accessibility tree exposes too little interactivity
        // (or nothing at all) and a recognizer was supplied.
        // Mirrors the C# condition exactly: an empty tree always falls back; a
        // configured threshold additionally falls back when interactivity is below it.
        let interactiveCount = rawElements.filter { ElementRanker.isInteractive($0.role) }.count
        let needsFallback = rawElements.isEmpty
            || (options.ocrFallbackThreshold > 0 && interactiveCount < options.ocrFallbackThreshold)
        if let ocrService, needsFallback {
            GhostLog.shared.info(
                "Interactive accessibility element count (\(interactiveCount)) requires fallback. Activating local OCR."
            )
            let ocrElements = await ocrService.recognizeScreenArea(target.bounds)
            rawElements.append(contentsOf: ocrElements)
        }

        // Stable IDs, priority ordering and final filtering live in GhostHandCore.
        return ElementRanker.rankAndFilter(rawElements, options: options)
    }

    // MARK: - Tree walk

    private func walk(target: AppTarget) -> [AccessibilityElement] {
        let appElement = AXUIElementCreateApplication(target.processId)
        AXUIElementSetMessagingTimeout(appElement, 0.1)

        let deadline = Date().addingTimeInterval(Self.walkTimeBudget)
        let elementLimit = max(1, options.maxNodes)
        let visitedCap = min(max(elementLimit * 6, 600), Self.maxVisitedNodes)
        let windowBounds = target.windowBounds
        let filterOffscreen = options.filterOffscreen

        var elements: [AccessibilityElement] = []
        var visited = 0

        // Prefer the focused window; fall back to the application element itself.
        let root = Self.focusedWindow(of: appElement) ?? appElement
        Self.enumerate(
            root,
            depth: 0,
            elementLimit: elementLimit,
            visitedCap: visitedCap,
            deadline: deadline,
            windowBounds: windowBounds,
            filterOffscreen: filterOffscreen,
            elements: &elements,
            visited: &visited
        )

        // Some apps expose nothing under the focused window but do expose windows.
        if elements.isEmpty {
            for window in Self.windows(of: appElement) {
                Self.enumerate(
                    window,
                    depth: 0,
                    elementLimit: elementLimit,
                    visitedCap: visitedCap,
                    deadline: deadline,
                    windowBounds: windowBounds,
                    filterOffscreen: filterOffscreen,
                    elements: &elements,
                    visited: &visited
                )
                if elements.count >= elementLimit || Date() >= deadline { break }
            }
        }

        GhostLog.shared.debug(
            "AXWalk: \(elements.count) elements for \(target.processName) visited=\(visited) budget_exhausted=\(Date() >= deadline)"
        )
        return elements
    }

    // The recursion context is threaded through the walk; collapsing these into a struct would
    // only move the same state around, so the wide signature is the honest one.
    // swiftlint:disable:next function_parameter_count
    private static func enumerate(
        _ element: AXUIElement,
        depth: Int,
        elementLimit: Int,
        visitedCap: Int,
        deadline: Date,
        windowBounds: CGRect,
        filterOffscreen: Bool,
        elements: inout [AccessibilityElement],
        visited: inout Int
    ) {
        guard depth < maxWalkDepth,
              elements.count < elementLimit,
              visited < visitedCap,
              Date() < deadline else { return }
        visited += 1

        // One cross-process call per node instead of one per attribute.
        let keys: [String] = [
            kAXRoleAttribute,
            kAXSubroleAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXRoleDescriptionAttribute,
            kAXValueAttribute,
            kAXEnabledAttribute,
            kAXFocusedAttribute,
            kAXChildrenAttribute,
            kAXPositionAttribute,
            kAXSizeAttribute,
        ]

        var batch: CFArray?
        let batchResult = AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &batch)
        let batchValues = batch as? [AnyObject]

        func attribute(_ key: String) -> AnyObject? {
            if batchResult == .success,
               let batchValues,
               let index = keys.firstIndex(of: key),
               index < batchValues.count {
                return batchValues[index]
            }
            return copyAttribute(element, key)
        }

        let role = attribute(kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(kAXSubroleAttribute) as? String ?? ""
        let isPassword = role == "AXSecureTextField" || subrole == "AXSecureTextField"

        let title = normalized(attribute(kAXTitleAttribute) as? String)
        let description = normalized(attribute(kAXDescriptionAttribute) as? String)
        let roleDescription = normalized(attribute(kAXRoleDescriptionAttribute) as? String)
        let rawName = [title, description, roleDescription].compactMap { $0 }.first { !$0.isEmpty }

        // Never read the value of a secure field, and sanitize whatever we do read.
        var rawValue: String?
        if !isPassword {
            let valueAttribute = attribute(kAXValueAttribute)
            rawValue = (valueAttribute as? String) ?? (valueAttribute as? NSNumber)?.stringValue
        }

        let label = SecretSanitizer.sanitize(rawName, isPassword: isPassword)
        let value = isPassword ? "" : SecretSanitizer.sanitize(rawValue, isPassword: false)

        let interactive = ElementRanker.isInteractive(role)
        let hasLabel = !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasValue = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let frame = Self.frame(
            position: attribute(kAXPositionAttribute),
            size: attribute(kAXSizeAttribute)
        )

        var onScreen = true
        if filterOffscreen {
            if frame.width <= 0 || frame.height <= 0 {
                onScreen = false
            } else if windowBounds.width > 0, windowBounds.height > 0, !windowBounds.intersects(frame) {
                onScreen = false
            }
        }

        // Skip structural containers carrying no information, but always recurse.
        if (hasLabel || hasValue || interactive) && onScreen {
            let enabled = (attribute(kAXEnabledAttribute) as? Bool) ?? true
            let focused = (attribute(kAXFocusedAttribute) as? Bool) ?? false
            let actions = Self.actions(of: element, role: role, isPassword: isPassword)

            elements.append(AccessibilityElement(
                id: "", // ElementRanker assigns stable "e1", "e2", ... IDs.
                role: role,
                label: label,
                value: value,
                enabled: enabled,
                focused: focused,
                frame: frame,
                source: "accessibility",
                actions: actions
            ))
        }

        for child in Self.children(of: element, attribute: attribute) {
            Self.enumerate(
                child,
                depth: depth + 1,
                elementLimit: elementLimit,
                visitedCap: visitedCap,
                deadline: deadline,
                windowBounds: windowBounds,
                filterOffscreen: filterOffscreen,
                elements: &elements,
                visited: &visited
            )
            if elements.count >= elementLimit || Date() >= deadline { break }
        }
    }

    // MARK: - Attribute helpers

    private static let textEntryRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
    ]

    private static func actions(of element: AXUIElement, role: String, isPassword: Bool) -> [String] {
        var actions: [String] = []
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let names = names as? [String] {
            if names.contains(kAXPressAction) || names.contains(kAXConfirmAction) {
                actions.append("click")
            }
            if names.contains(kAXIncrementAction) || names.contains(kAXDecrementAction) {
                actions.append("toggle")
            }
            if names.contains("AXScrollDownByPage") || names.contains("AXScrollUpByPage") {
                actions.append("scroll")
            }
        }
        if !isPassword && textEntryRoles.contains(role) {
            actions.append("type")
        }

        var seen = Set<String>()
        return actions.filter { seen.insert($0).inserted }
    }

    private static func children(
        of element: AXUIElement,
        attribute: (String) -> AnyObject?
    ) -> [AXUIElement] {
        if let children = attribute(kAXChildrenAttribute) as? [AXUIElement] {
            return children
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let value else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func frame(position: AnyObject?, size: AnyObject?) -> CGRect {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return .zero }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        // The CFTypeID checks above already validated the dynamic types. Swift has no checked
        // downcast to a CoreFoundation type — `as?` is rejected as "always succeeds" — so `as!`
        // after an explicit type-ID check is the correct idiom here.
        // swiftlint:disable:next force_cast
        let positionValue = position as! AXValue
        // swiftlint:disable:next force_cast
        let sizeValue = size as! AXValue
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return .zero }
        return CGRect(origin: point, size: dimensions)
    }

    private static func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let window = value as! AXUIElement
        return window
    }

    private static func windows(of appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let value else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func copyAttribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
