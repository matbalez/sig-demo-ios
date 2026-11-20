// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct SigDemoRegistrationScope: Codable, Equatable, Sendable {
    public let identity: SigDemoAppIdentity
    public let serverURL: URL
    public let trust: SigDemoTrustMaterial

    public init(identity: SigDemoAppIdentity, configuration: SigDemoConfiguration) {
        self.identity = identity
        self.serverURL = configuration.serverURL
        self.trust = configuration.trust
    }
}

/// Only ciphertext from the upstream adapter crosses the draft-storage boundary.
/// The adapter must seal *all* private keys, generated passwords, invitation/name,
/// exact request bytes, profile/account entropy, and prekey IDs using the isolated
/// Signal database/keychain. This package supplies no plaintext storage fallback.
public struct SigDemoPendingRegistration: Codable, Equatable, Sendable {
    public let version: Int
    public let scope: SigDemoRegistrationScope
    public let sealedState: Data

    public init(scope: SigDemoRegistrationScope, sealedState: Data) throws {
        guard !sealedState.isEmpty else { throw SigDemoError.invalidRegistrationPayload }
        self.version = 1
        self.scope = scope
        self.sealedState = sealedState
    }
}

/// Implement against the separately identified Signal database. Save must be
/// atomic and durable before returning; remove must be durable. Never use
/// UserDefaults or a plaintext JSON file for a draft or its encryption key.
public protocol SigDemoRegistrationDraftStore: Sendable {
    func load() async throws -> SigDemoPendingRegistration?
    func save(_ draft: SigDemoPendingRegistration) async throws
    func remove() async throws
}

public struct SigDemoPreparedRegistration: Sendable {
    public let draft: SigDemoPendingRegistration
    public let payload: SigDemoRegistrationPayload

    public init(draft: SigDemoPendingRegistration, payload: SigDemoRegistrationPayload) {
        self.draft = draft
        self.payload = payload
    }
}

/// Required bridge into a real Signal-iOS fork. Implement with upstream Signal
/// key generation, libsignal, SQLCipher, and keychain APIs; do not implement
/// replacement cryptography or fabricate a locally registered Signal account.
public protocol SigDemoSignalRegistrationAdapter: Sendable {
    /// Generate fresh ACI/PNI identity, signed and Kyber keys, profile/account
    /// secrets and authentication material. Seal a complete exact-retry draft.
    func prepare(inviteCode: String, displayName: String, scope: SigDemoRegistrationScope) async throws -> SigDemoPreparedRegistration

    /// Decrypt existing material without generating replacement keys or changing
    /// any request fields. Returning identical JSON bytes makes retry reviewable.
    func restorePayload(from draft: SigDemoPendingRegistration) async throws -> SigDemoRegistrationPayload

    /// Idempotently commit upstream primary-device registration with returned ACI,
    /// PNI, synthetic identifier, device 1, auth secret and original private keys.
    /// Durably enqueue the encrypted profile upload before returning. A failure
    /// must remain resumable with the same draft and accepted server identity.
    func commit(account: SigDemoAccount, draft: SigDemoPendingRegistration) async throws
}

/// A single owner serializes signup and retains pending material on ambiguous
/// network/server errors or local commit failures. Existing drafts always resume;
/// a new invitation/name never replaces a possibly redeemed identity.
public actor SigDemoRegistrationCoordinator {
    private let scope: SigDemoRegistrationScope
    private let api: any SigDemoAccountAPI
    private let store: any SigDemoRegistrationDraftStore
    private let adapter: any SigDemoSignalRegistrationAdapter
    private var running = false

    public init(scope: SigDemoRegistrationScope, api: any SigDemoAccountAPI,
                store: any SigDemoRegistrationDraftStore, adapter: any SigDemoSignalRegistrationAdapter) {
        self.scope = scope
        self.api = api
        self.store = store
        self.adapter = adapter
    }

    public func register(inviteCode: String, displayName: String) async throws -> SigDemoAccount {
        guard !running else { throw SigDemoError.registrationAlreadyRunning }
        running = true
        defer { running = false }
        if let pending = try await store.load() {
            return try await redeem(pending, payload: nil)
        }
        let prepared = try await adapter.prepare(inviteCode: inviteCode, displayName: displayName, scope: scope)
        try validate(prepared.draft)
        try await store.save(prepared.draft)
        return try await redeem(prepared.draft, payload: prepared.payload)
    }

    @discardableResult
    public func resumeIfNeeded() async throws -> SigDemoAccount? {
        guard !running else { throw SigDemoError.registrationAlreadyRunning }
        running = true
        defer { running = false }
        guard let pending = try await store.load() else { return nil }
        return try await redeem(pending, payload: nil)
    }

    private func validate(_ draft: SigDemoPendingRegistration) throws {
        guard draft.version == 1 else { throw SigDemoError.unsupportedDraftVersion }
        guard draft.scope == scope else { throw SigDemoError.draftBelongsToAnotherEnvironment }
        guard !draft.sealedState.isEmpty else { throw SigDemoError.invalidRegistrationPayload }
    }

    private func redeem(_ draft: SigDemoPendingRegistration, payload: SigDemoRegistrationPayload?) async throws -> SigDemoAccount {
        try validate(draft)
        let request: SigDemoRegistrationPayload
        if let payload { request = payload } else { request = try await adapter.restorePayload(from: draft) }
        let account: SigDemoAccount
        do {
            account = try await api.register(request)
            try account.validate()
        } catch SigDemoError.rejected(let status) where [400, 401, 403, 409].contains(status) {
            try await store.remove()
            throw SigDemoError.rejected(status: status)
        }
        try await adapter.commit(account: account, draft: draft)
        try await store.remove()
        return account
    }
}
