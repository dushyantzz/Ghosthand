import Foundation

// MARK: - LayaOptions
//
// Configuration for the LOCAL Laya decision model. Laya runs on this machine and is
// reached over its `POST /v1/systemone` HTTP protocol (the same wire shape Jev clients
// use, plus Laya's `noul` yes/no question type).
//
// Nothing here talks to the network by default: the default base URL is loopback.

/// Configuration for the local Laya decision model, reachable over its HTTP protocol.
public final class LayaOptions: @unchecked Sendable {
    /// Loopback address of the local Laya server.
    public var baseUrl: String = "http://127.0.0.1:8000"
    /// Checkpoint to force ("english", "multilingual", "typed-decisions").
    /// Empty lets Laya route by language itself (the documented default).
    public var model: String = ""
    /// Optional bearer token; only needed when the server sets LAYA_API_KEY.
    public var apiKey: String?
    /// CPU inference on a large checkpoint takes seconds; allow plenty of headroom.
    public var timeoutSeconds: Int = 120
    public var maxRetries: Int = 2
    /// Token budget for the whole request (state + options).
    public var maxLen: Int = 4096
    /// Token window the choice options share; raised because the agent offers many options.
    public var headMaxLen: Int = 2048
    /// Abstention threshold passed to Laya; 0 disables the low-confidence flag.
    public var minConfidence: Double = 0.0
    /// Maximum options in the next-action choice question (Laya caps a choice at 100).
    public var maxChoiceOptions: Int = 90
    /// Floor for `maxChoiceOptions`: below this the cap would drop every per-element action.
    public static let minimumMaxChoiceOptions = 20
    /// Start the local Laya server automatically when it is not already listening.
    public var autoStartServer: Bool = true
    /// Python interpreter with Laya's dependencies (empty = auto-detect).
    public var pythonPath: String = ""
    /// Local Laya checkout holding the `laya` package and `models/` (empty = auto-detect).
    public var home: String = ""
    /// Directory holding `laya`, `laya-multilingual`, `laya-typed-decisions`.
    public var modelsRoot: String = ""
    /// Path to `laya_serve.py` (empty = bundled resource / repo default).
    public var serveScript: String = ""
    /// Extra seconds to wait for the server to become healthy while checkpoints load.
    public var startupTimeoutSeconds: Int = 240

    /// Creates Laya options populated with the built-in defaults.
    public init() {}

    /// Builds options from `LAYA_*` environment variables, falling back to the defaults.
    public static func fromEnvironment() -> LayaOptions {
        let options = LayaOptions()
        let env = ProcessInfo.processInfo.environment

        if let value = env["LAYA_BASE_URL"], !value.isBlank { options.baseUrl = value.trimmed }
        if let value = env["LAYA_MODEL"], !value.isBlank { options.model = value.trimmed }
        if let value = env["LAYA_API_KEY"], !value.isBlank { options.apiKey = value.trimmed }
        if let value = env["LAYA_PYTHON"], !value.isBlank { options.pythonPath = value.trimmed }
        if let value = env["LAYA_HOME"], !value.isBlank { options.home = value.trimmed }
        if let value = env["LAYA_MODELS_ROOT"], !value.isBlank { options.modelsRoot = value.trimmed }
        if let value = env["LAYA_SERVE_SCRIPT"], !value.isBlank { options.serveScript = value.trimmed }

        if let raw = env["LAYA_TIMEOUT_SECONDS"], let value = Int(raw) { options.timeoutSeconds = value }
        if let raw = env["LAYA_MAX_RETRIES"], let value = Int(raw) { options.maxRetries = value }
        if let raw = env["LAYA_MAX_LEN"], let value = Int(raw) { options.maxLen = value }
        if let raw = env["LAYA_HEAD_MAX_LEN"], let value = Int(raw) { options.headMaxLen = value }
        if let raw = env["LAYA_MAX_CHOICE_OPTIONS"], let value = Int(raw) {
            // Never let a small positive value silently starve the choice question: the cap must
            // leave room for the standard controls plus at least some per-element actions.
            options.maxChoiceOptions = max(LayaOptions.minimumMaxChoiceOptions, value)
        }
        if let raw = env["LAYA_MIN_CONFIDENCE"], let value = Double(raw) { options.minConfidence = value }
        if let raw = env["LAYA_AUTOSTART"], let value = Bool(raw) { options.autoStartServer = value }
        if let raw = env["LAYA_STARTUP_TIMEOUT_SECONDS"], let value = Int(raw) { options.startupTimeoutSeconds = value }

        return options
    }
}

// MARK: - LayaError
//
// Error strings are sanitized so a bearer token can never leak through a message.

/// Error raised by the Laya client, with messages sanitized against token leakage.
public enum LayaError: Error, LocalizedError, CustomStringConvertible {
    case auth(String, statusCode: Int)
    case transient(String, statusCode: Int)
    case proto(String)
    case serverUnavailable(String)

    public var statusCode: Int {
        switch self {
        case .auth(_, let code): return code
        case .transient(_, let code): return code
        case .proto, .serverUnavailable: return 0
        }
    }

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .auth(let message, let code):
            return "Laya authentication failed (HTTP \(code)): \(LayaError.sanitize(message))"
        case .transient(let message, let code):
            return "Laya transient error (HTTP \(code)): \(LayaError.sanitize(message))"
        case .proto(let message):
            return "Laya protocol / serialization error: \(LayaError.sanitize(message))"
        case .serverUnavailable(let message):
            return "Laya server unavailable: \(LayaError.sanitize(message))"
        }
    }

    /// Returns `message` with bearer tokens and Laya/API keys redacted.
    static func sanitize(_ message: String) -> String {
        guard !message.isEmpty else { return message }
        var result = message
        let patterns = [
            (#"(?i)(bearer\s+)([a-zA-Z0-9_\-\.]{8,})"#, "$1[REDACTED]"),
            (#"(vck_[a-zA-Z0-9_\-]{8,})"#, "[REDACTED]"),
            (#"(laya_[a-zA-Z0-9_\-]{8,})"#, "[REDACTED]"),
        ]
        for (pattern, template) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
            }
        }
        return result
    }
}
