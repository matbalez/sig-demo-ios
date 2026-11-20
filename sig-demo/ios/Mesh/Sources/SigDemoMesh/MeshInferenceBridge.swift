// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Request terms for the owned HTTP adapter, not wallet spending authority.
/// Payments-v3's legacy max_total_msat field does not enforce a hard cap;
/// the paid transport must separately authorize and reserve actual debits.
public enum MeshBridgePaymentPolicy: Sendable {
    case freeOnly
    case paid(maxInputMsatPerMillion: UInt64, maxOutputMsatPerMillion: UInt64, legacyMaxTotalMsat: UInt64)

    func validate() throws {
        if case .paid(let input, let output, let total) = self {
            guard input > 0, output > 0, total > 0, total <= UInt64(Int64.max) else {
                throw MeshInferenceError.invalidConfiguration
            }
        }
    }

    var requestTerms: [String: Any] {
        switch self {
        case .freeOnly: return ["mode": "free_only"]
        case .paid(let input, let output, let total):
            return ["mode": "allow_paid", "max_input_msat_per_million": input,
                    "max_output_msat_per_million": output, "max_total_msat": total]
        }
    }
}

/// Shared bounded HTTP/SSE parser for independently owned free and paid clients.
/// The free runtime always uses .freeOnly, and its SDK enforces that policy again.
public actor MeshInferenceBridge {
    private let bridge: LoopbackBridge

    public init(transport: any MeshInferenceTransport, model: String, paymentPolicy: MeshBridgePaymentPolicy) {
        bridge = LoopbackBridge(transport: transport, model: model, paymentPolicy: paymentPolicy)
    }

    public func start() async throws -> URL { try await bridge.start() }
    public func stop() async { await bridge.stop() }
}
