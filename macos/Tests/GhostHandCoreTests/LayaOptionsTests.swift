import XCTest
@testable import GhostHandCore

/// Laya configuration defaults and error-message redaction.
final class LayaOptionsTests: XCTestCase {
    /// Verifies the default options target the loopback server with the local model settings.
    func testDefaultsPointAtLoopbackAndTheLocalModel() {
        let options = LayaOptions()
        XCTAssertEqual(options.baseUrl, "http://127.0.0.1:8000")
        XCTAssertTrue(options.model.isEmpty, "the default lets Laya route by language")
        XCTAssertEqual(options.timeoutSeconds, 120)
        XCTAssertEqual(options.maxRetries, 2)
        XCTAssertEqual(options.maxLen, 4096)
        XCTAssertEqual(options.headMaxLen, 2048)
        XCTAssertEqual(options.maxChoiceOptions, 90)
        XCTAssertTrue(options.autoStartServer)
    }

    /// Verifies the default choice option cap stays within Laya's option limit.
    func testChoiceOptionCapFitsWithinLayaLimits() {
        // Laya refuses a choice question with more than 100 options, and the option texts
        // share the head token budget; the default cap must leave room.
        XCTAssertLessThanOrEqual(LayaOptions().maxChoiceOptions, 100)
    }

    /// Verifies error descriptions redact bearer tokens and API keys.
    func testErrorMessagesRedactSecrets() {
        let bearer = LayaError.auth("Bearer supersecrettokenvalue123", statusCode: 401).description
        XCTAssertFalse(bearer.contains("supersecrettokenvalue123"), bearer)
        XCTAssertTrue(bearer.contains("[REDACTED]"), bearer)

        let key = LayaError.proto("request rejected for laya_abcdefghijklmnop").description
        XCTAssertFalse(key.contains("laya_abcdefghijklmnop"), key)
        XCTAssertTrue(key.contains("[REDACTED]"), key)
    }

    /// Verifies a server-unavailable error keeps its endpoint and reports status zero.
    func testServerUnavailableCarriesNoSecret() {
        let error = LayaError.serverUnavailable("nothing listening at http://127.0.0.1:8000")
        XCTAssertEqual(error.statusCode, 0)
        XCTAssertTrue(error.description.contains("127.0.0.1:8000"))
    }
}
