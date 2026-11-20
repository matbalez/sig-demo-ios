// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SigDemoKit

private final class MemoryCredentialStorage: SigDemoInferenceCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? {
        lock.withLock { items[service + ":" + account] }
    }
    func write(_ value: Data, service: String, account: String) throws {
        lock.withLock { items[service + ":" + account] = value }
    }
    func remove(service: String, account: String) throws {
        _ = lock.withLock { items.removeValue(forKey: service + ":" + account) }
    }
    var keys: [String] { lock.withLock { Array(items.keys) } }
}

private func credentialIdentity(_ bundleSuffix: String = "signal") throws -> SigDemoAppIdentity {
    try SigDemoAppIdentity(bundleIdentifier: "dev.matbalez.sig-demo.ios." + bundleSuffix,
                           appGroupIdentifier: "group.dev.matbalez.sig-demo.ios.signal.group",
                           keychainService: "dev.matbalez.sig-demo.ios.registration")
}

@Test func inferenceCredentialsRemainSeparateByAccountDeploymentBundleAndProvider() throws {
    let memory = MemoryCredentialStorage()
    let account = UUID()
    func store(_ accountID: UUID, _ deployment: String, _ suffix: String = "signal") throws -> SigDemoInferenceCredentialStore {
        try SigDemoInferenceCredentialStore(accountID: accountID, deploymentID: deployment,
            identity: credentialIdentity(suffix), storage: memory)
    }
    let a = try store(account, String(repeating: "a", count: 64))
    try a.setCredential("synthetic-openai-value", for: .openAI)
    try a.setCredential("synthetic-brave-value", for: .braveSearch)
    #expect(try a.credential(for: .openAI) == "synthetic-openai-value")
    #expect(try a.credential(for: .braveSearch) == "synthetic-brave-value")
    for other in [try store(UUID(), String(repeating: "a", count: 64)),
                  try store(account, String(repeating: "b", count: 64)),
                  try store(account, String(repeating: "a", count: 64), "other")] {
        #expect(try other.credential(for: .openAI) == nil)
        #expect(try other.credential(for: .braveSearch) == nil)
    }
    #expect(memory.keys.allSatisfy { $0.hasPrefix("dev.matbalez.sig-demo.ios.signal.inference-credentials.v1:") })
    #expect(memory.keys.allSatisfy { !$0.contains(account.uuidString) && !$0.contains("synthetic") })
    #expect(!String(reflecting: a).contains("synthetic"))
}

@Test func invalidCredentialReplacementPreservesPreviousValueAndRemovalIsScoped() throws {
    let memory = MemoryCredentialStorage()
    let store = try SigDemoInferenceCredentialStore(accountID: UUID(), deploymentID: String(repeating: "1", count: 64),
        identity: credentialIdentity(), storage: memory)
    try store.setCredential("synthetic-openai-value", for: .openAI)
    try store.setCredential("synthetic-brave-value", for: .braveSearch)
    for value in ["", "contains spaces", "header\r\ninjection", "unicode-🔑", String(repeating: "a", count: 4_097)] {
        #expect(throws: SigDemoInferenceCredentialError.invalidCredential) { try store.setCredential(value, for: .openAI) }
    }
    #expect(throws: SigDemoInferenceCredentialError.invalidCredential) {
        try store.setCredential(String(repeating: "a", count: 1_025), for: .braveSearch)
    }
    #expect(try store.credential(for: .openAI) == "synthetic-openai-value")
    try store.setCredential(nil, for: .openAI)
    try store.setCredential(nil, for: .openAI)
    let availability = try store.availability()
    #expect(!availability.openAI && availability.braveSearch)
    #expect(try store.credential(for: .braveSearch) == "synthetic-brave-value")
}

@Test func credentialStoreRequiresCanonicalDeploymentDigestAndRejectsCorruptStoredValues() throws {
    let memory = MemoryCredentialStorage()
    for value in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
        #expect(throws: SigDemoInferenceCredentialError.invalidScope) {
            try SigDemoInferenceCredentialStore(accountID: UUID(), deploymentID: value,
                identity: credentialIdentity(), storage: memory)
        }
    }
    let store = try SigDemoInferenceCredentialStore(accountID: UUID(), deploymentID: String(repeating: "0", count: 64),
        identity: credentialIdentity(), storage: memory)
    try store.setCredential("synthetic-value", for: .openAI)
    let key = try #require(memory.keys.first)
    let split = try #require(key.firstIndex(of: ":"))
    try memory.write(Data([0xff]), service: String(key[..<split]), account: String(key[key.index(after: split)...]))
    #expect(throws: SigDemoInferenceCredentialError.invalidCredential) { try store.credential(for: .openAI) }
}

@Test func authoritativeProvisionRotatesOnlyItsAccountAndRemovesOmittedProviders() throws {
    let memory = MemoryCredentialStorage()
    let account = try SigDemoInferenceCredentialStore(accountID: UUID(), deploymentID: String(repeating: "a", count: 64),
        identity: credentialIdentity(), storage: memory)
    let other = try SigDemoInferenceCredentialStore(accountID: UUID(), deploymentID: String(repeating: "a", count: 64),
        identity: credentialIdentity(), storage: memory)
    try account.setCredential("synthetic-old-openai", for: .openAI)
    try account.setCredential("synthetic-old-brave", for: .braveSearch)
    try other.setCredential("synthetic-other-account", for: .openAI)
    let provision = try JSONDecoder().decode(SigDemoInferenceCredentialProvision.self,
        from: Data("{\"version\":1,\"openAIAPIKey\":\"synthetic-new-openai\"}".utf8))
    try provision.save(to: account)
    #expect(try account.credential(for: .openAI) == "synthetic-new-openai")
    #expect(try account.credential(for: .braveSearch) == nil)
    #expect(try other.credential(for: .openAI) == "synthetic-other-account")
}
