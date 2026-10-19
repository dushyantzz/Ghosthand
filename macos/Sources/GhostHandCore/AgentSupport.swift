import CryptoKit
import Foundation

// MARK: - LoopGuard
//
// Port of GhostHand.Core.Agent.LoopGuard. Detects an unchanging screen state so the
// agent cannot spin forever on a page that never updates.

public final class LoopGuard {
    private let maxConsecutiveStalls: Int
    private var lastStateSignature: String?
    private var _consecutiveStalls = 0

    public var consecutiveStalls: Int { _consecutiveStalls }
    public var isStalled: Bool { _consecutiveStalls >= maxConsecutiveStalls }

    public init(maxConsecutiveStalls: Int = 10) {
        self.maxConsecutiveStalls = maxConsecutiveStalls
    }

    /// Returns true when the stall threshold has been reached.
    @discardableResult
    public func recordObservation(_ elements: [AccessibilityElement]) -> Bool {
        let currentSignature = Self.computeSignature(elements)
        if let last = lastStateSignature, currentSignature == last {
            _consecutiveStalls += 1
        } else {
            _consecutiveStalls = 1
        }
        lastStateSignature = currentSignature
        return isStalled
    }

    public func reset() {
        lastStateSignature = nil
        _consecutiveStalls = 0
    }

    private static func computeSignature(_ elements: [AccessibilityElement]) -> String {
        var builder = ""
        for element in elements {
            builder += element.id
            builder += "|"
            builder += element.role
            builder += "|"
            builder += element.displayLabel
            builder += "|"
            builder += element.value
            builder += "|"
            builder += String(element.focused)
            builder += "|"
            builder += String(element.enabled)
            builder += ";"
        }
        let digest = SHA256.hash(data: Data(builder.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - AgentLoopOptions

public struct AgentLoopOptions: Sendable {
    /// 0 = unlimited: runs until the task completes or is cancelled.
    public var maxSteps: Int = 0
    public var dryRun: Bool = true
    public var maxConsecutiveStalls: Int = 15
    public var actionTimeoutSeconds: Int = 10

    public init() {}

    public static func fromEnvironment() -> AgentLoopOptions {
        var options = AgentLoopOptions()
        let env = ProcessInfo.processInfo.environment
        if let raw = env["DRY_RUN"], let value = Bool(raw) {
            options.dryRun = value
        }
        if let raw = env["MAX_STEPS_PER_RUN"], let value = Int(raw) {
            options.maxSteps = value
        }
        return options
    }
}
