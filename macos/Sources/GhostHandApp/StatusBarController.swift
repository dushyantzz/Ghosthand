import AppKit
import GhostHandCore

// MARK: - StatusBarController
//
// Menu-bar presence for GhostHand (replaces the Windows system-tray icon).
// Keeps the app reachable without a Dock icon.

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let onActivate: () -> Void
    private let onSetApiKey: () -> Void
    private let onQuit: () -> Void
    private var runningItem: NSMenuItem?

    init(
        onActivate: @escaping () -> Void,
        onSetApiKey: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onActivate = onActivate
        self.onSetApiKey = onSetApiKey
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "hand.raised.fill",
                accessibilityDescription: "GhostHand"
            )
            button.image?.isTemplate = true
            button.toolTip = "GhostHand — press Control + Option to activate"
        }

        let menu = NSMenu()
        let activate = NSMenuItem(title: "Open GhostHand  (⌃⌥)", action: #selector(activateClicked), keyEquivalent: "")
        activate.target = self
        menu.addItem(activate)

        let running = NSMenuItem(title: "Running…", action: nil, keyEquivalent: "")
        running.isEnabled = false
        running.isHidden = true
        menu.addItem(running)
        runningItem = running

        menu.addItem(.separator())

        let setKey = NSMenuItem(title: "Set Laya API Key…", action: #selector(setKeyClicked), keyEquivalent: "")
        setKey.target = self
        menu.addItem(setKey)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit GhostHand", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func setRunning(_ running: Bool) {
        runningItem?.isHidden = !running
        statusItem.button?.image = NSImage(
            systemSymbolName: running ? "hand.raised.slash.fill" : "hand.raised.fill",
            accessibilityDescription: running ? "GhostHand running" : "GhostHand idle"
        )
        statusItem.button?.image?.isTemplate = true
    }

    @objc private func activateClicked() { onActivate() }
    @objc private func setKeyClicked() { onSetApiKey() }
    @objc private func quitClicked() { onQuit() }
}
