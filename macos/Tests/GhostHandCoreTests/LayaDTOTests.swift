import XCTest
@testable import GhostHandCore

/// Wire-format tests for the Laya `/v1/systemone` request and response types.
final class LayaDTOTests: XCTestCase {
    // MARK: - Request encoding

    func testRequestEncodesLayaSchema() throws {
        let request = LayaRequest(
            state: ["goal": "search for Adele", "app": "Safari"],
            questions: [
                "goalAchieved": .noul("Has the task finished?"),
                "nextAction": .choice([
                    "type:e1:Adele": "Type Adele into the search field",
                    "done": "Task is finished",
                ]),
                "actionRisk": .score(["harmless", "reversible edit", "irreversible or external effect"]),
            ],
            model: "english",
            maxLen: 4096,
            headMaxLen: 2048,
            minConfidence: 0.25
        )

        let data = try JSONEncoder().encode(request)
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")

        XCTAssertTrue(json.contains("\"state\":{"), json)
        XCTAssertTrue(json.contains("\"questions\":{"), json)
        XCTAssertTrue(json.contains("\"model\":\"english\""), json)
        // Laya's HTTP controls are snake_case.
        XCTAssertTrue(json.contains("\"max_len\":4096"), json)
        XCTAssertTrue(json.contains("\"head_max_len\":2048"), json)
        XCTAssertTrue(json.contains("\"min_confidence\":0.25"), json)
        XCTAssertTrue(json.contains("\"type\":\"noul\""), json)
        XCTAssertTrue(json.contains("\"type\":\"choice\""), json)
        XCTAssertTrue(json.contains("\"type\":\"score\""), json)
    }

    func testNoulQuestionHasNoCriteria() throws {
        let data = try JSONEncoder().encode(LayaQuestion.noul("Is it done?"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "noul")
        XCTAssertEqual(object?["instructions"] as? String, "Is it done?")
        XCTAssertNil(object?["criteria"])
    }

    func testChoiceCriteriaIsAnObject_andScoreCriteriaIsAnArray() throws {
        let choice = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LayaQuestion.choice(["a": "Option A"]))) as? [String: Any]
        XCTAssertNotNil(choice?["criteria"] as? [String: Any])

        let score = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LayaQuestion.score(["low", "high"]))) as? [String: Any]
        XCTAssertEqual((score?["criteria"] as? [String])?.count, 2)
    }

    // MARK: - Response parsing

    private let responseJSON = """
    {
        "model": "laya-rl-agent",
        "answers": {
            "goalAchieved": {"type": "noul", "noul": 0.88, "confidence": 0.88, "answer_confidence": 0.88},
            "nextAction": {
                "type": "choice",
                "choice": "click:e2",
                "probabilities": {"click:e2": 0.91, "press:enter": 0.09},
                "confidence": 0.31,
                "answer_confidence": 0.91
            },
            "actionRisk": {
                "type": "score",
                "score": 1.7,
                "legend": {"0": "harmless", "1": "reversible edit", "2": "irreversible or external effect"},
                "probabilities": {"0": 0.10, "1": 0.85, "2": 0.05},
                "confidence": 0.40,
                "answer_confidence": 0.85
            }
        },
        "usage": {"input_tokens": 120, "output_tokens": 0, "state_tokens": 40, "truncated": false},
        "routing": {"model": "english", "reason": "English Latin text"}
    }
    """

    func testNoulChoiceAndScoreAnswersParse() throws {
        let response = try JSONDecoder().decode(LayaResponse.self, from: Data(responseJSON.utf8))

        let noul = response.tryGetNoul("goalAchieved")
        XCTAssertNotNil(noul)
        XCTAssertEqual(noul?.probability ?? 0, 0.88, accuracy: 0.0001)
        XCTAssertEqual(noul?.isTrue, true)

        let choice = response.tryGetChoice("nextAction")
        XCTAssertEqual(choice?.choice, "click:e2")
        // Answer confidence (mass on the reported answer) is preferred over entropy confidence.
        XCTAssertEqual(choice?.answerConfidence ?? 0, 0.91, accuracy: 0.0001)
        XCTAssertEqual(choice?.probabilities["press:enter"] ?? 0, 0.09, accuracy: 0.0001)

        let score = response.tryGetScore("actionRisk")
        XCTAssertEqual(score?.score ?? 0, 1.7, accuracy: 0.0001)
        XCTAssertEqual(score?.probabilities, [0.10, 0.85, 0.05])
        XCTAssertEqual(score?.legend[2], "irreversible or external effect")
    }

    func testJevCompatibleBooleanAccessorMapsOntoNoul() throws {
        let response = try JSONDecoder().decode(LayaResponse.self, from: Data(responseJSON.utf8))
        let boolean = response.tryGetBooleanAnswer("goalAchieved")
        XCTAssertEqual(boolean?.value, true)
        XCTAssertEqual(boolean?.probability ?? 0, 0.88, accuracy: 0.0001)
    }

    func testNoulIsFalseBelowHalf() throws {
        let response = try JSONDecoder().decode(
            LayaResponse.self, from: Data(#"{"answers":{"done":{"noul":0.49}}}"#.utf8))
        XCTAssertEqual(response.tryGetNoul("done")?.isTrue, false)
    }

    func testMissingAnswersReturnNil() throws {
        let response = try JSONDecoder().decode(LayaResponse.self, from: Data(#"{"answers":{}}"#.utf8))
        XCTAssertNil(response.tryGetNoul("missing"))
        XCTAssertNil(response.tryGetChoice("missing"))
        XCTAssertNil(response.tryGetScore("missing"))
    }

    func testChoiceWithoutAChoiceStringReturnsNil() throws {
        let response = try JSONDecoder().decode(
            LayaResponse.self, from: Data(#"{"answers":{"next":{"probabilities":{"a":0.9}}}}"#.utf8))
        XCTAssertNil(response.tryGetChoice("next"))
    }

    func testScoreAcceptsNumericStringAndFallsBackToConfidence() throws {
        let response = try JSONDecoder().decode(
            LayaResponse.self, from: Data(#"{"answers":{"risk":{"score":"2","probabilities":{"0":0.1,"1":0.2,"2":0.7}}}}"#.utf8))
        XCTAssertEqual(response.tryGetScore("risk")?.score ?? 0, 2.0, accuracy: 0.0001)
        XCTAssertEqual(response.tryGetScore("risk")?.probabilities.count, 3)
    }

    func testRoutingAndUsageDecode() throws {
        let response = try JSONDecoder().decode(LayaResponse.self, from: Data(responseJSON.utf8))
        XCTAssertEqual(response.usage?.inputTokens, 120)
        XCTAssertEqual(response.usage?.stateTokens, 40)
        XCTAssertEqual(response.routing?.value(forKey: "model")?.stringValue, "english")
    }

    func testHealthDecodes() throws {
        let health = try JSONDecoder().decode(
            LayaHealth.self,
            from: Data(#"{"status":"ok","loaded":["english"],"device":"cpu"}"#.utf8))
        XCTAssertTrue(health.isOK)
        XCTAssertEqual(health.device, "cpu")
        XCTAssertEqual(health.loaded, ["english"])
    }

    // MARK: - JSONValue

    func testJSONValueAccessors() {
        XCTAssertEqual(JSONValue.string("x").stringValue, "x")
        XCTAssertEqual(JSONValue.number(2.5).doubleValue, 2.5)
        XCTAssertEqual(JSONValue.number(2.0).intValue, 2)
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
        XCTAssertTrue(JSONValue.null.isNull)
        XCTAssertNil(JSONValue.string("x").doubleValue)

        let object: JSONValue = ["a": 1, "b": true]
        XCTAssertEqual(object.value(forKey: "a")?.intValue, 1)
        XCTAssertEqual(object.value(caseInsensitive: "A")?.intValue, 1)
    }

    func testJSONValueRoundTrips() throws {
        let value: JSONValue = ["nested": ["list": [1, 2, 3], "flag": false]]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }
}
