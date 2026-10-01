import Foundation
import GhostHandCore
import Security

// MARK: - KeychainCredentialStore
//
// macOS port of GhostHand.Platform.Safety.CredentialStore.
//
// The Windows implementation reads/writes the Windows Credential Manager under the
// target name "GhostHand/AI_GATEWAY_API_KEY". On macOS the equivalent secure store is
// the login Keychain: a `kSecClassGenericPassword` item with service "GhostHand" and
// account "LAYA_API_KEY".
//
// Precedence matches C# exactly: the environment variable wins over the stored
// credential (see CredentialStore.GetApiKey). Laya normally runs locally and needs no
// key at all; this store only exists for a server configured with LAYA_API_KEY.

/// Errors thrown by ``KeychainCredentialStore``.
public enum KeychainCredentialStoreError: Error, LocalizedError, Equatable {
    /// `setApiKey` was called with an empty or whitespace-only value.
    case emptyAPIKey
    /// The Security framework rejected a write/update.
    case keychainFailure(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .emptyAPIKey:
            return "API key cannot be empty."
        case let .keychainFailure(status, message):
            return "Keychain error \(status): \(message)"
        }
    }
}

/// Secure credential storage backed by the macOS Keychain.
///
/// Mirrors `GhostHand.Platform.Safety.CredentialStore`:
/// * `getApiKey()` returns the `LAYA_API_KEY` environment variable first, then the Keychain item.
/// * `hasKey()` is true when the resolved key is non-blank.
/// * `setApiKey(_:)` throws on an empty key.
/// * `deleteApiKey()` is best-effort and never throws.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {

    /// Environment variable that takes precedence over the Keychain.
    public static let environmentVariableName = "LAYA_API_KEY"
    /// Default Keychain service name (the C# target name's "service" half).
    public static let defaultService = "GhostHand"
    /// Default Keychain account name.
    public static let defaultAccount = "LAYA_API_KEY"

    private let service: String
    private let account: String

    public init(
        service: String = KeychainCredentialStore.defaultService,
        account: String = KeychainCredentialStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    // MARK: - CredentialStore

    /// Resolves the API key: environment variable first (C# precedence), then Keychain.
    public func getApiKey() -> String? {
        if let envValue = ProcessInfo.processInfo.environment[Self.environmentVariableName] {
            let trimmed = envValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        guard let stored = readKeychainItem() else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func hasKey() -> Bool {
        guard let key = getApiKey() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Writes the API key to the Keychain as UTF-8 data. Throws on an empty key.
    public func setApiKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainCredentialStoreError.emptyAPIKey }

        let data = Data(trimmed.utf8)
        let updateAttributes: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }

        if status == errSecDuplicateItem {
            // Lost a race with another writer: update instead.
            status = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.keychainFailure(
                status: status,
                message: Self.describe(status)
            )
        }
        GhostLog.shared.debug("KeychainCredentialStore: stored API key for service '\(service)'.")
    }

    /// Best-effort delete: failures are logged, never thrown (matches C# `DeleteApiKey`).
    public func deleteApiKey() {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            GhostLog.shared.warning(
                "KeychainCredentialStore: failed to delete API key (status \(status): \(Self.describe(status)))."
            )
        }
    }

    // MARK: - Keychain plumbing

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readKeychainItem() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            GhostLog.shared.warning(
                "KeychainCredentialStore: failed to read API key (status \(status): \(Self.describe(status)))."
            )
            return nil
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Unknown error"
    }
}
