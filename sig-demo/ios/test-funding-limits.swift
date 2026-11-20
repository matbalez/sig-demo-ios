// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

@main
enum FundingLimitPolicyTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool) {
            precondition(condition(), "Funding limit policy contract failed")
            checks += 1
        }
        var policy = SigDemoFundingLimitDefaults()
        expect(policy.state == .pending)
        var confirmedSubunit = SigDemoFundingLimitDefaults()
        expect(confirmedSubunit.consumeConfirmedFunding(amountBaseUnits: 0, daily: 0, perRequest: 0, maximum: 100) == .init(daily: 0, perRequest: 0))
        expect(confirmedSubunit.state == .automatic)
        let first = policy.consumeConfirmedFunding(amountBaseUnits: 101, daily: 0, perRequest: 0, maximum: 100)
        expect(first == .init(daily: 50, perRequest: 50))
        expect(policy.initialConfirmedAmountBaseUnits == 101)
        expect(policy.consumeConfirmedFunding(amountBaseUnits: 200, daily: 50, perRequest: 50, maximum: 100) == nil)
        var restored = try JSONDecoder().decode(SigDemoFundingLimitDefaults.self, from: JSONEncoder().encode(policy))
        expect(restored == policy)
        expect(restored.consumeConfirmedFunding(amountBaseUnits: 200, daily: 50, perRequest: 50, maximum: 100) == nil)
        restored.markUserEdited()
        expect(restored.consumeConfirmedFunding(amountBaseUnits: 200, daily: 0, perRequest: 0, maximum: 100) == nil)
        expect(restored.state == .userEdited)
        var editedBeforeFunding = SigDemoFundingLimitDefaults()
        editedBeforeFunding.markUserEdited()
        expect(editedBeforeFunding.consumeConfirmedFunding(amountBaseUnits: 100, daily: 0, perRequest: 0, maximum: 100) == nil)
        var existing = SigDemoFundingLimitDefaults.legacy(daily: 25, perRequest: 10)
        expect(existing.state == .userEdited)
        expect(existing.consumeConfirmedFunding(amountBaseUnits: 100, daily: 25, perRequest: 10, maximum: 100) == nil)
        var untouched = SigDemoFundingLimitDefaults.legacy(daily: 0, perRequest: 0)
        expect(untouched.consumeConfirmedFunding(amountBaseUnits: 1, daily: 0, perRequest: 0, maximum: 100) == .init(daily: 0, perRequest: 0))
        expect(untouched.state == .automatic)
        var tooLarge = SigDemoFundingLimitDefaults()
        expect(tooLarge.consumeConfirmedFunding(amountBaseUnits: UInt64.max, daily: 0, perRequest: 0, maximum: 100) == nil)
        expect(tooLarge.state == .pending)
        var defensive = SigDemoFundingLimitDefaults()
        expect(defensive.consumeConfirmedFunding(amountBaseUnits: 100, daily: 0, perRequest: 5, maximum: 100) == .init(daily: 0, perRequest: 5))
        expect(defensive.state == .userEdited)
        print("Funding limit policy: \(checks) checks passed")
    }
}
