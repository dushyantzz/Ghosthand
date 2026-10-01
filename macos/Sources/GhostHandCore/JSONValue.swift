import Foundation

// MARK: - JSONValue
//
// Minimal dynamic-JSON representation used for the "state" object of an
// evaluate request and for the "answers" bag of an evaluate response.
// Shared by the Laya request/response types.

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Bool must be probed before Double: JSONDecoder refuses to decode a
        // number as Bool, and refuses to decode a boolean as Double.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    // MARK: Accessors

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Mirrors `JsonElement.TryGetDouble`: only JSON numbers convert.
    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Mirrors `JsonElement.TryGetInt32`: only JSON numbers convert (truncated).
    public var intValue: Int? {
        guard case .number(let value) = self,
              value.isFinite,
              value >= Double(Int.min),
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public func value(forKey key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Case- and separator-insensitive object lookup, used when decoding the
    /// gateway envelope (Swift Codable has no PropertyNameCaseInsensitive).
    public func value(caseInsensitive key: String) -> JSONValue? {
        guard let object = objectValue else { return nil }
        if let direct = object[key] { return direct }
        let target = key.lowercased().replacingOccurrences(of: "_", with: "")
        for (candidate, value) in object
        where candidate.lowercased().replacingOccurrences(of: "_", with: "") == target {
            return value
        }
        return nil
    }
}

// MARK: - JSONValue literal conveniences
//
// Lets call sites build dynamic state objects with ordinary Swift literals, e.g.
// `let state: JSONValue = ["task": "open notepad", "step": 1]`.

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object: [String: JSONValue] = [:]
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}
