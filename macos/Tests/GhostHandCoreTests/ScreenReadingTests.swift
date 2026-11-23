import CoreGraphics
import XCTest
@testable import GhostHandCore

// MARK: - SecretSanitizer

/// Port of the pure parts of `GhostHand.Tests.ScreenReading.ScreenReaderTests` (RD03) plus
/// coverage for every pattern the Swift sanitizer recognises.
final class SecretSanitizerTests: XCTestCase {
    /// Verifies password-flagged fields always sanitize to the password placeholder.
    func testPasswordFields_AlwaysBecomePasswordPlaceholder() {
        XCTAssertEqual(SecretSanitizer.sanitize("SuperSecretP@ssword123!", isPassword: true), "[PASSWORD]")
        // The password flag wins even over an empty string.
        XCTAssertEqual(SecretSanitizer.sanitize("", isPassword: true), "[PASSWORD]")
        XCTAssertEqual(SecretSanitizer.sanitize(nil, isPassword: true), "[PASSWORD]")
    }

    /// Verifies credit card numbers are redacted in separated, dashed, and compact forms.
    func testCreditCardNumbers_AreRedacted() {
        let separated = "Please bill credit card 4111 2222 3333 4444 for $50"
        let sanitizedSeparated = SecretSanitizer.sanitize(separated)
        XCTAssertFalse(sanitizedSeparated.contains("4111 2222 3333 4444"))
        XCTAssertTrue(sanitizedSeparated.contains("[REDACTED_CARD]"))

        let dashed = "card=4532-0150-1234-5678"
        let sanitizedDashed = SecretSanitizer.sanitize(dashed)
        XCTAssertFalse(sanitizedDashed.contains("4532-0150-1234-5678"))
        XCTAssertTrue(sanitizedDashed.contains("[REDACTED_CARD]"))

        let compact = "4111222233334444"
        XCTAssertEqual(SecretSanitizer.sanitize(compact), "[REDACTED_CARD]")
    }

    /// Verifies API key patterns are redacted from surrounding text.
    func testApiKeys_AreRedacted() {
        let samples = [
            "vck_dummy_test_key_sample1234567890abcdef",
            "sk-abcdefghijklmnopqrstuvwxyz0123456789",
            "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        ]

        for secret in samples {
            let text = "Gateway token is \(secret) ok"
            let sanitized = SecretSanitizer.sanitize(text)
            XCTAssertFalse(sanitized.contains(secret), "Secret leaked: \(secret)")
            XCTAssertTrue(sanitized.contains("[REDACTED_KEY]"))
        }
    }

    /// Verifies a JWT is redacted as an API key.
    func testJwt_IsRedacted() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let sanitized = SecretSanitizer.sanitize("auth=\(jwt)")

        XCTAssertFalse(sanitized.contains(jwt))
        XCTAssertTrue(sanitized.contains("[REDACTED_KEY]"))
    }

    /// Verifies bearer tokens are redacted while the Bearer scheme is preserved.
    func testBearerTokens_AreRedacted_KeepingTheScheme() {
        let token = "my_secret_token_1234567890_abcdef"
        let sanitized = SecretSanitizer.sanitize("Authorization: Bearer \(token)")

        XCTAssertFalse(sanitized.contains(token))
        XCTAssertTrue(sanitized.contains("Bearer [REDACTED]"))
    }

    /// Verifies a whole PEM private-key block is redacted, body included.
    func testPemPrivateKeys_AreFullyRedacted() {
        // The key body — not just the BEGIN marker — must be removed, or the secret survives
        // redaction in the model prompt and the audit log.
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAsecretkeymaterial\n-----END RSA PRIVATE KEY-----"
        let sanitized = SecretSanitizer.sanitize("key:\n\(pem)\ndone")

        XCTAssertFalse(sanitized.contains("MIIEowIBAAKCAQEAsecretkeymaterial"))
        XCTAssertFalse(sanitized.contains("BEGIN RSA PRIVATE KEY"))
        XCTAssertFalse(sanitized.contains("END RSA PRIVATE KEY"))
        XCTAssertTrue(sanitized.contains("[REDACTED_PRIVATE_KEY]"))
    }

    /// Verifies ordinary text passes through the sanitizer unchanged.
    func testOrdinaryText_IsUntouched() {
        let text = "Submit Application Form for Alice Smith"
        XCTAssertEqual(SecretSanitizer.sanitize(text), text)
    }

    /// Verifies nil and empty input both sanitize to an empty string.
    func testNilAndEmptyText_ReturnEmptyString() {
        XCTAssertEqual(SecretSanitizer.sanitize(nil), "")
        XCTAssertEqual(SecretSanitizer.sanitize(""), "")
    }
}

// MARK: - ElementRanker

/// Port of `GhostHand.Tests.ScreenReading.ScreenReaderTests` RD02/RD04 plus focused tests
/// for the port-only canonical-role map.
final class ElementRankerTests: XCTestCase {
    /// Builds screen reader options with the given node, candidate, and filter settings.
    private func options(
        maxNodes: Int = 500,
        maxCandidates: Int = 40,
        filterOffscreen: Bool = true,
        filterDisabled: Bool = false
    ) -> ScreenReaderOptions {
        var options = ScreenReaderOptions()
        options.maxNodes = maxNodes
        options.maxCandidates = maxCandidates
        options.filterOffscreen = filterOffscreen
        options.filterDisabled = filterDisabled
        return options
    }

    /// Builds an accessibility element with the given identity, role, and attributes.
    private func element(
        _ id: String,
        role: String,
        label: String = "",
        value: String = "",
        enabled: Bool = true,
        focused: Bool = false,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 30)
    ) -> AccessibilityElement {
        AccessibilityElement(
            id: id, role: role, label: label, value: value,
            enabled: enabled, focused: focused, frame: frame)
    }

    // MARK: Canonical role mapping

    /// Verifies canonical role mapping passes Windows names through and maps macOS AX names.
    func testCanonicalRole_MapsWindowsAndMacOSRoleNames() {
        // Windows UIA names pass through unchanged.
        XCTAssertEqual(ElementRanker.canonicalRole("Button"), "Button")
        XCTAssertEqual(ElementRanker.canonicalRole("Edit"), "Edit")
        XCTAssertEqual(ElementRanker.canonicalRole("MenuItem"), "MenuItem")

        // macOS AX names map to the canonical Windows names.
        XCTAssertEqual(ElementRanker.canonicalRole("AXButton"), "Button")
        XCTAssertEqual(ElementRanker.canonicalRole("AXTextField"), "Edit")
        XCTAssertEqual(ElementRanker.canonicalRole("AXTextArea"), "Edit")
        XCTAssertEqual(ElementRanker.canonicalRole("AXSearchField"), "Edit")
        XCTAssertEqual(ElementRanker.canonicalRole("AXLink"), "Hyperlink")
        XCTAssertEqual(ElementRanker.canonicalRole("AXCheckBox"), "CheckBox")
        XCTAssertEqual(ElementRanker.canonicalRole("AXSwitch"), "CheckBox")
        XCTAssertEqual(ElementRanker.canonicalRole("AXRadioButton"), "RadioButton")
        XCTAssertEqual(ElementRanker.canonicalRole("AXPopUpButton"), "ComboBox")
        XCTAssertEqual(ElementRanker.canonicalRole("AXMenuItem"), "MenuItem")
        XCTAssertEqual(ElementRanker.canonicalRole("AXStaticText"), "Text")
    }

    /// Verifies an unrecognized AX role prefix is stripped and plain roles pass through.
    func testCanonicalRole_StripsUnknownAxPrefix() {
        XCTAssertEqual(ElementRanker.canonicalRole("AXCustomThing"), "CustomThing")
        XCTAssertEqual(ElementRanker.canonicalRole("PlainRole"), "PlainRole")
    }

    /// Verifies interactive detection recognizes both platform role names.
    func testIsInteractive_RecognizesBothPlatformRoleNames() {
        XCTAssertTrue(ElementRanker.isInteractive("Button"))
        XCTAssertTrue(ElementRanker.isInteractive("Edit"))
        XCTAssertTrue(ElementRanker.isInteractive("AXButton"))
        XCTAssertTrue(ElementRanker.isInteractive("AXTextField"))
        XCTAssertTrue(ElementRanker.isInteractive("AXLink"))

        XCTAssertFalse(ElementRanker.isInteractive("Text"))
        XCTAssertFalse(ElementRanker.isInteractive("AXStaticText"))
    }

    // MARK: rankAndFilter ordering

    /// Verifies ranking puts focused elements first, then interactive ones, with fresh ids.
    func testRankAndFilter_PutsFocusedFirstThenInteractive() {
        let focusedText = element("focused_text", role: "AXStaticText", label: "Focused note", focused: true,
                                  frame: CGRect(x: 0, y: 200, width: 100, height: 30))
        let button = element("button", role: "Button", label: "Go",
                             frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        let edit = element("edit", role: "Edit", label: "Search",
                           frame: CGRect(x: 0, y: 50, width: 100, height: 30))

        let ranked = ElementRanker.rankAndFilter([button, edit, focusedText], options: options())

        XCTAssertEqual(ranked.map(\.role), ["AXStaticText", "Button", "Edit"])
        XCTAssertEqual(ranked.map(\.id), ["e1", "e2", "e3"])
    }

    /// Verifies ranking assigns sequential ids and caps the candidate count.
    func testRankAndFilter_AssignsSequentialIdsAndCapsCandidates() {
        let elements = (0..<10).map {
            element("raw_\($0)", role: "Button", label: "Item \($0)",
                    frame: CGRect(x: 0, y: 10 * $0, width: 50, height: 20))
        }

        let ranked = ElementRanker.rankAndFilter(elements, options: options(maxCandidates: 3))

        XCTAssertEqual(ranked.count, 3)
        XCTAssertEqual(ranked.map(\.id), ["e1", "e2", "e3"])
    }

    /// Verifies ranking drops zero-size frames while keeping negative origins.
    func testRankAndFilter_DropsZeroSizeFrames() {
        let elements = [
            element("visible", role: "Button", label: "Visible", frame: CGRect(x: 10, y: 10, width: 100, height: 30)),
            element("zero", role: "Button", label: "Zero Size", frame: .zero),
            element("negative_origin", role: "Button", label: "Negative Origin",
                    frame: CGRect(x: -100, y: -100, width: 50, height: 20)),
        ]

        let ranked = ElementRanker.rankAndFilter(elements, options: options())

        XCTAssertFalse(ranked.contains { $0.label == "Zero Size" })
        XCTAssertTrue(ranked.contains { $0.label == "Visible" })
        XCTAssertTrue(ranked.contains { $0.label == "Negative Origin" })
    }

    /// Verifies disabled and offscreen filters apply only when requested.
    func testRankAndFilter_FiltersDisabledWhenRequested() {
        let elements = [
            element("on1", role: "Button", label: "Visible Button"),
            element("dis1", role: "Button", label: "Disabled Button", enabled: false),
        ]

        let offscreenOnly = ElementRanker.rankAndFilter(
            elements, options: options(filterOffscreen: true, filterDisabled: false))
        XCTAssertTrue(offscreenOnly.contains { $0.label == "Visible Button" })
        XCTAssertTrue(offscreenOnly.contains { $0.label == "Disabled Button" })

        let disabledOnly = ElementRanker.rankAndFilter(
            elements, options: options(filterOffscreen: false, filterDisabled: true))
        XCTAssertTrue(disabledOnly.contains { $0.label == "Visible Button" })
        XCTAssertFalse(disabledOnly.contains { $0.label == "Disabled Button" })
    }

    /// Verifies ranking respects the maximum node cap.
    func testRankAndFilter_RespectsMaxNodes() {
        let elements = (0..<10).map {
            element("raw_\($0)", role: "Button", label: "Item \($0)")
        }

        let ranked = ElementRanker.rankAndFilter(elements, options: options(maxNodes: 4, maxCandidates: 40))
        XCTAssertEqual(ranked.count, 4)
    }

    // MARK: RD02 determinism / node cap

    /// Verifies the node cap holds and identical inputs produce identical ids and metadata.
    func testRD02_NodeCap_Enforced_And_IdsStableAcrossIdenticalInputs() {
        var rawElements: [AccessibilityElement] = []
        for i in 0..<600 {
            let role = (i % 3 == 0) ? "Button" : (i % 3 == 1) ? "Edit" : "Text"
            rawElements.append(element(
                "raw_\(i)",
                role: role,
                label: "Item \(i)",
                frame: CGRect(x: 10 + (i % 20) * 10, y: 10 + (i / 20) * 10, width: 50, height: 20)))
        }

        let opts = options(maxNodes: 500, maxCandidates: 40)

        let run1 = ElementRanker.rankAndFilter(rawElements, options: opts)
        XCTAssertEqual(run1.count, 40)
        XCTAssertEqual(run1.first?.id, "e1")
        XCTAssertEqual(run1.last?.id, "e40")

        let run2 = ElementRanker.rankAndFilter(rawElements, options: opts)
        XCTAssertEqual(run2.count, 40)
        for i in 0..<run1.count {
            XCTAssertEqual(run2[i].id, run1[i].id)
            XCTAssertEqual(run2[i].label, run1[i].label)
            XCTAssertEqual(run2[i].role, run1[i].role)
            XCTAssertEqual(run2[i].frame, run1[i].frame)
        }
    }
}
