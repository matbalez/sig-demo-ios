// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network

/// Adapts the local GDK's streaming HTTP provider to the embedded Mesh client.
/// A random loopback port owns one immutable model for its entire lifetime.
actor LoopbackBridge {
    private let transport: any MeshInferenceTransport
    private let model: String
    private let paymentPolicy: MeshBridgePaymentPolicy
    private let queue = DispatchQueue(label: "dev.matbalez.sig-demo.ios.mesh.bridge")
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var port: UInt16?
    private var stopped = false
    private var sessions: [UUID: Session] = [:]
    private static let headerLimit = 16 * 1024
    private static let bodyLimit = 4 * 1024 * 1024
    private static let streamLimit = 16 * 1024 * 1024

    private struct Session {
        let connection: NWConnection
        var worker: Task<Void, Never>?
        var monitor: Task<Void, Never>?
        var deadline: Task<Void, Never>?
    }

    init(transport: any MeshInferenceTransport, model: String, paymentPolicy: MeshBridgePaymentPolicy = .freeOnly) {
        self.transport = transport
        self.model = model
        self.paymentPolicy = paymentPolicy
    }

    func start() async throws -> URL {
        guard listener == nil, !stopped, PublicMeshRuntime.validModel(model) else {
            throw MeshInferenceError.invalidConfiguration
        }
        try paymentPolicy.validate()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerState(state) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: queue)
            }
        } onCancel: {
            listener.cancel()
        }
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard !stopped, let number = listener?.port?.rawValue,
                  let url = URL(string: "http://127.0.0.1:\(number)/v1") else {
                ready?.resume(throwing: MeshInferenceError.stopped)
                ready = nil
                return
            }
            port = number
            ready?.resume(returning: url)
            ready = nil
        case .failed, .cancelled:
            ready?.resume(throwing: MeshInferenceError.unavailable)
            ready = nil
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, port != nil, sessions.count < 8 else { connection.cancel(); return }
        let id = UUID()
        sessions[id] = Session(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { await self?.cancel(id) }
            default: break
            }
        }
        connection.start(queue: queue)
        sessions[id]?.worker = Task { await self.serve(connection, id: id) }
        sessions[id]?.deadline = Task {
            do {
                try await Task.sleep(for: .seconds(100))
                self.cancel(id)
            } catch {}
        }
    }

    private func cancel(_ id: UUID) {
        guard let session = sessions[id] else { return }
        session.worker?.cancel()
        session.monitor?.cancel()
        session.deadline?.cancel()
        session.connection.cancel()
    }

    private func finish(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.monitor?.cancel()
        session.deadline?.cancel()
        session.connection.cancel()
    }

    func stop() async {
        stopped = true
        ready?.resume(throwing: MeshInferenceError.stopped)
        ready = nil
        listener?.cancel()
        listener = nil
        port = nil
        let active = Array(sessions.values)
        for id in sessions.keys { cancel(id) }
        for session in active { await session.worker?.value }
        sessions.removeAll()
    }

    private func serve(_ connection: NWConnection, id: UUID) async {
        defer { finish(id) }
        var sentHeaders = false
        do {
            let request = try await readRequest(connection)
            #if DEBUG
            NSLog("SIG_DEMO_MESH_BRIDGE_REQUEST_VALIDATED")
            #endif
            try Task.checkCancellation()
            guard !stopped else { throw MeshInferenceError.stopped }
            // Once the complete body is read, a peer EOF means cancellation.
            // Pipelining is deliberately unsupported; there is one request/socket.
            sessions[id]?.monitor = Task {
                _ = try? await Self.receive(connection)
                self.cancel(id)
            }
            let events = try await transport.streamChatCompletions(body: request)
            var started = false
            var done = false
            var bytes = 0
            for try await event in events {
                try Task.checkCancellation()
                guard !stopped else { throw MeshInferenceError.stopped }
                switch event {
                case .started(let status, let contentType):
                    guard !started else { throw MeshInferenceError.invalidResponse }
                    started = true
                    if status == 402 { throw MeshInferenceError.paymentRequired }
                    guard status == 200,
                          contentType?.lowercased().hasPrefix("text/event-stream") == true else {
                        throw MeshInferenceError.unavailable
                    }
                    try await Self.send(Self.responseHeaders(status: 200, contentType: "text/event-stream"), connection)
                    sentHeaders = true
                    #if DEBUG
                    NSLog("SIG_DEMO_MESH_BRIDGE_STREAM_STARTED")
                    #endif
                case .sse(let raw, let data):
                    guard started, !done, raw.utf8.count <= 1024 * 1024 else {
                        throw MeshInferenceError.invalidResponse
                    }
                    let frame = raw.hasSuffix("\n\n") || raw.hasSuffix("\r\n\r\n") ? raw : raw + "\n\n"
                    bytes += frame.utf8.count
                    guard bytes <= Self.streamLimit else { throw MeshInferenceError.invalidResponse }
                    try await Self.send(Data(frame.utf8), connection)
                    if data == "[DONE]" { done = true }
                }
            }
            guard started, done else { throw MeshInferenceError.invalidResponse }
            try await Self.send(nil, connection, final: true)
        } catch {
            if !Task.isCancelled, !stopped {
                if sentHeaders {
                    #if DEBUG
                    NSLog("SIG_DEMO_MESH_BRIDGE_STREAM_FAILED")
                    #endif
                    // Preserve a transport failure as an error, never a clean
                    // truncated completion. No remote error descriptions escape.
                    let payload = "data: {\"error\":{\"message\":\"Public Mesh inference was interrupted.\",\"type\":\"mesh_unavailable\"}}\n\n"
                    try? await Self.send(Data(payload.utf8), connection)
                } else {
                    let status = (error as? MeshInferenceError) == .paymentRequired ? 402 :
                        ((error as? BridgeError) != nil ? 400 : 503)
                    #if DEBUG
                    NSLog("SIG_DEMO_MESH_BRIDGE_ERROR status=%d", status)
                    #endif
                    let message = status == 402 ? "Public Mesh requires a free inference route." :
                        (status == 400 ? "Invalid local Mesh request." : "Public Mesh is unavailable. Try again while the app is open.")
                    let body = try? JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": "mesh_unavailable"]])
                    if let body {
                        var response = Self.responseHeaders(status: status, contentType: "application/json", length: body.count)
                        response.append(body)
                        try? await Self.send(response, connection)
                    }
                }
            }
        }
    }

    private enum BridgeError: Error { case invalidRequest }

    private func readRequest(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        var headerEnd: Data.Index?
        while headerEnd == nil {
            let piece = try await Self.receive(connection)
            guard !piece.isEmpty else { throw BridgeError.invalidRequest }
            buffer.append(piece)
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))?.upperBound
            guard (headerEnd ?? buffer.endIndex) <= Self.headerLimit else { throw BridgeError.invalidRequest }
        }
        guard let headerEnd, let header = String(data: buffer[..<headerEnd], encoding: .utf8), let port else {
            throw BridgeError.invalidRequest
        }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first == "POST /v1/chat/completions HTTP/1.1" else { throw BridgeError.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else {
                throw BridgeError.invalidRequest
            }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[name] == nil else { throw BridgeError.invalidRequest }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(port)",
              headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              headers["transfer-encoding"] == nil, headers["expect"] == nil,
              headers["authorization"] == nil, headers["proxy-authorization"] == nil,
              headers["origin"] == nil, headers["x-mesh-target"] == nil,
              let length = headers["content-length"], !length.isEmpty,
              length.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(length), count > 0, count <= Self.bodyLimit else {
            throw BridgeError.invalidRequest
        }
        var body = Data(buffer[headerEnd...])
        while body.count < count {
            let piece = try await Self.receive(connection)
            guard !piece.isEmpty, body.count + piece.count <= count else { throw BridgeError.invalidRequest }
            body.append(piece)
        }
        guard body.count == count,
              var object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["model"] as? String == model,
              let stream = object["stream"] as? NSNumber,
              CFGetTypeID(stream) == CFBooleanGetTypeID(), stream.boolValue,
              object["messages"] is [Any] else { throw BridgeError.invalidRequest }
        // The bridge owns these terms. Caller-supplied payment fields cannot
        // expand authority; paid transports also enforce their durable caps.
        object["mesh_payment"] = paymentPolicy.requestTerms
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func receive(_ connection: NWConnection) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: Data()) }
                else { continuation.resume(throwing: MeshInferenceError.invalidResponse) }
            }
        }
    }

    private static func send(_ data: Data?, _ connection: NWConnection, final: Bool = false) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage,
                            isComplete: final, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private static func responseHeaders(status: Int, contentType: String, length: Int? = nil) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 402: "Payment Required", 503: "Service Unavailable"][status] ?? "Error"
        var headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if let length { headers += "Content-Length: \(length)\r\n" }
        return Data((headers + "\r\n").utf8)
    }
}
