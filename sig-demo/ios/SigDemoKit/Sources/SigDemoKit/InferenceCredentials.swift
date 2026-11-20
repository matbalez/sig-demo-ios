// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

public enum SigDemoInferenceCredential: String, CaseIterable, Sendable {
    case openAI
    case braveSearch

    var maximumBytes: Int { self == .openAI ? 4_096 : 1_024 }
}

public enum SigDemoInferenceCredentialError: Error, Equatable, Sendable {
    case invalidScope
    case invalidCredential
    case unavailable
    case unsupportedPlatform
}

public struct SigDemoInferenceCredentialAvailability: Equatable, Sendable {
    public let openAI: Bool
    public let braveSearch: Bool
}

/// Local storage only: never provisions a key, calls a provider, or contacts the
/// invite server. The caller must supply the current registered account and the
/// canonical public deployment configuration hash used for account isolation.
/// Retrieval deliberately returns the secret only to the native inference
/// adapter; do not place it in messages, preferences, logs, or model payloads.
public struct SigDemoInferenceCredentialStore: Sendable, CustomStringConvertible {
    private let service: String
    private let accountNamespace: String
    private let storage: any SigDemoInferenceCredentialStorage
    public var description: String { "SigDemoInferenceCredentialStore(<redacted>)" }

    public init(accountID: UUID, deploymentID: String, identity: SigDemoAppIdentity) throws {
        try identity.validateCurrentProcess()
        try self.init(accountID: accountID, deploymentID: deploymentID,
                      identity: identity, storage: SigDemoInferenceKeychainStorage())
    }

    init(accountID: UUID, deploymentID: String, identity: SigDemoAppIdentity,
         storage: any SigDemoInferenceCredentialStorage) throws {
        guard deploymentID.utf8.count == 64,
              deploymentID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SigDemoInferenceCredentialError.invalidScope
        }
        self.service = identity.bundleIdentifier + ".inference-credentials.v1"
        #if canImport(CryptoKit)
        let scope = "sig-demo-inference-credentials-v1\0" + deploymentID + "\0" + accountID.uuidString.lowercased()
        accountNamespace = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        throw SigDemoInferenceCredentialError.unsupportedPlatform
        #endif
        self.storage = storage
    }

    public func credential(for provider: SigDemoInferenceCredential) throws -> String? {
        guard let data = try storage.read(service: service, account: account(provider)) else { return nil }
        guard let value = String(data: data, encoding: .utf8), Self.valid(value, for: provider) else {
            throw SigDemoInferenceCredentialError.invalidCredential
        }
        return value
    }

    /// nil removes only this provider's key in this account/deployment scope.
    /// An invalid replacement leaves the previous valid item intact.
    public func setCredential(_ value: String?, for provider: SigDemoInferenceCredential) throws {
        guard let value else {
            try storage.remove(service: service, account: account(provider))
            return
        }
        guard Self.valid(value, for: provider) else { throw SigDemoInferenceCredentialError.invalidCredential }
        try storage.write(Data(value.utf8), service: service, account: account(provider))
    }

    public func availability() throws -> SigDemoInferenceCredentialAvailability {
        try SigDemoInferenceCredentialAvailability(openAI: credential(for: .openAI) != nil,
                                                   braveSearch: credential(for: .braveSearch) != nil)
    }

    private func account(_ provider: SigDemoInferenceCredential) -> String {
        accountNamespace + "." + provider.rawValue
    }

    static func valid(_ value: String, for provider: SigDemoInferenceCredential) -> Bool {
        !value.isEmpty && value.utf8.count <= provider.maximumBytes
            && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

/// An ephemeral response for already registered private-demo accounts. The
/// server must opt in; public client configuration never contains this object.
public struct SigDemoInferenceCredentialProvision: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let openAIAPIKey: String?
    private let braveSearchAPIKey: String?
    public var description: String { "SigDemoInferenceCredentialProvision(<redacted>)" }
    public var debugDescription: String { description }

    private enum CodingKeys: String, CodingKey { case version, openAIAPIKey, braveSearchAPIKey }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else { throw SigDemoError.invalidServerResponse }
        openAIAPIKey = try values.decodeIfPresent(String.self, forKey: .openAIAPIKey)
        braveSearchAPIKey = try values.decodeIfPresent(String.self, forKey: .braveSearchAPIKey)
        guard openAIAPIKey != nil || braveSearchAPIKey != nil,
              openAIAPIKey.map({ SigDemoInferenceCredentialStore.valid($0, for: .openAI) }) ?? true,
              braveSearchAPIKey.map({ SigDemoInferenceCredentialStore.valid($0, for: .braveSearch) }) ?? true else {
            throw SigDemoError.invalidServerResponse
        }
    }

    /// The caller must recheck cancellation and current account/deployment
    /// after the network response, before committing it to this local scope.
    public func save(to store: SigDemoInferenceCredentialStore) throws {
        try store.setCredential(openAIAPIKey, for: .openAI)
        try store.setCredential(braveSearchAPIKey, for: .braveSearch)
    }
}

protocol SigDemoInferenceCredentialStorage: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ value: Data, service: String, account: String) throws
    func remove(service: String, account: String) throws
}

private struct SigDemoInferenceKeychainStorage: SigDemoInferenceCredentialStorage {
    #if canImport(Security)
    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func read(service: String, account: String) throws -> Data? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else {
            throw SigDemoInferenceCredentialError.unavailable
        }
        return data
    }

    func write(_ value: Data, service: String, account: String) throws {
        let query = query(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SigDemoInferenceCredentialError.unavailable }
        var item = query
        item.merge(attributes, uniquingKeysWith: { _, new in new })
        let added = SecItemAdd(item as CFDictionary, nil)
        // Another caller can insert between update and add.
        if added == errSecDuplicateItem,
           SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess { return }
        guard added == errSecSuccess else { throw SigDemoInferenceCredentialError.unavailable }
    }

    func remove(service: String, account: String) throws {
        let result = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw SigDemoInferenceCredentialError.unavailable
        }
    }
    #else
    func read(service: String, account: String) throws -> Data? { throw SigDemoInferenceCredentialError.unsupportedPlatform }
    func write(_ value: Data, service: String, account: String) throws { throw SigDemoInferenceCredentialError.unsupportedPlatform }
    func remove(service: String, account: String) throws { throw SigDemoInferenceCredentialError.unsupportedPlatform }
    #endif
}
