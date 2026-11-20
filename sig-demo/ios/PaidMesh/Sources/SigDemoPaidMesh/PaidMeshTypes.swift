// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Fixed local startup stages. Native error descriptions never cross the FFI.
public enum PaidMeshStartupStage: String, Sendable, Equatable {
    case walletRefresh, recovery, policy, buyerIdentity, nodeStart
}

public enum PaidMeshError: Error, Sendable, Equatable {
    case invalidConfiguration, walletNotSetUp, walletLocked, insufficientFunds
    case spendingDisabled, budgetExceeded, paymentPending, modelUnavailable
    case busy, stopped, unavailable
    case startupFailed(PaidMeshStartupStage)

    static func nativeCode(_ code: String) -> Self {
        switch code {
        case "invalid_configuration", "invalid_request": .invalidConfiguration
        case "wallet_not_set_up", "not_provisioned": .walletNotSetUp
        case "wallet_locked", "keychain_locked": .walletLocked
        case "insufficient_funds": .insufficientFunds
        case "spending_disabled": .spendingDisabled
        case "budget_exceeded": .budgetExceeded
        case "payment_pending", "reconciliation_required": .paymentPending
        case "model_unavailable": .modelUnavailable
        case "busy": .busy
        case "stopped", "cancelled": .stopped
        case "startup_wallet_refresh_failed": .startupFailed(.walletRefresh)
        case "startup_recovery_failed": .startupFailed(.recovery)
        case "startup_policy_failed": .startupFailed(.policy)
        case "startup_buyer_identity_failed": .startupFailed(.buyerIdentity)
        case "startup_node_start_failed": .startupFailed(.nodeStart)
        default: .unavailable
        }
    }
}

public struct PaidMeshWalletSnapshot: Sendable, Equatable {
    public enum State: String, Sendable {
        case notSetUp, locked, syncing, unfunded, ready, reconciliationNeeded, unavailable
    }
    public let state: State
    public let balanceBaseUnits: UInt64?
    public let spentTodayBaseUnits: UInt64?
    public let reservedBaseUnits: UInt64?
    public let pendingPayments: UInt32
    public var canStart: Bool { state == .ready && pendingPayments == 0 }

    public var status: String {
        switch state {
        case .notSetUp: "Set up the separate demo wallet before using paid Mesh."
        case .locked: "Unlock the device to open the demo wallet."
        case .syncing: "The demo wallet is syncing."
        case .unfunded: "Add funds to the demo wallet before using paid Mesh."
        case .ready: "The demo wallet is ready. Set positive spending limits to enable paid inference."
        case .reconciliationNeeded: "An earlier inference request needs payment reconciliation. Refresh the wallet before starting another request."
        case .unavailable: "The demo wallet is unavailable. Refresh it to try again."
        }
    }

    static func empty(_ state: State = .notSetUp) -> Self {
        .init(state: state, balanceBaseUnits: nil, spentTodayBaseUnits: nil, reservedBaseUnits: nil, pendingPayments: 0)
    }

    static func from(_ value: NativeWalletSnapshot) -> Self {
        let state: State
        if value.reconciliation_required || value.pending_count > 0 { state = .reconciliationNeeded }
        else if value.setup_pending { state = .syncing }
        else if !value.provisioned { state = .notSetUp }
        else if !value.ready { state = .syncing }
        else if value.balance_msat.map({ $0 < 1_000 }) ?? true { state = .unfunded }
        else { state = .ready }
        return .init(state: state, balanceBaseUnits: value.balance_msat.map { $0 / 1_000 },
                     spentTodayBaseUnits: roundedDebit(value.spent_today_msat),
                     reservedBaseUnits: roundedDebit(value.reserved_msat),
                     pendingPayments: UInt32(clamping: value.pending_count))
    }

    private static func roundedDebit(_ msat: UInt64) -> UInt64 {
        msat / 1_000 + (msat % 1_000 == 0 ? 0 : 1)
    }
}

struct NativeWalletSnapshot: Decodable, Sendable {
    let provisioned: Bool
    let ready: Bool
    let balance_msat: UInt64?
    let reserved_msat: UInt64
    let spent_today_msat: UInt64
    let daily_budget_msat: UInt64
    let per_request_budget_msat: UInt64
    let pending_count: UInt64
    let setup_pending: Bool
    let reconciliation_required: Bool
}

public struct PaidMeshFundingInvoice: Sendable, Equatable {
    public let bolt11: String
    public let paymentHash: String
    public let amountBaseUnits: UInt64
    public let expiresAt: Date?
}

public struct PaidMeshFundingStatus: Sendable, Equatable {
    public enum State: String, Decodable, Sendable { case pending, paid, expired, failed }
    public let paymentHash: String
    public let state: State
    public let receivedBaseUnits: UInt64?
    public let confirmedAt: Date?
    /// Refreshed after the exact invoice status was read, without payment recovery.
    public let wallet: PaidMeshWalletSnapshot
}

public struct PaidMeshTransaction: Sendable, Equatable, Identifiable {
    public enum Direction: String, Decodable, Sendable { case inbound, outbound, info }
    public enum Status: String, Decodable, Sendable { case pending, completed, failed }
    public let id: String
    public let direction: Direction
    public let status: Status
    public let amountBaseUnits: UInt64?
    public let feeBaseUnits: UInt64
    public let createdAt: Date
    public let confirmedAt: Date?
    public let paymentHash: String?
}

public struct PaidMeshTransactionPage: Sendable, Equatable {
    /// Lexe update order, oldest update first. Merge pages by stable ID and sort
    /// by createdAt for display; an updated payment can occur on a later page.
    public let transactions: [PaidMeshTransaction]
    public let nextCursor: String?
    public let hasMore: Bool
}

public struct PaidMeshConfirmedFunding: Sendable, Equatable {
    public let id: String
    public let amountBaseUnits: UInt64
    public let confirmedAt: Date
}

public struct PaidMeshConfirmedFundingSummary: Sendable, Equatable {
    /// Earliest authoritative completed inbound, ordered by completion time.
    /// Present only when the entire bounded history scan completed.
    public let initialFunding: PaidMeshConfirmedFunding?
    public let historyComplete: Bool
}
