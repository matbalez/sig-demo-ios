// Copyright 2026 sig demo contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

private actor CollectedEvents {
    var text = ""
    var done = false
    var failed = false
    func append(_ event: SigAgentEvent) {
        switch event {
        case .text(let value): text += value
        case .done: done = true
        case .error: failed = true
        default: break
        }
    }
    func verify() -> Bool { text == "Native Swift answer." && done && !failed }
}

@main
struct NativeAgentSmoke {
    static func request(_ index: Int) -> SigAgentRequest {
        SigAgentRequest(
            mode: .answer, queryId: "local-query-\(index)", responseId: "local-response-\(index)",
            sourceText: "@sig Answer this question.", prompt: "Answer this question.",
            author: "Alice", history: [], currentDate: "2026-10-15"
        )
    }

    static func rejectsConfiguration(_ url: URL, model: String = "swift-fixture", accountID: String = "local-account-secret") {
        do {
            _ = try ChatGPTSigAgent(accountID: accountID, publicMeshBaseURL: url, model: model)
            fatalError("Invalid public Mesh configuration was accepted")
        } catch SigChatAgentError.invalidConfiguration { }
        catch { fatalError("Unexpected configuration error") }
    }

    static func verifyConfiguration(_ endpoint: URL) async throws {
        for address in [
            "https://127.0.0.1:9337/v1", "http://localhost:9337/v1", "http://[::1]:9337/v1",
            "http://0.0.0.0:9337/v1", "http://192.0.2.1:9337/v1", "http://127.0.0.1/v1",
            "http://127.0.0.1:0/v1", "http://127.0.0.1:65536/v1", "http://127.0.0.1:9337/",
            "http://127.0.0.1:9337/v1/", "http://127.0.0.1:9337/%761",
            "http://127.0.0.1:9337/v1?", "http://127.0.0.1:9337/v1#",
            "http://user:password@127.0.0.1:9337/v1", "http://@127.0.0.1:9337/v1",
        ] {
            if let url = URL(string: address) { rejectsConfiguration(url) }
        }
        for model in ["", " \t", String(repeating: "x", count: 129), "line\nbreak", "nul\0model",
                      "delete\u{7f}", String(repeating: "🚀", count: 33)] {
            rejectsConfiguration(endpoint, model: model)
        }
        rejectsConfiguration(endpoint, accountID: "")
        for key in ["", "with space", "line\nbreak", "nonascii-🚀", String(repeating: "x", count: 1025)] {
            do {
                _ = try ChatGPTSigAgent(accountID: "local-account-secret", publicMeshBaseURL: endpoint,
                                         model: "swift-fixture", braveApiKey: key)
                fatalError("Invalid search credential was accepted")
            } catch SigChatAgentError.invalidConfiguration { }
            do {
                _ = try ChatGPTSigAgent(accountID: "local-account-secret", apiKey: "synthetic-key-never-send",
                                       braveApiKey: key)
                fatalError("Invalid hosted search credential was accepted")
            } catch SigChatAgentError.invalidConfiguration { }
        }

        // The Rust model limit is UTF-8 bytes, including for non-ASCII names.
        let unicode = try ChatGPTSigAgent(accountID: "local-account-secret", publicMeshBaseURL: endpoint,
                                         model: String(repeating: "🚀", count: 32))
        await unicode.shutdown()
        // Keep the existing hosted API usable; construction does not make I/O.
        let hosted = try ChatGPTSigAgent(accountID: "local-account-secret", apiKey: "synthetic-key-never-send")
        await hosted.shutdown()
    }

    static func main() async throws {
        let endpoint = URL(string: CommandLine.arguments[1])!
        let environment = ProcessInfo.processInfo.environment
        if CommandLine.arguments[2] == "no-openai-key" {
            precondition(environment["SIG_DEMO_OPENAI_API_KEY"] == nil && environment["OPENAI_API_KEY"] == nil,
                         "Credential-free smoke received an OpenAI environment value")
        } else {
            precondition(environment["SIG_DEMO_OPENAI_API_KEY"] == "synthetic-launcher-key-never-send"
                         && environment["OPENAI_API_KEY"] == "synthetic-ambient-key-never-send",
                         "Key-isolation smoke environment is invalid")
        }
        try await verifyConfiguration(endpoint)
        let agent = try ChatGPTSigAgent(accountID: "local-account-secret", publicMeshBaseURL: endpoint, model: "swift-fixture")
        for index in 1...2 {
            let events = CollectedEvents()
            try await agent.answer(chatID: "local-chat-secret", request: request(index)) {
                await events.append($0)
            }
            let valid = await events.verify()
            precondition(valid, "Native stream failed")
        }

        // Retain compatibility for the existing synthetic test initializer.
        let compatible = ChatGPTSigAgent(testAccountID: "local-account-secret", syntheticEndpoint: endpoint, model: "swift-fixture")
        let compatibleEvents = CollectedEvents()
        try await compatible.answer(chatID: "local-chat-secret", request: request(6)) {
            await compatibleEvents.append($0)
        }
        let compatibleValid = await compatibleEvents.verify()
        precondition(compatibleValid, "Synthetic initializer regressed")
        await compatible.shutdown()

        // Advertising the actual native local tool proves this Swift value
        // reaches GDK. The fixture answers directly, so it makes no Brave call.
        let searchable = try ChatGPTSigAgent(accountID: "local-account-secret", publicMeshBaseURL: endpoint,
            model: "swift-search-capable", braveApiKey: "synthetic-brave-key-never-send")
        let searchEvents = CollectedEvents()
        try await searchable.answer(chatID: "local-chat-secret", request: request(7)) {
            await searchEvents.append($0)
        }
        let searchValid = await searchEvents.verify()
        precondition(searchValid, "Search-capable agent configuration regressed")
        await searchable.shutdown()

        // The shipping ChatGPT constructor must retain its local search key.
        // Switch only the provider/route for this fixture: a missing retained
        // key makes Rust omit the tool and the HTTP schema assertion fail.
        let hostedSearch = try ChatGPTSigAgent(accountID: "local-account-secret",
            apiKey: "synthetic-key-never-send", braveApiKey: "synthetic-brave-key-never-send")
        await hostedSearch.useSyntheticMeshEndpoint(endpoint, model: "swift-hosted-search-capable")
        let hostedEvents = CollectedEvents()
        try await hostedSearch.answer(chatID: "local-chat-secret", request: request(8)) {
            await hostedEvents.append($0)
        }
        let hostedValid = await hostedEvents.verify()
        precondition(hostedValid, "Hosted search credential did not reach the native runtime")
        await hostedSearch.shutdown()

        await agent.useSyntheticModel("swift-cancel")
        let task = Task {
            try await agent.answer(chatID: "local-chat-secret", request: request(3)) { _ in }
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            try await task.value
            fatalError("Cancelled answer succeeded")
        } catch is CancellationError { }

        // Teardown also cancels a Swift callback suspended before the first
        // network event. It must join the invocation before returning.
        let callback = CallbackProbe()
        let pending = Task {
            try await agent.answer(chatID: "shutdown-chat", request: request(4)) { _ in
                await callback.enter()
                try await Task.sleep(for: .seconds(10))
                await callback.complete()
            }
        }
        while !(await callback.entered) { try await Task.sleep(for: .milliseconds(5)) }
        await agent.shutdown()
        do {
            try await pending.value
            fatalError("Account teardown left its Swift invocation running")
        } catch is CancellationError { }
        let completed = await callback.completed
        precondition(!completed, "An account callback completed after teardown")
        do {
            try await agent.answer(chatID: "local-chat-secret", request: request(5)) { _ in }
            fatalError("Closed account accepted an answer")
        } catch SigChatAgentError.closed { }
        print("Swift native agent: public Mesh configuration, credential isolation, streaming, reuse, cancellation and account shutdown passed.")
    }
}

private actor CallbackProbe {
    var entered = false
    var completed = false
    func enter() { entered = true }
    func complete() { completed = true }
}
