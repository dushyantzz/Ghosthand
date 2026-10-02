import Foundation

// MARK: - LayaDecisionModel
//
// A DecisionModel backed by the LOCAL Laya decision model (see /Users/threaded/projects/Laya),
// served by `laya-serve` over the Jev-compatible `POST /v1/systemone` protocol.
//
// Candidate actions are generated deterministically from the goal and the visible
// accessibility elements; Laya only chooses among them. This is the same grounding the
// Windows build used, re-pointed from the hosted Jev gateway to the offline model.

/// A `DecisionModel` backed by a local Laya server, using deterministic candidate generation.
public final class LayaDecisionModel: DecisionModel, @unchecked Sendable {
    private let client: LayaClientProtocol
    private let options: LayaOptions

    /// Creates a decision model that routes every Laya request through the given client.
    public init(client: LayaClientProtocol, options: LayaOptions) {
        self.client = client
        self.options = options
    }

    /// Convenience wiring used by the CLI and the app wrapper.
    public convenience init(options: LayaOptions) {
        self.init(client: LayaClient(options: options), options: options)
    }

    // MARK: DecisionModel

    /// Asks Laya to select the next action from generated candidates and converts the
    /// choice into an `AgentDecision`, returning `done` when Laya reports the goal is met.
    public func decideNextAction(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> AgentDecision {
        // 1. Build candidate action choices deterministically, then cap the option count
        //    to what Laya's choice question accepts in one forward pass.
        let candidateChoices = LayaDecisionModel.buildCandidateChoices(goal: goal, elements: elements)
        let cappedChoices = LayaDecisionModel.capCandidateChoices(
            candidateChoices,
            limit: options.maxChoiceOptions
        )

        // 2. Build a compact state object (text-only, no secrets).
        let actionAttempts: JSONValue = history.isEmpty
            ? .array([.string("nothing yet")])
            : .array(history.suffix(8).map { .string($0) })

        let state = JSONValue.object([
            "task": .string(LayaDecisionModel.truncate(goal, maxChars: 4000)),
            "app": .string(LayaDecisionModel.truncate(target.processName, maxChars: 100)),
            "window": .string(LayaDecisionModel.truncate(target.windowTitle, maxChars: 150)),
            "step": .number(Double(history.count + 1)),
            "actionAttempts": actionAttempts,
            "elementCount": .number(Double(elements.count)),
            "elements": .array(elements.prefix(40).map { LayaDecisionModel.elementJSON($0) }),
        ])

        // 3. Build questions: next action (choice) + goal achieved (yes/no).
        let questions: [String: LayaQuestion] = [
            "nextAction": .choice(
                cappedChoices,
                instructions: "Select the single best next action to advance toward: \"\(goal)\""
            ),
            "goalAchieved": .noul(
                "Has the user's task \"\(goal)\" already been completely fulfilled by the current screen state? Answer yes only when every requirement is visibly satisfied."
            ),
        ]

        let response = try await client.decide(makeRequest(state: state, questions: questions))

        // Check whether the goal is already completed.
        if let achieved = response.tryGetNoul("goalAchieved"), achieved.isTrue {
            return AgentDecision(
                operation: .done,
                reason: "Goal achieved (probability: \(LayaDecisionModel.percent(achieved.probability)))",
                confidence: achieved.probability
            )
        }

        // Parse the next-action choice.
        guard let action = response.tryGetChoice("nextAction") else {
            GhostLog.shared.warning("Failed to parse nextAction choice from Laya response. Asking user.")
            return AgentDecision(operation: .askUser, reason: "Could not parse decision")
        }

        // Deterministic grounding: the model may only pick from the candidates we generated
        // from the goal and the visible screen. A recognized-but-unoffered key (extra text,
        // an element id the screen never exposed, an invented URL) is refused rather than
        // becoming action authority.
        guard cappedChoices[action.choice] != nil else {
            GhostLog.shared.warning(
                "Laya returned action '\(action.choice)' that was not among the offered candidates. Asking the user."
            )
            return AgentDecision(operation: .askUser, reason: "Model selected an action that was not offered.")
        }

        // Execute the chosen action directly as decided by Laya.
        GhostLog.shared.info(
            "Laya selected action: '\(action.choice)' (probability: \(LayaDecisionModel.percent(action.confidence)))"
        )
        return LayaDecisionModel.parseActionDecision(
            action.choice,
            confidence: action.confidence,
            elements: elements
        )
    }

    /// Asks Laya whether every requirement of the goal is satisfied and returns its yes/no verdict.
    public func verifyCompletion(
        goal: String,
        target: AppTarget,
        elements: [AccessibilityElement],
        history: [String]
    ) async throws -> Bool {
        let state = JSONValue.object([
            "task": .string(LayaDecisionModel.truncate(goal, maxChars: 4000)),
            "app": .string(LayaDecisionModel.truncate(target.processName, maxChars: 100)),
            "window": .string(LayaDecisionModel.truncate(target.windowTitle, maxChars: 150)),
            "actionAttempts": .array(history.suffix(6).map { .string($0) }),
            "visibleControls": .array(
                elements.prefix(30).map { .string("\($0.displayRole): \"\($0.displayLabel)\"") }
            ),
        ])

        let response = try await client.decide(makeRequest(
            state: state,
            questions: [
                "done": .noul(
                    "Are ALL requirements of the task \"\(goal)\" completely satisfied based on the visible controls and the recorded actions? Answer yes only when every requirement is met."
                ),
            ]
        ))

        if let done = response.tryGetNoul("done") {
            return done.isTrue
        }
        return false
    }

    /// Rates the risk of a proposed action through Laya, falling back to a conservative
    /// category when the model is unreachable.
    public func evaluateActionRisk(
        goal: String,
        target: AppTarget,
        decision: AgentDecision,
        targetElement: AccessibilityElement?
    ) async throws -> ActionRiskScore {
        // Benign agent control-flow actions are harmless.
        if decision.operation == .done || decision.operation == .askUser || decision.operation == .wait {
            return .harmless
        }

        var proposedAction: [String: JSONValue] = [
            "operation": .string(decision.operation.rawValue),
            "targetRole": .string(targetElement?.displayRole ?? "Unknown"),
            "targetLabel": .string(
                LayaDecisionModel.truncate(
                    targetElement?.displayLabel ?? decision.targetLabel ?? "None",
                    maxChars: 200
                )
            ),
        ]
        if let targetId = decision.targetId {
            proposedAction["targetId"] = .string(targetId)
        }
        if let textValue = decision.textValue {
            proposedAction["textValue"] = .string(LayaDecisionModel.truncate(textValue, maxChars: 100))
        }

        let state = JSONValue.object([
            "task": .string(LayaDecisionModel.truncate(goal, maxChars: 4000)),
            "app": .string(LayaDecisionModel.truncate(target.processName, maxChars: 100)),
            "window": .string(LayaDecisionModel.truncate(target.windowTitle, maxChars: 150)),
            "proposedAction": .object(proposedAction),
        ])

        do {
            let response = try await client.decide(makeRequest(
                state: state,
                questions: [
                    "actionRisk": .score(
                        ["harmless", "reversible edit", "irreversible or external effect"],
                        instructions: "Rate the risk of this proposed user-interface action from lowest (harmless UI navigation) to highest (irreversible external effect, submission, payment, deletion, or external data transmission)."
                    ),
                ]
            ))

            if let risk = response.tryGetScore("actionRisk") {
                let probabilityText = risk.probabilities
                    .map { LayaDecisionModel.percent($0) }
                    .joined(separator: ", ")
                GhostLog.shared.info(
                    "Laya evaluated action risk: level \(String(format: "%.2f", risk.score)), probabilities: [\(probabilityText)]"
                )

                // Laya returns the expected level index, which may fall between levels;
                // round it for the C# threshold comparisons and still use the level
                // probabilities for the ambiguous middle case.
                let level = Int(risk.score.rounded())
                if level >= 3
                    || (level == 2 && risk.probabilities.count == 3 && risk.probabilities[2] >= 0.5) {
                    return .irreversibleOrExternalEffect
                } else if level == 2 || level == 1 {
                    return .reversibleEdit
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            GhostLog.shared.warning("Failed to evaluate action risk via Laya. Defaulting to ReversibleEdit.")
            return .reversibleEdit
        }

        return .harmless
    }

    // MARK: Request assembly

    /// Assembles a `LayaRequest` from the state and questions using the configured model options.
    private func makeRequest(state: JSONValue, questions: [String: LayaQuestion]) -> LayaRequest {
        LayaRequest(
            state: state,
            questions: questions,
            model: options.model.isBlank ? nil : options.model,
            maxLen: options.maxLen,
            headMaxLen: options.headMaxLen,
            minConfidence: options.minConfidence > 0 ? options.minConfidence : nil
        )
    }

    /// Keeps the control options (app/URL launch, standard keys) and as many per-element
    /// click/type options as the choice-question cap allows. Deterministic (key order).
    static func capCandidateChoices(_ choices: [String: String], limit: Int) -> [String: String] {
        guard limit > 0, choices.count > limit else { return choices }

        var controls: [(String, String)] = []
        var targets: [(String, String)] = []
        for (key, value) in choices {
            if key.hasPrefix("click:") || key.hasPrefix("type:") || key.hasPrefix("type_and_enter:") {
                targets.append((key, value))
            } else {
                controls.append((key, value))
            }
        }
        controls.sort { $0.0 < $1.0 }
        targets.sort { $0.0 < $1.0 }

        let room = max(0, limit - controls.count)
        var result: [String: String] = [:]
        for pair in controls.prefix(limit) { result[pair.0] = pair.1 }
        for pair in targets.prefix(room) { result[pair.0] = pair.1 }
        return result
    }

    // MARK: Candidate generation

    /// Percent-encodes the two characters that would make a `type:<id>:<text>` choice key
    /// ambiguous. IDs without `%` or `:` are returned unchanged, so the existing key format
    /// is preserved for the element IDs the screen reader actually produces.
    static func encodeElementId(_ id: String) -> String {
        var encoded = ""
        for character in id {
            switch character {
            case "%": encoded += "%25"
            case ":": encoded += "%3A"
            default: encoded.append(character)
            }
        }
        return encoded
    }

    /// Reverses `encodeElementId` after the choice key has been split.
    static func decodeElementId(_ id: String) -> String {
        var decoded = ""
        let characters = Array(id)
        var index = 0
        while index < characters.count {
            if characters[index] == "%", index + 2 < characters.count {
                switch String(characters[(index + 1)...(index + 2)]).uppercased() {
                case "3A":
                    decoded.append(":")
                    index += 3
                    continue
                case "25":
                    decoded.append("%")
                    index += 3
                    continue
                default:
                    break
                }
            }
            decoded.append(characters[index])
            index += 1
        }
        return decoded
    }

    /// Builds the deterministic set of candidate action choices offered to Laya for the
    /// goal and the visible accessibility elements.
    static func buildCandidateChoices(
        goal: String,
        elements: [AccessibilityElement]
    ) -> [String: String] {
        var choices: [String: String] = [:]

        // 0. App launch & URL candidates.
        for app in extractAppLaunchCandidates(goal) {
            choices["open_app:\(app)"] = "Launch or switch to application \"\(app)\""
        }

        for url in UrlLauncherValidator.extractWebURLs(from: goal) {
            choices["open_url:\(url.absoluteString)"] = "Open web URL \"\(url.absoluteString)\" in browser"
        }

        // Extract search/literal candidate phrases from the user goal.
        let textCandidates = extractCandidatePhrases(goal)

        var clickCount = 0
        for element in elements {
            if !element.enabled { continue }

            if isClickable(element.role) && clickCount < 25 {
                clickCount += 1
                let key = "click:\(element.id)"
                let description = "Click \(element.displayRole) \"\(element.displayLabel)\""
                choices[key] = description
            }

            if isTypeable(element.role) && !textCandidates.isEmpty {
                let encodedId = encodeElementId(element.id)
                for textCandidate in textCandidates.prefix(3) {
                    // If the element already contains this exact text, avoid looping.
                    if !element.value.isEmpty,
                       element.value.range(of: textCandidate, options: .caseInsensitive) != nil {
                        continue
                    }

                    let keyEnter = "type_and_enter:\(encodedId):\(textCandidate)"
                    let descriptionEnter = "Type \"\(textCandidate)\" into \(element.displayRole) \"\(element.displayLabel)\" and press Enter"
                    choices[keyEnter] = descriptionEnter

                    let key = "type:\(encodedId):\(textCandidate)"
                    let description = "Type \"\(textCandidate)\" into \(element.displayRole) \"\(element.displayLabel)\""
                    choices[key] = description
                }
            }
        }

        // Standard actions.
        choices["press:enter"] = "Press Enter/Return key"
        choices["press:space"] = "Press Spacebar to play/pause or select"
        choices["press:media_play"] = "Press Media Play key to toggle playback"
        choices["press:tab"] = "Press Tab key to advance focus"
        choices["press:escape"] = "Press Escape key to dismiss dialog/menu"
        choices["scroll:down"] = "Scroll down to reveal more controls"
        choices["scroll:up"] = "Scroll up"
        choices["wait"] = "Wait 1 second for UI to update"
        choices["done"] = "Task is completely finished"
        choices["ask_user"] = "Need human guidance or clarification"

        return choices
    }

    /// Converts a Laya choice key such as `click:<id>` or `press:enter` into the matching
    /// `AgentDecision`.
    static func parseActionDecision(
        _ key: String,
        confidence: Double,
        elements: [AccessibilityElement]
    ) -> AgentDecision {
        if key.lowercased().hasPrefix("open_app:") {
            let appName = String(key.dropFirst(9)).trimmed
            return AgentDecision(
                operation: .openApp,
                targetId: appName,
                targetLabel: appName,
                reason: "Launch application '\(appName)'",
                confidence: confidence
            )
        }

        if key.lowercased().hasPrefix("open_url:") {
            let url = String(key.dropFirst(9)).trimmed
            // Re-validate at the parse boundary so a decision-supplied URL obeys the same
            // rules as one extracted from the goal: http/https, a real host, no embedded
            // credentials. Otherwise a response URL would bypass candidate validation.
            guard let validated = UrlLauncherValidator.isValidWebURL(url) else {
                return AgentDecision(
                    operation: .askUser,
                    reason: "Rejected a URL from the decision model that is not a safe web URL.",
                    confidence: confidence
                )
            }
            return AgentDecision(
                operation: .openUrl,
                targetId: validated.absoluteString,
                targetLabel: validated.absoluteString,
                textValue: validated.absoluteString,
                reason: "Open web URL '\(validated.absoluteString)'",
                confidence: confidence
            )
        }

        if key.lowercased().hasPrefix("click:") {
            let elementId = String(key.dropFirst(6))
            let element = elements.first { $0.id == elementId }
            return AgentDecision(
                operation: .click,
                targetId: elementId,
                targetLabel: element?.displayLabel,
                reason: "Click element \(elementId)",
                confidence: confidence
            )
        }

        if key.lowercased().hasPrefix("type_and_enter:") {
            let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            let elementId = decodeElementId(parts.count > 1 ? String(parts[1]) : "")
            let text = parts.count > 2 ? String(parts[2]) : ""
            let element = elements.first { $0.id == elementId }

            return AgentDecision(
                operation: .typeAndEnter,
                targetId: elementId,
                targetLabel: element?.displayLabel,
                textValue: text,
                reason: "Type '\(text)' into \(elementId) and press Enter",
                confidence: confidence
            )
        }

        if key.lowercased().hasPrefix("type:") {
            let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            let elementId = decodeElementId(parts.count > 1 ? String(parts[1]) : "")
            let text = parts.count > 2 ? String(parts[2]) : ""
            let element = elements.first { $0.id == elementId }

            return AgentDecision(
                operation: .typeText,
                targetId: elementId,
                targetLabel: element?.displayLabel,
                textValue: text,
                reason: "Type '\(text)' into \(elementId)",
                confidence: confidence
            )
        }

        switch key.lowercased() {
        case "press:enter":
            return AgentDecision(operation: .pressReturn, confidence: confidence)
        case "press:space":
            return AgentDecision(operation: .pressSpace, confidence: confidence)
        case "press:media_play":
            return AgentDecision(operation: .pressMediaPlay, confidence: confidence)
        case "press:tab":
            return AgentDecision(operation: .pressTab, confidence: confidence)
        case "press:escape":
            return AgentDecision(operation: .pressEscape, confidence: confidence)
        case "scroll:down":
            return AgentDecision(operation: .scrollDown, confidence: confidence)
        case "scroll:up":
            return AgentDecision(operation: .scrollUp, confidence: confidence)
        case "wait":
            return AgentDecision(operation: .wait, confidence: confidence)
        case "done":
            return AgentDecision(operation: .done, confidence: confidence)
        default:
            return AgentDecision(operation: .askUser, confidence: confidence)
        }
    }

    private static let clickableRoles: Set<String> = [
        "button", "menuitem", "tabitem", "hyperlink", "checkbox",
        "radiobutton", "combobox", "listitem",
    ]

    private static let typeableRoles: Set<String> = [
        "edit", "document", "combobox",
    ]

    /// Role classification goes through ElementRanker.canonicalRole so Windows UIA
    /// names ("Button"/"Edit") and macOS AX names ("AXButton"/"AXTextField")
    /// classify identically.
    static func isClickable(_ role: String) -> Bool {
        clickableRoles.contains(ElementRanker.canonicalRole(role).lowercased())
    }

    /// Returns whether the canonical form of the role accepts typed text.
    static func isTypeable(_ role: String) -> Bool {
        typeableRoles.contains(ElementRanker.canonicalRole(role).lowercased())
    }

    // MARK: Phrase extraction

    /// Extracts literal text/search/play/calculation phrases from the user goal.
    /// Public because the app/CLI layers use it for candidate previews.
    public static func extractCandidatePhrases(_ goal: String) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        /// Appends a candidate unless an equivalent value was already recorded.
        func add(_ value: String) {
            let key = value.lowercased()
            if seen.insert(key).inserted {
                candidates.append(value)
            }
        }

        // 1. Quoted text: "Adele", 'Hello World'.
        for match in allMatches(quotedRegex, in: goal) {
            if let value = group(1, of: match, in: goal)?.trimmed, !value.isEmpty {
                add(value)
            }
        }

        // 2. Action verbs with target hints: "write/type/enter/insert/put <text> in/into/...".
        if let match = firstMatch(writeRegex, in: goal),
           var value = group(1, of: match, in: goal)?.trimmed {
            value = replace(writeContextRegex, in: value, with: "").trimmed
            if !value.isEmpty && value.lowercased() != "there" {
                add(value)
            }
        }

        // 3. Search queries: "search/look up/find/google/query [for/about/on] <text>".
        for match in allMatches(searchPhraseRegex, in: goal) {
            if var value = group(1, of: match, in: goal)?.trimmed {
                value = replace(searchPrefixRegex, in: value, with: "").trimmed
                if !value.isEmpty {
                    add(value)
                }
            }
        }

        // 4. Play / listen / stream queries: "play/listen to [any song of/by] <text>".
        for match in allMatches(playPhraseRegex, in: goal) {
            if var value = group(1, of: match, in: goal)?.trimmed {
                value = replace(playPrefixRegex, in: value, with: "").trimmed
                if !value.isEmpty {
                    add(value)
                }
            }
        }

        // 5. Calculations: "calculate/compute <expression>".
        if let match = firstMatch(calculateRegex, in: goal),
           let value = group(1, of: match, in: goal)?.trimmed, !value.isEmpty {
            add(value)
        }

        // 6. Fallback: if nothing was extracted, treat a short direct goal as the phrase.
        if candidates.isEmpty
            && !goal.lowercased().hasPrefix("click")
            && !goal.lowercased().hasPrefix("scroll") {
            let cleaned = replace(leadingPolitenessRegex, in: goal, with: "").trimmed
            if !cleaned.isEmpty && cleaned.count <= 40 {
                add(cleaned)
            }
        }

        return candidates
    }

    /// Extracts a launchable application name from goals like "open notepad",
    /// "launch vlc", "switch to discord".
    public static func extractAppLaunchCandidates(_ goal: String) -> [String] {
        guard !goal.isBlank else { return [] }

        guard let match = firstMatch(appLaunchRegex, in: goal),
              let app = group(1, of: match, in: goal)?.trimmed,
              !app.isEmpty else {
            return []
        }

        let stopWords = [
            "menu", "tab", "link", "window", "dialog", "document",
            "file", "page", "browser", "app", "application",
        ]
        guard !stopWords.contains(app.lowercased()) else { return [] }
        return [app]
    }

    // MARK: Utilities

    /// Truncates to `maxChars` (no ellipsis), mirroring the C# helper.
    static func truncate(_ text: String, maxChars: Int) -> String {
        if text.isEmpty || text.count <= maxChars { return text }
        return String(text.prefix(maxChars))
    }

    /// .NET `:P0`-style formatting (e.g. 0.75 -> "75%").
    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    /// Serializes one accessibility element into the compact JSON object sent to Laya.
    private static func elementJSON(_ element: AccessibilityElement) -> JSONValue {
        .object([
            "id": .string(element.id),
            "role": .string(element.displayRole),
            "label": .string(truncate(element.displayLabel, maxChars: 160)),
            "enabled": .bool(element.enabled),
            "focused": .bool(element.focused),
            "source": .string(element.source),
        ])
    }

    // MARK: Regex plumbing

    /// Compiles a regex from a compile-time constant pattern, treating a failure as a programmer error.
    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programmer error.
        try! NSRegularExpression(
            pattern: pattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        )
    }

    private static let quotedRegex = regex(#"["']([^"']+)["']"#)

    private static let writeRegex = regex(
        #"(?:write|type|enter|insert|put)\s+(?:the\s+text\s+)?(?:["']?)(.+?)(?:["']?)(?:\s+(?:in|into|there|here|on|to)\b|$|\.)"#,
        caseInsensitive: true
    )
    private static let writeContextRegex = regex(
        #"\s+(?:in|into|to|on)\s+(?:notepad|document|file|editor|app|browser|search|bar|box).*$"#,
        caseInsensitive: true
    )

    private static let searchPhraseRegex = regex(
        #"(?:search|look\s+up|find|google|query)(?:\s+(?:for|about|on|regarding|the\s+web\s+for))?\s+(?:["']?)(.+?)(?:["']?)(?:\s+(?:on|in|using|with)\s+[a-zA-Z0-9_\-]+|\.|$|\band\b)"#,
        caseInsensitive: true
    )
    private static let searchPrefixRegex = regex(#"^(?:for|about|on)\s+"#, caseInsensitive: true)

    private static let playPhraseRegex = regex(
        #"(?:play|listen\s+to|stream)(?:\s+(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|tracks?\s+(?:of|by)))?\s+(?:["']?)(.+?)(?:["']?)(?:\s+(?:on|in|using|with)\s+[a-zA-Z0-9_\-]+|\.|$|\band\b)"#,
        caseInsensitive: true
    )
    private static let playPrefixRegex = regex(
        #"^(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|track\s+(?:of|by))\s+"#,
        caseInsensitive: true
    )

    private static let calculateRegex = regex(#"(?:calculate|calc|compute)\s+(.+)$"#, caseInsensitive: true)
    private static let leadingPolitenessRegex = regex(
        #"^(?:please\s+|can\s+you\s+|i\s+want\s+to\s+)"#,
        caseInsensitive: true
    )
    private static let appLaunchRegex = regex(
        #"(?:open|launch|start|run|switch\s+to|go\s+to|focus)\s+(?:the\s+app\s+)?([a-zA-Z0-9\-_ ]+?)(?:\s+(?:and|to|then|in|with)\b|$|\.)"#,
        caseInsensitive: true
    )

    /// Returns the first match of the regex in the text, or nil when nothing matches.
    private static func firstMatch(
        _ regex: NSRegularExpression,
        in text: String
    ) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    /// Returns every match of the regex in the text, in order of appearance.
    private static func allMatches(
        _ regex: NSRegularExpression,
        in text: String
    ) -> [NSTextCheckingResult] {
        regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    /// Returns the text captured by the given group index, or nil when the group is absent.
    private static func group(
        _ index: Int,
        of match: NSTextCheckingResult,
        in text: String
    ) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    /// Returns the text with every regex match replaced by the given template.
    private static func replace(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: template
        )
    }
}
