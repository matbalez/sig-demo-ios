// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

/// Binds a completed test account to its private deployment inside SQLCipher.
/// App and extension launch paths validate this before constructing networking.
public enum SigDemoDeploymentBinding {
    public enum ValidationError: Swift.Error {
        case missingOrMismatchedBinding
    }

    private struct Record: Codable {
        let version: Int
        let accountID: String
        let configurationDigest: Data
    }

    private static let store = NewKeyValueStore(collection: "SigDemo.Deployment")
    private static let key = "registered-account-v1"

    /// No existing account means this is still the ordinary fresh invite flow.
    public static func validate(accountID: String?, tx: DBReadTransaction) throws(ValidationError) {
        guard let accountID else { return }
        do {
            guard let data = try store.fetchValueOrThrow(Data.self, forKey: key, tx: tx) else {
                throw ValidationError.missingOrMismatchedBinding
            }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.version == 1, record.accountID == accountID,
                  record.configurationDigest == (try configurationDigest()) else {
                throw ValidationError.missingOrMismatchedBinding
            }
        } catch {
            // Do not surface account identifiers or configuration contents.
            throw ValidationError.missingOrMismatchedBinding
        }
    }

    /// Must be called in the same transaction that installs the local account,
    /// before registration notifications or any authenticated work can start.
    public static func bind(accountID: String, existingAccountID: String?, tx: DBWriteTransaction) throws {
        if let existingAccountID {
            guard existingAccountID == accountID else { throw ValidationError.missingOrMismatchedBinding }
            try validate(accountID: existingAccountID, tx: tx)
        }
        let record = Record(version: 1, accountID: accountID, configurationDigest: try configurationDigest())
        try store.writeValueOrThrow(JSONEncoder().encode(record), forKey: key, tx: tx)
    }

    private static func configurationDigest() throws -> Data {
        let configuration = try JSONSerialization.jsonObject(with: SigDemoRuntimeConfiguration.publicClientConfigurationData)
        let canonical = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        // Includes every public service route, relay destination and trust root.
        // Inference credentials are never part of the public configuration.
        return Data(SHA256.hash(data: canonical))
    }
}
