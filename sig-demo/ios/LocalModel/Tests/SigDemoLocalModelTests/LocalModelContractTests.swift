// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SigDemoLocalModel

@Test func catalogIsPinnedToLiquid() {
    #expect(LocalModelCatalog.models.count == 1)
    #expect(LocalModelCatalog.models.first?.id == LocalModelCatalog.defaultModelID)
    #expect(LocalModelCatalog.model(id: "unknown") == nil)
    #expect(Set(LocalModelCatalog.models.map(\.filename)).count == 1)
    for model in LocalModelCatalog.models {
        #expect(model.sha256.count == 64)
        #expect(model.filename.hasSuffix(".gguf"))
        #expect(!model.filename.contains("/"))
        #expect(model.byteCount > 0)
    }
}
@Test func stopPermanentlyRetiresAnUnstartedRuntime() async throws {
    let runtime = LocalModelRuntime(accountID: "synthetic-only", modelsDirectory: URL(fileURLWithPath: "/nonexistent"))
    await runtime.stop()
    await #expect(throws: LocalModelError.stopped) { try await runtime.start() }
    await runtime.stop()
    await #expect(throws: LocalModelError.stopped) { try await runtime.start(modelID: LocalModelCatalog.defaultModelID) }
}
@Test func unknownModelAndMissingResourceFailBeforeNativeLoad() async {
    let runtime = LocalModelRuntime(accountID: "synthetic-only", modelsDirectory: URL(fileURLWithPath: "/nonexistent"))
    await #expect(throws: LocalModelError.invalidModel) { try await runtime.start(modelID: "unknown") }
    await #expect(throws: LocalModelError.modelUnavailable) { try await runtime.start() }
    await runtime.stop()
}
