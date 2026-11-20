// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network
import SigDemoKit

/// A loopback-only byte relay. TLS is never terminated here: the native Signal
/// transport and URLSession authenticate the private server's localhost CA.
final class SigDemoTCPRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.matbalez.sig-demo.ios.relay")
    private var listener: NWListener?
    private var sessions: [UUID: Session] = [:]

    func start(configuration: SigDemoConfiguration) throws {
        guard let target = configuration.relay else { return }
        guard let portNumber = configuration.serverURL.port,
              let localPort = NWEndpoint.Port(rawValue: UInt16(portNumber)),
              let remotePort = NWEndpoint.Port(rawValue: UInt16(target.port)) else {
            throw SigDemoError.invalidConfiguration("Invalid private relay port.")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: localPort)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        let ready = RelayResult<Void>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.finish(.success(()))
            case .failed(let error): ready.finish(.failure(error))
            case .cancelled: ready.finish(.failure(CancellationError()))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] inbound in
            guard let self else { inbound.cancel(); return }
            let id = UUID()
            let session = Session(inbound: inbound, host: target.host, port: remotePort, queue: self.queue) { [weak self] in
                self?.sessions.removeValue(forKey: id)
            }
            self.sessions[id] = session
            session.start()
        }
        self.listener = listener
        listener.start(queue: queue)
        do {
            try ready.wait(timeout: 5)
        } catch {
            listener.cancel()
            self.listener = nil
            throw error
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            let active = Array(self.sessions.values)
            for session in active { session.close() }
        }
    }

    /// Simulator and desktop share a loopback namespace. Reuse is allowed only
    /// after a credential-free HTTPS health check authenticated by this demo CA.
    /// This object never owns or stops the listener it verified this way.
    static func verifyExistingPrivateRelay(configuration: SigDemoConfiguration) throws {
        let result = RelayResult<Void>()
        let transport = try SigDemoURLSessionTransport(configuration: configuration)
        let task = Task.detached {
            do {
                var request = URLRequest(url: configuration.serverURL.appendingPathComponent("health"), timeoutInterval: 3)
                request.httpMethod = "GET"
                request.httpShouldHandleCookies = false
                let (data, response) = try await transport.send(request)
                guard response.statusCode == 200, data.count < 4096,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      body["ok"] as? Bool == true, body["app"] as? String == "sig-demo",
                      body["registration"] as? String == "invite-only" else {
                    throw SigDemoError.invalidServerResponse
                }
                result.finish(.success(()))
            } catch { result.finish(.failure(error)) }
        }
        do { try result.wait(timeout: 5) }
        catch { task.cancel(); throw error }
    }

    private final class Session: @unchecked Sendable {
        let inbound: NWConnection
        let outbound: NWConnection
        let queue: DispatchQueue
        let onClose: () -> Void
        var closed = false

        init(inbound: NWConnection, host: String, port: NWEndpoint.Port, queue: DispatchQueue, onClose: @escaping () -> Void) {
            self.inbound = inbound
            self.outbound = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            inbound.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.close() }
            }
            outbound.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.pipe(from: self.inbound, to: self.outbound)
                    self.pipe(from: self.outbound, to: self.inbound)
                case .failed, .cancelled: self.close()
                default: break
                }
            }
            inbound.start(queue: queue)
            outbound.start(queue: queue)
        }

        func pipe(from source: NWConnection, to destination: NWConnection) {
            guard !closed else { return }
            source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self, !self.closed else { return }
                guard error == nil else { self.close(); return }
                if let data, !data.isEmpty {
                    destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        guard let self, !self.closed else { return }
                        if sendError != nil || complete { self.close() }
                        else { self.pipe(from: source, to: destination) }
                    })
                } else if complete { self.close() }
                else { self.pipe(from: source, to: destination) }
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            inbound.cancel()
            outbound.cancel()
            onClose()
        }
    }
}

/// Used only while launch waits for a listener or an authenticated reuse probe.
private final class RelayResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, any Error>?

    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) throws -> Value {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { throw URLError(.timedOut) }
        lock.lock()
        let result = self.result!
        lock.unlock()
        return try result.get()
    }
}
