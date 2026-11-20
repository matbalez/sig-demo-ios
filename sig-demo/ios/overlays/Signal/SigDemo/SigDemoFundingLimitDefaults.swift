// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A confirmed inbound payment can initialize untouched limits once. Invoice
/// requests and balance changes are deliberately not inputs to this policy.
struct SigDemoFundingLimitDefaults: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case pending, automatic, userEdited }
    struct Limits: Equatable, Sendable {
        let daily: UInt64
        let perRequest: UInt64
    }

    private(set) var state: State = .pending
    private(set) var initialConfirmedAmountBaseUnits: UInt64?

    static func legacy(daily: UInt64, perRequest: UInt64) -> Self {
        var value = Self()
        if daily != 0 || perRequest != 0 { value.markUserEdited() }
        return value
    }

    mutating func markUserEdited() { state = .userEdited }

    /// Returns a decision only once; integer division rounds downward. Existing
    /// nonzero limits are preserved even if their older record has no marker.
    mutating func consumeConfirmedFunding(amountBaseUnits: UInt64, daily: UInt64,
        perRequest: UInt64, maximum: UInt64
    ) -> Limits? {
        guard state == .pending else { return nil }
        if daily != 0 || perRequest != 0 {
            markUserEdited()
            return Limits(daily: daily, perRequest: perRequest)
        }
        guard amountBaseUnits / 2 <= maximum else { return nil }
        state = .automatic
        initialConfirmedAmountBaseUnits = amountBaseUnits
        let half = amountBaseUnits / 2
        return Limits(daily: half, perRequest: half)
    }

    var isValid: Bool {
        switch state {
        case .pending: return initialConfirmedAmountBaseUnits == nil
        case .automatic: return initialConfirmedAmountBaseUnits != nil
        case .userEdited: return true
        }
    }
}
