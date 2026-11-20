// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import SigDemoMesh

/// An isolated buyer: one on-device Node, embedded Lexe wallet, and durable
/// fee-inclusive authorization scope for each complete Sig invocation.
public actor PaidMeshRuntime {
    public static let defaultModel = "Qwen3.6-27B-Q6_K"

    private let nativeFactory: @Sendable () async throws -> PaidMeshNativeClient
    private var retired = false
    private var native: PaidMeshNativeClient?
    private var creating: Task<PaidMeshNativeClient, Error>?
    private var startup: Task<PublicMeshRoute, Error>?
    private var stopping: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var bridge: MeshInferenceBridge?
    private var transport: PaidNodeTransport?
    private var route: PublicMeshRoute?
    private var catalog: [MeshInferenceModel] = []
    private var invocation: UUID?
    private var beginningInvocation = false
    private var observingWallet = false
    private var walletControlOperation = false
    private var ending: [UUID: Task<NativeWalletSnapshot?, Never>] = [:]
    private var cachedWallet = PaidMeshWalletSnapshot.empty()
    private var settings: Settings?

    private struct Settings: Equatable, Sendable {
        let model: String
        let dailyMsat: UInt64
        let requestMsat: UInt64
    }

    public init(accountID: String, deploymentID: String) {
        nativeFactory = {
            let directory = try await Task.detached(priority: .utility) {
                try Self.storageDirectory(accountID: accountID, deploymentID: deploymentID)
            }.value
            try Task.checkCancellation()
            return try await PaidMeshNativeClient.create(storageDirectory: directory)
        }
    }

    /// Internal creation seam for lifecycle tests without a Keychain or wallet.
    init(nativeFactory: @escaping @Sendable () async throws -> PaidMeshNativeClient) {
        self.nativeFactory = nativeFactory
    }

    public func models() -> [MeshInferenceModel] { catalog }

    /// Reads native cached wallet facts only. It never opens or provisions a
    /// Lexe wallet and does not interrupt a payment operation to refresh UI.
    public func walletSnapshot() async -> PaidMeshWalletSnapshot {
        if retired || stopping != nil { return cachedWallet }
        let epoch = generation
        do {
            let client = try await client(epoch: epoch)
            if await client.hasPendingCalls { return cachedWallet }
            let value = try await client.call(PaidNativeCommand(op: "snapshot"), as: NativeWalletSnapshot.self,
                                              cancelNativeOnCancellation: false)
            try check(epoch)
            cachedWallet = .from(value)
        } catch is CancellationError {}
        catch let error as PaidMeshError {
            if epoch == generation {
                if error == .walletLocked { cachedWallet = .empty(.locked) }
                else if error != .stopped { cachedWallet = .empty(.unavailable) }
            }
        } catch { if epoch == generation { cachedWallet = .empty(.unavailable) } }
        return cachedWallet
    }

    /// The app calls this only after the user's explicit wallet-setup action.
    public func setupWallet() async throws -> PaidMeshWalletSnapshot {
        try await walletOperation("setup_wallet")
    }

    /// Reconciles only the existing account wallet. Current limits, including
    /// zero, restrict new settlement payments within their original scope caps.
    public func refreshWallet(dailyBudgetBaseUnits: UInt64,
                              perRequestBudgetBaseUnits: UInt64) async throws -> PaidMeshWalletSnapshot {
        try check(generation)
        guard perRequestBudgetBaseUnits <= dailyBudgetBaseUnits else {
            throw PaidMeshError.invalidConfiguration
        }
        return try await walletOperation("refresh_wallet",
            dailyMsat: Self.budgetMsat(dailyBudgetBaseUnits),
            requestMsat: Self.budgetMsat(perRequestBudgetBaseUnits))
    }

    private func walletOperation(_ op: String, dailyMsat: UInt64? = nil,
                                 requestMsat: UInt64? = nil) async throws -> PaidMeshWalletSnapshot {
        try Task.checkCancellation()
        try check(generation)
        guard invocation == nil, !beginningInvocation, !observingWallet, !walletControlOperation, ending.isEmpty, startup == nil else { throw PaidMeshError.busy }
        walletControlOperation = true
        defer { walletControlOperation = false }
        let epoch = generation
        let client = try await client(epoch: epoch)
        let value = try await client.call(PaidNativeCommand(op: op,
            daily_budget_msat: dailyMsat, per_request_budget_msat: requestMsat), as: NativeWalletSnapshot.self)
        try check(epoch)
        cachedWallet = .from(value)
        return cachedWallet
    }

    public func createFundingInvoice(amountBaseUnits: UInt64) async throws -> PaidMeshFundingInvoice {
        try check(generation)
        guard invocation == nil, !beginningInvocation, !observingWallet, !walletControlOperation, ending.isEmpty, startup == nil else { throw PaidMeshError.busy }
        walletControlOperation = true
        defer { walletControlOperation = false }
        let amount = try Self.msat(amountBaseUnits)
        let epoch = generation
        let client = try await client(epoch: epoch)
        let value = try await client.call(PaidNativeCommand(op: "funding_invoice", amount_msat: amount), as: PaidNativeFunding.self)
        try check(epoch)
        guard value.amount_msat == amount, !value.bolt11.isEmpty, value.bolt11.utf8.count <= 8_192,
              value.bolt11.hasPrefix("lnbc"), !value.bolt11.contains(where: { $0.isWhitespace }), Self.validPaymentHash(value.payment_hash) else {
            throw PaidMeshError.unavailable
        }
        return .init(bolt11: value.bolt11, paymentHash: value.payment_hash, amountBaseUnits: amountBaseUnits,
                     expiresAt: value.expires_at_ms.map { Date(timeIntervalSince1970: Double($0) / 1_000) })
    }

    /// Network reads of an existing wallet only. This does not provision the
    /// trusted release, reconcile outgoing requests, or start a Mesh Node.
    public func refreshWalletObservation() async throws -> PaidMeshWalletSnapshot {
        let value = try await observe(PaidNativeCommand(op: "refresh_wallet_observation"), as: NativeWalletSnapshot.self)
        cachedWallet = .from(value)
        return cachedWallet
    }

    /// Looks up exactly this invoice's hash. Balance is fetched after the
    /// authoritative status; a balance query failure throws and can be retried.
    public func fundingStatus(for invoice: PaidMeshFundingInvoice) async throws -> PaidMeshFundingStatus {
        guard Self.validPaymentHash(invoice.paymentHash) else { throw PaidMeshError.invalidConfiguration }
        let value = try await observe(PaidNativeCommand(op: "funding_status", payment_hash: invoice.paymentHash), as: PaidNativeFundingStatus.self)
        guard value.payment_hash == invoice.paymentHash, value.wallet.balance_msat != nil,
              value.state != .paid || (value.received_msat.map { $0 > 0 } == true && value.confirmed_at_ms != nil) else {
            throw PaidMeshError.unavailable
        }
        cachedWallet = .from(value.wallet)
        return .init(paymentHash: value.payment_hash, state: value.state,
                     receivedBaseUnits: value.received_msat.map { $0 / 1_000 },
                     confirmedAt: try value.confirmed_at_ms.map(Self.observedDate), wallet: cachedWallet)
    }

    public func transactionHistory(cursor: String? = nil, limit: Int = 50) async throws -> PaidMeshTransactionPage {
        guard (1...100).contains(limit), Self.validHistoryCursor(cursor) else { throw PaidMeshError.invalidConfiguration }
        let value = try await observe(PaidNativeCommand(op: "transaction_history", cursor: cursor, limit: limit), as: PaidNativeHistory.self)
        guard value.transactions.count <= limit, Self.validHistoryCursor(value.next_cursor),
              !value.has_more || (value.next_cursor != nil && value.next_cursor != cursor),
              value.has_more || value.next_cursor == nil else { throw PaidMeshError.unavailable }
        let transactions = try value.transactions.map { row in
            guard Self.validHistoryID(row.id), row.payment_hash.map(Self.validPaymentHash) ?? true else { throw PaidMeshError.unavailable }
            return PaidMeshTransaction(id: row.id, direction: row.direction, status: row.status,
                amountBaseUnits: row.amount_msat.map { row.direction == .outbound ? Self.roundedDebit($0) : $0 / 1_000 },
                feeBaseUnits: Self.roundedDebit(row.fee_msat), createdAt: try Self.observedDate(row.created_at_ms),
                confirmedAt: try row.confirmed_at_ms.map(Self.observedDate), paymentHash: row.payment_hash)
        }
        return .init(transactions: transactions, nextCursor: value.next_cursor, hasMore: value.has_more)
    }

    /// Never derives a funding amount from balance or a pending invoice. A
    /// truncated/unsupported history returns no automatic initialization basis.
    public func confirmedFunding() async throws -> PaidMeshConfirmedFundingSummary {
        let value = try await observe(PaidNativeCommand(op: "confirmed_funding"), as: PaidNativeFundingSummary.self)
        guard value.history_complete || value.initial_funding == nil else { throw PaidMeshError.unavailable }
        let funding = try value.initial_funding.map { row in
            guard Self.validHistoryID(row.id), row.amount_msat > 0 else { throw PaidMeshError.unavailable }
            return PaidMeshConfirmedFunding(id: row.id, amountBaseUnits: row.amount_msat / 1_000,
                                            confirmedAt: try Self.observedDate(row.confirmed_at_ms))
        }
        return .init(initialFunding: funding, historyComplete: value.history_complete)
    }

    private func observe<Value: Decodable & Sendable>(_ command: PaidNativeCommand, as type: Value.Type) async throws -> Value {
        try Task.checkCancellation()
        try check(generation)
        guard invocation == nil, !beginningInvocation, !observingWallet, !walletControlOperation, ending.isEmpty, startup == nil, stopping == nil else { throw PaidMeshError.busy }
        observingWallet = true
        defer { observingWallet = false }
        let epoch = generation
        let client = try await client(epoch: epoch)
        guard !(await client.hasPendingCalls) else { throw PaidMeshError.busy }
        // Dismissing a read-only screen must not permanently fence the payment
        // context. Native reads are individually bounded and return no secrets.
        let result = try await client.call(command, as: type, cancelNativeOnCancellation: false)
        try check(epoch)
        return result
    }

    public func start(preferredModel: String?, dailyBudgetBaseUnits: UInt64,
                      perRequestBudgetBaseUnits: UInt64) async throws -> PublicMeshRoute {
        try Task.checkCancellation()
        try check(generation)
        guard !observingWallet, !walletControlOperation else { throw PaidMeshError.busy }
        if let stopping { await stopping.value; self.stopping = nil }
        try Task.checkCancellation()
        try check(generation)
        guard !observingWallet, !walletControlOperation else { throw PaidMeshError.busy }
        let chosen = preferredModel ?? Self.defaultModel
        guard Self.validModel(chosen), perRequestBudgetBaseUnits <= dailyBudgetBaseUnits else {
            throw PaidMeshError.invalidConfiguration
        }
        let next = try Settings(model: chosen, dailyMsat: Self.msat(dailyBudgetBaseUnits), requestMsat: Self.msat(perRequestBudgetBaseUnits))
        if let settings, settings != next { throw PaidMeshError.invalidConfiguration }
        if let route { return route }
        if let startup {
            let epoch = generation
            let result = try await startup.value
            try check(epoch)
            return result
        }
        settings = next
        let epoch = generation
        let task = Task { try await connect(next, epoch: epoch) }
        startup = task
        defer { if epoch == generation { startup = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func connect(_ settings: Settings, epoch: UInt64) async throws -> PublicMeshRoute {
        var ownedClient: PaidMeshNativeClient?
        var adapter: MeshInferenceBridge?
        var connection: PaidNodeTransport?
        do {
            let client = try await client(epoch: epoch)
            ownedClient = client
            let value = try await client.call(PaidNativeCommand(op: "start", model: settings.model,
                daily_budget_msat: settings.dailyMsat, per_request_budget_msat: settings.requestMsat), as: PaidNativeStart.self)
            try check(epoch)
            guard value.model == settings.model, let url = URL(string: value.api_base_url),
                  PaidNodeTransport.validBaseURL(url), value.max_input_msat_per_million > 0,
                  value.max_output_msat_per_million > 0 else { throw PaidMeshError.invalidConfiguration }
            let connected = try PaidNodeTransport(baseURL: url, model: value.model)
            connection = connected
            let owned = MeshInferenceBridge(transport: connected, model: value.model,
                paymentPolicy: .paid(maxInputMsatPerMillion: value.max_input_msat_per_million,
                    maxOutputMsatPerMillion: value.max_output_msat_per_million,
                    legacyMaxTotalMsat: settings.requestMsat))
            adapter = owned
            let baseURL = try await owned.start()
            try check(epoch)
            let models = try await client.call(PaidNativeCommand(op: "models"), as: [PaidNativeModel].self)
            try check(epoch)
            var seen = Set<String>()
            catalog = models.filter { Self.validModel($0.id) && seen.insert($0.id).inserted }
                .prefix(256).map { .init(id: $0.id, name: Self.safeName($0.name, fallback: $0.id)) }
            if !catalog.contains(where: { $0.id == value.model }) { catalog.insert(.init(id: value.model, name: value.model), at: 0) }
            let result = PublicMeshRoute(baseURL: baseURL, model: value.model)
            transport = connected
            bridge = owned
            route = result
            return result
        } catch {
            await adapter?.stop()
            await connection?.stop()
            await ownedClient?.shutdown()
            if epoch == generation {
                native = nil
                route = nil
                bridge = nil
                transport = nil
                catalog = []
                self.settings = nil
            }
            throw error
        }
    }

    public func beginInference() async throws -> UUID {
        try Task.checkCancellation()
        try check(generation)
        guard let transport, route != nil else { throw PaidMeshError.stopped }
        guard invocation == nil, !beginningInvocation, !observingWallet, !walletControlOperation, ending.isEmpty else { throw PaidMeshError.busy }
        beginningInvocation = true
        defer { beginningInvocation = false }
        let epoch = generation
        let client = try await client(epoch: epoch)
        let id = UUID()
        let command = PaidNativeCommand(op: "begin_request", scope_id: id.uuidString.lowercased())
        do {
            _ = try await client.call(command, as: PaidNativeAcknowledgement.self)
            try check(epoch)
            try await transport.setInvocation(id)
            try check(epoch)
            invocation = id
            return id
        } catch {
            // A cancellation may arrive after native begin committed. Cleanup
            // must run even when the calling agent task is already cancelled.
            let cleanup = Task<NativeWalletSnapshot?, Never> {
                await transport.drainInvocation()
                _ = try? await client.call(PaidNativeCommand(op: "end_request", scope_id: id.uuidString.lowercased()), as: PaidNativeAcknowledgement.self)
                return nil
            }
            ending[id] = cleanup
            _ = await cleanup.value
            ending.removeValue(forKey: id)
            // Cancellation can permanently fence the native handle even when
            // begin failed before returning its acknowledgement. Drain that
            // handle before another attempt can reuse this route.
            await stop()
            throw error
        }
    }

    /// Closes the original authorization only after native settlement cleanup.
    /// A false result requires a fresh route and reconciliation before retry.
    @discardableResult
    public func endInference(_ id: UUID) async -> Bool {
        if let cleanup = ending[id] { return await cleanup.value != nil }
        guard invocation == id else { return false }
        invocation = nil
        let epoch = generation
        let client = native
        let transport = self.transport
        let cleanup = Task<NativeWalletSnapshot?, Never> {
            await transport?.drainInvocation()
            guard let client else { return nil }
            do {
                _ = try await client.call(PaidNativeCommand(op: "end_request", scope_id: id.uuidString.lowercased()), as: PaidNativeAcknowledgement.self)
                return try await client.call(PaidNativeCommand(op: "snapshot"), as: NativeWalletSnapshot.self,
                                             cancelNativeOnCancellation: false)
            } catch { return nil }
        }
        ending[id] = cleanup
        let value = await cleanup.value
        ending.removeValue(forKey: id)
        guard epoch == generation else { return false }
        if let value {
            cachedWallet = .from(value)
            return true
        }
        // A failed Keychain/ledger update is not proof that the request closed.
        // Fence and drain rather than letting a later ready snapshot hide it.
        await stop()
        cachedWallet = .empty(.reconciliationNeeded)
        return false
    }

    /// Retire this owner permanently before any teardown suspension. Late
    /// snapshot callbacks cannot reopen its account while a new owner starts.
    public func shutdown() async {
        retired = true
        await stop()
    }

    /// Drain the current context while allowing an explicit later reuse by the
    /// same lifecycle owner, such as wallet reconciliation or route refresh.
    public func stop() async {
        if let stopping { await stopping.value; return }
        generation &+= 1
        invocation = nil
        beginningInvocation = false
        let priorBridge = bridge
        let priorTransport = transport
        let priorClient = native
        let priorStartup = startup
        let priorCreation = creating
        let priorEndings = Array(ending.values)
        priorClient?.fenceNewPayments()
        priorStartup?.cancel()
        priorCreation?.cancel()
        bridge = nil
        transport = nil
        native = nil
        creating = nil
        startup = nil
        route = nil
        settings = nil
        catalog = []
        ending.removeAll()
        let epoch = generation
        let task = Task {
            await priorBridge?.stop()
            await priorTransport?.stop()
            await priorClient?.shutdown()
            if let priorCreation, case .success(let lateClient) = await priorCreation.result { await lateClient.shutdown() }
            for cleanup in priorEndings { _ = await cleanup.value }
            _ = try? await priorStartup?.value
        }
        stopping = task
        await task.value
        if epoch == generation { stopping = nil }
    }

    private func client(epoch: UInt64) async throws -> PaidMeshNativeClient {
        try check(epoch)
        guard stopping == nil else { throw PaidMeshError.stopped }
        if let native { return native }
        let task: Task<PaidMeshNativeClient, Error>
        if let creating { task = creating }
        else {
            let factory = nativeFactory
            task = Task {
                try Task.checkCancellation()
                return try await factory()
            }
            creating = task
        }
        do {
            let result = try await task.value
            guard !retired, epoch == generation, !Task.isCancelled else {
                await result.shutdown()
                throw PaidMeshError.stopped
            }
            native = result
            creating = nil
            return result
        } catch {
            if epoch == generation { creating = nil }
            throw error
        }
    }

    private func check(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard !retired, epoch == generation else { throw PaidMeshError.stopped }
    }

    static func msat(_ amount: UInt64) throws -> UInt64 {
        guard amount > 0 else { throw PaidMeshError.spendingDisabled }
        return try budgetMsat(amount)
    }

    static func budgetMsat(_ amount: UInt64) throws -> UInt64 {
        guard amount <= UInt64(Int64.max) / 1_000 else { throw PaidMeshError.invalidConfiguration }
        return amount * 1_000
    }

    static func validModel(_ model: String) -> Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.utf8.count <= 128
            && !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !["auto", "mesh"].contains(model.lowercased())
    }

    static func validPaymentHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validHistoryCursor(_ cursor: String?) -> Bool {
        guard let cursor else { return true }
        return !cursor.isEmpty && cursor.utf8.count <= 512 && !cursor.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validHistoryID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func observedDate(_ milliseconds: UInt64) throws -> Date {
        guard milliseconds <= 253_402_300_799_000 else { throw PaidMeshError.unavailable }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func roundedDebit(_ msat: UInt64) -> UInt64 {
        msat / 1_000 + (msat % 1_000 == 0 ? 0 : 1)
    }

    private static func safeName(_ name: String, fallback: String) -> String {
        let value = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : String(value.prefix(160))
    }

    private static func storageDirectory(accountID: String, deploymentID: String) throws -> URL {
        guard !accountID.isEmpty, accountID.utf8.count <= 256,
              deploymentID.count == 64, deploymentID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw PaidMeshError.invalidConfiguration
        }
        let binding = "sig-demo-paid-mesh-v1\n" + deploymentID + "\n" + accountID
        let digest = SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined()
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = support.appendingPathComponent("SigDemo/PaidMesh", isDirectory: true).appendingPathComponent(digest, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw PaidMeshError.invalidConfiguration }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try directory.setResourceValues(resource)
        return directory
    }
}
