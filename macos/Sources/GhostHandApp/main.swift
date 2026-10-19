import AppKit
import GhostHandCore
import GhostHandPlatform

// GhostHand for macOS — menu-bar application entry point (port of GhostHand.App).
//
// The app runs as an accessory (no Dock icon). Pressing the activation chord
// (Ctrl + Option by default) shows the prompt overlay; Ctrl + Option again, Esc,
// or the menu-bar Quit item cancels a run.

// Keep URLSession from writing a disk cache outside the app sandbox.
URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
