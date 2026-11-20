// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Testing
@testable import SigDemoPaidMesh

@Test func nativeStartupStageCodesAreFixedAndPreservePreconditions() {
    let stages: [(String, PaidMeshStartupStage)] = [
        ("startup_wallet_refresh_failed", .walletRefresh),
        ("startup_recovery_failed", .recovery),
        ("startup_policy_failed", .policy),
        ("startup_buyer_identity_failed", .buyerIdentity),
        ("startup_node_start_failed", .nodeStart),
    ]
    for (code, stage) in stages {
        #expect(PaidMeshError.nativeCode(code) == .startupFailed(stage))
    }
    #expect(PaidMeshError.nativeCode("payment_pending") == .paymentPending)
    #expect(PaidMeshError.nativeCode("stopped") == .stopped)
    #expect(PaidMeshError.nativeCode("unknown synthetic detail") == .unavailable)
}
