// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SigDemoMesh

/// Streams only to this runtime's owned embedded Node. The public GDK endpoint
/// is a separate validating bridge; no Node control route is forwarded.
actor PaidNodeTransport: MeshInferenceTransport {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let endpoint: URL
    private let model: String
    private let session: URLSession
    private var active: (id: UUID, task: Task<Void, Never>)?
    private var invocation: UUID?
    private var stopped = false

    init(baseURL: URL, model: String) throws {
        guard Self.validBaseURL(baseURL), !model.isEmpty, model.utf8.count <= 128 else {
            throw PaidMeshError.invalidConfiguration
        }
        endpoint = baseURL.appendingPathComponent("chat/completions")
        self.model = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 95
        configuration.timeoutIntervalForResource = 100
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static func validBaseURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "http" && parts.host == "127.0.0.1"
            && parts.port.map { (1...65_535).contains($0) } == true
            && parts.percentEncodedPath == "/v1" && parts.user == nil && parts.password == nil
            && parts.query == nil && parts.fragment == nil
    }

    func setInvocation(_ id: UUID?) throws {
        guard !stopped else { throw PaidMeshError.stopped }
        guard active == nil else { throw PaidMeshError.busy }
        invocation = id
    }

    func drainInvocation() async {
        invocation = nil
        let prior = active
        prior?.task.cancel()
        await prior?.task.value
        if active?.id == prior?.id { active = nil }
    }

    func start(model: String?) async throws {
        guard !stopped, model == nil || model == self.model else { throw PaidMeshError.invalidConfiguration }
    }

    func listModels() async throws -> [MeshInferenceModel] {
        guard !stopped else { throw PaidMeshError.stopped }
        return [.init(id: model, name: model)]
    }

    func streamChatCompletions(body: Data) async throws -> AsyncThrowingStream<MeshInferenceEvent, Error> {
        try Task.checkCancellation()
        guard !stopped else { throw PaidMeshError.stopped }
        guard invocation != nil else { throw PaidMeshError.spendingDisabled }
        guard active == nil else { throw PaidMeshError.busy }
        guard body.count <= 4 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["model"] as? String == model else { throw PaidMeshError.invalidConfiguration }
        let (stream, continuation) = AsyncThrowingStream<MeshInferenceEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let id = UUID()
        let endpoint = self.endpoint
        let session = self.session
        let task = Task {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.httpBody = body
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, (100...599).contains(response.statusCode) else {
                    throw MeshInferenceError.invalidResponse
                }
                let contentType = response.value(forHTTPHeaderField: "Content-Type")
                try Self.emit(.started(statusCode: UInt16(response.statusCode), contentType: contentType), continuation)
                guard response.statusCode == 200, contentType?.lowercased().hasPrefix("text/event-stream") == true else {
                    throw response.statusCode == 402 ? MeshInferenceError.paymentRequired : MeshInferenceError.unavailable
                }
                var frame = Data()
                var count = 0
                for try await byte in bytes {
                    try Task.checkCancellation()
                    frame.append(byte)
                    count += 1
                    guard frame.count <= 1024 * 1024, count <= 16 * 1024 * 1024 else {
                        throw MeshInferenceError.invalidResponse
                    }
                    if frame.suffix(2).elementsEqual([10, 10]) || frame.suffix(4).elementsEqual([13, 10, 13, 10]) {
                        guard let raw = String(data: frame, encoding: .utf8) else { throw MeshInferenceError.invalidResponse }
                        let data = raw.replacingOccurrences(of: "\r\n", with: "\n")
                            .components(separatedBy: "\n").compactMap { line -> String? in
                                guard line.hasPrefix("data:") else { return nil }
                                let value = line.dropFirst(5)
                                return String(value.first == " " ? value.dropFirst() : value)
                            }.joined(separator: "\n")
                        try Self.emit(.sse(raw: raw, data: data), continuation)
                        frame.removeAll(keepingCapacity: true)
                    }
                }
                guard frame.isEmpty else { throw MeshInferenceError.invalidResponse }
                continuation.finish()
            } catch is CancellationError { continuation.finish(throwing: PaidMeshError.stopped) }
            catch { continuation.finish(throwing: error) }
            if active?.id == id { active = nil }
        }
        active = (id, task)
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func emit(_ event: MeshInferenceEvent,
                             _ continuation: AsyncThrowingStream<MeshInferenceEvent, Error>.Continuation) throws {
        switch continuation.yield(event) {
        case .enqueued: return
        case .terminated: throw CancellationError()
        case .dropped: throw MeshInferenceError.invalidResponse
        @unknown default: throw MeshInferenceError.invalidResponse
        }
    }

    func stop() async {
        stopped = true
        await drainInvocation()
        session.invalidateAndCancel()
    }
}
