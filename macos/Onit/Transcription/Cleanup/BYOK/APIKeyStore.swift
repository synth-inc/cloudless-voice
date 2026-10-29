// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  APIKeyStore.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  Where BYOK API keys live: the macOS Keychain, one generic-password item per
//  provider, and nowhere else (not preferences, logs, Crashlytics or history).
//

import Foundation
import Security

/// Reads and writes API keys by account (one account per provider).
protocol APIKeyStore: AnyObject, Sendable {
    /// The stored key, or nil when there is none or the store can't be read.
    func apiKey(for account: String) -> String?
    /// Stores `key`, or deletes the item when `key` is nil or blank. Returns
    /// whether the store now holds what was asked.
    @discardableResult
    func setAPIKey(_ key: String?, for account: String) -> Bool
}

/// Keychain-backed `APIKeyStore`.
///
/// Every query is non-interactive: a locked keychain or an item whose ACL would
/// need the user's password fails instead of showing a prompt mid-dictation, and
/// the provider then reports that it needs setup.
///
/// Prefers the data-protection keychain (items scoped to this app's signing
/// identity). Builds without a signing entitlement (`CODE_SIGNING_ALLOWED=NO`,
/// some open-source builds) can't use it, and fall back to the login keychain.
final class KeychainAPIKeyStore: APIKeyStore, @unchecked Sendable {
    static let shared = KeychainAPIKeyStore()

    private let service: String
    private let lock = NSLock()
    /// Set once the data-protection keychain reported a missing entitlement.
    private var useLegacyKeychain = false

    init(service: String = "inc.synth.Onit.byokCleanup") {
        self.service = service
    }

    func apiKey(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecMissingEntitlement, switchToLegacyKeychain() {
            query = baseQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
                return nil
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            // Status codes only: never the item.
            log.warning("[byok] keychain read failed: \(status)")
            return nil
        }
    }

    @discardableResult
    func setAPIKey(_ key: String?, for account: String) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let result = trimmed.isEmpty ? delete(account: account) : save(trimmed, account: account)
        if result == errSecMissingEntitlement, switchToLegacyKeychain() {
            let retry = trimmed.isEmpty ? delete(account: account) : save(trimmed, account: account)
            return retry == errSecSuccess
        }
        return result == errSecSuccess
    }

    // MARK: - Private

    private func save(_ key: String, account: String) -> OSStatus {
        let data = Data(key.utf8)
        let query = baseQuery(account: account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.removeValue(forKey: kSecUseAuthenticationUI as String)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Onit cleanup API key (\(account))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log.warning("[byok] keychain write failed: \(status)")
        }
        return status
    }

    private func delete(account: String) -> OSStatus {
        var query = baseQuery(account: account)
        query.removeValue(forKey: kSecUseAuthenticationUI as String)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return errSecSuccess }
        if status != errSecSuccess {
            log.warning("[byok] keychain delete failed: \(status)")
        }
        return status
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Fail rather than prompt (kSecUseAuthenticationUIFail is the only
            // non-interactive option that also covers the login keychain's ACL).
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        lock.lock()
        let legacy = useLegacyKeychain
        lock.unlock()
        if !legacy {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Returns true when this call made the switch (so the caller should retry).
    private func switchToLegacyKeychain() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !useLegacyKeychain else { return false }
        useLegacyKeychain = true
        log.info("[byok] data-protection keychain unavailable (unsigned build); using the login keychain")
        return true
    }
}

/// In-memory `APIKeyStore`, for tests and previews.
final class InMemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]

    init(_ keys: [String: String] = [:]) {
        self.keys = keys
    }

    func apiKey(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[account]
    }

    @discardableResult
    func setAPIKey(_ key: String?, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        keys[account] = trimmed.isEmpty ? nil : trimmed
        return true
    }
}
