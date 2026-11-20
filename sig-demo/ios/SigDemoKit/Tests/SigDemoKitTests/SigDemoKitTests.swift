// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SigDemoKit

private func configuration(_ overrides: [String: Any] = [:]) throws -> SigDemoConfiguration {
    let origin = "https://localhost:14443"
    var values: [String: Any] = [
        "sigDemoEnabled": true, "sigDemoNetworkMode": "localhost", "updatesEnabled": false, "storageProfile": "demo",
        "serverUrl": origin, "storageUrl": origin + "/storageService", "resourcesUrl": origin + "/updates2",
        "sfuUrl": origin + "/callingService", "contentProxyUrl": origin + "/disabled", "updatesUrl": origin + "/disabled",
        "challengeUrl": origin + "/disabled", "registrationChallengeUrl": origin + "/disabled",
        "cdn": ["0": origin, "2": origin, "3": origin + "/cdn3"],
        "sigDemoRelay": ["host": SigDemoRelayApproval.host, "port": 8443],
        // Synthetic public fixture. Actual URLSession construction rejects this
        // non-certificate; protocol tests inject their transport deliberately.
        "certificateAuthority": "-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----\n",
        "serverTrustRoots": [Data(repeating: 7, count: 33).base64EncodedString()],
        "serverPublicParams": "AQID", "genericServerPublicParams": "BAUG", "backupServerPublicParams": "BwgJ",
    ]
    values.merge(overrides, uniquingKeysWith: { _, new in new })
    return try JSONDecoder().decode(SigDemoConfiguration.self, from: JSONSerialization.data(withJSONObject: values))
}

private func identity() throws -> SigDemoAppIdentity {
    try SigDemoAppIdentity(bundleIdentifier: "dev.matbalez.sig-demo.ios.signal",
                           appGroupIdentifier: "group.dev.matbalez.sig-demo.ios.signal.group",
                           keychainService: "dev.matbalez.sig-demo.ios.registration")
}

private func payloadJSON() throws -> Data {
    let signed: [String: Any] = ["keyId": 1, "publicKey": "AQID", "signature": "BAUG"]
    return try JSONSerialization.data(withJSONObject: [
        "inviteCode": "synthetic-invitation-12345", "displayName": "Alice", "password": "synthetic-generated-password-12345",
        "sessionId": "", "skipDeviceTransfer": true,
        "aciIdentityKey": "AQID", "pniIdentityKey": "BAUG",
        "aciSignedPreKey": signed, "aciPqLastResortPreKey": signed,
        "pniSignedPreKey": signed, "pniPqLastResortPreKey": signed,
        "accountAttributes": [
            "fetchesMessages": true, "registrationId": 123, "pniRegistrationId": 456,
            "capabilities": ["attachmentBackfill": true, "spqr": true, "usernameChangeSyncMessage": true, "optionalPhoneNumber": false],
            "unidentifiedAccessKey": Array(repeating: 3, count: 16),
            "unrestrictedUnidentifiedAccess": false, "discoverableByPhoneNumber": false, "recoveryPassword": "AQID",
        ],
    ])
}

private let accountJSON = Data("""
{"uuid":"c6e91a41-9cf1-4534-8fa3-2312ac4d0480","pni":"2c83e873-8be2-457b-a115-7e375366bd61","number":"+999123456789","deviceId":1,"storageCapable":false,"reregistration":false,"entitlements":{"badges":[]}}
""".utf8)

private actor StubTransport: SigDemoHTTPTransport {
    var requests: [URLRequest] = []
    let status: Int
    let body: Data
    init(status: Int = 200, body: Data) { self.status = status; self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!)
    }
}

@Test func sharedDemoCredentialLookupUsesOnlyPrivateAuthenticatedGETAndRedactsPayload() async throws {
    let body = Data("{\"version\":1,\"openAIAPIKey\":\"synthetic-openai-value\",\"braveSearchAPIKey\":\"synthetic-brave-value\"}".utf8)
    let transport = StubTransport(body: body)
    let api = try SigDemoPrivateAPI(configuration: configuration(), identity: identity(), transport: transport)
    let authentication = try SigDemoCredentials(accountID: UUID(), generatedPassword: "synthetic-generated-password")
    let provision = try await api.demoInferenceCredentials(credentials: authentication)
    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://localhost:14443/v1/sig-demo/demo-credentials")
    #expect(request.value(forHTTPHeaderField: "Authorization") == authentication.authorization)
    #expect(request.httpBody == nil && !request.httpShouldHandleCookies)
    #expect(!String(describing: provision).contains("synthetic"))
    #expect(!String(reflecting: provision).contains("synthetic"))
    for bad in [Data("{\"version\":2,\"openAIAPIKey\":\"synthetic-value\"}".utf8),
                Data("{\"version\":1}".utf8),
                Data("{\"version\":1,\"braveSearchAPIKey\":\"bad value\"}".utf8)] {
        let badAPI = try SigDemoPrivateAPI(configuration: configuration(), identity: identity(), transport: StubTransport(body: bad))
        await #expect(throws: SigDemoError.invalidServerResponse) { try await badAPI.demoInferenceCredentials(credentials: authentication) }
    }
    let rejected = try SigDemoPrivateAPI(configuration: configuration(), identity: identity(), transport: StubTransport(status: 401, body: body))
    await #expect(throws: SigDemoError.rejected(status: 401)) { try await rejected.demoInferenceCredentials(credentials: authentication) }
}

@Test func configurationRejectsProductionAndEscapingEndpoints() throws {
    let config = try configuration()
    #expect(config.serverURL.absoluteString == "https://localhost:14443")
    #expect(config.relay?.host == SigDemoRelayApproval.host)
    for value in ["https://chat.signal.org", "https://localhost", "http://localhost:14443", "https://user@localhost:14443", "https://localhost:14443/evil", "https://localhost:14443?query=1"] {
        #expect(throws: (any Error).self) { try configuration(["serverUrl": value]) }
    }
    for value in ["https://cdn.signal.org", "https://localhost:8443/cdn3", "https://localhost:14443/%2e%2e/evil"] {
        #expect(throws: (any Error).self) { try configuration(["cdn": ["0": value, "2": value, "3": value]]) }
    }
    #expect(throws: (any Error).self) { try configuration(["sigDemoRelay": ["host": "chat.signal.org", "port": 443]]) }
    #expect(throws: (any Error).self) { try configuration(["updatesEnabled": true]) }
    #expect(throws: (any Error).self) { try configuration(["serverTrustRoots": ["BbqY1DzohE4NUZoVF+L18oUPrK3kILllLEJh2UnPSsEx"]]) }
    #expect(throws: (any Error).self) { try configuration(["serverTrustRoots": ["BXu6QIKVz5MA8gstzfOgRQGqyLqOwNKHL6INkv3IHWMF"]]) }
    #expect(throws: (any Error).self) { try configuration(["certificateAuthority": "sig-demo-private-ca-not-configured"]) }
    #if canImport(Security)
    #expect(throws: (any Error).self) { try SigDemoURLSessionTransport(configuration: config) }
    #endif
}

@Test func isolationIdentityCannotUseProductionEvenThroughDecoding() throws {
    _ = try identity()
    #expect(throws: (any Error).self) {
        try SigDemoAppIdentity(bundleIdentifier: "org.whispersystems.signal", appGroupIdentifier: "group.org.whispersystems.signal", keychainService: "Signal")
    }
    let copiedEntitlements = Data("""
    {"bundleIdentifier":"dev.matbalez.sig-demo.ios","appGroupIdentifier":"group.org.whispersystems.signal","keychainService":"dev.matbalez.sig-demo.ios"}
    """.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(SigDemoAppIdentity.self, from: copiedEntitlements) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SIG_DEMO_PUBLIC_CONFIG_PATH"] != nil))
func existingPublicDesktopConfigurationDecodesWithoutPrintingContents() throws {
    let path = try #require(ProcessInfo.processInfo.environment["SIG_DEMO_PUBLIC_CONFIG_PATH"])
    let config = try JSONDecoder().decode(SigDemoConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(config.serverURL.host == "localhost")
    #expect(config.relay != nil)
    #if canImport(Security)
    _ = try SigDemoURLSessionTransport(configuration: config)
    #endif
}

@Test func publicPayloadRejectsPrivateFieldsAndRetainsExactRequestBytes() throws {
    let original = try payloadJSON()
    let payload = try SigDemoRegistrationPayload(json: original)
    #expect(payload.json == original)
    #expect(!payload.description.contains("synthetic-generated-password"))
    var leaked = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    leaked["aciIdentityPrivateKey"] = "must-never-send"
    #expect(throws: SigDemoError.invalidRegistrationPayload) {
        try SigDemoRegistrationPayload(json: JSONSerialization.data(withJSONObject: leaked))
    }
    leaked.removeValue(forKey: "aciIdentityPrivateKey")
    var attributes = leaked["accountAttributes"] as! [String: Any]
    attributes["discoverableByPhoneNumber"] = true
    leaked["accountAttributes"] = attributes
    #expect(throws: SigDemoError.invalidRegistrationPayload) {
        try SigDemoRegistrationPayload(json: JSONSerialization.data(withJSONObject: leaked))
    }
}

@Test func inviteAndDirectoryUseExactPrivateEndpointsAndGeneratedAccountAuthentication() async throws {
    let config = try configuration()
    let requestBody = try payloadJSON()
    let transport = StubTransport(body: accountJSON)
    let api = try SigDemoPrivateAPI(configuration: config, identity: identity(), transport: transport)
    let account = try await api.register(SigDemoRegistrationPayload(json: requestBody))
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests[0].url?.absoluteString == "https://localhost:14443/v1/sig-demo/accounts")
    #expect(requests[0].httpMethod == "POST")
    #expect(requests[0].httpBody == requestBody)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    let roster = StubTransport(body: Data("{\"accounts\":[{\"uuid\":\"\(account.uuid)\",\"displayName\":\"Alice\"}]}".utf8))
    let rosterAPI = try SigDemoPrivateAPI(configuration: config, identity: identity(), transport: roster)
    let password = "synthetic-generated-password-12345"
    let contacts = try await rosterAPI.directory(credentials: SigDemoCredentials(accountID: account.uuid, generatedPassword: password))
    #expect(contacts.map(\.displayName) == ["Alice"])
    let directoryRequest = try #require(await roster.requests.first)
    #expect(directoryRequest.url?.path == "/v1/sig-demo/directory")
    #expect(directoryRequest.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("\(account.uuid.uuidString.lowercased()).1:\(password)".utf8).base64EncodedString())
    let rejection = StubTransport(status: 403, body: Data("{\"error\":\"invalid invite\"}".utf8))
    let rejectedAPI = try SigDemoPrivateAPI(configuration: config, identity: identity(), transport: rejection)
    await #expect(throws: SigDemoError.rejected(status: 403)) {
        try await rejectedAPI.register(SigDemoRegistrationPayload(json: requestBody))
    }
}

private actor Events {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor MemoryDrafts: SigDemoRegistrationDraftStore {
    var pending: SigDemoPendingRegistration?
    let events: Events
    init(events: Events, pending: SigDemoPendingRegistration? = nil) { self.events = events; self.pending = pending }
    func load() async throws -> SigDemoPendingRegistration? { pending }
    func save(_ draft: SigDemoPendingRegistration) async throws { pending = draft; await events.append("save") }
    func remove() async throws { pending = nil; await events.append("remove") }
}

private enum SyntheticFailure: Error { case disconnected, commitFailed }

private actor StubAdapter: SigDemoSignalRegistrationAdapter {
    let events: Events
    let payload: SigDemoRegistrationPayload
    var failCommit: Bool
    init(events: Events, failCommit: Bool = false) throws {
        self.events = events; self.payload = try SigDemoRegistrationPayload(json: payloadJSON()); self.failCommit = failCommit
    }
    func prepare(inviteCode: String, displayName: String, scope: SigDemoRegistrationScope) async throws -> SigDemoPreparedRegistration {
        await events.append("prepare")
        return try SigDemoPreparedRegistration(draft: SigDemoPendingRegistration(scope: scope, sealedState: Data("synthetic-ciphertext-only".utf8)), payload: payload)
    }
    func restorePayload(from draft: SigDemoPendingRegistration) async throws -> SigDemoRegistrationPayload {
        await events.append("restore"); return payload
    }
    func commit(account: SigDemoAccount, draft: SigDemoPendingRegistration) async throws {
        await events.append("commit")
        if failCommit { failCommit = false; throw SyntheticFailure.commitFailed }
    }
}

private actor StubAccountAPI: SigDemoAccountAPI {
    let events: Events
    var firstError: (any Error)?
    var bodies: [Data] = []
    init(events: Events, firstError: (any Error)? = nil) { self.events = events; self.firstError = firstError }
    func register(_ payload: SigDemoRegistrationPayload) async throws -> SigDemoAccount {
        await events.append("redeem"); bodies.append(payload.json)
        if let error = firstError { firstError = nil; throw error }
        return try JSONDecoder().decode(SigDemoAccount.self, from: accountJSON)
    }
}

@Test func ambiguousRegistrationResumesOriginalIdentityAfterDurableDraftSave() async throws {
    let scope = try SigDemoRegistrationScope(identity: identity(), configuration: configuration())
    let events = Events()
    let store = MemoryDrafts(events: events)
    let adapter = try StubAdapter(events: events)
    let api = StubAccountAPI(events: events, firstError: SyntheticFailure.disconnected)
    let coordinator = SigDemoRegistrationCoordinator(scope: scope, api: api, store: store, adapter: adapter)
    await #expect(throws: SyntheticFailure.self) { try await coordinator.register(inviteCode: "invite", displayName: "Alice") }
    #expect(await store.pending != nil)
    _ = try await coordinator.register(inviteCode: "replacement-must-be-ignored", displayName: "Bob")
    #expect(await store.pending == nil)
    #expect(await events.values == ["prepare", "save", "redeem", "restore", "redeem", "commit", "remove"])
    let bodies = await api.bodies
    #expect(bodies.count == 2 && bodies[0] == bodies[1])
}

@Test func failedLocalCommitPreservesDraftAndDefinitiveRejectionClearsIt() async throws {
    let scope = try SigDemoRegistrationScope(identity: identity(), configuration: configuration())
    let events = Events()
    let store = MemoryDrafts(events: events)
    let adapter = try StubAdapter(events: events, failCommit: true)
    let api = StubAccountAPI(events: events)
    let coordinator = SigDemoRegistrationCoordinator(scope: scope, api: api, store: store, adapter: adapter)
    await #expect(throws: SyntheticFailure.self) { try await coordinator.register(inviteCode: "invite", displayName: "Alice") }
    #expect(await store.pending != nil)
    #expect(try await coordinator.resumeIfNeeded() != nil)
    #expect(await store.pending == nil)
    let rejectedStore = MemoryDrafts(events: events)
    let rejected = SigDemoRegistrationCoordinator(scope: scope, api: StubAccountAPI(events: events, firstError: SigDemoError.rejected(status: 403)), store: rejectedStore, adapter: adapter)
    await #expect(throws: SigDemoError.rejected(status: 403)) { try await rejected.register(inviteCode: "expired", displayName: "Alice") }
    #expect(await rejectedStore.pending == nil)
}

@Test func draftCannotCrossTrustEnvironmentsOrVersions() async throws {
    let scope = try SigDemoRegistrationScope(identity: identity(), configuration: configuration())
    let changedScope = try SigDemoRegistrationScope(identity: identity(), configuration: configuration(["serverTrustRoots": [Data(repeating: 8, count: 33).base64EncodedString()]]))
    let events = Events()
    let pending = try SigDemoPendingRegistration(scope: scope, sealedState: Data([1]))
    let store = MemoryDrafts(events: events, pending: pending)
    let coordinator = try SigDemoRegistrationCoordinator(scope: changedScope, api: StubAccountAPI(events: events), store: store, adapter: StubAdapter(events: events))
    await #expect(throws: SigDemoError.draftBelongsToAnotherEnvironment) { try await coordinator.resumeIfNeeded() }
    #expect(await store.pending == pending)
    #expect(await events.values.isEmpty)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as! [String: Any]
    json["version"] = 2
    let unknown = try JSONDecoder().decode(SigDemoPendingRegistration.self, from: JSONSerialization.data(withJSONObject: json))
    let unknownStore = MemoryDrafts(events: events, pending: unknown)
    let unknownCoordinator = try SigDemoRegistrationCoordinator(scope: scope, api: StubAccountAPI(events: events), store: unknownStore, adapter: StubAdapter(events: events))
    await #expect(throws: SigDemoError.unsupportedDraftVersion) { try await unknownCoordinator.resumeIfNeeded() }
    #expect(await unknownStore.pending == unknown)
}

private actor InterruptibleAccountAPI: SigDemoAccountAPI {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var bodies: [Data] = []

    func waitForRequest() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func register(_ payload: SigDemoRegistrationPayload) async throws -> SigDemoAccount {
        let firstAttempt = !started
        started = true
        bodies.append(payload.json)
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        // The test cancels as soon as this request begins, then retries without
        // waiting. This models dismissing onboarding during a real URLSession.
        if firstAttempt { try await Task.sleep(for: .seconds(30)) }
        return try JSONDecoder().decode(SigDemoAccount.self, from: accountJSON)
    }
}

@Test func cancelledRegistrationRetainsEncryptedIdentityForNextPresentation() async throws {
    let scope = try SigDemoRegistrationScope(identity: identity(), configuration: configuration())
    let events = Events()
    let store = MemoryDrafts(events: events)
    let api = InterruptibleAccountAPI()
    let coordinator = try SigDemoRegistrationCoordinator(scope: scope, api: api, store: store, adapter: StubAdapter(events: events))
    let operation = Task { try await coordinator.register(inviteCode: "invitation", displayName: "Alice") }
    await api.waitForRequest()
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(await store.pending != nil)
    #expect(try await coordinator.resumeIfNeeded() != nil)
    #expect(await store.pending == nil)
    let bodies = await api.bodies
    #expect(bodies.count == 2 && bodies[0] == bodies[1])
    #expect(await events.values == ["prepare", "save", "restore", "commit", "remove"])
}
