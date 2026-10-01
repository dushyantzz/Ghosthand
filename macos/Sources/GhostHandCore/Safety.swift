import Foundation

// MARK: - ActionRiskScore

public enum ActionRiskScore: Int, Sendable, Comparable, CaseIterable {
    case harmless = 1
    case reversibleEdit = 2
    case irreversibleOrExternalEffect = 3

    public static func < (lhs: ActionRiskScore, rhs: ActionRiskScore) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - RiskPolicyOptions

public final class RiskPolicyOptions: @unchecked Sendable {
    /// Empty by design: Jarvis mode requires no confirmation dialogs for any safe action.
    public static let defaultSensitiveVerbs: Set<String> = []

    /// Only actual deletion operations — strictly enforced.
    public static let defaultProhibitedTerms: Set<String> = [
        "delete", "deletion", "erase", "wipe", "destroy", "truncate", "format", "del",
    ]

    /// Password managers that must never be automated.
    public static let defaultDenyListedProcesses: Set<String> = [
        "1password", "bitwarden", "keepass", "keepassxc", "lastpass",
        "dashlane", "enpass", "authenticator",
    ]

    public var sensitiveVerbs: Set<String>
    public var prohibitedTerms: Set<String>
    public var denyListedProcesses: Set<String>
    public var escalateOnRiskScore: ActionRiskScore = .irreversibleOrExternalEffect
    public var requireConfirmationOnSensitiveText: Bool = false

    public init() {
        sensitiveVerbs = Set(Self.defaultSensitiveVerbs.map { $0.lowercased() })
        prohibitedTerms = Set(Self.defaultProhibitedTerms.map { $0.lowercased() })
        denyListedProcesses = Set(Self.defaultDenyListedProcesses.map { $0.lowercased() })
    }
}

// MARK: - AuditLogEntry

public struct AuditLogEntry: Codable, Sendable {
    public var timestamp: Date
    /// Correlates every entry produced by a single `AgentLoop.run` invocation.
    public var runId: String?
    /// Agent-loop step that produced this entry (0 for pre-loop policy refusals).
    public var step: Int?
    public var goal: String
    public var operation: AgentOperation
    public var targetId: String?
    public var targetLabel: String?
    public var targetRole: String?
    public var appProcess: String
    public var appTitle: String
    /// "auto", "confirmed", "rejected", "denied", "prohibited"
    public var decisionType: String
    public var reason: String?

    public init(
        timestamp: Date = Date(),
        runId: String? = nil,
        step: Int? = nil,
        goal: String = "",
        operation: AgentOperation,
        targetId: String? = nil,
        targetLabel: String? = nil,
        targetRole: String? = nil,
        appProcess: String = "",
        appTitle: String = "",
        decisionType: String = "auto",
        reason: String? = nil
    ) {
        self.timestamp = timestamp
        self.runId = runId
        self.step = step
        self.goal = goal
        self.operation = operation
        self.targetId = targetId
        self.targetLabel = targetLabel
        self.targetRole = targetRole
        self.appProcess = appProcess
        self.appTitle = appTitle
        self.decisionType = decisionType
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, runId, step, goal, operation, targetId, targetLabel, targetRole
        case appProcess, appTitle, decisionType, reason
    }
}

// MARK: - RiskPolicy
//
// Jarvis-mode risk policy: execute ALL tasks automatically.
// The ONLY restriction is deletion operations — these are permanently prohibited.

public final class DefaultRiskPolicy: RiskPolicy {
    private let options: RiskPolicyOptions
    private let prohibitedRegex: NSRegularExpression

    public init(options: RiskPolicyOptions = RiskPolicyOptions()) {
        self.options = options
        if options.prohibitedTerms.isEmpty {
            // Never matches.
            prohibitedRegex = (try? NSRegularExpression(pattern: "^$"))!
        } else {
            let escaped = options.prohibitedTerms.map { NSRegularExpression.escapedPattern(for: $0) }
            let pattern = "\\b(\(escaped.joined(separator: "|")))\\b"
            prohibitedRegex = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))!
        }
    }

    public func isAppDenied(_ appTarget: AppTarget) -> String? {
        let name = appTarget.processName.lowercased()
        let bundle = (appTarget.bundleIdentifier ?? "").lowercased()
        for denied in options.denyListedProcesses {
            if name == denied || name.contains(denied) || bundle.contains(denied) {
                return "Application process '\(appTarget.processName)' is on the security deny-list."
            }
        }
        return nil
    }

    /// Jarvis mode: NEVER requires human confirmation.
    public func requiresConfirmation(
        decision: AgentDecision,
        target: AccessibilityElement?,
        appTarget: AppTarget
    ) -> String? {
        nil
    }

    public func isGoalProhibited(_ goal: String) -> String? {
        guard !goal.isBlank else { return nil }
        let normalized = Self.normalizeForMatch(goal)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = prohibitedRegex.firstMatch(in: normalized, options: [], range: range),
              let matchRange = Range(match.range, in: normalized) else { return nil }
        let term = String(normalized[matchRange])
        return "Prohibited by safety policy: Deletion tasks (matching '\(term)') are strictly prohibited."
    }

    public func isActionProhibited(
        decision: AgentDecision,
        target: AccessibilityElement?,
        goal: String
    ) -> String? {
        var textToInspect: [String] = []
        if let label = decision.targetLabel, !label.isBlank { textToInspect.append(label) }
        if let target {
            if !target.label.isBlank { textToInspect.append(target.label) }
            if !target.value.isBlank { textToInspect.append(target.value) }
        }
        if decision.operation == .typeText || decision.operation == .typeAndEnter,
           let text = decision.textValue, !text.isBlank {
            textToInspect.append(text)
        }

        for text in textToInspect {
            let normalized = Self.normalizeForMatch(text)
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            guard let match = prohibitedRegex.firstMatch(in: normalized, options: [], range: range),
                  let matchRange = Range(match.range, in: normalized) else { continue }
            let term = String(normalized[matchRange])
            let label = target?.displayLabel ?? decision.targetLabel ?? ""
            return "Prohibited by safety policy: Action '\(decision.operation.rawValue)' on '\(label)' matches deletion term '\(term)'."
        }
        return nil
    }

    /// Normalises text before deletion-term matching: strips zero-width / bidirectional
    /// control characters that could smuggle a prohibited word past the regex
    /// (e.g. "del\u{200B}ete"), then applies Unicode NFC so decomposed forms also match.
    static func normalizeForMatch(_ text: String) -> String {
        var filtered = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF,
                 0x202A, 0x202B, 0x202C, 0x202D, 0x202E:
                continue
            default:
                filtered.append(scalar)
            }
        }
        return String(filtered).precomposedStringWithCanonicalMapping
    }
}
