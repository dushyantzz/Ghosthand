import XCTest
@testable import GhostHandCore

/// Deterministic grounding (candidate/phrase extraction, URL validation) plus the
/// decision-mapping flow through a fake Laya client. No network, no UI.
final class LayaDecisionModelTests: XCTestCase {
    // MARK: - AL08: candidate phrase extraction

    /// Verifies candidate phrase extraction pulls search and write terms from each goal.
    func testAL08_extractCandidatePhrases_extractsSearchAndWriteTerms() {
        let cases: [(goal: String, expected: String)] = [
            ("open brave and search lion", "lion"),
            ("search about lion", "lion"),
            ("open chrome and search for weather", "weather"),
            ("write hello into notepad", "hello"),
            ("open spotify and play any song of aditya rikhari", "aditya rikhari"),
            ("play aditya rikhari on spotify", "aditya rikhari"),
            ("listen to Bohemian Rhapsody", "Bohemian Rhapsody"),
        ]
        for (goal, expected) in cases {
            let candidates = LayaDecisionModel.extractCandidatePhrases(goal)
            XCTAssertTrue(candidates.contains(expected),
                          "Goal '\(goal)' did not yield '\(expected)'; got \(candidates)")
        }
    }

    /// Verifies candidate phrase extraction keeps quoted text and arithmetic expressions.
    func testExtractCandidatePhrases_extractsQuotedTextAndCalculations() {
        XCTAssertTrue(LayaDecisionModel.extractCandidatePhrases("write \"Hello World\" into notepad")
            .contains("Hello World"))
        XCTAssertTrue(LayaDecisionModel.extractCandidatePhrases("calculate 5 + 5").contains("5 + 5"))
    }

    // MARK: - AL04: app-launch candidates and explicit URLs

    /// Verifies app-launch candidates include the app name and explicit URLs are extracted.
    func testAL04_candidateChoices_includeOpenAppAndOpenUrl() {
        let appCandidates = LayaDecisionModel.extractAppLaunchCandidates("open obsidian")
        XCTAssertTrue(appCandidates.contains { $0.lowercased() == "obsidian" })

        let urlCandidates = UrlLauncherValidator.extractWebURLs(from: "open https://news.ycombinator.com")
        XCTAssertEqual(urlCandidates.first?.host, "news.ycombinator.com")
    }

    /// Verifies app-launch extraction ignores UI stop words and empty goals.
    func testExtractAppLaunchCandidates_ignoresUiStopWords() {
        XCTAssertTrue(LayaDecisionModel.extractAppLaunchCandidates("open menu").isEmpty)
        XCTAssertTrue(LayaDecisionModel.extractAppLaunchCandidates("").isEmpty)
    }

    // MARK: - EX07: URL validation

    /// Verifies URL validation accepts http and https and rejects unsafe or unknown schemes.
    func testEX07_urlValidator_acceptsHttpAndHttps_rejectsOthers() {
        XCTAssertEqual(UrlLauncherValidator.isValidWebURL("https://news.ycombinator.com")?.host, "news.ycombinator.com")
        XCTAssertEqual(UrlLauncherValidator.isValidWebURL("http://localhost:3000/dashboard")?.scheme, "http")

        for raw in ["file:///C:/Windows/System32/cmd.exe", "javascript:alert(1)", "cmd.exe /c calc",
                    "ftp://ftp.example.com", "data:text/html,<html></html>", ""] {
            XCTAssertNil(UrlLauncherValidator.isValidWebURL(raw), "Expected '\(raw)' to be rejected")
        }
    }

    /// Verifies URL extraction finds each URL and strips trailing punctuation.
    func testEX07_extractWebUrls_extractsAndStripsPunctuation() {
        let prompt = "Please navigate to https://github.com/dushyantzz/Ghosthand and also check http://example.com/api."
        let extracted = UrlLauncherValidator.extractWebURLs(from: prompt)
        XCTAssertEqual(extracted.count, 2)
        XCTAssertEqual(extracted[0].absoluteString, "https://github.com/dushyantzz/Ghosthand")
        XCTAssertEqual(extracted[1].absoluteString, "http://example.com/api")
    }

    // MARK: - AL06 / AL10 / AL11: synthesized search URLs

    /// Verifies search and site intents synthesize URLs with the expected host and query.
    func testAL06_synthesizesWebSearchesAndSites() {
        let cases: [(goal: String, host: String, queryFragment: String)] = [
            ("search for Adele on youtube", "youtube.com", "Adele"),
            ("search for quantum computing on google", "google.com", "quantum"),
            ("google current weather", "google.com", "weather"),
            ("open brave and search lion", "google.com", "lion"),
            ("search about lion", "google.com", "lion"),
            ("search lion in brave", "google.com", "lion"),
            ("open github.com", "github.com", ""),
            ("visit wikipedia.org", "wikipedia.org", ""),
        ]
        for (goal, expectedHost, expectedQueryFragment) in cases {
            let urls = UrlLauncherValidator.extractWebURLs(from: goal)
            XCTAssertFalse(urls.isEmpty, "No URL synthesized for '\(goal)'")
            guard let url = urls.first else { continue }
            XCTAssertTrue(url.host?.contains(expectedHost) ?? false,
                          "Goal '\(goal)' produced host '\(url.host ?? "nil")', expected '\(expectedHost)'")
            if !expectedQueryFragment.isEmpty {
                XCTAssertTrue(url.query?.contains(expectedQueryFragment) ?? false,
                              "Goal '\(goal)' produced query '\(url.query ?? "nil")', expected '\(expectedQueryFragment)'")
            }
        }
    }

    /// Verifies a music intent synthesizes a Spotify search URL.
    func testAL10_synthesizesSpotifySearchUrl_forMusicIntent() {
        let urls = UrlLauncherValidator.extractWebURLs(from: "open spotify and play any song of aditya rikhari")
        XCTAssertTrue(urls.contains { ($0.host?.contains("spotify.com") ?? false) && $0.path.contains("search") },
                      "Got URLs: \(urls)")
    }

    /// Verifies a chained platform intent synthesizes the platform search URL.
    func testAL11_synthesizesChainedPlatformSearchUrl() {
        let urls = UrlLauncherValidator.extractWebURLs(
            from: "open brave and search for youtube and search honey singh songs")
        XCTAssertTrue(urls.contains { ($0.host?.contains("youtube.com") ?? false) && ($0.query?.contains("honey") ?? false) },
                      "Got URLs: \(urls)")
    }

    // MARK: - Candidate choices

    /// Verifies candidate choices include element, standard, and app-launch options.
    func testBuildCandidateChoices_includeElementsStandardsAndAppLaunch() {
        let choices = LayaDecisionModel.buildCandidateChoices(
            goal: "open obsidian",
            elements: [AccessibilityElement(id: "btn1", role: "Button", label: "Search")])

        XCTAssertNotNil(choices["click:btn1"])
        XCTAssertNotNil(choices["press:enter"])
        XCTAssertNotNil(choices["done"])
        XCTAssertNotNil(choices["open_app:obsidian"])
    }

    /// Verifies capping preserves control options and trims element choices to the limit.
    func testCapCandidateChoices_keepsControlsAndCapsElementOptions() {
        var choices: [String: String] = [:]
        for index in 1...50 { choices["click:e\(index)"] = "Click element e\(index)" }
        choices["press:enter"] = "Press Enter"
        choices["done"] = "Finished"
        choices["ask_user"] = "Ask the user"
        choices["open_app:obsidian"] = "Launch Obsidian"

        let capped = LayaDecisionModel.capCandidateChoices(choices, limit: 10)
        XCTAssertEqual(capped.count, 10)
        // Control/standard options survive; per-element options fill the remaining room.
        XCTAssertNotNil(capped["press:enter"])
        XCTAssertNotNil(capped["done"])
        XCTAssertNotNil(capped["ask_user"])
        XCTAssertNotNil(capped["open_app:obsidian"])
    }

    /// Verifies candidate choices pass through unchanged when already under the limit.
    func testCapCandidateChoices_isANoOpUnderTheLimit() {
        let choices = ["click:e1": "Click", "done": "Finished"]
        XCTAssertEqual(LayaDecisionModel.capCandidateChoices(choices, limit: 90), choices)
    }

    // MARK: - Element IDs containing the key delimiter

    /// Verifies an element id containing a colon survives typing keys through encode and parse.
    func testColonInElementId_roundTripsThroughTypedActionKeys() throws {
        // A `:` in the element id would otherwise be read back as the id/text delimiter,
        // so it must survive encoding in the key and decoding in the parser.
        let element = AccessibilityElement(id: "field:1", role: "Edit", label: "Search")
        let choices = LayaDecisionModel.buildCandidateChoices(
            goal: "write hello into the search field", elements: [element])

        let typeKey = try XCTUnwrap(
            choices.keys.first { $0.hasPrefix("type:") && !$0.hasPrefix("type_and_enter:") })
        let enterKey = try XCTUnwrap(choices.keys.first { $0.hasPrefix("type_and_enter:") })
        XCTAssertTrue(typeKey.contains("%3A"), "Expected the id delimiter to be encoded: \(typeKey)")

        let typed = LayaDecisionModel.parseActionDecision(typeKey, confidence: 0.9, elements: [element])
        XCTAssertEqual(typed.operation, .typeText)
        XCTAssertEqual(typed.targetId, "field:1")
        XCTAssertEqual(typed.targetLabel, "Search")
        XCTAssertFalse(typed.textValue?.isEmpty ?? true)

        let entered = LayaDecisionModel.parseActionDecision(enterKey, confidence: 0.9, elements: [element])
        XCTAssertEqual(entered.operation, .typeAndEnter)
        XCTAssertEqual(entered.targetId, "field:1")
        XCTAssertEqual(entered.targetLabel, "Search")
        XCTAssertFalse(entered.textValue?.isEmpty ?? true)
    }

    /// Verifies a plain element id keeps the legacy typing key format.
    func testElementIdWithoutDelimiter_keepsLegacyKeyFormat() {
        let element = AccessibilityElement(id: "e1", role: "Edit", label: "Search")
        let choices = LayaDecisionModel.buildCandidateChoices(
            goal: "write hello into notepad", elements: [element])

        XCTAssertTrue(choices.keys.contains { $0.hasPrefix("type:e1:") },
                      "Expected an unchanged key for a plain id; got \(choices.keys.filter { $0.hasPrefix("type") })")
        XCTAssertTrue(choices.keys.contains { $0.hasPrefix("type_and_enter:e1:") })
    }

    /// Verifies element id encoding escapes colons and percent signs and decodes back exactly.
    func testEncodeDecodeElementId_handlesPercentAndColon() {
        XCTAssertEqual(LayaDecisionModel.encodeElementId("e1"), "e1")
        XCTAssertEqual(LayaDecisionModel.encodeElementId("a:b"), "a%3Ab")
        XCTAssertEqual(LayaDecisionModel.encodeElementId("100%"), "100%25")
        for raw in ["e1", "field:1", "a:b:c", "100%", "%3A", "a%3Ab"] {
            XCTAssertEqual(LayaDecisionModel.decodeElementId(LayaDecisionModel.encodeElementId(raw)), raw)
        }
    }

    // MARK: - Decision mapping through a fake Laya client (no network)

    /// Verifies the top action executes even at low confidence with a correctly shaped request.
    func testExecutesTopAction_evenWithLowConfidence() async throws {
        let response = try Self.decode(#"""
        {
            "answers": {
                "nextAction": {
                    "type": "choice",
                    "choice": "click:btn1",
                    "probabilities": {"click:btn1": 0.45, "press:enter": 0.35, "done": 0.20},
                    "answer_confidence": 0.45
                },
                "goalAchieved": {"type": "noul", "noul": 0.10}
            }
        }
        """#)
        let client = FakeLayaClient(response: response)
        let model = LayaDecisionModel(client: client, options: LayaOptions())

        let target = AppTarget(processId: 1234, processName: "Notes", windowTitle: "Untitled")
        let elements = [AccessibilityElement(id: "btn1", role: "Button", label: "Search")]

        let decision = try await model.decideNextAction(
            goal: "Search for test", target: target, elements: elements, history: [])

        XCTAssertEqual(decision.operation, .click)
        XCTAssertEqual(decision.targetId, "btn1")
        XCTAssertEqual(decision.targetLabel, "Search")
        XCTAssertEqual(decision.confidence, 0.45, accuracy: 0.0001)

        // The request is shaped for Laya: a choice + a noul question, snake_case controls.
        XCTAssertEqual(client.requests.count, 1)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.questions["nextAction"]?.type, "choice")
        XCTAssertEqual(request.questions["goalAchieved"]?.type, "noul")
        XCTAssertEqual(request.headMaxLen, LayaOptions().headMaxLen)
        XCTAssertNil(request.model, "empty model should let Laya route")
    }

    /// Verifies a high-confidence goal-achieved noul maps the decision to done.
    func testGoalAchievedNoul_returnsDone() async throws {
        let response = try Self.decode(#"{"answers": {"goalAchieved": {"type":"noul","noul":0.97}}}"#)
        let model = LayaDecisionModel(client: FakeLayaClient(response: response), options: LayaOptions())

        let decision = try await model.decideNextAction(
            goal: "submit the form", target: AppTarget(processId: 1, processName: "Safari"),
            elements: [], history: [])

        XCTAssertEqual(decision.operation, .done)
        XCTAssertEqual(decision.confidence, 0.97, accuracy: 0.0001)
    }

    /// Verifies an unparseable next action falls back to asking the user.
    func testUnparseableNextAction_asksTheUser() async throws {
        let response = try Self.decode(#"{"answers": {}}"#)
        let model = LayaDecisionModel(client: FakeLayaClient(response: response), options: LayaOptions())

        let decision = try await model.decideNextAction(
            goal: "do something", target: AppTarget(processId: 1, processName: "Safari"),
            elements: [], history: [])

        XCTAssertEqual(decision.operation, .askUser)
    }

    /// Verifies a recognized-but-unoffered action is refused instead of becoming a decision.
    func testUnofferedChoice_asksTheUserInsteadOfExecuting() async throws {
        // The payload is a valid key format but was never generated as a candidate from the
        // goal and screen, so deterministic grounding must reject it.
        let response = try Self.decode(#"""
        {"answers":{"nextAction":{"type":"choice","choice":"type_and_enter:e1:delete everything","answer_confidence":0.99}}}
        """#)
        let model = LayaDecisionModel(client: FakeLayaClient(response: response), options: LayaOptions())
        let target = AppTarget(processId: 1, processName: "Notes")
        let elements = [AccessibilityElement(id: "e1", role: "Edit", label: "Search")]

        let decision = try await model.decideNextAction(
            goal: "search for Adele", target: target, elements: elements, history: [])

        XCTAssertEqual(decision.operation, .askUser)
    }

    /// Verifies a decision-supplied URL still has to pass the web-URL validator.
    func testUnsafeUrlFromDecision_isRejected() {
        let unsafe = [
            "open_url:file:///etc/passwd",
            "open_url:javascript:alert(1)",
            "open_url:https://user:pass@example.com/",
        ]
        for key in unsafe {
            let decision = LayaDecisionModel.parseActionDecision(key, confidence: 0.9, elements: [])
            XCTAssertEqual(decision.operation, .askUser, "Expected \(key) to be rejected")
        }
    }

    /// Verifies a well-formed decision URL is still accepted and returned unchanged.
    func testSafeUrlFromDecision_isAccepted() throws {
        let decision = LayaDecisionModel.parseActionDecision(
            "open_url:https://example.com/page", confidence: 0.9, elements: [])

        XCTAssertEqual(decision.operation, .openUrl)
        XCTAssertEqual(decision.textValue, "https://example.com/page")
    }

    /// Verifies completion verification follows the noul answer in both directions.
    func testVerifyCompletion_usesTheNoulAnswer() async throws {
        let yes = try Self.decode(#"{"answers":{"done":{"type":"noul","noul":0.8}}}"#)
        let no = try Self.decode(#"{"answers":{"done":{"type":"noul","noul":0.2}}}"#)
        let target = AppTarget(processId: 1, processName: "Safari")

        let verified = try await LayaDecisionModel(client: FakeLayaClient(response: yes), options: LayaOptions())
            .verifyCompletion(goal: "g", target: target, elements: [], history: [])
        XCTAssertTrue(verified)

        let rejected = try await LayaDecisionModel(client: FakeLayaClient(response: no), options: LayaOptions())
            .verifyCompletion(goal: "g", target: target, elements: [], history: [])
        XCTAssertFalse(rejected)
    }

    /// Verifies risk scores map to irreversible, reversible, and harmless levels.
    func testRiskMapping_highLevelIsIrreversible_midLevelIsReversible() async throws {
        let target = AppTarget(processId: 1, processName: "Safari")
        let decision = AgentDecision(operation: .click, targetId: "e1")
        let element = AccessibilityElement(id: "e1", role: "Button", label: "Buy now")

        let high = try Self.decode(#"""
        {"answers":{"actionRisk":{"type":"score","score":2.9,"probabilities":{"0":0.01,"1":0.04,"2":0.95}}}}
        """#)
        let highScore = try await LayaDecisionModel(client: FakeLayaClient(response: high), options: LayaOptions())
            .evaluateActionRisk(goal: "buy", target: target, decision: decision, targetElement: element)
        XCTAssertEqual(highScore, .irreversibleOrExternalEffect)

        let mid = try Self.decode(#"""
        {"answers":{"actionRisk":{"type":"score","score":1.4,"probabilities":{"0":0.05,"1":0.90,"2":0.05}}}}
        """#)
        let midScore = try await LayaDecisionModel(client: FakeLayaClient(response: mid), options: LayaOptions())
            .evaluateActionRisk(goal: "edit", target: target, decision: decision, targetElement: element)
        XCTAssertEqual(midScore, .reversibleEdit)

        let low = try Self.decode(#"""
        {"answers":{"actionRisk":{"type":"score","score":0.1,"probabilities":{"0":0.95,"1":0.04,"2":0.01}}}}
        """#)
        let lowScore = try await LayaDecisionModel(client: FakeLayaClient(response: low), options: LayaOptions())
            .evaluateActionRisk(goal: "scroll", target: target, decision: decision, targetElement: element)
        XCTAssertEqual(lowScore, .harmless)
    }

    /// Verifies control-flow actions are harmless without calling the Laya client.
    func testControlFlowActionsAreHarmlessWithoutACall() async throws {
        let client = FakeLayaClient(response: try Self.decode(#"{"answers":{}}"#))
        let model = LayaDecisionModel(client: client, options: LayaOptions())
        let target = AppTarget(processId: 1, processName: "Safari")

        for operation in [AgentOperation.done, .askUser, .wait] {
            let score = try await model.evaluateActionRisk(
                goal: "g", target: target, decision: AgentDecision(operation: operation), targetElement: nil)
            XCTAssertEqual(score, .harmless)
        }
        XCTAssertTrue(client.requests.isEmpty, "control-flow actions should not call Laya")
    }

    /// Decodes a Laya response from the given JSON string.
    private static func decode(_ json: String) throws -> LayaResponse {
        try JSONDecoder().decode(LayaResponse.self, from: Data(json.utf8))
    }
}

/// A Laya client stub that records requests and replays a canned response.
private final class FakeLayaClient: LayaClientProtocol {
    private let response: LayaResponse
    private(set) var requests: [LayaRequest] = []

    /// Creates a fake client that returns the given response for every request.
    init(response: LayaResponse) {
        self.response = response
    }

    /// Records the request and returns the canned response.
    func decide(_ request: LayaRequest) async throws -> LayaResponse {
        requests.append(request)
        return response
    }
}
