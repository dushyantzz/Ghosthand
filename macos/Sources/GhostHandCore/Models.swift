import CoreGraphics
import Foundation

// MARK: - AgentOperation
//
// Swift port of GhostHand.Core.Models.AgentOperation.
// Raw values are kept in the original C# PascalCase so audit-log JSON stays wire-compatible.

/// Operations an agent can request, with raw values kept wire-compatible with the C# original.
public enum AgentOperation: String, Codable, CaseIterable, Sendable {
    case click = "Click"
    case typeText = "TypeText"
    case typeAndEnter = "TypeAndEnter"
    case clickText = "ClickText"
    case scrollUp = "ScrollUp"
    case scrollDown = "ScrollDown"
    case pressReturn = "PressReturn"
    case pressTab = "PressTab"
    case pressEscape = "PressEscape"
    case wait = "Wait"
    case openApp = "OpenApp"
    case openUrl = "OpenUrl"
    case pressSpace = "PressSpace"
    case pressMediaPlay = "PressMediaPlay"
    case done = "Done"
    case blocked = "Blocked"
    case askUser = "AskUser"

    public var displayName: String { rawValue }
}

// MARK: - AccessibilityElement
//
// Platform-independent representation of a readable UI control or OCR detection.
// Mirrors GhostHand.Core.Models.AccessibilityElement.

/// A platform-independent view of a readable UI control or OCR detection.
public struct AccessibilityElement: Identifiable, Equatable, Sendable {
    public var id: String
    public var role: String
    public var label: String
    public var value: String
    public var enabled: Bool
    public var focused: Bool
    public var frame: CGRect
    /// "accessibility" or "ocr"
    public var source: String
    public var actions: [String]

    /// Creates an accessibility element from its identity, role, and optional attributes.
    public init(
        id: String,
        role: String,
        label: String = "",
        value: String = "",
        enabled: Bool = true,
        focused: Bool = false,
        frame: CGRect = .zero,
        source: String = "accessibility",
        actions: [String] = []
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
        self.source = source
        self.actions = actions
    }

    public var displayRole: String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }

    public var displayLabel: String {
        if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return label }
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        return ""
    }

    public var isOutcomeEvidence: Bool {
        switch role.lowercased() {
        case "text", "statictext", "axstatictext", "statusbar":
            return true
        default:
            return false
        }
    }

    /// Returns a short display string, truncating the label or role to `maxChars` characters.
    public func compactDescription(maxChars: Int = 160) -> String {
        let text = !displayLabel.isEmpty ? displayLabel : displayRole
        if text.count > maxChars {
            return String(text.prefix(maxChars)) + "..."
        }
        return text
    }
}

// MARK: - AppTarget
//
// Information about the target application and its active window.

/// Describes the target application process and its active window.
public struct AppTarget: Equatable, Sendable {
    public var processId: Int32
    public var processName: String
    public var executablePath: String
    public var windowTitle: String
    /// CGWindowID of the target window, or 0 when unknown.
    public var windowHandle: UInt64
    public var windowBounds: CGRect
    public var isElevated: Bool
    public var bundleIdentifier: String?

    /// Creates a target description for an application process and its active window.
    public init(
        processId: Int32,
        processName: String,
        executablePath: String = "",
        windowTitle: String = "",
        windowHandle: UInt64 = 0,
        windowBounds: CGRect = .zero,
        isElevated: Bool = false,
        bundleIdentifier: String? = nil
    ) {
        self.processId = processId
        self.processName = processName
        self.executablePath = executablePath
        self.windowTitle = windowTitle
        self.windowHandle = windowHandle
        self.windowBounds = windowBounds
        self.isElevated = isElevated
        self.bundleIdentifier = bundleIdentifier
    }

    public var bounds: CGRect { windowBounds }
}

// MARK: - AgentDecision

/// A single operation chosen by the agent, with optional target, text, and coordinates.
public struct AgentDecision: Equatable, Sendable {
    public var operation: AgentOperation
    public var targetId: String?
    public var targetLabel: String?
    public var textValue: String?
    public var x: Int?
    public var y: Int?
    public var reason: String?
    public var confidence: Double
    public var requiresConfirmation: Bool

    /// Creates an agent decision for the given operation with optional targeting and confidence details.
    public init(
        operation: AgentOperation,
        targetId: String? = nil,
        targetLabel: String? = nil,
        textValue: String? = nil,
        x: Int? = nil,
        y: Int? = nil,
        reason: String? = nil,
        confidence: Double = 1.0,
        requiresConfirmation: Bool = false
    ) {
        self.operation = operation
        self.targetId = targetId
        self.targetLabel = targetLabel
        self.textValue = textValue
        self.x = x
        self.y = y
        self.reason = reason
        self.confidence = confidence
        self.requiresConfirmation = requiresConfirmation
    }
}

// MARK: - ActionResult

/// The outcome of executing an agent operation, including error text and any new target.
public struct ActionResult: Sendable {
    public var success: Bool
    public var errorMessage: String?
    public var message: String?
    public var duration: TimeInterval
    public var newTarget: AppTarget?

    public var error: String? { errorMessage }

    /// Creates a result with the given outcome, optional messages, duration, and follow-up target.
    public init(
        success: Bool,
        errorMessage: String? = nil,
        message: String? = nil,
        duration: TimeInterval = 0,
        newTarget: AppTarget? = nil
    ) {
        self.success = success
        self.errorMessage = errorMessage
        self.message = message
        self.duration = duration
        self.newTarget = newTarget
    }

    /// Returns a successful result carrying only the given duration.
    public static func succeeded(duration: TimeInterval = 0) -> ActionResult {
        ActionResult(success: true, duration: duration)
    }

    /// Returns a failed result carrying the supplied error message and duration.
    public static func failed(_ error: String, duration: TimeInterval = 0) -> ActionResult {
        ActionResult(success: false, errorMessage: error, duration: duration)
    }

    /// Returns a successful result with an optional informational message.
    public static func successResult(_ message: String? = nil) -> ActionResult {
        ActionResult(success: true, message: message)
    }

    /// Returns a failed result carrying the supplied error message.
    public static func failureResult(_ error: String) -> ActionResult {
        ActionResult(success: false, errorMessage: error)
    }

    /// Returns a successful result that reports the new active target after a transition.
    public static func targetChanged(_ target: AppTarget, _ message: String? = nil) -> ActionResult {
        ActionResult(success: true, message: message, newTarget: target)
    }
}
