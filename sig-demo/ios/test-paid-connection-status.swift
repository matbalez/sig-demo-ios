// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

@main
enum PaidConnectionStatusTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool) {
            precondition(value(), "Paid connection status contract failed")
            checks += 1
        }

        var status = SigDemoPaidConnectionStatus()
        expect(status.walletReadyMessage(spendingEnabled: true, connectedModel: nil)
            == "The paid Mesh wallet is ready. The inference connection is not established.")
        expect(status.walletReadyMessage(spendingEnabled: false, connectedModel: nil).contains("spending is disabled"))
        expect(status.walletReadyMessage(spendingEnabled: true, connectedModel: "test-model") == "Paid Mesh ready · test-model.")

        let failure = SigDemoPaidConnectionStatus.Failure(stage: .routeStart, category: .unavailable)
        expect(status.record(failure))
        expect(!status.record(failure))
        for _ in 0..<4 {
            expect(status.walletReadyMessage(spendingEnabled: true, connectedModel: nil) == failure.message)
        }
        expect(status.walletReadyMessage(spendingEnabled: false, connectedModel: nil) == failure.message)
        expect(status.walletReadyMessage(spendingEnabled: true, connectedModel: "old-model") == failure.message)
        expect(failure.marker == "SIG_DEMO_PAID_FAILURE_ROUTE_START_UNAVAILABLE")

        let beginFailure = SigDemoPaidConnectionStatus.Failure(stage: .beginInvocation, category: .paymentPending)
        expect(status.record(beginFailure))
        expect(status.walletReadyMessage(spendingEnabled: true, connectedModel: nil) == beginFailure.message)
        status.clear() // A new route attempt, successful connection, or owner teardown.
        expect(status.failure == nil)
        expect(status.walletReadyMessage(spendingEnabled: true, connectedModel: "new-model") == "Paid Mesh ready · new-model.")

        let privateText = "synthetic-private-token https://private.invalid/query?credential=synthetic"
        let ats = NSError(domain: NSURLErrorDomain,
            code: URLError.appTransportSecurityRequiresSecureConnection.rawValue,
            userInfo: [NSLocalizedDescriptionKey: privateText,
                       NSURLErrorFailingURLErrorKey: URL(string: "https://private.invalid/?token=synthetic-private-token")!])
        expect(SigDemoPaidConnectionStatus.Category.network(ats) == .transportSecurity)
        let sanitized = SigDemoPaidConnectionStatus.Failure(stage: .agentCreation, category: .network(ats)!)
        expect(!sanitized.marker.contains(privateText) && !sanitized.message.contains(privateText))
        expect(sanitized.marker == "SIG_DEMO_PAID_FAILURE_AGENT_CREATION_TRANSPORT_SECURITY")
        expect(SigDemoPaidConnectionStatus.Category.network(URLError(.timedOut)) == .networkTimeout)
        expect(SigDemoPaidConnectionStatus.Category.network(URLError(.cannotConnectToHost)) == .networkConnection)
        expect(SigDemoPaidConnectionStatus.Category.network(NSError(domain: privateText, code: 1)) == nil)
        let startupCodes: [(String, PaidMeshStartupStage)] = [
            ("startup_wallet_refresh_failed", .walletRefresh),
            ("startup_recovery_failed", .recovery),
            ("startup_policy_failed", .policy),
            ("startup_buyer_identity_failed", .buyerIdentity),
            ("startup_node_start_failed", .nodeStart)
        ]
        for (code, stage) in startupCodes {
            expect(PaidMeshError.nativeCode(code) == .startupFailed(stage))
        }
        expect(PaidMeshError.nativeCode(privateText) == .unavailable)
        for category in SigDemoPaidConnectionStatus.Category.allCases {
            let marker = SigDemoPaidConnectionStatus.Failure(stage: .agentAnswer, category: category).marker
            expect(marker.utf8.allSatisfy { (65...90).contains($0) || $0 == 95 })
        }
        print("Paid connection status: \(checks) checks passed")
    }
}
