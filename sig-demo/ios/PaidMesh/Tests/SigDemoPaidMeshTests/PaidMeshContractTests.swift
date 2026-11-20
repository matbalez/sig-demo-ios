// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SigDemoPaidMeshFFI
import Testing
@testable import SigDemoPaidMesh

@Test func realPaidDynamicBoundaryRejectsInvalidInputWithoutOpeningAWallet() async throws {
    let response = try await Task.detached {
        let value = "{}".withCString { sig_demo_paid_mesh_call(nil, $0) }
        guard let value else { throw PaidMeshError.unavailable }
        let response = String(cString: value)
        sig_demo_paid_mesh_string_free(value)
        let unexpectedHandle = "{}".withCString { sig_demo_paid_mesh_create($0) }
        if let unexpectedHandle {
            sig_demo_paid_mesh_free(unexpectedHandle)
            throw PaidMeshError.invalidConfiguration
        }
        sig_demo_paid_mesh_cancel(nil)
        sig_demo_paid_mesh_free(nil)
        return response
    }.value
    let result = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    #expect(result["ok"] as? Bool == false)
    #expect((result["error"] as? [String: String])?["code"] == "invalid_configuration")
}

@Test func paidBudgetsRequireAnExplicitPositiveAmountAndCannotOverflow() async throws {
    #expect(throws: PaidMeshError.spendingDisabled) { try PaidMeshRuntime.msat(0) }
    #expect(throws: PaidMeshError.invalidConfiguration) { try PaidMeshRuntime.msat(UInt64.max) }
    #expect(try PaidMeshRuntime.msat(3) == 3_000)
    #expect(try PaidMeshRuntime.budgetMsat(0) == 0)
    let runtime = PaidMeshRuntime(accountID: "synthetic-account", deploymentID: String(repeating: "a", count: 64))
    await #expect(throws: PaidMeshError.spendingDisabled) {
        try await runtime.start(preferredModel: nil, dailyBudgetBaseUnits: 0, perRequestBudgetBaseUnits: 0)
    }
    await #expect(throws: PaidMeshError.invalidConfiguration) {
        try await runtime.start(preferredModel: nil, dailyBudgetBaseUnits: 1, perRequestBudgetBaseUnits: 2)
    }
    await runtime.stop()
}

@Test func reconciliationCarriesExplicitCurrentZeroLimits() throws {
    let data = try JSONEncoder().encode(PaidNativeCommand(op: "refresh_wallet",
        daily_budget_msat: 0, per_request_budget_msat: 0))
    let command = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(command["daily_budget_msat"] as? UInt64 == 0)
    #expect(command["per_request_budget_msat"] as? UInt64 == 0)
}

@Test func unknownPaymentsStayBlockedAndDisplayedDebitsRoundUp() {
    let native = NativeWalletSnapshot(provisioned: true, ready: true, balance_msat: 2_999,
        reserved_msat: 1, spent_today_msat: 1_001, daily_budget_msat: 10_000,
        per_request_budget_msat: 5_000, pending_count: 1, setup_pending: false, reconciliation_required: true)
    let value = PaidMeshWalletSnapshot.from(native)
    #expect(value.state == .reconciliationNeeded)
    #expect(!value.canStart)
    #expect(value.balanceBaseUnits == 2)
    #expect(value.reservedBaseUnits == 1)
    #expect(value.spentTodayBaseUnits == 2)
    #expect(value.pendingPayments == 1)
}

@Test func paidTransportAcceptsOnlyAnOwnedLoopbackBaseURL() {
    for raw in ["https://127.0.0.1:1234/v1", "http://localhost:1234/v1", "http://127.0.0.1/v1",
                "http://127.0.0.1:0/v1", "http://example.com:1234/v1", "http://127.0.0.1:1234/v1/",
                "http://user@127.0.0.1:1234/v1", "http://127.0.0.1:1234/v1?key=synthetic",
                "http://127.0.0.1:1234/%76%31"] {
        #expect(!PaidNodeTransport.validBaseURL(URL(string: raw)!))
    }
    #expect(PaidNodeTransport.validBaseURL(URL(string: "http://127.0.0.1:1234/v1")!))
}

@Test func noPaidHTTPCallCanStartWithoutAnInvocationScope() async throws {
    let transport = try PaidNodeTransport(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, model: "test-model")
    await #expect(throws: PaidMeshError.spendingDisabled) {
        try await transport.streamChatCompletions(body: Data("{}".utf8))
    }
    await transport.stop()
}

@Test func arbitraryNativeErrorsNeverReachTheUser() {
    #expect(PaidMeshError.nativeCode("unexpected remote description with secret") == .unavailable)
    #expect(PaidMeshError.nativeCode("budget_exceeded") == .budgetExceeded)
    #expect(PaidMeshRuntime.defaultModel == "Qwen3.6-27B-Q6_K")
}

@Test func invoiceObservationCarriesOnlyItsExactHashWithoutSpendingAuthority() throws {
    let hash = String(repeating: "ab", count: 32)
    let data = try JSONEncoder().encode(PaidNativeCommand(op: "funding_status", payment_hash: hash))
    let command = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(command.keys) == ["op", "payment_hash"])
    #expect(command["payment_hash"] as? String == hash)
    #expect(PaidMeshRuntime.validPaymentHash(hash))
    #expect(!PaidMeshRuntime.validPaymentHash(String(repeating: "AB", count: 32)))
}

@Test func invalidObservationArgumentsCannotOpenAnAccountOrContactAWallet() async throws {
    // Invalid account configuration would fail differently if native creation
    // happened before these public input checks.
    let runtime = PaidMeshRuntime(accountID: "", deploymentID: "")
    let invalidInvoice = PaidMeshFundingInvoice(bolt11: "synthetic-unrelated-invoice", paymentHash: "bad",
                                               amountBaseUnits: 1, expiresAt: nil)
    await #expect(throws: PaidMeshError.invalidConfiguration) { try await runtime.fundingStatus(for: invalidInvoice) }
    await #expect(throws: PaidMeshError.invalidConfiguration) { try await runtime.transactionHistory(limit: 0) }
    await #expect(throws: PaidMeshError.invalidConfiguration) { try await runtime.transactionHistory(limit: 101) }
    await #expect(throws: PaidMeshError.invalidConfiguration) {
        try await runtime.transactionHistory(cursor: String(repeating: "a", count: 513))
    }
    #expect(!PaidMeshRuntime.validHistoryCursor("cursor\n"))
    await runtime.stop()
}

@Test func unsupportedHistoryStatusIsRejectedInsteadOfBecomingConfirmedFunding() throws {
    let raw = Data("""
        {"transactions":[{"id":"stable-id","payment_hash":null,"direction":"inbound",
        "status":"unknown-success","amount_msat":9000,"fee_msat":0,"created_at_ms":1,
        "confirmed_at_ms":2}],"next_cursor":null,"has_more":false}
        """.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(PaidNativeHistory.self, from: raw) }
}

private actor NativeCreationProbe {
    private(set) var attempts = 0

    func create() throws -> PaidMeshNativeClient {
        attempts += 1
        // No Keychain, account directory, native handle, or network request.
        throw PaidMeshError.walletNotSetUp
    }
}

@Test func permanentShutdownRejectsLateWalletReadsAndInferenceAdmissions() async {
    let probe = NativeCreationProbe()
    let runtime = PaidMeshRuntime(nativeFactory: { try await probe.create() })
    await runtime.shutdown()
    _ = await runtime.walletSnapshot()
    _ = await runtime.walletSnapshot()
    await #expect(throws: PaidMeshError.stopped) {
        try await runtime.start(preferredModel: nil, dailyBudgetBaseUnits: 1, perRequestBudgetBaseUnits: 1)
    }
    await #expect(throws: PaidMeshError.stopped) { try await runtime.beginInference() }
    await #expect(throws: PaidMeshError.stopped) { try await runtime.setupWallet() }
    await #expect(throws: PaidMeshError.stopped) {
        try await runtime.refreshWallet(dailyBudgetBaseUnits: 0, perRequestBudgetBaseUnits: 0)
    }
    await #expect(throws: PaidMeshError.stopped) { try await runtime.createFundingInvoice(amountBaseUnits: 1) }
    await #expect(throws: PaidMeshError.stopped) { try await runtime.refreshWalletObservation() }
    let invoice = PaidMeshFundingInvoice(bolt11: "synthetic", paymentHash: String(repeating: "ab", count: 32),
                                        amountBaseUnits: 1, expiresAt: nil)
    await #expect(throws: PaidMeshError.stopped) { try await runtime.fundingStatus(for: invoice) }
    await #expect(throws: PaidMeshError.stopped) { try await runtime.transactionHistory() }
    await #expect(throws: PaidMeshError.stopped) { try await runtime.confirmedFunding() }
    #expect(await probe.attempts == 0)
}

@Test func ordinaryStopAllowsReopeningButPermanentShutdownDoesNot() async {
    let probe = NativeCreationProbe()
    let runtime = PaidMeshRuntime(nativeFactory: { try await probe.create() })
    _ = await runtime.walletSnapshot()
    #expect(await probe.attempts == 1)
    await runtime.stop()
    _ = await runtime.walletSnapshot()
    #expect(await probe.attempts == 2)
    await runtime.shutdown()
    // These reproduce a late cleanup callback retaining the retired owner.
    _ = await runtime.walletSnapshot()
    await runtime.stop()
    _ = await runtime.walletSnapshot()
    #expect(await probe.attempts == 2)
}

@Test func failedNativeCreationDoesNotPinAnUnusedConnectionPolicy() async {
    let probe = NativeCreationProbe()
    let runtime = PaidMeshRuntime(nativeFactory: { try await probe.create() })
    await #expect(throws: PaidMeshError.walletNotSetUp) {
        try await runtime.start(preferredModel: "first-test-model",
            dailyBudgetBaseUnits: 2, perRequestBudgetBaseUnits: 1)
    }
    // A later funding/default/model choice must retry creation, rather than
    // reject against settings left over from a connection that never existed.
    await #expect(throws: PaidMeshError.walletNotSetUp) {
        try await runtime.start(preferredModel: "second-test-model",
            dailyBudgetBaseUnits: 4, perRequestBudgetBaseUnits: 2)
    }
    #expect(await probe.attempts == 2)
    await runtime.shutdown()
}
