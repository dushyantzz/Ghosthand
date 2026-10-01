import AppKit
import GhostHandCore
import GhostHandPlatform

// MARK: - StatusBarController
//
// Menu-bar presence for GhostHand (replaces the Windows system-tray icon).
// Keeps the app reachable without a Dock icon.

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let onActivate: () -> Void
    private let onSetApiKey: () -> Void
    private let onGrantAccessibility: () -> Void
    private let onToggleLogging: (Bool) -> Void
    private let onRevealLog: () -> Void
    private let onQuit: () -> Void
    private var runningItem: NSMenuItem?
    private var loggingItem: NSMenuItem?

    init(
        onActivate: @escaping () -> Void,
        onSetApiKey: @escaping () -> Void,
        onGrantAccessibility: @escaping () -> Void,
        onToggleLogging: @escaping (Bool) -> Void,
        onRevealLog: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onActivate = onActivate
        self.onSetApiKey = onSetApiKey
        self.onGrantAccessibility = onGrantAccessibility
        self.onToggleLogging = onToggleLogging
        self.onRevealLog = onRevealLog
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

        // Reachable from the menu bar on purpose: if Accessibility is missing the global hotkey
        // cannot fire, so the menu is the only way the user can repair it.
        let grant = NSMenuItem(
            title: "Grant Accessibility Permission…",
            action: #selector(grantAccessibilityClicked),
            keyEquivalent: ""
        )
        grant.target = self
        menu.addItem(grant)

        let setKey = NSMenuItem(title: "Set Laya API Key…", action: #selector(setKeyClicked), keyEquivalent: "")
        setKey.target = self
        menu.addItem(setKey)

        menu.addItem(.separator())

        // Diagnostics: the toggle survives relaunches so a crash can still be traced afterwards.
        let logging = NSMenuItem(
            title: "Verbose Logging (debug)",
            action: #selector(toggleLoggingClicked),
            keyEquivalent: ""
        )
        logging.target = self
        logging.state = DiagnosticLogging.isEnabled ? .on : .off
        logging.toolTip = "Writes debug detail to \(DiagnosticLogging.logFileURL.path)"
        menu.addItem(logging)
        loggingItem = logging

        let reveal = NSMenuItem(
            title: "Reveal Log in Finder",
            action: #selector(revealLogClicked),
            keyEquivalent: ""
        )
        reveal.target = self
        menu.addItem(reveal)

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
    @objc private func grantAccessibilityClicked() { onGrantAccessibility() }
    @objc private func revealLogClicked() { onRevealLog() }
    @objc private func quitClicked() { onQuit() }

    @objc private func toggleLoggingClicked() {
        let enable = loggingItem?.state != .on
        loggingItem?.state = enable ? .on : .off
        onToggleLogging(enable)
    }
}
