// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import LibSignalClient
import SigDemoKit
import SignalServiceKit

/// The draft is stored inside Signal's SQLCipher database. Its sensitive body is
/// additionally sealed with an installation-local, ThisDeviceOnly keychain key.
final class SigDemoEncryptedDraftStore: SigDemoRegistrationDraftStore, @unchecked Sendable {
    private let db: any DB
    private let store = NewKeyValueStore(collection: "SigDemo.PendingRegistration")

    init(db: any DB) { self.db = db }

    func load() async throws -> SigDemoPendingRegistration? {
        try db.read { tx in
            guard let bytes = try store.fetchValueOrThrow(Data.self, forKey: "draft", tx: tx) else { return nil }
            return try JSONDecoder().decode(SigDemoPendingRegistration.self, from: bytes)
        }
    }

    func save(_ draft: SigDemoPendingRegistration) async throws {
        let bytes = try JSONEncoder().encode(draft)
        try await db.awaitableWrite { tx in
            try store.writeValueOrThrow(bytes, forKey: "draft", tx: tx)
        }
    }

    func remove() async throws {
        try await db.awaitableWrite { tx in
            try store.removeValueOrThrow(forKey: "draft", tx: tx)
        }
    }
}

/// Uses upstream Signal key generation, prekey persistence, profile jobs and
/// registration state changes. No production registration or linking is used.
final class SigDemoUpstreamRegistrationAdapter: SigDemoSignalRegistrationAdapter, @unchecked Sendable {
    private let db: any DB
    private let keychain: any KeychainStorage
    private let keychainService = "SigDemo.PendingRegistration"
    private let keychainKey = "draft-wrapping-key-v1"

    private struct BundleState: Codable {
        let identityKeyPair: Data
        let signedPreKey: Data
        let lastResortPreKey: Data

        init(_ bundle: RegistrationPreKeyUploadBundle) {
            identityKeyPair = bundle.identityKeyPair.serialize()
            signedPreKey = bundle.signedPreKey.serialize()
            lastResortPreKey = bundle.lastResortPreKey.serialize()
        }

        func restore(identity: OWSIdentity) throws -> RegistrationPreKeyUploadBundle {
            try RegistrationPreKeyUploadBundle(
                identity: identity,
                identityKeyPair: IdentityKeyPair(bytes: identityKeyPair),
                signedPreKey: SignedPreKeyRecord(bytes: signedPreKey),
                lastResortPreKey: KyberPreKeyRecord(bytes: lastResortPreKey)
            )
        }
    }

    private struct Material: Codable {
        let payload: Data
        let aci: BundleState
        let pni: BundleState
        let profileKey: Data
        let accountEntropyPool: String
        let mediaRootBackupKey: Data
        let password: String
        let registrationId: UInt32
        let pniRegistrationId: UInt32
        let displayName: String
    }

    init(db: any DB, keychain: any KeychainStorage) {
        self.db = db
        self.keychain = keychain
    }

    func prepare(inviteCode: String, displayName: String, scope: SigDemoRegistrationScope) async throws -> SigDemoPreparedRegistration {
        try scope.identity.validateCurrentProcess()
        let bridge = DependenciesBridge.shared
        try await db.awaitableWrite { tx in
            guard case .unregistered = bridge.tsAccountManager.registrationState(tx: tx) else {
                throw OWSAssertionError("A fresh isolated installation is required for a new demo account.")
            }
            // New invitation attempts get fresh native identities. Existing
            // pending drafts bypass this method and reuse every original key.
            bridge.identityManager.setIdentityKeyPair(bridge.identityManager.generateNewIdentityKeyPair(), for: .aci, tx: tx)
            bridge.identityManager.setIdentityKeyPair(bridge.identityManager.generateNewIdentityKeyPair(), for: .pni, tx: tx)
        }
        let aci = await bridge.preKeyManager.createPreKeysForRegistration(forIdentity: .aci)
        let pni = await bridge.preKeyManager.createPreKeysForRegistration(forIdentity: .pni)
        let profileKey = Aes256Key.generateRandom()
        let aep = SignalServiceKit.AccountEntropyPool()
        let mediaKey = MediaRootBackupKey(backupKey: .generateRandom())
        let password = Randomness.generateRandomBytes(16).hexadecimalString
        let registrationId = RegistrationIdGenerator.generate()
        let pniRegistrationId = RegistrationIdGenerator.generate()
        let payload = try Self.publicPayload(
            inviteCode: inviteCode, displayName: displayName, password: password,
            aci: aci, pni: pni, profileKey: profileKey,
            registrationId: registrationId, pniRegistrationId: pniRegistrationId
        )
        let material = Material(
            payload: payload.json, aci: BundleState(aci), pni: BundleState(pni),
            profileKey: profileKey.keyData, accountEntropyPool: aep.rawString,
            mediaRootBackupKey: mediaKey.serialize(), password: password,
            registrationId: registrationId, pniRegistrationId: pniRegistrationId,
            displayName: displayName
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sealed = try AES.GCM.seal(
            encoder.encode(material), using: wrappingKey(createIfMissing: true),
            authenticating: scopeData(scope)
        )
        guard let ciphertext = sealed.combined else { throw OWSAssertionError("Could not seal registration state.") }
        let draft = try SigDemoPendingRegistration(scope: scope, sealedState: ciphertext)
        return SigDemoPreparedRegistration(draft: draft, payload: payload)
    }

    func restorePayload(from draft: SigDemoPendingRegistration) async throws -> SigDemoRegistrationPayload {
        try SigDemoRegistrationPayload(json: open(draft).payload)
    }

    func commit(account: SigDemoAccount, draft: SigDemoPendingRegistration) async throws {
        let material = try open(draft)
        let aciBundle = try material.aci.restore(identity: .aci)
        let pniBundle = try material.pni.restore(identity: .pni)
        guard let profileKey = Aes256Key(data: material.profileKey),
              let givenName = OWSUserProfile.NameComponent(truncating: material.displayName),
              let e164 = E164(account.number) else {
            throw OWSAssertionError("Invalid retained registration material.")
        }
        let aci = Aci(fromUUID: account.uuid)
        let pni = Pni(fromUUID: account.pni)
        let authedAccount = AuthedAccount.Explicit(
            aci: aci, accountType: .forPhoneNumber(.init(e164: e164, pni: pni)),
            deviceId: .primary, authPassword: material.password
        )
        let bridge = DependenciesBridge.shared
        // This is idempotent and uses the already-persisted original prekeys.
        await bridge.preKeyManager.finalizeRegistrationPreKeyBundle(aciBundle, uploadDidSucceed: true)
        await bridge.preKeyManager.finalizeRegistrationPreKeyBundle(pniBundle, uploadDidSucceed: true)
        try await db.awaitableWrite { tx in
            let existing = bridge.tsAccountManager.localIdentifiers(tx: tx)
            if let existing, existing.aci != aci {
                throw OWSAssertionError("Refusing to replace another local account.")
            }
            try SigDemoDeploymentBinding.bind(
                accountID: aci.serviceIdUppercaseString,
                existingAccountID: existing?.aci.serviceIdUppercaseString, tx: tx
            )
            bridge.identityManager.setIdentityKeyPair(aciBundle.identityKeyPair.asECKeyPair, for: .aci, tx: tx)
            bridge.identityManager.setIdentityKeyPair(pniBundle.identityKeyPair.asECKeyPair, for: .pni, tx: tx)
            bridge.accountKeyStore.setAccountEntropyPool(try SignalServiceKit.AccountEntropyPool(key: material.accountEntropyPool), tx: tx)
            bridge.accountKeyStore.setMediaRootBackupKey(try MediaRootBackupKey(backupKey: BackupKey(contents: material.mediaRootBackupKey)), tx: tx)
            bridge.tsAccountManager.setRegistrationId(material.registrationId, for: .aci, tx: tx)
            bridge.tsAccountManager.setRegistrationId(material.pniRegistrationId, for: .pni, tx: tx)
            bridge.tsAccountManager.setIsManualMessageFetchEnabled(true, tx: tx)
            SSKEnvironment.shared.profileManagerRef.setLocalProfileKey(profileKey, userProfileWriter: .registration, transaction: tx)
            if !bridge.tsAccountManager.registrationState(tx: tx).isRegistered {
                bridge.registrationStateChangeManager.didRegisterOrProvision(account: authedAccount, tx: tx)
            }
            // updateLocalProfile durably queues the normal encrypted profile
            // upload in this same SQLCipher transaction before draft removal.
            _ = SSKEnvironment.shared.profileManagerRef.updateLocalProfile(
                profileGivenName: .setTo(givenName), profileFamilyName: .setTo(nil),
                profileBio: .setTo(nil), profileBioEmoji: .setTo(nil),
                profileAvatarData: .setTo(nil), visibleBadgeIds: .setTo([]),
                unsavedRotatedProfileKey: nil, userProfileWriter: .registration,
                authedAccount: .explicit(authedAccount), tx: tx
            )
            bridge.preKeyManager.resetOneTimePreKeyCheckTimestamp()
        }
    }

    private func open(_ draft: SigDemoPendingRegistration) throws -> Material {
        let sealed = try AES.GCM.SealedBox(combined: draft.sealedState)
        let plaintext = try AES.GCM.open(sealed, using: wrappingKey(createIfMissing: false), authenticating: scopeData(draft.scope))
        return try JSONDecoder().decode(Material.self, from: plaintext)
    }

    private func scopeData(_ scope: SigDemoRegistrationScope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(scope)
    }

    private func wrappingKey(createIfMissing: Bool) throws -> CryptoKit.SymmetricKey {
        do {
            let bytes = try keychain.dataValue(service: keychainService, key: keychainKey)
            guard bytes.count == 32 else { throw OWSAssertionError("Invalid registration wrapping key.") }
            return CryptoKit.SymmetricKey(data: bytes)
        } catch KeychainError.notFound where createIfMissing {
            let bytes = Randomness.generateRandomBytes(32)
            try keychain.setDataValue(bytes, service: keychainService, key: keychainKey)
            return CryptoKit.SymmetricKey(data: bytes)
        }
    }

    private static func publicPayload(
        inviteCode: String, displayName: String, password: String,
        aci: RegistrationPreKeyUploadBundle, pni: RegistrationPreKeyUploadBundle,
        profileKey: Aes256Key, registrationId: UInt32, pniRegistrationId: UInt32
    ) throws -> SigDemoRegistrationPayload {
        func signed(_ record: SignedPreKeyRecord) throws -> [String: Any] {
            ["keyId": record.id, "publicKey": try record.publicKey().serialize().base64EncodedString(), "signature": record.signature.base64EncodedString()]
        }
        func kyber(_ record: KyberPreKeyRecord) throws -> [String: Any] {
            ["keyId": record.id, "publicKey": try record.publicKey().serialize().base64EncodedString(), "signature": record.signature.base64EncodedString()]
        }
        let body: [String: Any] = [
            "inviteCode": inviteCode, "displayName": displayName, "password": password,
            "sessionId": "", "skipDeviceTransfer": true,
            "aciIdentityKey": aci.identityKeyPair.publicKey.serialize().base64EncodedString(),
            "pniIdentityKey": pni.identityKeyPair.publicKey.serialize().base64EncodedString(),
            "aciSignedPreKey": try signed(aci.signedPreKey), "aciPqLastResortPreKey": try kyber(aci.lastResortPreKey),
            "pniSignedPreKey": try signed(pni.signedPreKey), "pniPqLastResortPreKey": try kyber(pni.lastResortPreKey),
            "accountAttributes": [
                "fetchesMessages": true, "registrationId": registrationId, "pniRegistrationId": pniRegistrationId,
                "capabilities": ["attachmentBackfill": true, "spqr": true, "usernameChangeSyncMessage": true, "optionalPhoneNumber": false],
                "unidentifiedAccessKey": Array(SMKUDAccessKey(profileKey: profileKey).keyData),
                "unrestrictedUnidentifiedAccess": false, "discoverableByPhoneNumber": false,
                "recoveryPassword": Randomness.generateRandomBytes(32).base64EncodedString(),
            ],
        ]
        return try SigDemoRegistrationPayload(json: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }
}
