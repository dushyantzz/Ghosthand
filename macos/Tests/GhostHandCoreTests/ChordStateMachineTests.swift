import XCTest
@testable import GhostHandCore

/// Port of `GhostHand.Tests.Hotkey.ChordStateMachineTests` (HK01–HK07) plus focused
/// tests for the Swift state machine's port-only surface.
final class ChordStateMachineTests: XCTestCase {
    private var machine: ChordStateMachine!
    private var triggerCount = 0
    private var cancelCount = 0

    /// Sets up a fresh state machine and resets the trigger and cancel counters.
    override func setUp() {
        super.setUp()
        machine = ChordStateMachine()
        triggerCount = 0
        cancelCount = 0
        machine.onTrigger = { [weak self] in self?.triggerCount += 1 }
        machine.onCancel = { [weak self] in self?.cancelCount += 1 }
    }

    /// Releases the state machine and completes the test teardown.
    override func tearDown() {
        machine = nil
        super.tearDown()
    }

    // MARK: - HK01: both modifier orders fire exactly once

    /// Verifies Ctrl-down then Win-down chords fire exactly once as both keys release.
    func testHK01_ctrlDown_winDown_winUp_ctrlUp_firesExactlyOnce() {
        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLControl))

        XCTAssertEqual(triggerCount, 1)
        XCTAssertEqual(cancelCount, 0)
    }

    /// Verifies Win-down then Ctrl-down chords fire exactly once in the reverse order.
    func testHK01_winDown_ctrlDown_ctrlUp_winUp_firesExactlyOnce() {
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyUp(RawKeyEvent.vkLControl))
        machine.process(.keyUp(RawKeyEvent.vkLWin))

        XCTAssertEqual(triggerCount, 1)
        XCTAssertEqual(cancelCount, 0)
    }

    // MARK: - HK02: an intervening key cancels the chord

    /// Verifies an intervening key press cancels the chord so nothing fires.
    func testHK02_ctrlWinD_interveningKey_doesNotFire() {
        let vkD = 0x44

        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyDown(vkD))
        machine.process(.keyUp(vkD))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLControl))

        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(cancelCount, 0)
    }

    // MARK: - HK03: single modifiers never fire

    /// Verifies pressing and releasing a single modifier alone never fires the chord.
    func testHK03_ctrlAlone_or_winAlone_doesNotFire() {
        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyUp(RawKeyEvent.vkLControl))
        XCTAssertEqual(triggerCount, 0)

        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        XCTAssertEqual(triggerCount, 0)
    }

    // MARK: - HK04: left/right variants both work

    /// Verifies left and right Ctrl and Win variants both arm and fire the chord.
    func testHK04_leftAndRightModifierVariants_bothWork() {
        // Right Ctrl + Left Win
        machine.process(.keyDown(RawKeyEvent.vkRControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkRControl))
        XCTAssertEqual(triggerCount, 1)

        // Left Ctrl + Right Win
        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyDown(RawKeyEvent.vkRWin))
        machine.process(.keyUp(RawKeyEvent.vkRWin))
        machine.process(.keyUp(RawKeyEvent.vkLControl))
        XCTAssertEqual(triggerCount, 2)
    }

    // MARK: - HK05: injected events are ignored

    /// Verifies injected key events are ignored and never fire or cancel.
    func testHK05_injectedEvents_areIgnored() {
        machine.process(.keyDown(RawKeyEvent.vkLControl, isInjected: true))
        machine.process(.keyDown(RawKeyEvent.vkLWin, isInjected: true))
        machine.process(.keyUp(RawKeyEvent.vkLWin, isInjected: true))
        machine.process(.keyUp(RawKeyEvent.vkLControl, isInjected: true))

        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(cancelCount, 0)
    }

    // MARK: - HK06: kill switch while a run is active

    /// Verifies a chord completed while a run is active emits cancel instead of trigger.
    func testHK06_triggerWhileRunActive_emitsCancelNotTrigger() {
        machine.isRunActive = true

        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLControl))

        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

    /// Verifies Escape while a run is active emits cancel and no trigger.
    func testHK06_escapeWhileRunActive_emitsCancel() {
        machine.isRunActive = true

        machine.process(.keyDown(ChordStateMachine.vkEscape))
        machine.process(.keyUp(ChordStateMachine.vkEscape))

        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

    // MARK: - HK07: auto-repeat does not double fire

    /// Verifies auto-repeated modifier key-downs do not double fire the chord.
    func testHK07_keyAutoRepeat_doesNotDoubleFire() {
        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyDown(RawKeyEvent.vkLWin)) // auto-repeat
        machine.process(.keyDown(RawKeyEvent.vkLWin)) // auto-repeat
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLControl))

        XCTAssertEqual(triggerCount, 1)
    }

    // MARK: - HK08: ordinary typing before the chord must not block it

    /// Verifies ordinary typing before a chord leaves state clean and the chord still fires.
    func testHK08_plainKeyBeforeChord_doesNotBlockChord() {
        // Typing with no chord modifier held must not latch `interrupted`.
        machine.process(.keyDown(0x41)) // 'a'
        machine.process(.keyUp(0x41))
        XCTAssertFalse(machine.currentState.interrupted)

        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLControl))

        XCTAssertEqual(triggerCount, 1)
        XCTAssertEqual(cancelCount, 0)
    }

    /// Verifies typing before the kill-switch chord still cancels while a run is active.
    func testHK08_plainKeyBeforeKillSwitchChord_stillCancelsWhileRunning() {
        machine.isRunActive = true

        machine.process(.keyDown(0x41))
        machine.process(.keyUp(0x41))

        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLControl))

        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

    // MARK: - Port-only surface

    /// Verifies the platform-neutral Ctrl key also arms the chord as a Ctrl modifier.
    func testGenericVkControl_alsoCountsAsCtrlModifier() {
        // The C# tests only exercised VkLControl/VkRControl; the Swift constants also
        // expose the platform-neutral `vkControl`.
        machine.process(.keyDown(RawKeyEvent.vkControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkControl))

        XCTAssertEqual(triggerCount, 1)
    }

    /// Verifies Escape while no run is active does not emit a cancel.
    func testEscapeWhileNotRunning_doesNotCancel() {
        machine.isRunActive = false

        machine.process(.keyDown(ChordStateMachine.vkEscape))
        machine.process(.keyUp(ChordStateMachine.vkEscape))

        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(cancelCount, 0)
    }

    /// Verifies injected Escape while a run is active does not emit a cancel.
    func testInjectedEscapeWhileRunning_doesNotCancel() {
        machine.isRunActive = true

        machine.process(.keyDown(ChordStateMachine.vkEscape, isInjected: true))
        machine.process(.keyUp(ChordStateMachine.vkEscape, isInjected: true))

        XCTAssertEqual(cancelCount, 0)
    }

    /// Verifies the exposed state tracks modifier holds, arming, and the interruption latch.
    func testCurrentState_tracksModifiersArmingAndInterruption() {
        XCTAssertFalse(machine.currentState.ctrlDown)
        XCTAssertFalse(machine.currentState.winDown)

        machine.process(.keyDown(RawKeyEvent.vkLControl))
        XCTAssertTrue(machine.currentState.ctrlDown)
        XCTAssertFalse(machine.currentState.chordArmed)

        machine.process(.keyDown(RawKeyEvent.vkLWin))
        XCTAssertTrue(machine.currentState.winDown)
        XCTAssertTrue(machine.currentState.chordArmed)
        XCTAssertFalse(machine.currentState.interrupted)

        // Intervening key marks the chord interrupted and disarms it.
        machine.process(.keyDown(0x44))
        XCTAssertFalse(machine.currentState.chordArmed)
        XCTAssertTrue(machine.currentState.interrupted)

        // Releasing every modifier clears the interruption latch.
        machine.process(.keyUp(0x44))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLControl))
        XCTAssertFalse(machine.currentState.interrupted)
        XCTAssertFalse(machine.currentState.chordArmed)
    }

    /// Verifies an armed chord fires once and does not fire again without re-arming.
    func testChordDoesNotRefireWithoutRearming() {
        // A single armed chord fires once; a second release with no new chording does not.
        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        XCTAssertEqual(triggerCount, 1)

        machine.process(.keyUp(RawKeyEvent.vkLControl))
        XCTAssertEqual(triggerCount, 1)
    }
}
