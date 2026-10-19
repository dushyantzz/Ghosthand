import CoreGraphics
import XCTest
@testable import GhostHandCore

/// Port of `GhostHand.Tests.Agent.AgentLoopTests` EX05's underlying loopGuard behavior plus
/// focused tests for the Swift `LoopGuard` surface.
final class LoopGuardTests: XCTestCase {
    private func elements(_ id: String, label: String = "Search Button") -> [AccessibilityElement] {
        [AccessibilityElement(
            id: id, role: "Button", label: label, enabled: true,
            frame: CGRect(x: 0, y: 0, width: 100, height: 30))]
    }

    func testIdenticalObservationsIncrementStalls_AndTripAtThreshold() {
        let loopGuard = LoopGuard(maxConsecutiveStalls: 3)

        XCTAssertFalse(loopGuard.recordObservation(elements("e1")))
        XCTAssertEqual(loopGuard.consecutiveStalls, 1)
        XCTAssertFalse(loopGuard.isStalled)

        XCTAssertFalse(loopGuard.recordObservation(elements("e1")))
        XCTAssertEqual(loopGuard.consecutiveStalls, 2)
        XCTAssertFalse(loopGuard.isStalled)

        XCTAssertTrue(loopGuard.recordObservation(elements("e1")))
        XCTAssertEqual(loopGuard.consecutiveStalls, 3)
        XCTAssertTrue(loopGuard.isStalled)
    }

    func testChangedObservationResetsTheStallCount() {
        let loopGuard = LoopGuard(maxConsecutiveStalls: 3)

        XCTAssertFalse(loopGuard.recordObservation(elements("e1")))
        XCTAssertFalse(loopGuard.recordObservation(elements("e1")))
        XCTAssertEqual(loopGuard.consecutiveStalls, 2)

        // A different screen signature resets the counter to 1.
        XCTAssertFalse(loopGuard.recordObservation(elements("e2")))
        XCTAssertEqual(loopGuard.consecutiveStalls, 1)
        XCTAssertFalse(loopGuard.isStalled)
    }

    func testResetClearsState() {
        let loopGuard = LoopGuard(maxConsecutiveStalls: 2)

        XCTAssertFalse(loopGuard.recordObservation(elements("e1")))
        XCTAssertTrue(loopGuard.recordObservation(elements("e1")))
        XCTAssertTrue(loopGuard.isStalled)

        loopGuard.reset()
        XCTAssertEqual(loopGuard.consecutiveStalls, 0)
        XCTAssertFalse(loopGuard.isStalled)

        // After reset the next observation starts a fresh sequence.
        XCTAssertFalse(loopGuard.recordObservation(elements("e1")))
        XCTAssertEqual(loopGuard.consecutiveStalls, 1)
    }

    func testThresholdIsConfigurable() {
        let immediate = LoopGuard(maxConsecutiveStalls: 1)
        XCTAssertTrue(immediate.recordObservation(elements("e1")))
        XCTAssertTrue(immediate.isStalled)
    }

    func testChangedLabelsResetButFrameOnlyChangesDoNot() {
        // The signature is built from id/role/label/value/focused/enabled — a frame-only
        // change is still the same observed state.
        let loopGuard = LoopGuard(maxConsecutiveStalls: 2)
        let base = AccessibilityElement(
            id: "e1", role: "Button", label: "Search", enabled: true,
            frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        let moved = AccessibilityElement(
            id: "e1", role: "Button", label: "Search", enabled: true,
            frame: CGRect(x: 300, y: 300, width: 100, height: 30))

        XCTAssertFalse(loopGuard.recordObservation([base]))
        XCTAssertTrue(loopGuard.recordObservation([moved])) // frame change is not a state change

        loopGuard.reset()
        XCTAssertFalse(loopGuard.recordObservation([base]))
        XCTAssertFalse(loopGuard.recordObservation(elements("e1", label: "Different")))
    }
}
