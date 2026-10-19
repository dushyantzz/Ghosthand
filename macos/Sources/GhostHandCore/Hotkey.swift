import Foundation

// MARK: - RawKeyEvent
//
// Platform-independent raw keyboard event.
//
// macOS mapping note: the Windows build uses the Ctrl + Win chord. macOS has no
// Windows key, so the platform layer maps the chord to Ctrl + Option. `isWin`
// therefore means "the secondary chord modifier" (Option on macOS).

public struct RawKeyEvent: Sendable {
    public static let vkControl: Int = 0x11
    public static let vkLControl: Int = 0xA2
    public static let vkRControl: Int = 0xA3
    public static let vkLWin: Int = 0x5B
    public static let vkRWin: Int = 0x5C
    public static let vkDummySuppression: Int = 0xE8

    public var keyCode: Int
    public var isKeyUp: Bool
    public var isInjected: Bool
    public var timestampMs: Int64

    public init(keyCode: Int, isKeyUp: Bool, isInjected: Bool = false, timestampMs: Int64 = 0) {
        self.keyCode = keyCode
        self.isKeyUp = isKeyUp
        self.isInjected = isInjected
        self.timestampMs = timestampMs
    }

    public var isCtrl: Bool { keyCode == Self.vkControl || keyCode == Self.vkLControl || keyCode == Self.vkRControl }
    public var isWin: Bool { keyCode == Self.vkLWin || keyCode == Self.vkRWin }
    public var isModifier: Bool { isCtrl || isWin }

    public static func keyDown(_ keyCode: Int, isInjected: Bool = false, timestamp: Int64 = 0) -> RawKeyEvent {
        RawKeyEvent(keyCode: keyCode, isKeyUp: false, isInjected: isInjected, timestampMs: timestamp)
    }

    public static func keyUp(_ keyCode: Int, isInjected: Bool = false, timestamp: Int64 = 0) -> RawKeyEvent {
        RawKeyEvent(keyCode: keyCode, isKeyUp: true, isInjected: isInjected, timestampMs: timestamp)
    }
}

// MARK: - ChordStateMachine
//
// Pure, testable state machine for detecting the modifier chord.
// Fires when both modifiers are held and one is released with no other key pressed in between.

public final class ChordStateMachine {
    private var ctrlDown = false
    private var winDown = false
    private var chordArmed = false
    private var interrupted = false

    public static let vkEscape = 0x1B

    public var isRunActive: Bool = false

    public var onTrigger: (() -> Void)?
    public var onCancel: (() -> Void)?

    public init() {}

    public func process(_ event: RawKeyEvent) {
        if event.isInjected { return }
        if !event.isKeyUp {
            handleKeyDown(event)
        } else {
            handleKeyUp(event)
        }
    }

    private func handleKeyDown(_ event: RawKeyEvent) {
        if event.isCtrl {
            if ctrlDown { return } // ignore auto-repeat
            ctrlDown = true
            if winDown && !interrupted { chordArmed = true }
            return
        }
        if event.isWin {
            if winDown { return } // ignore auto-repeat
            winDown = true
            if ctrlDown && !interrupted { chordArmed = true }
            return
        }

        // Intervening non-chord key was pressed while a chord modifier is held.
        // Ordinary typing (no modifier down) must not latch `interrupted`, or the next
        // chord would be silently ignored until a modifier is pressed and released.
        if ctrlDown || winDown {
            interrupted = true
            chordArmed = false
        }

        // Esc while running triggers cancel (kill switch).
        if event.keyCode == Self.vkEscape && isRunActive {
            onCancel?()
        }
    }

    private func handleKeyUp(_ event: RawKeyEvent) {
        if event.isCtrl {
            ctrlDown = false
            checkAndFireChord()
            resetInterruptedIfAllModifiersUp()
            return
        }
        if event.isWin {
            winDown = false
            checkAndFireChord()
            resetInterruptedIfAllModifiersUp()
            return
        }
    }

    private func checkAndFireChord() {
        guard chordArmed && !interrupted else { return }
        chordArmed = false
        if isRunActive {
            onCancel?()
        } else {
            onTrigger?()
        }
    }

    private func resetInterruptedIfAllModifiersUp() {
        if !ctrlDown && !winDown {
            interrupted = false
            chordArmed = false
        }
    }

    public var currentState: (ctrlDown: Bool, winDown: Bool, chordArmed: Bool, interrupted: Bool) {
        (ctrlDown, winDown, chordArmed, interrupted)
    }
}
