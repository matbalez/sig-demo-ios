// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MeshLLM
import Testing
@testable import SigDemoMesh

private final class SDKCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

@Test
func sdkCancellationBeforeActivationStillCancelsNativeID() async throws {
    let pair = AsyncThrowingStream<MeshInferenceEvent, Error>.makeStream()
    let recorder = SDKCancellationRecorder()
    let listener = PublicMeshStreamListener(continuation: pair.continuation,
        cancel: { recorder.record($0) }, nativeFinished: {})
    listener.cancel()
    listener.activate(requestId: "fixture")
    #expect(recorder.snapshot() == ["fixture"])
    listener.onEvent(event: .failed(requestId: "fixture", statusCode: nil, error: "cancelled", body: nil))
    await listener.waitForNativeCompletion()
    do {
        for try await _ in pair.stream {}
        Issue.record("Cancelled stream ended successfully")
    } catch { #expect(error as? MeshInferenceError == .stopped) }
}

@Test
func sdkRejectsOversizedEventsBeforeQueueingThem() async throws {
    let pair = AsyncThrowingStream<MeshInferenceEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
    let recorder = SDKCancellationRecorder()
    let listener = PublicMeshStreamListener(continuation: pair.continuation,
        cancel: { recorder.record($0) }, nativeFinished: {})
    listener.activate(requestId: "fixture")
    listener.onEvent(event: .sse(requestId: "fixture", eventType: nil,
        data: String(repeating: "x", count: 1024 * 1024 + 1), raw: "data: oversized\n\n"))
    #expect(recorder.snapshot() == ["fixture"])
    listener.onEvent(event: .failed(requestId: "fixture", statusCode: nil, error: "cancelled", body: nil))
    await listener.waitForNativeCompletion()
    var received = 0
    do {
        for try await _ in pair.stream { received += 1 }
        Issue.record("Oversized stream ended successfully")
    } catch { #expect(error as? MeshInferenceError == .invalidResponse) }
    #expect(received == 0)
}

@Test
func sdkCumulativeBudgetBoundsTheProducerQueue() async throws {
    let pair = AsyncThrowingStream<MeshInferenceEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
    let recorder = SDKCancellationRecorder()
    let listener = PublicMeshStreamListener(continuation: pair.continuation,
        cancel: { recorder.record($0) }, nativeFinished: {})
    listener.activate(requestId: "fixture")
    let payload = String(repeating: "x", count: 512 * 1024)
    for _ in 0..<17 {
        listener.onEvent(event: .sse(requestId: "fixture", eventType: nil, data: payload, raw: payload))
    }
    #expect(recorder.snapshot() == ["fixture"])
    listener.onEvent(event: .completed(requestId: "fixture"))
    await listener.waitForNativeCompletion()
    var received = 0
    do {
        for try await _ in pair.stream { received += 1 }
        Issue.record("Over-budget stream ended successfully")
    } catch { #expect(error as? MeshInferenceError == .invalidResponse) }
    #expect(received == 16)
}

@Test
func sdkPaidFailurePreservesTheTypedBoundary() async throws {
    let pair = AsyncThrowingStream<MeshInferenceEvent, Error>.makeStream()
    let listener = PublicMeshStreamListener(continuation: pair.continuation, cancel: { _ in }, nativeFinished: {})
    listener.activate(requestId: "fixture")
    listener.onEvent(event: .failed(requestId: "fixture", statusCode: 402,
        error: "untrusted provider description", body: "untrusted provider body"))
    await listener.waitForNativeCompletion()
    do {
        for try await _ in pair.stream {}
        Issue.record("Paid failure ended successfully")
    } catch { #expect(error as? MeshInferenceError == .paymentRequired) }
}
