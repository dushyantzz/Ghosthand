import XCTest
@testable import GhostHandCore

/// Port of `GhostHand.Tests.Hotkey.ChordStateMachineTests` (HK01–HK07) plus focused
/// tests for the Swift state machine's port-only surface.
final class ChordStateMachineTests: XCTestCase {
    private var machine: ChordStateMachine!
    private var triggerCount = 0
    private var cancelCount = 0

    override func setUp() {
        super.setUp()
        machine = ChordStateMachine()
        triggerCount = 0
        cancelCount = 0
        machine.onTrigger = { [weak self] in self?.triggerCount += 1 }
        machine.onCancel = { [weak self] in self?.cancelCount += 1 }
    }

    override func tearDown() {
        machine = nil
        super.tearDown()
    }

    // MARK: - HK01: both modifier orders fire exactly once

    func testHK01_ctrlDown_winDown_winUp_ctrlUp_firesExactlyOnce() {
        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLControl))

        XCTAssertEqual(triggerCount, 1)
        XCTAssertEqual(cancelCount, 0)
    }

    func testHK01_winDown_ctrlDown_ctrlUp_winUp_firesExactlyOnce() {
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyUp(RawKeyEvent.vkLControl))
        machine.process(.keyUp(RawKeyEvent.vkLWin))

        XCTAssertEqual(triggerCount, 1)
        XCTAssertEqual(cancelCount, 0)
    }

    // MARK: - HK02: an intervening key cancels the chord

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

    func testHK03_ctrlAlone_or_winAlone_doesNotFire() {
        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyUp(RawKeyEvent.vkLControl))
        XCTAssertEqual(triggerCount, 0)

        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        XCTAssertEqual(triggerCount, 0)
    }

    // MARK: - HK04: left/right variants both work

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

    func testHK05_injectedEvents_areIgnored() {
        machine.process(.keyDown(RawKeyEvent.vkLControl, isInjected: true))
        machine.process(.keyDown(RawKeyEvent.vkLWin, isInjected: true))
        machine.process(.keyUp(RawKeyEvent.vkLWin, isInjected: true))
        machine.process(.keyUp(RawKeyEvent.vkLControl, isInjected: true))

        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(cancelCount, 0)
    }

    // MARK: - HK06: kill switch while a run is active

    func testHK06_triggerWhileRunActive_emitsCancelNotTrigger() {
        machine.isRunActive = true

        machine.process(.keyDown(RawKeyEvent.vkLControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLControl))

        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

    func testHK06_escapeWhileRunActive_emitsCancel() {
        machine.isRunActive = true

        machine.process(.keyDown(ChordStateMachine.vkEscape))
        machine.process(.keyUp(ChordStateMachine.vkEscape))

        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

    // MARK: - HK07: auto-repeat does not double fire

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

    func testGenericVkControl_alsoCountsAsCtrlModifier() {
        // The C# tests only exercised VkLControl/VkRControl; the Swift constants also
        // expose the platform-neutral `vkControl`.
        machine.process(.keyDown(RawKeyEvent.vkControl))
        machine.process(.keyDown(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkLWin))
        machine.process(.keyUp(RawKeyEvent.vkControl))

        XCTAssertEqual(triggerCount, 1)
    }

    func testEscapeWhileNotRunning_doesNotCancel() {
        machine.isRunActive = false

        machine.process(.keyDown(ChordStateMachine.vkEscape))
        machine.process(.keyUp(ChordStateMachine.vkEscape))

        XCTAssertEqual(triggerCount, 0)
        XCTAssertEqual(cancelCount, 0)
    }

    func testInjectedEscapeWhileRunning_doesNotCancel() {
        machine.isRunActive = true

        machine.process(.keyDown(ChordStateMachine.vkEscape, isInjected: true))
        machine.process(.keyUp(ChordStateMachine.vkEscape, isInjected: true))

        XCTAssertEqual(cancelCount, 0)
    }

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
