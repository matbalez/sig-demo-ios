// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Security

/// One foreground, account-scoped public client and its private agent adapter.
/// No model is served locally, no wallet is opened, and no provider fallback occurs.
public actor PublicMeshRuntime {
    private let accountID: String
    private var transport: (any MeshInferenceTransport)?
    private var bridge: LoopbackBridge?
    private var route: PublicMeshRoute?
    private var catalog: [MeshInferenceModel] = []
    private var pending: Task<PublicMeshRoute, Error>?
    private var preferredModel: String?
    private var generation: UInt64 = 0

    public init(accountID: String) {
        self.accountID = accountID
    }

    public func models() -> [MeshInferenceModel] { catalog }

    public func start(preferredModel: String?) async throws -> PublicMeshRoute {
        try Task.checkCancellation()
        guard !accountID.isEmpty, accountID.utf8.count <= 256 else {
            throw MeshInferenceError.invalidConfiguration
        }
        if let pending {
            guard preferredModel == self.preferredModel else { throw MeshInferenceError.invalidConfiguration }
            let result = try await pending.value
            try Task.checkCancellation()
            return result
        }
        if let route {
            guard preferredModel == self.preferredModel else { throw MeshInferenceError.invalidConfiguration }
            return route
        }
        self.preferredModel = preferredModel
        let epoch = generation
        let task = Task { try await self.connect(preferredModel: preferredModel, epoch: epoch) }
        pending = task
        defer { if generation == epoch { pending = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func connect(preferredModel: String?, epoch: UInt64) async throws -> PublicMeshRoute {
        try Task.checkCancellation()
        let identity = try Self.ownerIdentity(accountID: accountID)
        let client = MeshSDKPublicTransport(ownerKeypairHex: identity)
        transport = client
        var listener: LoopbackBridge?
        do {
            try await client.start(model: preferredModel)
            try check(epoch)
            let discovered = try await client.listModels()
            try check(epoch)
            var seen = Set<String>()
            let models = discovered.filter {
                Self.validModel($0.id) && seen.insert($0.id).inserted
            }.prefix(256)
            // Public listings put the contacted node's hosted models before
            // models advertised by its peers. Preserve that preference for
            // Automatic; the settings screen may sort its display separately.
            let selected: MeshInferenceModel?
            if let preferredModel {
                selected = models.first { $0.id == preferredModel }
            } else {
                selected = models.first
            }
            guard let selected else { throw MeshInferenceError.unavailable }
            let adapter = LoopbackBridge(transport: client, model: selected.id)
            listener = adapter
            let baseURL = try await adapter.start()
            try check(epoch)
            let result = PublicMeshRoute(baseURL: baseURL, model: selected.id)
            catalog = Array(models)
            bridge = adapter
            route = result
            return result
        } catch {
            await listener?.stop()
            await client.stop()
            if epoch == generation {
                transport = nil
                bridge = nil
                route = nil
                catalog = []
            }
            throw error
        }
    }

    private func check(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == generation else { throw MeshInferenceError.stopped }
    }

    public func stop() async {
        generation &+= 1
        let starting = pending
        let previousBridge = bridge
        let previousClient = transport
        pending = nil
        bridge = nil
        transport = nil
        route = nil
        catalog = []
        preferredModel = nil
        starting?.cancel()
        await previousBridge?.stop()
        await previousClient?.stop()
        _ = try? await starting?.value
    }

    static func validModel(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 128
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !["auto", "mesh"].contains(value.lowercased())
    }

    private static func ownerIdentity(accountID: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.matbalez.sig-demo.ios.mesh.public-owner.v1",
            kSecAttrAccount as String: accountID,
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &value)
        if status == errSecSuccess {
            guard let data = value as? Data, let identity = String(data: data, encoding: .utf8),
                  validIdentity(identity) else { throw MeshInferenceError.invalidConfiguration }
            return identity
        }
        guard status == errSecItemNotFound else { throw MeshInferenceError.unavailable }
        let identity = try MeshSDKPublicTransport.generateOwnerKeypairHex()
        guard validIdentity(identity) else { throw MeshInferenceError.invalidResponse }
        var insert = query
        insert[kSecValueData as String] = Data(identity.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        if added == errSecDuplicateItem { return try ownerIdentity(accountID: accountID) }
        guard added == errSecSuccess else { throw MeshInferenceError.unavailable }
        return identity
    }

    private static func validIdentity(_ value: String) -> Bool {
        (64...256).contains(value.utf8.count) && value.utf8.count.isMultiple(of: 2)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }
}
