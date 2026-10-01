import AppKit
import GhostHandCore

// MARK: - ApiKeySetupWindow
//
// Port of GhostHand.App.Windows.ApiKeySetupDialog: a first-run window that stores the
// Vercel AI Gateway key in the macOS Keychain and exports it for this process.

@MainActor
final class ApiKeySetupWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let credentialStore: CredentialStore
    private let onClose: () -> Void
    private let keyField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    init(credentialStore: CredentialStore, onClose: @escaping () -> Void) {
        self.credentialStore = credentialStore
        self.onClose = onClose

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "GhostHand — Laya API Key (optional)"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self

        buildContent()
        if let existing = credentialStore.getApiKey(), !existing.isBlank {
            keyField.stringValue = existing
        }
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(keyField)
    }

    private func buildContent() {
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "Laya API key (only if the server sets LAYA_API_KEY)")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: 20, y: 158, width: 420, height: 20)
        content.addSubview(title)

        let hint = NSTextField(labelWithString: "Laya runs locally and normally needs no key. If you set LAYA_API_KEY on the server, paste it here — it is stored in the macOS Keychain.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.frame = NSRect(x: 20, y: 126, width: 420, height: 30)
        content.addSubview(hint)

        keyField.frame = NSRect(x: 20, y: 98, width: 420, height: 24)
        keyField.placeholderString = "LAYA_API_KEY (optional)"
        content.addSubview(keyField)

        statusLabel.frame = NSRect(x: 20, y: 70, width: 420, height: 18)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        content.addSubview(statusLabel)

        let saveButton = NSButton(title: "Save & Connect", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 320, y: 20, width: 120, height: 32)
        content.addSubview(saveButton)

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitClicked))
        quitButton.bezelStyle = .rounded
        quitButton.frame = NSRect(x: 230, y: 20, width: 80, height: 32)
        content.addSubview(quitButton)

        window.contentView = content
    }

    @objc private func saveClicked() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusLabel.stringValue = "⚠️ Please enter a valid API key before saving."
            window.makeFirstResponder(keyField)
            return
        }
        do {
            try credentialStore.setApiKey(key)
            setenv("LAYA_API_KEY", key, 1)
            GhostLog.shared.info("Laya API key saved to the Keychain.")
            close()
        } catch {
            statusLabel.stringValue = "⚠️ Failed to save key: \(error.localizedDescription)"
        }
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    private func close() {
        window.orderOut(nil)
        onClose()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
