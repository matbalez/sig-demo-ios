// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SigDemoMesh

private actor ProbeTransport: MeshInferenceTransport {
    enum Behavior: Sendable { case complete, paymentRequired, truncated, suspended }
    let behavior: Behavior
    private(set) var bodies: [Data] = []
    private(set) var cancelled = false
    private var continuation: AsyncThrowingStream<MeshInferenceEvent, Error>.Continuation?

    init(_ behavior: Behavior = .complete) { self.behavior = behavior }
    func start(model: String?) async throws {}
    func listModels() async throws -> [MeshInferenceModel] { [.init(id: "test-model", name: "Test")] }
    func stop() async { continuation?.finish(throwing: MeshInferenceError.stopped) }

    func streamChatCompletions(body: Data) async throws -> AsyncThrowingStream<MeshInferenceEvent, Error> {
        bodies.append(body)
        let pair = AsyncThrowingStream<MeshInferenceEvent, Error>.makeStream()
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { Task { await self?.markCancelled() } }
        }
        if behavior == .paymentRequired {
            pair.continuation.yield(.started(statusCode: 402, contentType: "application/json"))
            pair.continuation.finish()
        } else {
            pair.continuation.yield(.started(statusCode: 200, contentType: "text/event-stream; charset=utf-8"))
            let json = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_test\",\"type\":\"function\",\"function\":{\"name\":\"search\",\"arguments\":\"{}\"}}]},\"finish_reason\":null}],\"usage\":{\"prompt_tokens\":12}}"
            pair.continuation.yield(.sse(raw: "data: " + json + "\n\n", data: json))
            if behavior == .complete {
                pair.continuation.yield(.sse(raw: "data: [DONE]\n\n", data: "[DONE]"))
                pair.continuation.finish()
            } else if behavior == .truncated {
                pair.continuation.finish()
            }
        }
        return pair.stream
    }
    private func markCancelled() { cancelled = true }
}

private func request(_ base: URL, model: String = "test-model") throws -> URLRequest {
    var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model, "stream": true,
        "messages": [["role": "user", "content": "Synthetic bridge probe"]],
        "tools": [["type": "function", "function": ["name": "search", "parameters": ["type": "object"]]]],
        "tool_choice": "auto", "parallel_tool_calls": false,
        "mesh_payment": ["mode": "paid", "max_sats": 100],
    ])
    return request
}

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 5
    configuration.connectionProxyDictionary = [:]
    return URLSession(configuration: configuration)
}

@Test func rawToolWireAndFreeOnlyPolicySurviveTheBridge() async throws {
    let transport = ProbeTransport()
    let bridge = LoopbackBridge(transport: transport, model: "test-model")
    let endpoint = try await bridge.start()
    #expect(endpoint.host == "127.0.0.1")
    #expect(endpoint.port != nil && endpoint.port != 0)
    let client = session()
    let (data, response) = try await client.data(for: request(endpoint))
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"tool_calls\""))
    #expect(text.contains("\"prompt_tokens\":12"))
    #expect(text.hasSuffix("data: [DONE]\n\n"))
    let bodies = await transport.bodies
    #expect(bodies.count == 1)
    let object = try #require(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
    #expect((object["mesh_payment"] as? [String: String]) == ["mode": "free_only"])
    #expect((object["tools"] as? [[String: Any]])?.count == 1)
    #expect(object["tool_choice"] as? String == "auto")
    #expect(object["parallel_tool_calls"] as? Bool == false)
    await bridge.stop()
    client.invalidateAndCancel()
}

@Test func mismatchedModelsAndCredentialHeadersNeverReachMesh() async throws {
    let transport = ProbeTransport()
    let bridge = LoopbackBridge(transport: transport, model: "test-model")
    let endpoint = try await bridge.start()
    let client = session()
    var cases = [try request(endpoint, model: "other-model")]
    for header in ["Authorization", "Proxy-Authorization", "Origin", "X-Mesh-Target"] {
        var candidate = try request(endpoint)
        candidate.setValue("synthetic-rejected-value", forHTTPHeaderField: header)
        cases.append(candidate)
    }
    var nonstream = try request(endpoint)
    nonstream.httpBody = try JSONSerialization.data(withJSONObject: ["model":"test-model", "stream":false, "messages":[]])
    cases.append(nonstream)
    var numericStream = try request(endpoint)
    numericStream.httpBody = try JSONSerialization.data(withJSONObject: ["model":"test-model", "stream":1, "messages":[]])
    cases.append(numericStream)
    for candidate in cases {
        let (_, response) = try await client.data(for: candidate)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
    }
    let bodies = await transport.bodies
    #expect(bodies.isEmpty)
    await bridge.stop()
    client.invalidateAndCancel()
}

@Test func paidRoutesFailWithoutRetryOrProviderFallback() async throws {
    let transport = ProbeTransport(.paymentRequired)
    let bridge = LoopbackBridge(transport: transport, model: "test-model")
    let endpoint = try await bridge.start()
    let client = session()
    let (body, response) = try await client.data(for: request(endpoint))
    #expect((response as? HTTPURLResponse)?.statusCode == 402)
    #expect(String(decoding: body, as: UTF8.self).contains("requires a free inference route"))
    let bodies = await transport.bodies
    #expect(bodies.count == 1)
    await bridge.stop()
    client.invalidateAndCancel()
}

@Test func upstreamTruncationIsNotTurnedIntoSuccessfulDone() async throws {
    let transport = ProbeTransport(.truncated)
    let bridge = LoopbackBridge(transport: transport, model: "test-model")
    let endpoint = try await bridge.start()
    let client = session()
    let (data, _) = try await client.data(for: request(endpoint))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"error\""))
    #expect(!text.contains("[DONE]"))
    await bridge.stop()
    client.invalidateAndCancel()
}

@Test func disconnectAndShutdownDrainTheActiveMeshStream() async throws {
    let transport = ProbeTransport(.suspended)
    let bridge = LoopbackBridge(transport: transport, model: "test-model")
    let endpoint = try await bridge.start()
    let client = session()
    let query = try request(endpoint)
    let task = Task { try await client.data(for: query) }
    for _ in 0..<100 {
        if !(await transport.bodies).isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!(await transport.bodies).isEmpty)
    task.cancel()
    _ = await task.result
    for _ in 0..<100 {
        if await transport.cancelled { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.cancelled)
    await bridge.stop()
    client.invalidateAndCancel()
}

@Test func paidBridgePinsItsOwnTermsAndPreservesToolWire() async throws {
    let transport = ProbeTransport()
    let bridge = MeshInferenceBridge(transport: transport, model: "test-model",
        paymentPolicy: .paid(maxInputMsatPerMillion: 7, maxOutputMsatPerMillion: 11, legacyMaxTotalMsat: 2_000))
    let endpoint = try await bridge.start()
    let client = session()
    let (body, response) = try await client.data(for: request(endpoint))
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: body, as: UTF8.self).contains("\"tool_calls\""))
    let bodies = await transport.bodies
    let object = try #require(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
    let terms = try #require(object["mesh_payment"] as? [String: Any])
    #expect(terms["mode"] as? String == "allow_paid")
    #expect(terms["max_input_msat_per_million"] as? UInt64 == 7)
    #expect(terms["max_output_msat_per_million"] as? UInt64 == 11)
    #expect(terms["max_total_msat"] as? UInt64 == 2_000)
    #expect(terms["max_sats"] == nil)
    #expect(object["tool_choice"] as? String == "auto")
    await bridge.stop()
    client.invalidateAndCancel()
}

@Test func invalidPaidTermsCannotOpenABridge() async {
    let transport = ProbeTransport()
    let bridge = MeshInferenceBridge(transport: transport, model: "test-model",
        paymentPolicy: .paid(maxInputMsatPerMillion: 0, maxOutputMsatPerMillion: 1, legacyMaxTotalMsat: 1))
    await #expect(throws: MeshInferenceError.invalidConfiguration) { try await bridge.start() }
    await bridge.stop()
}
