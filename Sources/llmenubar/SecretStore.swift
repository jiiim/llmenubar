// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation
import Security

/// The values the app keeps out of its preferences file.
enum Secret: String, CaseIterable, Sendable {
    /// The key clients send to this Mac's server.
    case apiKey = "api-key"
    /// The Hugging Face token for private and gated models.
    case huggingFaceToken = "huggingface-token"
}

/// Where the secrets live. The app uses the login keychain; tests use memory.
protocol SecretStore: AnyObject {
    /// The stored value, or nil when there is none. Throws when the store
    /// cannot answer (a locked keychain, a refused prompt), which is different
    /// from there being nothing stored.
    func read(_ secret: Secret) throws -> String?
    /// Stores `value`; an empty value removes the entry.
    func write(_ value: String, for secret: Secret) throws
}

struct SecretStoreError: Error, LocalizedError, Equatable {
    let status: Int32
    var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "the keychain said: \(text)"
    }
}

enum SecretStores {
    /// The store the app uses. A test process gets memory, so a test run never
    /// touches the keychain of whoever runs it.
    static func standard() -> SecretStore {
        NSClassFromString("XCTestCase") == nil
            ? KeychainSecretStore()
            : MemorySecretStore()
    }
}

/// Generic-password items in the login keychain, one per secret.
///
/// The login keychain is the file-based one, not the data-protection keychain,
/// which needs an entitlement a Developer ID app does not have. An item an app
/// created is readable by that app without a prompt. A build with another
/// signature (an ad hoc build after each rebuild) is another app to the
/// keychain, and macOS asks once before it reads the item.
final class KeychainSecretStore: SecretStore {
    private let service: String

    init(service: String = "com.jiiim.llmenubar") {
        self.service = service
    }

    private func query(_ secret: Secret) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.rawValue,
        ]
    }

    func read(_ secret: Secret) throws -> String? {
        var search = query(secret)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, for secret: Secret) throws {
        if value.isEmpty {
            let status = SecItemDelete(query(secret) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError(status: status)
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(secret) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError(status: update) }
        var add = query(secret)
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }
}

/// Holds the secrets in memory, for tests and for a process that must not
/// touch the keychain.
final class MemorySecretStore: SecretStore {
    private var values: [Secret: String] = [:]
    /// Set by a test to make the store fail.
    var failure: SecretStoreError?

    func read(_ secret: Secret) throws -> String? {
        if let failure { throw failure }
        return values[secret]
    }

    func write(_ value: String, for secret: Secret) throws {
        if let failure { throw failure }
        values[secret] = value.isEmpty ? nil : value
    }
}
