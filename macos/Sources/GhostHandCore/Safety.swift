import Foundation

// MARK: - ActionRiskScore

/// Classifies how disruptive an action is, from harmless to irreversible or externally visible.
public enum ActionRiskScore: Int, Sendable, Comparable, CaseIterable {
    case harmless = 1
    case reversibleEdit = 2
    case irreversibleOrExternalEffect = 3

    /// Orders risk scores by raw value so higher-risk actions compare greater than lower-risk ones.
    public static func < (lhs: ActionRiskScore, rhs: ActionRiskScore) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - RiskPolicyOptions

/// Configurable vocabulary and risk threshold used to build the default risk policy.
public final class RiskPolicyOptions: @unchecked Sendable {
    /// Credential vocabulary that escalates a text-writing action to a confirmation prompt.
    /// This is deliberately non-empty: an agent that can type into a password or API-key
    /// field must ask a human first, even though every other safe action auto-executes.
    public static let defaultSensitiveVerbs: Set<String> = [
        "password", "passwd", "passphrase", "passcode",
        "credential", "credentials",
        "secret", "api key", "apikey", "access token", "auth token",
        "private key", "recovery code", "seed phrase", "one-time code", "verification code",
    ]

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
    /// Whether text that names credential material requires confirmation. Defaults to `true`
    /// so the secure behaviour is the out-of-the-box behaviour; set it to `false` for the
    /// fully automatic Jarvis mode only when the operator accepts that risk.
    public var requireConfirmationOnSensitiveText: Bool = true

    /// Creates options seeded with the default sensitive verbs, prohibited terms, and deny-listed processes.
    public init() {
        sensitiveVerbs = Set(Self.defaultSensitiveVerbs.map { $0.lowercased() })
        prohibitedTerms = Set(Self.defaultProhibitedTerms.map { $0.lowercased() })
        denyListedProcesses = Set(Self.defaultDenyListedProcesses.map { $0.lowercased() })
    }
}

// MARK: - AuditLogEntry

/// One recorded agent decision, suitable for JSON encoding into the audit trail.
public struct AuditLogEntry: Codable, Sendable {
    public var timestamp: Date
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

    /// Creates an audit entry, defaulting the timestamp to now and the decision type to "auto".
    public init(
        timestamp: Date = Date(),
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
        case timestamp, goal, operation, targetId, targetLabel, targetRole
        case appProcess, appTitle, decisionType, reason
    }
}

// MARK: - RiskPolicy
//
// Deterministic risk policy: safe actions auto-execute, deletion is permanently
// prohibited, and credential writes require a human confirmation by default.

/// Default policy that auto-executes safe actions while blocking or confirming risky ones.
public final class DefaultRiskPolicy: RiskPolicy {
    private let options: RiskPolicyOptions
    private let prohibitedRegex: NSRegularExpression
    private let sensitiveRegex: NSRegularExpression

    /// Creates a policy and precompiles the prohibited-term and sensitive-verb regular expressions.
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
        if options.sensitiveVerbs.isEmpty {
            // Never matches.
            sensitiveRegex = (try? NSRegularExpression(pattern: "^$"))!
        } else {
            let escaped = options.sensitiveVerbs.map { NSRegularExpression.escapedPattern(for: $0) }
            let pattern = "\\b(\(escaped.joined(separator: "|")))\\b"
            sensitiveRegex = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))!
        }
    }

    /// Returns the refusal reason when the target's name, bundle id, or path is deny-listed.
    public func isAppDenied(_ appTarget: AppTarget) -> String? {
        let name = appTarget.processName.lowercased()
        let bundle = (appTarget.bundleIdentifier ?? "").lowercased()
        let path = appTarget.executablePath.lowercased()
        for denied in options.denyListedProcesses {
            // Match the process name, the bundle id and the executable path. A deny-listed
            // binary that has been renamed still exposes the original name in its path, so
            // dropping the path check would let it through.
            if name == denied || name.contains(denied)
                || bundle.contains(denied)
                || path.contains(denied) {
                return "Application process '\(appTarget.processName)' is on the security deny-list."
            }
        }
        return nil
    }

    /// Requires confirmation when an action would write credential material: typing into a
    /// password/secure field, or typing text that names a credential. Everything else stays
    /// in Jarvis mode (auto-executed); deletion is blocked outright before this is reached.
    public func requiresConfirmation(
        decision: AgentDecision,
        target: AccessibilityElement?,
        appTarget: AppTarget
    ) -> String? {
        let writesText = decision.operation == .typeText || decision.operation == .typeAndEnter

        if writesText, let target, Self.isCredentialField(target) {
            return "Confirmation required: writing into the credential field "
                + "'\(target.displayLabel)' must be approved by a human."
        }

        if writesText, options.requireConfirmationOnSensitiveText,
           let text = decision.textValue, !text.isBlank {
            let normalized = Self.normalizeForMatch(text)
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            if let match = sensitiveRegex.firstMatch(in: normalized, options: [], range: range),
               let matchRange = Range(match.range, in: normalized) {
                return "Confirmation required: the action types credential material "
                    + "(matching '\(normalized[matchRange])')."
            }
        }

        return nil
    }

    /// Returns the refusal reason when the goal names a prohibited deletion term; otherwise nil.
    public func isGoalProhibited(_ goal: String) -> String? {
        guard !goal.isBlank else { return nil }
        let normalized = Self.normalizeForMatch(goal)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = prohibitedRegex.firstMatch(in: normalized, options: [], range: range),
              let matchRange = Range(match.range, in: normalized) else { return nil }
        let term = String(normalized[matchRange])
        return "Prohibited by safety policy: Deletion tasks (matching '\(term)') are strictly prohibited."
    }

    /// Returns the refusal reason when any decision payload matches a prohibited term; otherwise nil.
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
        // Inspect *every* decision-supplied payload, not just the operations we happen to
        // know about today. A returned decision can carry text on any operation (and an
        // unoffered `type_and_enter` choice carries it too), so the payload must never
        // reach the executor uninspected.
        if let text = decision.textValue, !text.isBlank {
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

    /// Whether an element is a credential field that must not be written to without approval.
    static func isCredentialField(_ element: AccessibilityElement) -> Bool {
        let role = element.role.lowercased()
        return role.contains("secure") || role.contains("password")
    }

    /// Normalises text before term matching: strips zero-width and bidirectional control
    /// characters that could smuggle a prohibited word past the regex (e.g. "del\u{200B}ete"
    /// or "de\u{2066}lete"), then applies Unicode NFC so decomposed forms also match.
    static func normalizeForMatch(_ text: String) -> String {
        var filtered = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00AD,                    // soft hyphen
                 0x180E,                    // Mongolian vowel separator
                 0x200B, 0x200C, 0x200D,    // zero-width space / non-joiner / joiner
                 0x200E, 0x200F,            // left-to-right / right-to-left mark
                 0x202A...0x202E,           // bidi embedding / override controls
                 0x2060,                    // word joiner
                 0x2066...0x2069,           // bidi isolate controls
                 0xFEFF:                    // zero-width no-break space (BOM)
                continue
            default:
                filtered.append(scalar)
            }
        }
        return String(filtered).precomposedStringWithCanonicalMapping
    }
}

// MARK: - Launch authorization

extension RiskPolicy {
    /// Returns the deny-list refusal when `decision` would launch a deny-listed application,
    /// otherwise nil. The launch target is not the foreground target yet, so it needs its own
    /// check — otherwise the app is opened before the post-launch target check can see it.
    func launchDenial(for decision: AgentDecision) -> String? {
        guard decision.operation == .openApp,
              let appName = decision.targetId, !appName.isBlank else { return nil }
        return isAppDenied(AppTarget(processId: 0, processName: appName, windowTitle: appName))
    }
}
