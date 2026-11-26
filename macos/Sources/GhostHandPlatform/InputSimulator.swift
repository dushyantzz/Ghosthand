import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GhostHandCore

// MARK: - Injected-event marker
//
// Every event this process posts is stamped with a magic `eventSourceUserData` value.
// EventTapHotkeyService checks it (plus the source process id) so simulated input can
// never re-trigger the global chord.

enum GhostHandInjectedEvent {
    /// "GHND" + protocol version.
    static let magic: Int64 = 0x4748_4E44_0001

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: magic)
    }

    static func isOurs(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == magic { return true }
        let sourcePid = event.getIntegerValueField(.eventSourceUnixProcessID)
        return sourcePid != 0 && sourcePid == Int64(getpid())
    }
}

// MARK: - CGInputSimulator
//
// Swift / CoreGraphics port of GhostHand.Platform.Execution.InputSimulator.
// All input is posted to `.cghidEventTap`, the closest macOS analogue of SendInput.

public enum CGInputSimulator {

    // MARK: Key codes

    public static let returnKey: CGKeyCode = 36
    public static let tabKey: CGKeyCode = 48
    public static let spaceKey: CGKeyCode = 49
    public static let deleteKey: CGKeyCode = 51
    public static let escapeKey: CGKeyCode = 53
    public static let keyA: CGKeyCode = 0

    /// NX_KEYTYPE_PLAY — system-defined media key.
    private static let nxKeyTypePlay: Int32 = 16

    // MARK: Mouse

    public static func click(x: Int, y: Int) {
        click(point: CGPoint(x: x, y: y))
    }

    public static func click(point: CGPoint) {
        // Match the Windows SetCursorPos behaviour before the button events.
        CGWarpMouseCursorPosition(point)

        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }

        GhostHandInjectedEvent.mark(down)
        GhostHandInjectedEvent.mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Negative wheel deltas scroll down, matching the Windows
    /// `MOUSEEVENTF_WHEEL` convention with a small line-based magnitude.
    public static func scroll(down: Bool, at point: CGPoint? = nil) {
        let delta: Int32 = down ? -3 : 3
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else { return }

        if let point { event.location = point }
        GhostHandInjectedEvent.mark(event)
        event.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    public static func typeText(_ text: String) {
        guard !text.isEmpty else { return }

        // Unicode keyboard events avoid touching the user's clipboard.
        for character in text {
            let units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }

            // A preceding shortcut must not turn Unicode input into a shortcut.
            down.flags = []
            up.flags = []
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
            }
            GhostHandInjectedEvent.mark(down)
            GhostHandInjectedEvent.mark(up)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    public static func sendKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return }

        down.flags = flags
        up.flags = flags
        GhostHandInjectedEvent.mark(down)
        GhostHandInjectedEvent.mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    public static func sendChord(modifier: CGKeyCode, key: CGKeyCode) {
        guard let modifierDown = CGEvent(keyboardEventSource: nil, virtualKey: modifier, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false),
              let modifierUp = CGEvent(keyboardEventSource: nil, virtualKey: modifier, keyDown: false) else {
            return
        }

        let events = [modifierDown, keyDown, keyUp, modifierUp]
        for event in events { GhostHandInjectedEvent.mark(event) }
        for event in events { event.post(tap: .cghidEventTap) }
    }

    /// Select all (⌘A) then clear (Backspace). Windows used Ctrl+A + Backspace.
    public static func selectAllAndClear() {
        sendKey(keyA, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.03)
        sendKey(deleteKey)
        Thread.sleep(forTimeInterval: 0.03)
    }

    /// Port of the Windows `VK_MEDIA_PLAY_PAUSE` key: an NX_SYSDEFINED event.
    public static func pressMediaPlay() {
        sendSystemDefinedKey(nxKeyTypePlay)
    }

    // MARK: System-defined media key

    private static func sendSystemDefinedKey(_ key: Int32) {
        // NX_KEYDOWN = 0x0A, NX_KEYUP = 0x0B; data1 = (key << 16) | (state << 8).
        for isDown in [true, false] {
            let state = isDown ? 0x0A : 0x0B
            let data1 = (Int(key) << 16) | (state << 8)
            guard let nsEvent = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                data1: data1,
                data2: -1
            ), let cgEvent = nsEvent.cgEvent else { continue }

            GhostHandInjectedEvent.mark(cgEvent)
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}
