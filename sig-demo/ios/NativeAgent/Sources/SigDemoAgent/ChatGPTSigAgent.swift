// Copyright 2026 sig demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum SigChatAgentError: Error {
    case invalidConfiguration
    case closed
    case warmupForbidden
}

/// Swift lifecycle adapter for the same Rust Goose state machine used on desktop.
/// The Signal adapter remains responsible for filtering eligible chat records
/// and sending encrypted response frames through Signal's normal send pipeline.
public actor ChatGPTSigAgent {
    private let accountID: String
    private var sessions: [String: SigAgentSession] = [:]
    private var streams: [UUID: SigAgentStream] = [:]
    private var jobs: [UUID: Task<Void, Error>] = [:]
    private var closed = false
    private var configuration: SigAgentConfig?
    private var localEngine: SigLocalModelEngine?

    /// The lifecycle owner supplies account-scoped credentials. This adapter
    /// does not persist them or include them in Signal messages. Brave is used
    /// only by the GDK's local search tool, never as a model credential.
    public init(accountID: String, apiKey: String, model: String = "gpt-6-luna",
                braveApiKey: String? = nil) throws {
        guard !accountID.isEmpty, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              apiKey.utf8.count <= 4096, !apiKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.utf8.count <= 128,
              !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Self.validSearchCredential(braveApiKey) else {
            throw SigChatAgentError.invalidConfiguration
        }
        self.accountID = accountID
        self.configuration = SigAgentConfig(provider: .chatgpt, model: model, baseUrl: nil,
            targetNodeId: nil, apiKey: apiKey, braveApiKey: braveApiKey, phalaApiKey: nil)
    }

    /// Uses the app-owned foreground Mesh bridge. The bridge owns discovery and
    /// enforces the selected routing policy. The optional search credential is
    /// used only by the GDK's local Brave tool and never sent to Mesh or a model.
    public init(accountID: String, publicMeshBaseURL: URL, model: String,
                braveApiKey: String? = nil) throws {
        guard !accountID.isEmpty,
              let endpoint = URLComponents(url: publicMeshBaseURL, resolvingAgainstBaseURL: false),
              endpoint.scheme?.lowercased() == "http", endpoint.host == "127.0.0.1",
              let port = endpoint.port, (1...65_535).contains(port),
              endpoint.percentEncodedPath == "/v1", endpoint.query == nil, endpoint.fragment == nil,
              endpoint.user == nil, endpoint.password == nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.utf8.count <= 128,
              !model.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              Self.validSearchCredential(braveApiKey) else {
            throw SigChatAgentError.invalidConfiguration
        }
        self.accountID = accountID
        self.configuration = SigAgentConfig(provider: .meshLlm, model: model,
            baseUrl: publicMeshBaseURL.absoluteString, targetNodeId: nil,
            apiKey: nil, braveApiKey: braveApiKey, phalaApiKey: nil)
    }

    private static func validSearchCredential(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 1_024
            && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }

    /// Direct in-process GDK inference. The lifecycle owner loads and retires
    /// this pinned engine; Brave remains an agent tool on the same device.
    public init(accountID: String, localEngine: SigLocalModelEngine, model: String,
        braveApiKey: String? = nil
    ) throws {
        guard !accountID.isEmpty, !model.isEmpty, model.utf8.count <= 128,
              !model.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              Self.validSearchCredential(braveApiKey) else { throw SigChatAgentError.invalidConfiguration }
        self.accountID = accountID
        self.localEngine = localEngine
        self.configuration = SigAgentConfig(provider: .localInference, model: model,
            baseUrl: nil, targetNodeId: nil, apiKey: nil, braveApiKey: braveApiKey, phalaApiKey: nil)
    }

    #if SIG_DEMO_AGENT_TESTING
    // Synthetic loopback providers are compiled only into the host smoke test.
    // Arbitrary synthetic endpoints and model mutation remain test-only. The
    // shipping Mesh initializer accepts only the owned loopback bridge shape.
    public init(testAccountID: String, syntheticEndpoint: URL, model: String,
                braveApiKey: String? = nil) {
        self.accountID = testAccountID
        self.configuration = SigAgentConfig(provider: .meshLlm, model: model,
            baseUrl: syntheticEndpoint.absoluteString, targetNodeId: nil,
            apiKey: nil, braveApiKey: braveApiKey, phalaApiKey: nil)
    }
    public func useSyntheticModel(_ model: String) {
        if var config = configuration { config.model = model; configuration = config }
    }
    /// Tests the shipping hosted constructor's retained search credential with
    /// a loopback model fixture instead of contacting the hosted provider.
    public func useSyntheticMeshEndpoint(_ endpoint: URL, model: String) {
        if var config = configuration {
            config.provider = .meshLlm
            config.baseUrl = endpoint.absoluteString
            config.apiKey = nil
            config.model = model
            configuration = config
        }
    }
    #endif

    public func answer(
        chatID: String,
        request: SigAgentRequest,
        onEvent: @escaping @Sendable (SigAgentEvent) async throws -> Void
    ) async throws {
        guard !closed else { throw SigChatAgentError.closed }
        guard request.mode == .answer else { throw SigChatAgentError.warmupForbidden }
        try Task.checkCancellation()
        // Register the Swift invocation before its first suspension. Account
        // teardown must also drain starts and suspended UI callbacks, not just
        // Rust streams that have already been returned by UniFFI.
        let id = UUID()
        let job = Task {
            try await perform(id: id, chatID: chatID, request: request, onEvent: onEvent)
        }
        jobs[id] = job
        let deadline = Task {
            try await Task.sleep(for: .seconds(120))
            job.cancel()
        }
        defer { deadline.cancel(); jobs.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private func perform(
        id: UUID, chatID: String, request: SigAgentRequest, onEvent: @Sendable (SigAgentEvent) async throws -> Void
    ) async throws {
        guard !closed else { throw SigChatAgentError.closed }
        try Task.checkCancellation()
        let session: SigAgentSession
        if let retained = sessions[chatID] {
            session = retained
        } else if let localEngine {
            session = try createLocalSigAgentSession(accountId: accountID, chatId: chatID, engine: localEngine)
            sessions[chatID] = session
        } else {
            session = try createSigAgentSession(accountId: accountID, chatId: chatID)
            sessions[chatID] = session
        }
        guard let configuration else { throw SigChatAgentError.closed }
        let stream = try await session.run(config: configuration, request: request)
        streams[id] = stream
        do {
            guard !closed else { throw SigChatAgentError.closed }
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                while let event = try await stream.nextEvent() {
                    guard !closed else { throw SigChatAgentError.closed }
                    try Task.checkCancellation()
                    try await onEvent(event)
                    guard !closed else { throw SigChatAgentError.closed }
                    try Task.checkCancellation()
                }
                try Task.checkCancellation()
            } onCancel: {
                stream.cancel()
            }
        } catch {
            await stream.shutdown()
            streams.removeValue(forKey: id)
            throw error
        }
        await stream.shutdown()
        streams.removeValue(forKey: id)
    }

    /// Call when this Signal account closes or the iOS app suspends. The Rust
    /// streams release network work before account-scoped sessions are dropped.
    /// Call from the lifecycle owner, outside onEvent. Event callbacks must
    /// cooperate with task cancellation; teardown waits for them to finish.
    public func shutdown() async {
        closed = true
        configuration = nil
        let invocations = Array(jobs.values)
        for job in invocations { job.cancel() }
        let draining = Array(streams.values)
        for stream in draining { stream.cancel() }
        for job in invocations { _ = try? await job.value }
        for stream in draining { await stream.shutdown() }
        jobs.removeAll()
        streams.removeAll()
        sessions.removeAll()
        localEngine = nil
    }
}
