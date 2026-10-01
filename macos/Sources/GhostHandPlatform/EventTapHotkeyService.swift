import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GhostHandCore

// MARK: - EventTapHotkeyService
//
// Swift / CoreGraphics port of GhostHand.Platform.Hotkey.LowLevelKeyboardHook.
//
// The Windows build installs a WH_KEYBOARD_LL hook and forwards raw virtual keys to
// the ported `ChordStateMachine`. Here a CGEventTap plays that role: it listens for
// keyDown/keyUp/flagsChanged at `.cgSessionEventTap`, maps macOS key codes onto the
// sentinel virtual-key space the state machine understands, and feeds it events.
//
// Key mapping: macOS has no Windows key, so the chord is Ctrl + Option (⌥):
//   Control  -> RawKeyEvent.vkControl
//   Option   -> RawKeyEvent.vkLWin
//   Escape   -> ChordStateMachine.vkEscape
//
// Events posted by this process (see GhostHandInjectedEvent) are ignored, so the
// simulator can type into a target without re-triggering the chord.

public final class EventTapHotkeyService: HotkeyService {

    public var onHotkeyPressed: (() -> Void)?
    public var onKillSwitchTriggered: (() -> Void)?

    public let stateMachine: ChordStateMachine

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastFlags: CGEventFlags = []

    /// Modifier key codes are delivered through `flagsChanged`; ignore any duplicate
    /// keyDown/keyUp so they are not mistaken for an intervening non-chord key.
    private static let modifierKeyCodes: Set<Int> = [
        54, 55, // right/left Command
        56, 60, // left/right Shift
        57,      // Caps Lock
        58, 61, // left/right Option
        59, 62, // left/right Control
        63,      // Fn
    ]

    public init() {
        stateMachine = ChordStateMachine()
        stateMachine.onTrigger = { [weak self] in self?.onHotkeyPressed?() }
        stateMachine.onCancel = { [weak self] in self?.onKillSwitchTriggered?() }
    }

    deinit {
        stop()
    }

    // MARK: - HotkeyService

    public func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: ghostHandHotkeyCallback,
            userInfo: refcon
        ) else {
            GhostLog.shared.warning(
                "Failed to create the keyboard event tap. Grant Accessibility permission "
                + "(System Settings > Privacy & Security > Accessibility) and restart GhostHand. "
                + "Global hotkeys are disabled until then."
            )
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        GhostLog.shared.info("Keyboard event tap started (Ctrl+Option chord, Esc kill switch).")
    }

    public func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
        lastFlags = []
        GhostLog.shared.info("Keyboard event tap stopped.")
    }

    // MARK: - Event handling

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables slow taps; re-enable immediately and pass the event on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                GhostLog.shared.warning("Keyboard event tap was disabled by the system; re-enabled.")
            }
            return Unmanaged.passUnretained(event)
        }

        // Never react to our own simulated input.
        guard !GhostHandInjectedEvent.isOurs(event) else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            let flags = event.flags
            let changed = flags.symmetricDifference(lastFlags)
            lastFlags = flags
            handleModifierChanges(changed: changed, now: flags, timestampMs: timestampMs(event))

        case .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard !Self.modifierKeyCodes.contains(code) else { break }
            let mapped = code == Int(CGInputSimulator.escapeKey) ? ChordStateMachine.vkEscape : code
            stateMachine.process(RawKeyEvent(
                keyCode: mapped,
                isKeyUp: type == .keyUp,
                isInjected: false,
                timestampMs: timestampMs(event)
            ))

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleModifierChanges(changed: CGEventFlags, now: CGEventFlags, timestampMs: Int64) {
        if changed.contains(.maskControl) {
            let isDown = now.contains(.maskControl)
            stateMachine.process(RawKeyEvent(
                keyCode: RawKeyEvent.vkControl,
                isKeyUp: !isDown,
                timestampMs: timestampMs
            ))
        }

        if changed.contains(.maskAlternate) {
            let isDown = now.contains(.maskAlternate)
            stateMachine.process(RawKeyEvent(
                keyCode: RawKeyEvent.vkLWin,
                isKeyUp: !isDown,
                timestampMs: timestampMs
            ))
        }
    }

    private func timestampMs(_ event: CGEvent) -> Int64 {
        Int64(event.timestamp / 1_000_000)
    }
}

// MARK: - C callback

private func ghostHandHotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<EventTapHotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handle(type: type, event: event)
}
