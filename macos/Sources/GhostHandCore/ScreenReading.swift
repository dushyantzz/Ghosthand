import CoreGraphics
import Foundation

// MARK: - ScreenReaderOptions

public struct ScreenReaderOptions: Sendable {
    public var maxNodes: Int = 500
    public var maxDepth: Int = 30
    public var maxCandidates: Int = 40
    public var ocrFallbackThreshold: Int = 0
    public var filterOffscreen: Bool = true
    public var filterDisabled: Bool = false

    public init() {}
    public static let `default` = ScreenReaderOptions()
}

// MARK: - SecretSanitizer
//
// Port of GhostHand.Core.ScreenReading.SecretSanitizer. Password fields and
// card/key/bearer patterns never escape toward the model or the audit log.

public enum SecretSanitizer {
    private static let cardRegex = try! NSRegularExpression(
        pattern: #"\b(?:\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{1,4}|\d{13,16})\b"#
    )
    private static let apiKeyRegex = try! NSRegularExpression(
        pattern: #"\b(?:vck_[a-zA-Z0-9_-]{10,}|sk-[a-zA-Z0-9_-]{20,}|ghp_[a-zA-Z0-9]{25,}|eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{10,})\b"#
    )
    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"(Bearer\s+)[a-zA-Z0-9_\-\.]{15,}"#,
        options: [.caseInsensitive]
    )

    public static func sanitize(_ text: String?, isPassword: Bool = false) -> String {
        if isPassword { return "[PASSWORD]" }
        guard let text, !text.isEmpty else { return "" }

        var result = text
        result = replace(cardRegex, in: result, with: "[REDACTED_CARD]")
        result = replace(apiKeyRegex, in: result, with: "[REDACTED_KEY]")
        result = replace(bearerRegex, in: result, with: "$1[REDACTED]")
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

// MARK: - ElementRanker
//
// Port of GhostHand.Core.ScreenReading.ElementRanker, extended with a canonical-role
// map so Windows UIA role names and macOS AX role names rank identically.

public enum ElementRanker {
    public static let interactiveRoles: Set<String> = [
        "Button", "MenuItem", "TabItem", "Hyperlink", "CheckBox",
        "RadioButton", "ComboBox", "ListItem", "Edit", "Document", "SplitButton",
    ]

    /// Maps a platform role (Windows UIA or macOS AX) to the canonical role names
    /// used by the decision model's candidate generation.
    public static func canonicalRole(_ role: String) -> String {
        switch role {
        case "AXButton", "AXMenuButton", "AXToolbarButton", "AXDisclosureTriangle", "AXIncrementor":
            return "Button"
        case "AXMenuItem", "AXMenuBarItem":
            return "MenuItem"
        case "AXTab":
            return "TabItem"
        case "AXLink":
            return "Hyperlink"
        case "AXCheckBox", "AXSwitch":
            return "CheckBox"
        case "AXRadioButton":
            return "RadioButton"
        case "AXPopUpButton", "AXComboBox":
            return "ComboBox"
        case "AXRow", "AXCell", "AXOutlineRow", "AXTableRow", "AXListItem":
            return "ListItem"
        case "AXTextField", "AXTextArea", "AXSearchField":
            return "Edit"
        case "AXStaticText":
            return "Text"
        case "AXSlider":
            return "Slider"
        default:
            return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        }
    }

    public static func isInteractive(_ role: String) -> Bool {
        interactiveRoles.contains(canonicalRole(role))
    }

    public static func rankAndFilter(
        _ elements: [AccessibilityElement],
        options: ScreenReaderOptions
    ) -> [AccessibilityElement] {
        let filtered = elements
            .filter { !options.filterOffscreen || isOnScreen($0) }
            .filter { !options.filterDisabled || $0.enabled }
            .prefix(options.maxNodes)

        let sorted = filtered.sorted { lhs, rhs in
            if lhs.focused != rhs.focused { return lhs.focused }
            let lhsInteractive = isInteractive(lhs.role)
            let rhsInteractive = isInteractive(rhs.role)
            if lhsInteractive != rhsInteractive { return lhsInteractive }
            let lhsLabel = !lhs.displayLabel.isBlank
            let rhsLabel = !rhs.displayLabel.isBlank
            if lhsLabel != rhsLabel { return lhsLabel }
            if lhs.isOutcomeEvidence != rhs.isOutcomeEvidence { return lhs.isOutcomeEvidence }
            if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
            return lhs.frame.minX < rhs.frame.minX
        }

        let candidates = sorted.prefix(options.maxCandidates)
        return candidates.enumerated().map { index, element in
            var copy = element
            copy.id = "e\(index + 1)"
            return copy
        }
    }

    private static func isOnScreen(_ element: AccessibilityElement) -> Bool {
        element.frame.width > 0 && element.frame.height > 0
    }
}
