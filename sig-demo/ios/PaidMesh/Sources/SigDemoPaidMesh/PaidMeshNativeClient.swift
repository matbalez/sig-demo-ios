// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Darwin
import SigDemoPaidMeshFFI

struct PaidNativeCommand: Encodable, Sendable {
    let op: String
    var model: String?
    var daily_budget_msat: UInt64?
    var per_request_budget_msat: UInt64?
    var amount_msat: UInt64?
    var scope_id: String?
    var payment_hash: String?
    var cursor: String?
    var limit: Int?
}

struct PaidNativeStart: Decodable, Sendable {
    let api_base_url: String
    let model: String
    let max_input_msat_per_million: UInt64
    let max_output_msat_per_million: UInt64
}

struct PaidNativeModel: Decodable, Sendable {
    let id: String
    let name: String
}

struct PaidNativeFunding: Decodable, Sendable {
    let bolt11: String
    let payment_hash: String
    let amount_msat: UInt64
    let expires_at_ms: UInt64?
}

struct PaidNativeFundingStatus: Decodable, Sendable {
    let payment_hash: String
    let state: PaidMeshFundingStatus.State
    let received_msat: UInt64?
    let confirmed_at_ms: UInt64?
    let wallet: NativeWalletSnapshot
}

struct PaidNativeTransaction: Decodable, Sendable {
    let id: String
    let payment_hash: String?
    let direction: PaidMeshTransaction.Direction
    let status: PaidMeshTransaction.Status
    let amount_msat: UInt64?
    let fee_msat: UInt64
    let created_at_ms: UInt64
    let confirmed_at_ms: UInt64?
}

struct PaidNativeHistory: Decodable, Sendable {
    let transactions: [PaidNativeTransaction]
    let next_cursor: String?
    let has_more: Bool
}

struct PaidNativeConfirmedFunding: Decodable, Sendable {
    let id: String
    let amount_msat: UInt64
    let confirmed_at_ms: UInt64
}

struct PaidNativeFundingSummary: Decodable, Sendable {
    let initial_funding: PaidNativeConfirmedFunding?
    let history_complete: Bool
}

private struct NativeEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    struct Failure: Decodable, Sendable { let code: String }
    let ok: Bool
    let value: Value?
    let error: Failure?
}

struct PaidNativeAcknowledgement: Decodable, Sendable {
    init(from decoder: any Decoder) throws {}
}

/// Only C call and cancellation may overlap. Ownership is transferred off the
/// main actor for creation, every blocking call, and final native destruction.
private final class NativeHandle: @unchecked Sendable {
    private let pointer: OpaquePointer
    private let closeLock = NSLock()
    private var closed = false

    init(storageDirectory: URL) throws {
        struct Configuration: Encodable { let version = 1; let storage_directory: String }
        let data = try JSONEncoder().encode(Configuration(storage_directory: storageDirectory.path))
        guard let json = String(data: data, encoding: .utf8),
              let pointer = json.withCString({ sig_demo_paid_mesh_create($0) }) else {
            throw PaidMeshError.invalidConfiguration
        }
        self.pointer = pointer
    }

    func call(_ command: Data) throws -> Data {
        guard let json = String(data: command, encoding: .utf8), !json.utf8.contains(0),
              let response = json.withCString({ sig_demo_paid_mesh_call(pointer, $0) }) else {
            throw PaidMeshError.unavailable
        }
        defer { sig_demo_paid_mesh_string_free(response) }
        // The owned C API only returns bounded, sanitized data. Bound it again
        // before decoding so an invalid native envelope cannot exhaust the UI.
        let limit = 2 * 1024 * 1024
        let count = strnlen(response, limit + 1)
        guard count <= limit else { throw PaidMeshError.unavailable }
        return Data(bytes: response, count: count)
    }

    func cancel() {
        closeLock.lock()
        defer { closeLock.unlock() }
        if !closed { sig_demo_paid_mesh_cancel(pointer) }
    }

    func close() {
        closeLock.lock()
        let shouldClose = !closed
        closed = true
        closeLock.unlock()
        if shouldClose { sig_demo_paid_mesh_free(pointer) }
    }

    deinit {
        closeLock.lock()
        let shouldClose = !closed
        closed = true
        closeLock.unlock()
        guard shouldClose else { return }
        let address = UInt(bitPattern: pointer)
        DispatchQueue.global(qos: .utility).async {
            if let pointer = OpaquePointer(bitPattern: address) { sig_demo_paid_mesh_free(pointer) }
        }
    }
}

actor PaidMeshNativeClient {
    private let handle: NativeHandle
    private var closing = false
    private var calls: [UUID: Task<Data, Error>] = [:]
    private var tail: Task<Data, Error>?
    private var shutdownTask: Task<Void, Never>?

    private init(handle: NativeHandle) { self.handle = handle }

    static func create(storageDirectory: URL) async throws -> PaidMeshNativeClient {
        let handle = try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try NativeHandle(storageDirectory: storageDirectory)
        }.value
        return PaidMeshNativeClient(handle: handle)
    }

    var hasPendingCalls: Bool { !calls.isEmpty || closing }

    /// The permanent native fence is atomic and may race a blocking call.
    /// Apply it synchronously before any Swift teardown await.
    nonisolated func fenceNewPayments() { handle.cancel() }

    func call<Value: Decodable & Sendable>(_ command: PaidNativeCommand, as: Value.Type,
                                          cancelNativeOnCancellation: Bool = true) async throws -> Value {
        try Task.checkCancellation()
        guard !closing else { throw PaidMeshError.stopped }
        let data = try JSONEncoder().encode(command)
        let predecessor = tail
        let handle = self.handle
        let task = Task.detached(priority: .utility) {
            _ = try? await predecessor?.value
            try Task.checkCancellation()
            return try handle.call(data)
        }
        let id = UUID()
        calls[id] = task
        tail = task
        defer { calls.removeValue(forKey: id) }
        let response = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            // Do not abandon a possibly submitted payment. Native cancellation
            // stops new work; its guarded ledger retains uncertain reservations.
            task.cancel()
            if cancelNativeOnCancellation { handle.cancel() }
        }
        try Task.checkCancellation()
        let result: NativeEnvelope<Value>
        do { result = try JSONDecoder().decode(NativeEnvelope<Value>.self, from: response) }
        catch { throw PaidMeshError.unavailable }
        guard result.ok else { throw PaidMeshError.nativeCode(result.error?.code ?? "unavailable") }
        guard let value = result.value else {
            // Lifecycle acknowledgements may intentionally have a null value.
            if Value.self == PaidNativeAcknowledgement.self {
                return try JSONDecoder().decode(Value.self, from: Data("{}".utf8))
            }
            throw PaidMeshError.unavailable
        }
        return value
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closing = true
        let active = Array(calls.values)
        for task in active { task.cancel() }
        handle.cancel()
        let handle = self.handle
        let task = Task {
            for task in active { _ = try? await task.value }
            await Task.detached(priority: .utility) {
                if let command = try? JSONEncoder().encode(PaidNativeCommand(op: "stop")) {
                    _ = try? handle.call(command)
                }
                handle.close()
            }.value
        }
        shutdownTask = task
        await task.value
        calls.removeAll()
        tail = nil
    }
}
