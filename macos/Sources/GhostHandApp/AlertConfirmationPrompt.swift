import AppKit
import GhostHandCore

// MARK: - AlertConfirmationPrompt
//
// Port of GhostHand.App.Windows.ConfirmationDialog as a modal NSAlert. Jarvis mode
// never requires confirmation, so this is only reached if the risk policy changes.

final class AlertConfirmationPrompt: ConfirmationPrompt {
    func requestConfirmation(
        decision: AgentDecision,
        target: AccessibilityElement?,
        appTarget: AppTarget,
        reason: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Confirm: \(decision.operation.rawValue)"
                let targetName = target?.displayLabel ?? decision.targetLabel ?? decision.targetId ?? ""
                var details = "Target: \(targetName) (\(target?.displayRole ?? "Control"))\n"
                if let text = decision.textValue, !text.isEmpty {
                    details += "Value: \"\(text)\"\n"
                }
                details += "App: \(appTarget.processName) — \"\(appTarget.windowTitle)\"\n\n"
                details += "Reason: \(reason)"
                alert.informativeText = details
                alert.addButton(withTitle: "Approve")
                alert.addButton(withTitle: "Reject")

                let response = alert.runModal()
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}
