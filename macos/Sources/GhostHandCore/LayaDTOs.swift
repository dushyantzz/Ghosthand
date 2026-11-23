import Foundation

// MARK: - Laya question / request / response
//
// Wire types for Laya's `POST /v1/systemone`. Laya answers choice / score / noul
// questions over a `state` document; `noul` ("yes-no question") is the yes/no type
// that replaces Jev's `boolean`.

/// A single question posed to Laya: a choice, a score, or a noul (yes/no) question.
public struct LayaQuestion: Codable, Equatable, Sendable {
    public var type: String
    public var instructions: String?
    /// Object for a choice question, array for a score question, nil for noul.
    public var criteria: JSONValue?

    /// Creates a question of the given wire type with optional instructions and criteria.
    public init(type: String, instructions: String? = nil, criteria: JSONValue? = nil) {
        self.type = type
        self.instructions = instructions
        self.criteria = criteria
    }

    /// Creates a choice question whose criteria map option values to display descriptions.
    public static func choice(_ criteria: [String: String], instructions: String? = nil) -> LayaQuestion {
        LayaQuestion(
            type: "choice",
            instructions: instructions,
            criteria: .object(criteria.mapValues { .string($0) })
        )
    }

    /// Creates a yes/no (`noul`) question carrying no criteria.
    public static func noul(_ instructions: String? = nil) -> LayaQuestion {
        LayaQuestion(type: "noul", instructions: instructions, criteria: nil)
    }

    /// Creates a score question from ordered criteria, lowest level first.
    public static func score(_ orderedCriteria: [String], instructions: String? = nil) -> LayaQuestion {
        LayaQuestion(
            type: "score",
            instructions: instructions,
            criteria: .array(orderedCriteria.map { .string($0) })
        )
    }
}

/// A `POST /v1/systemone` request: a state document plus named questions to answer.
public struct LayaRequest: Codable, Equatable, Sendable {
    public var state: JSONValue
    public var questions: [String: LayaQuestion]
    public var model: String?
    public var maxLen: Int?
    public var headMaxLen: Int?
    public var minConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case state, questions, model
        case maxLen = "max_len"
        case headMaxLen = "head_max_len"
        case minConfidence = "min_confidence"
    }

    /// Creates a request with the given state and questions and optional decoding limits.
    public init(
        state: JSONValue,
        questions: [String: LayaQuestion],
        model: String? = nil,
        maxLen: Int? = nil,
        headMaxLen: Int? = nil,
        minConfidence: Double? = nil
    ) {
        self.state = state
        self.questions = questions
        self.model = model
        self.maxLen = maxLen
        self.headMaxLen = headMaxLen
        self.minConfidence = minConfidence
    }
}

/// Token accounting reported by Laya for one request.
public struct LayaUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var stateTokens: Int?
    public var truncated: Bool?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case stateTokens = "state_tokens"
        case truncated
    }

    /// Creates a usage record with any subset of the token counts supplied.
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, stateTokens: Int? = nil, truncated: Bool? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.stateTokens = stateTokens
        self.truncated = truncated
    }
}

/// Snapshot of the Laya server's health endpoint.
public struct LayaHealth: Codable, Equatable, Sendable {
    public var status: String?
    public var device: String?
    public var loaded: [String]?
    public var model: String?

    /// Creates a health snapshot from the server's reported fields.
    public init(status: String? = nil, device: String? = nil, loaded: [String]? = nil, model: String? = nil) {
        self.status = status
        self.device = device
        self.loaded = loaded
        self.model = model
    }

    public var isOK: Bool { (status ?? "").lowercased() == "ok" }
}

/// A decoded `POST /v1/systemone` response holding one answer per requested question.
public struct LayaResponse: Codable, Equatable, Sendable {
    public var model: String?
    public var answers: [String: JSONValue]
    public var usage: LayaUsage?
    public var routing: JSONValue?

    /// Creates a response from decoded answers plus optional model, usage, and routing metadata.
    public init(
        model: String? = nil,
        answers: [String: JSONValue] = [:],
        usage: LayaUsage? = nil,
        routing: JSONValue? = nil
    ) {
        self.model = model
        self.answers = answers
        self.usage = usage
        self.routing = routing
    }

    /// Returns the raw answer for a question, or nil when the server omitted it.
    public func answer(_ questionName: String) -> JSONValue? {
        answers[questionName]
    }

    // MARK: Answer accessors

    /// Choice answer: the argmax option plus the probability distribution.
    /// `confidence` prefers Laya's `answer_confidence` (the mass on the reported answer,
    /// which is the quantity Jev called `confidence`) over the entropy-based `confidence`.
    public func tryGetChoice(
        _ questionName: String
    ) -> (choice: String, confidence: Double, answerConfidence: Double, probabilities: [String: Double])? {
        guard let element = answers[questionName] else { return nil }

        var choice = ""
        if let raw = element.value(forKey: "choice")?.stringValue { choice = raw }

        var probabilities: [String: Double] = [:]
        if let raw = element.value(forKey: "probabilities")?.objectValue {
            for (name, value) in raw {
                if let probability = LayaResponse.asDouble(value) { probabilities[name] = probability }
            }
        }

        guard !choice.isEmpty else { return nil }
        let answerConfidence = LayaResponse.asDouble(element.value(forKey: "answer_confidence"))
            ?? probabilities[choice]
            ?? LayaResponse.asDouble(element.value(forKey: "confidence"))
            ?? 0
        let confidence = LayaResponse.asDouble(element.value(forKey: "confidence")) ?? answerConfidence
        return (choice, confidence, answerConfidence, probabilities)
    }

    /// `noul` (yes/no) answer: `noul` is the probability of the yes option.
    public func tryGetNoul(
        _ questionName: String
    ) -> (probability: Double, isTrue: Bool, answerConfidence: Double)? {
        guard let element = answers[questionName] else { return nil }
        guard let probability = LayaResponse.asDouble(element.value(forKey: "noul")) else { return nil }
        let answerConfidence = LayaResponse.asDouble(element.value(forKey: "answer_confidence"))
            ?? max(probability, 1 - probability)
        return (probability, probability >= 0.5, answerConfidence)
    }

    /// Jev-compatible alias for a yes/no question.
    public func tryGetBooleanAnswer(_ questionName: String) -> (probability: Double, value: Bool)? {
        guard let answer = tryGetNoul(questionName) else { return nil }
        return (answer.probability, answer.isTrue)
    }

    /// Score answer. Laya returns the *expected* level index, which may be fractional,
    /// and a probabilities object keyed "0".."k-1" (Jev returned an array).
    public func tryGetScore(
        _ questionName: String
    ) -> (score: Double, probabilities: [Double], legend: [Int: String])? {
        guard let element = answers[questionName] else { return nil }
        guard let score = LayaResponse.asDouble(element.value(forKey: "score")) else { return nil }

        var probabilities: [Double] = []
        if let raw = element.value(forKey: "probabilities")?.objectValue {
            let indexed = raw.compactMap { key, value -> (Int, Double)? in
                guard let index = Int(key), let probability = LayaResponse.asDouble(value) else { return nil }
                return (index, probability)
            }
            probabilities = indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        var legend: [Int: String] = [:]
        if let raw = element.value(forKey: "legend")?.objectValue {
            for (key, value) in raw {
                if let index = Int(key), let text = value.stringValue { legend[index] = text }
            }
        }

        return (score, probabilities, legend)
    }

    /// Coerces a JSON value to a double, accepting numeric and numeric-string encodings.
    private static func asDouble(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        if let number = value.doubleValue { return number }
        if let text = value.stringValue { return Double(text) }
        return nil
    }
}
