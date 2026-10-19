import Foundation
import GhostHandCore

// MARK: - ConsoleConfirmationPrompt
//
// Port of GhostHand.Cli.ConsoleConfirmationPrompt: prints the pending action and asks
// the human to approve it. Only reachable if a future risk policy re-enables confirmation
// (Jarvis mode never asks).

public final class ConsoleConfirmationPrompt: ConfirmationPrompt {
    private let autoApprove: Bool?

    public init(autoApprove: Bool? = nil) {
        self.autoApprove = autoApprove
    }

    public func requestConfirmation(
        decision: AgentDecision,
        target: AccessibilityElement?,
        appTarget: AppTarget,
        reason: String
    ) async -> Bool {
        Console.yellow("\n================================================================================")
        Console.yellow("                       SAFETY CONFIRMATION REQUIRED                             ")
        Console.yellow("================================================================================")
        print("Action:     \(decision.operation.rawValue)")
        let targetName = target?.displayLabel ?? decision.targetLabel ?? decision.targetId ?? ""
        print("Target:     \(targetName) (\(target?.displayRole ?? "Control"))")
        if let text = decision.textValue, !text.isEmpty {
            print("Value:      \"\(text)\"")
        }
        print("App:        \(appTarget.processName) — \"\(appTarget.windowTitle)\"")
        Console.red("Reason:     \(reason)")
        print("--------------------------------------------------------------------------------")

        if let autoApprove {
            print("Automated response: \(autoApprove ? "Y (auto)" : "N (auto)")\n")
            return autoApprove
        }

        Console.cyan("Do you approve executing this action? [Y/N] (Default: N): ", terminator: "")
        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let approved = input == "y" || input == "yes"
        print(approved ? "Action APPROVED by human.\n" : "Action REJECTED by human.\n")
        return approved
    }
}

// MARK: - Console helpers

public enum Console {
    public static func red(_ text: String, terminator: String = "\n") { write(text, 31, terminator) }
    public static func green(_ text: String, terminator: String = "\n") { write(text, 32, terminator) }
    public static func yellow(_ text: String, terminator: String = "\n") { write(text, 33, terminator) }
    public static func cyan(_ text: String, terminator: String = "\n") { write(text, 36, terminator) }
    public static func gray(_ text: String, terminator: String = "\n") { write(text, 90, terminator) }
    public static func bold(_ text: String, terminator: String = "\n") { write(text, 1, terminator) }

    private static func write(_ text: String, _ code: Int, _ terminator: String) {
        if isatty(STDOUT_FILENO) == 1 {
            print("\u{001B}[\(code)m\(text)\u{001B}[0m", terminator: terminator)
        } else {
            print(text, terminator: terminator)
        }
    }
}
