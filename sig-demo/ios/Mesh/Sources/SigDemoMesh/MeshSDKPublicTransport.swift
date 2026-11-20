// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MeshLLM

/// Uses only the released thin client. It creates no host, serving runtime,
/// model cache, wallet, payment policy, or external inference fallback.
public actor MeshSDKPublicTransport: MeshInferenceTransport {
    private struct Startup: Sendable {
        let handle: MeshClientHandle
        let models: [MeshInferenceModel]
    }

    private let ownerKeypairHex: String
    private var generation: UInt64 = 0
    private var startup: Task<Startup, Error>?
    private var handle: MeshClientHandle?
    private var models: [MeshInferenceModel] = []
    private var streams: [UUID: PublicMeshStreamListener] = [:]

    public init(ownerKeypairHex: String) {
        self.ownerKeypairHex = ownerKeypairHex
    }

    public static func generateOwnerKeypairHex() throws -> String {
        MeshLLM.generateOwnerKeypairHex()
    }

    public func start(model: String?) async throws {
        await stop()
        try Task.checkCancellation()
        generation &+= 1
        // The upstream test override changes transport globally. Refuse it in
        // the app instead of silently sending public-Mesh requests over HTTP.
        guard ProcessInfo.processInfo.environment["MESH_CLIENT_API_BASE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              ownerKeypairHex.utf8.count == 128,
              ownerKeypairHex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }),
              model.map(PublicMeshRuntime.validModel) ?? true else {
            throw MeshInferenceError.invalidConfiguration
        }
        let epoch = generation
        let identity = ownerKeypairHex
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let query = PublicMeshQuery(model: model, minVramGb: nil, region: nil, targetName: nil, relays: [])
            let discovered = try discoverPublicMeshes(query: query)
            try Task.checkCancellation()
            let eligible = discovered.filter { listing in
                !listing.serving.isEmpty
                    && (listing.maxClients == 0 || listing.clientCount < listing.maxClients)
                    && (model == nil || listing.serving.contains(model!))
            }
            guard let selected = eligible.sorted(by: { $0.publishedAt > $1.publishedAt }).first else {
                throw MeshInferenceError.unavailable
            }
            var seen = Set<String>()
            let catalog = selected.serving.filter {
                PublicMeshRuntime.validModel($0) && seen.insert($0).inserted
            }.prefix(128).map { MeshInferenceModel(id: $0, name: $0) }
            guard !catalog.isEmpty else { throw MeshInferenceError.unavailable }
            let client = try createClient(ownerKeypairBytesHex: identity, inviteToken: selected.inviteToken)
            do {
                try Task.checkCancellation()
                try client.start()
                try Task.checkCancellation()
                return Startup(handle: client, models: catalog)
            } catch {
                client.stop()
                throw error
            }
        }
        startup = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard epoch == generation, !Task.isCancelled else {
                await Task.detached(priority: .utility) { result.handle.stop() }.value
                throw MeshInferenceError.stopped
            }
            handle = result.handle
            models = result.models
            startup = nil
        } catch {
            if epoch == generation { startup = nil }
            if error is CancellationError { throw MeshInferenceError.stopped }
            if let error = error as? MeshInferenceError { throw error }
            throw MeshInferenceError.unavailable
        }
    }

    public func listModels() async throws -> [MeshInferenceModel] {
        guard handle != nil else { throw MeshInferenceError.stopped }
        // Advertised catalog only: the upstream HTTP GET has no cancellable
        // request ID or read deadline. Availability is established by inference.
        return models
    }

    public func streamChatCompletions(body: Data) async throws -> AsyncThrowingStream<MeshInferenceEvent, Error> {
        try Task.checkCancellation()
        guard let handle else { throw MeshInferenceError.stopped }
        guard body.count <= 4 * 1024 * 1024,
              var object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = object["model"] as? String,
              models.contains(where: { $0.id == model }) else {
            throw MeshInferenceError.invalidConfiguration
        }
        object["mesh_payment"] = ["mode": "free_only"]
        object["stream"] = true
        let encoded = try JSONSerialization.data(withJSONObject: object)
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw MeshInferenceError.invalidConfiguration
        }
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<MeshInferenceEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(256))
        let listener = PublicMeshStreamListener(continuation: continuation, cancel: { request in
            handle.cancel(requestId: request)
        }, nativeFinished: { [weak self] in
            Task { await self?.removeStream(id) }
        })
        streams[id] = listener
        continuation.onTermination = { [weak listener] _ in listener?.cancel() }
        do {
            #if DEBUG
            NSLog("SIG_DEMO_MESH_SDK_STREAM_CREATE")
            #endif
            let request = try handle.openaiStream(path: "/v1/chat/completions", bodyJson: json, listener: listener)
            listener.activate(requestId: request)
        } catch {
            listener.creationFailed()
            streams.removeValue(forKey: id)
            throw MeshInferenceError.unavailable
        }
        return stream
    }

    public func stop() async {
        generation &+= 1
        let starting = startup
        startup = nil
        starting?.cancel()
        let previous = handle
        handle = nil
        models = []
        let pending = Array(streams.values)
        streams.removeAll()
        for listener in pending { listener.cancel() }
        if let previous {
            await Task.detached(priority: .utility) { previous.stop() }.value
        }
        for listener in pending { await listener.waitForNativeCompletion() }
        // A blocking Nostr lookup cannot be interrupted through the released
        // FFI. Drain it and dispose any late handle before teardown returns.
        if let starting, case .success(let result) = await starting.result {
            await Task.detached(priority: .utility) { result.handle.stop() }.value
        }
    }

    private func removeStream(_ id: UUID) { streams.removeValue(forKey: id) }
}

/// The raw callback retains the request ID so cancellation is explicit and
/// teardown can await the Rust terminal callback, after QUIC endpoint cleanup.
final class PublicMeshStreamListener: OpenAiStreamListener, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<MeshInferenceEvent, Error>.Continuation
    private let cancelRequest: @Sendable (String) -> Void
    private let nativeFinished: @Sendable () -> Void
    private var requestId: String?
    private var uiFinished = false
    private var cancelled = false
    private var nativeComplete = false
    private var receivedBytes = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(continuation: AsyncThrowingStream<MeshInferenceEvent, Error>.Continuation,
         cancel: @escaping @Sendable (String) -> Void,
         nativeFinished: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.cancelRequest = cancel
        self.nativeFinished = nativeFinished
    }

    func activate(requestId: String) {
        lock.lock()
        self.requestId = requestId
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { cancelRequest(requestId) }
    }

    func onEvent(event: OpenAiStreamEventNative) {
        switch event {
        case .started(_, let status, let contentType):
            #if DEBUG
            NSLog("SIG_DEMO_MESH_SDK_STREAM_STARTED status=%u", UInt32(status))
            #endif
            yield(.started(statusCode: status, contentType: contentType))
        case .sse(_, _, let data, let raw):
            yield(.sse(raw: raw, data: data))
        case .completed:
            #if DEBUG
            NSLog("SIG_DEMO_MESH_SDK_STREAM_COMPLETE")
            #endif
            finishNative(error: nil)
        case .failed(_, let status, _, _):
            #if DEBUG
            if let status { NSLog("SIG_DEMO_MESH_SDK_STREAM_FAILED status=%u", UInt32(status)) }
            else { NSLog("SIG_DEMO_MESH_SDK_STREAM_FAILED status=none") }
            #endif
            finishNative(error: status == 402 ? MeshInferenceError.paymentRequired : MeshInferenceError.unavailable)
        }
    }

    private func yield(_ event: MeshInferenceEvent) {
        lock.lock()
        let finished = uiFinished
        var exceedsBudget = false
        if case .sse(let raw, let data) = event, !finished {
            let size = raw.utf8.count + data.utf8.count
            exceedsBudget = raw.utf8.count > 1024 * 1024
                || data.utf8.count > 1024 * 1024
                || size > 16 * 1024 * 1024 - receivedBytes
            if !exceedsBudget { receivedBytes += size }
        }
        lock.unlock()
        guard !finished else { return }
        guard !exceedsBudget else { cancel(error: MeshInferenceError.invalidResponse); return }
        switch continuation.yield(event) {
        case .dropped: cancel(error: MeshInferenceError.invalidResponse)
        case .terminated: cancel()
        case .enqueued: break
        @unknown default: cancel(error: MeshInferenceError.invalidResponse)
        }
    }

    func cancel(error: Error = MeshInferenceError.stopped) {
        lock.lock()
        guard !cancelled, !nativeComplete else { lock.unlock(); return }
        cancelled = true
        uiFinished = true
        let request = requestId
        lock.unlock()
        continuation.finish(throwing: error)
        if let request { cancelRequest(request) }
    }

    func creationFailed() {
        #if DEBUG
        NSLog("SIG_DEMO_MESH_SDK_STREAM_FAILED status=none")
        #endif
        finishNative(error: MeshInferenceError.unavailable)
    }

    private func finishNative(error: Error?) {
        lock.lock()
        guard !nativeComplete else { lock.unlock(); return }
        nativeComplete = true
        let finishUI = !uiFinished
        uiFinished = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        if finishUI {
            if let error { continuation.finish(throwing: error) }
            else { continuation.finish() }
        }
        for waiter in pending { waiter.resume() }
        nativeFinished()
    }

    func waitForNativeCompletion() async {
        await withCheckedContinuation { waiter in
            lock.lock()
            if nativeComplete { lock.unlock(); waiter.resume() }
            else { waiters.append(waiter); lock.unlock() }
        }
    }
}
