// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct MeshInferenceModel: Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum MeshInferenceEvent: Sendable {
    case started(statusCode: UInt16, contentType: String?)
    case sse(raw: String, data: String)
}

public enum MeshInferenceError: Error, Sendable, Equatable {
    case invalidConfiguration
    case unavailable
    case paymentRequired
    case invalidResponse
    case stopped
}

/// The agent consumes raw Chat Completions JSON and SSE, including tool calls.
/// A future payments-v3 transport can implement this boundary without changing
/// the on-device agent or Signal response format. The released SDK adapter is free only.
public protocol MeshInferenceTransport: Sendable {
    func start(model: String?) async throws
    func listModels() async throws -> [MeshInferenceModel]
    func streamChatCompletions(body: Data) async throws -> AsyncThrowingStream<MeshInferenceEvent, Error>
    func stop() async
}

public struct PublicMeshRoute: Sendable, Equatable {
    public let baseURL: URL
    public let model: String

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
    }
}
