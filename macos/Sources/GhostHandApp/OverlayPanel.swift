import AppKit
import GhostHandCore
import SwiftUI

// MARK: - Overlay panel
//
// Port of GhostHand.App.Windows.PromptPopupWindow. A borderless, always-on-top panel
// that can become key (so it accepts typing) and hosts the SwiftUI prompt view.

@MainActor
final class OverlayModel: ObservableObject {
    @Published var prompt: String = ""
    @Published var status: String = "Press Enter to submit, Esc to cancel"
    @Published var statusIsError: Bool = false
    @Published var targetText: String = "Target: —"
    @Published var isElevated: Bool = false
    @Published var isRunning: Bool = false
    @Published var isListening: Bool = false
}

/// An NSPanel that is allowed to become the key window even though the app is an accessory.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayPanel {
    private let panel: KeyablePanel
    private let model = OverlayModel()
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void
    private weak var speech: SpeechInput?
    private var speechTask: Task<Void, Never>?

    private(set) var currentTarget: AppTarget?

    init(
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        speech: SpeechInput?
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.speech = speech

        let contentRect = NSRect(x: 0, y: 0, width: 560, height: 168)
        panel = KeyablePanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        let view = OverlayView(
            model: model,
            onSubmit: { [weak self] in self?.submit() },
            onCancel: { [weak self] in self?.onCancel() },
            onMic: { [weak self] in self?.toggleListening() }
        )
        panel.contentView = NSHostingView(rootView: view)
    }

    // MARK: - Lifecycle

    func show(target: AppTarget?) {
        currentTarget = target
        resetForNewPrompt(target: target)
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        speechTask?.cancel()
        speechTask = nil
        model.isListening = false
        model.isRunning = false
        panel.orderOut(nil)
    }

    func updateStatus(_ status: String, isError: Bool) {
        model.status = status
        model.statusIsError = isError
    }

    func updateTarget(_ target: AppTarget) {
        currentTarget = target
        setTargetText(target)
    }

    func beginRun(goal: String, target: AppTarget) {
        currentTarget = target
        model.isRunning = true
        model.status = "Running: \(goal)"
        model.statusIsError = false
        panel.makeKeyAndOrderFront(nil)
    }

    func finishRun(message: String, success: Bool) {
        model.isRunning = false
        model.status = (success ? "✓ " : "⚠ ") + message
        model.statusIsError = !success
        if !success {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Give the user a moment to read the success message, then dismiss.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.panel.orderOut(nil)
            }
        }
    }

    // MARK: - Actions

    private func resetForNewPrompt(target: AppTarget?) {
        model.prompt = ""
        model.isRunning = false
        model.isListening = false
        setTargetText(target)
        if target?.isElevated == true {
            model.status = "⚠ Target process may be protected; automation may be restricted."
            model.statusIsError = true
        } else {
            model.status = "Press Enter to submit, Esc to cancel"
            model.statusIsError = false
        }
    }

    private func setTargetText(_ target: AppTarget?) {
        guard let target else {
            model.targetText = "Target: macOS Desktop"
            model.isElevated = false
            return
        }
        let title = target.windowTitle.isBlank ? target.processName : target.windowTitle
        model.targetText = "Target: \(target.processName) — \"\(title)\""
        model.isElevated = target.isElevated
    }

    private func submit() {
        let goal = model.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        onSubmit(goal)
    }

    private func toggleListening() {
        if model.isListening {
            speechTask?.cancel()
            speechTask = nil
            model.isListening = false
            return
        }
        guard let speech else {
            updateStatus("Voice input is not available.", isError: true)
            return
        }

        model.isListening = true
        model.status = "🎙 Listening… speak your command"
        model.statusIsError = false
        speech.onRecognizing = { [weak self] partial in
            Task { @MainActor in
                self?.model.status = "📝 \"\(partial)\""
            }
        }

        speechTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await speech.transcribe()
                await MainActor.run {
                    self.model.isListening = false
                    if !transcript.isBlank {
                        self.model.prompt = transcript
                        self.updateStatus("✓ \"\(transcript)\" — executing…", isError: false)
                    } else if !Task.isCancelled {
                        self.updateStatus("No speech detected. Speak clearly and try again.", isError: true)
                    }
                }
                if !transcript.isBlank {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await MainActor.run { self.submit() }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.model.isListening = false
                    self.updateStatus("Voice recording cancelled.", isError: false)
                }
            } catch {
                await MainActor.run {
                    self.model.isListening = false
                    self.updateStatus("⚠ \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 120
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI content

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @FocusState private var promptFocused: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onMic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.secondary)
                Text(model.targetText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.isElevated {
                    Text("PROTECTED")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            }

            TextField("Tell GhostHand what to do…", text: $model.prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .focused($promptFocused)
                .disabled(model.isRunning)
                .onSubmit(onSubmit)

            HStack(spacing: 10) {
                Text(model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(model.statusIsError ? Color.orange : Color.secondary)
                    .lineLimit(2)
                Spacer()
                Button(action: onMic) {
                    Text(model.isListening ? "⏹ Stop" : "🎤 Mic")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .disabled(model.isRunning)

                Button(action: onCancel) {
                    Text("Close")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)

                Button(action: onSubmit) {
                    Text(model.isRunning ? "Running…" : "Send ↵")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)
            }
        }
        .padding(16)
        .frame(width: 560, height: 168)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(6)
        .onExitCommand(perform: onCancel)
        .onAppear { promptFocused = true }
    }
}
