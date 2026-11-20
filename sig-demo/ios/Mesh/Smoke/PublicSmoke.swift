// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation
import SigDemoMesh

/// One optional live, free public request. Never loads an application credential.
@main
enum PublicSmoke {
    static func main() async {
        guard let identity = try? MeshSDKPublicTransport.generateOwnerKeypairHex() else { exit(1) }
        let transport = MeshSDKPublicTransport(ownerKeypairHex: identity)
        let probe = Task {
            do {
                let requested = CommandLine.arguments.dropFirst().first
                try await transport.start(model: requested)
                let models = try await transport.listModels()
                print("PUBLIC_DISCOVERY_MODEL_COUNT=\(models.count)")
                guard let selected = requested ?? models.first?.id else { throw MeshInferenceError.unavailable }
                print("PUBLIC_SELECTED_MODEL=\(selected)")
                let body = try JSONSerialization.data(withJSONObject: [
                    "model": selected,
                    "messages": [["role": "user", "content": "Reply exactly MESH_PUBLIC_IOS_PROBE_OK"]],
                    "max_tokens": 64, "temperature": 0, "stream": true,
                ])
                var text = ""
                var events = 0
                var done = false
                for try await event in try await transport.streamChatCompletions(body: body) {
                    switch event {
                    case .started(let status, _): print("PUBLIC_HTTP_STATUS=\(status)")
                    case .sse(_, let data):
                        events += 1
                        if data == "[DONE]" { done = true; continue }
                        if let json = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                           let choices = json["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String { text += content }
                    }
                }
                await transport.stop()
                guard done, text.contains("MESH_PUBLIC_IOS_PROBE_OK") else { throw MeshInferenceError.invalidResponse }
                print("PUBLIC_FREE_COMPLETION_PASSED events=\(events)")
                return true
            } catch {
                await transport.stop()
                let kind = error as? MeshInferenceError
                print("PUBLIC_PROBE_FAILED=\(kind.map { String(describing: $0) } ?? "transport")")
                return false
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(45))
            probe.cancel()
        }
        let passed = await probe.value
        deadline.cancel()
        if !passed { exit(1) }
    }
}
