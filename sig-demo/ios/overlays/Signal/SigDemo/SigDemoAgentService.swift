// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import CryptoKit
import UIKit
import SignalServiceKit
import SignalUI
import SigDemoAgent
import SigDemoMesh
import SigDemoPaidMesh
import SigDemoKit
#if SIG_DEMO_LOCAL_MODEL
import SigDemoLocalModel
#if DEBUG
import func os.os_proc_available_memory
#endif

// BEGIN SIG_DEMO_LOCAL_REPLY_POLICY
/// Held for the entire GDK reply, including the gaps between tool rounds.
/// A completed older job must never release a newer job's admission.
struct SigDemoLocalReplyAdmission {
    private(set) var activeID: UUID?

    mutating func acquire(_ id: UUID) -> Bool {
        guard activeID == nil else { return false }
        activeID = id
        return true
    }

    mutating func release(_ id: UUID) {
        if activeID == id { activeID = nil }
    }
}
// END SIG_DEMO_LOCAL_REPLY_POLICY

// BEGIN SIG_DEMO_LOCAL_REPLY_PRESENTATION
/// Provider errors can follow provisional text. Failed local output is never
/// a completed answer, and may contain an unhandled model tool frame.
enum SigDemoLocalReplyPresentation {
    static let genericFailure = "The local model could not complete this reply. Please try again. No cloud model was used."
    static func failureMessage(code: String?, reason: String?) -> String {
        let categories = [code, reason].compactMap { $0?.lowercased() }
        if categories.contains(where: { ["web-search-unavailable", "web_search_unavailable", "brave-unavailable", "brave_unavailable"].contains($0) }) {
            return "Web search is unavailable. Check your connection and try again. Local chat still works."
        }
        if categories.contains(where: { ["tool-arguments-invalid", "tool-arguments-incomplete", "tool-invalid", "tool-incomplete", "tool_invalid", "tool_incomplete"].contains($0) }) {
            return "The local model could not complete its web search. Please try again. No cloud model was used."
        }
        if categories.contains("context-length") {
            return "This conversation exceeds the local model's context limit. Try a shorter question in a new conversation. No cloud model was used."
        }
        if categories.contains("output-token-limit") {
            return "The local model reached its reply limit before finishing. Try a shorter question. No cloud model was used."
        }
        if categories.contains("timeout") {
            return "The local model took too long to finish. Please try again. No cloud model was used."
        }
        if categories.contains("local-action-invalid") {
            return "The local model could not choose a valid next action. Please try again."
        }
        return genericFailure
    }
    static func failedText(provisional: String, message: String) -> String {
        // Discard all provisional text rather than retaining a failed tool frame.
        String(decoding: Array(message.utf16.prefix(65_536)), as: UTF16.self)
    }
}
// END SIG_DEMO_LOCAL_REPLY_PRESENTATION

// BEGIN SIG_DEMO_LOCAL_REPLY_DIAGNOSTICS
/// Content-free metadata only. Unknown native strings never enter diagnostics.
struct SigDemoLocalReplyDiagnostics: Codable, Sendable {
    private(set) var outcome = "RUNNING"
    private(set) var phase = "SETUP"
    private(set) var modelTurns = 0
    private(set) var searchStarted = 0
    private(set) var searchCompleted = 0
    // Optional storage keeps diagnostics from earlier builds decodable.
    private var historyStartCount: Int?
    private var historyEndCount: Int?
    var historyStarted: Int { historyStartCount ?? 0 }
    var historyCompleted: Int { historyEndCount ?? 0 }
    private(set) var historyScope: String?
    var braveAvailable: Bool?
    private(set) var code = "none"
    private(set) var reason = "none"
    private(set) var httpStatus = 0
    private(set) var elapsedMS: UInt64 = 0
    private(set) var agentMS: UInt64 = 0
    private(set) var nativeAnswerMS: UInt64?
    private(set) var firstTextMS: UInt64?
    private(set) var localFirstTokenMS: UInt64?
    private(set) var localDecodeMS: UInt64?
    private(set) var searchMS: UInt64 = 0
    static let codes: Set<String> = ["generic", "application-error", "timeout", "web-search-unavailable",
        "tool-arguments-invalid", "tool-arguments-incomplete", "output-token-limit", "authentication",
        "context-length", "rate-limited", "payment-required", "server-error", "endpoint-not-found",
        "request-rejected", "model-unavailable", "stream-format-invalid", "stream-interrupted",
        "network-connect", "network-error", "local-unavailable", "local-busy", "local-action-invalid", "swift-error"]
    static let reasons: Set<String> = ["local-template", "local-prefill", "local-decode", "local-context-create",
        "local-metal-unavailable", "local-stopped", "local-empty", "local-search-limit", "local-search-repeated", "local-action-invalid"]
    mutating func responding() { phase = searchCompleted > 0 ? "AFTER_SEARCH" : "MODEL" }
    mutating func searching() { phase = "WEB_SEARCH"; searchStarted = min(100, searchStarted + 1) }
    mutating func timing(_ phase: String, durationMS: UInt64 = 0) {
        if phase == "model-turn" { modelTurns = min(100, modelTurns + 1) }
        switch phase {
        case "history-started": historyStartCount = min(100, historyStarted + 1)
        case "history": historyEndCount = min(100, historyCompleted + 1)
        case "history-read-since-last-message": historyScope = "since_last_message"
        case "history-read-recent": historyScope = "recent"
        default: break
        }
        if phase == "search" {
            searchCompleted = min(100, searchCompleted + 1); self.phase = "AFTER_SEARCH"
            searchMS = min(3_600_000, searchMS + min(3_600_000, durationMS))
        }
        if phase == "local-first-token" { localFirstTokenMS = min(3_600_000, durationMS) }
        if phase == "local-decode" { localDecodeMS = min(3_600_000, durationMS) }
        if phase == "answer" { nativeAnswerMS = min(3_600_000, durationMS) }
        if phase == "answer-first-text" { firstTextMS = min(3_600_000, durationMS) }
    }
    mutating func elapsed(totalMS: UInt64, agentMS: UInt64) {
        self.elapsedMS = min(3_600_000, totalMS); self.agentMS = min(3_600_000, agentMS)
    }
    mutating func completed() { outcome = "REPLY_COMPLETED" }
    var completionSummary: String {
        if searchStarted == 0 { return "The local reply completed without invoking web search." }
        if searchCompleted > 0 { return "The local reply completed after a web tool returned." }
        return "The local reply completed; its web tool did not return."
    }
    mutating func fail(code: String?, reason: String?, httpStatus: UInt16?) {
        outcome = "FAILED"
        self.code = code.flatMap { Self.codes.contains($0) ? $0 : nil } ?? "other"
        self.reason = reason.map { Self.reasons.contains($0) ? $0 : "other" } ?? "none"
        self.httpStatus = httpStatus.flatMap { (400...599).contains(Int($0)) ? Int($0) : nil } ?? 0
    }
    var metadata: String {
        let total = nativeAnswerMS ?? agentMS
        let modelAgentMS = total >= searchMS ? total - searchMS : 0
        return "outcome=\(outcome) phase=\(phase) code=\(code) reason=\(reason) http=\(httpStatus) model_turns=\(modelTurns) search_started=\(searchStarted) search_completed=\(searchCompleted) history_started=\(historyStarted) history_completed=\(historyCompleted) history_scope=\(historyScope ?? "none") brave=\(braveAvailable.map { $0 ? "READY" : "MISSING" } ?? "UNKNOWN") elapsed_ms=\(elapsedMS) agent_ms=\(agentMS) model_agent_ms=\(modelAgentMS) search_ms=\(searchMS) first_text_ms=\(firstTextMS.map(String.init) ?? "NONE") local_first_token_ms=\(localFirstTokenMS.map(String.init) ?? "NONE") local_decode_ms=\(localDecodeMS.map(String.init) ?? "NONE")"
    }
    var isValidTerminalRecord: Bool {
        ["FAILED", "REPLY_COMPLETED"].contains(outcome)
            && ["SETUP", "MODEL", "WEB_SEARCH", "AFTER_SEARCH"].contains(phase)
            && (Self.codes.contains(code) || ["none", "other"].contains(code))
            && (Self.reasons.contains(reason) || ["none", "other"].contains(reason))
            && (httpStatus == 0 || (400...599).contains(httpStatus))
            && (0...100).contains(historyStarted) && (0...historyStarted).contains(historyCompleted)
            && (historyScope == nil || ["recent", "since_last_message"].contains(historyScope))
            && (0...100).contains(modelTurns) && (0...100).contains(searchStarted)
            && (0...100).contains(searchCompleted) && searchCompleted <= searchStarted
            && elapsedMS <= 3_600_000 && agentMS <= 3_600_000 && searchMS <= 3_600_000
            && (nativeAnswerMS.map { $0 <= 3_600_000 } ?? true)
            && (firstTextMS.map { $0 <= 3_600_000 } ?? true)
            && (localFirstTokenMS.map { $0 <= 3_600_000 } ?? true)
            && (localDecodeMS.map { $0 <= 3_600_000 } ?? true)
    }
    var terminalSummary: String {
        let message = outcome == "REPLY_COMPLETED" ? completionSummary
            : SigDemoLocalReplyPresentation.failureMessage(code: code, reason: reason)
        return message + "\n" + metadata
    }
}
// END SIG_DEMO_LOCAL_REPLY_DIAGNOSTICS

// BEGIN SIG_DEMO_LOCAL_ATTEMPT_PERSISTENCE
/// Only fixed terminal diagnostics enter preferences. Raw account/model scope
/// components and all message/credential content are excluded from stored data.
struct SigDemoLocalAttemptRecord: Codable, Sendable {
    let version: Int
    let recordedAt: Date
    let diagnostic: SigDemoLocalReplyDiagnostics
    init(diagnostic: SigDemoLocalReplyDiagnostics, recordedAt: Date = Date()) {
        version = 1; self.recordedAt = recordedAt; self.diagnostic = diagnostic
    }
    var summary: String {
        let date = ISO8601DateFormatter().string(from: recordedAt)
        return "Finished " + date + "\n" + diagnostic.terminalSummary
    }
    static func storageKey(account: String, deployment: String, model: String) -> String? {
        guard let accountID = UUID(uuidString: account), deployment.utf8.count == 64,
              deployment.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !model.isEmpty, model.utf8.count <= 128,
              model.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { return nil }
        let scope = "sig-demo-local-attempt-v1\0" + deployment + "\0" + accountID.uuidString.lowercased() + "\0" + model
        return "SigDemo.LocalAttempt.v1." + SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func decode(_ data: Data) -> Self? {
        guard data.count <= 8_192, let record = try? JSONDecoder().decode(Self.self, from: data),
              record.version == 1, record.diagnostic.isValidTerminalRecord,
              record.recordedAt.timeIntervalSince1970 >= 0,
              record.recordedAt <= Date().addingTimeInterval(60) else { return nil }
        return record
    }
}
// END SIG_DEMO_LOCAL_ATTEMPT_PERSISTENCE
#endif

// BEGIN SIG_DEMO_PAID_CONNECTION_STATUS
/// A funded wallet and a working inference connection are separate facts.
/// Retain only fixed diagnostics; error descriptions may contain private data.
struct SigDemoPaidConnectionStatus {
    enum Stage: String {
        case routeStart = "ROUTE_START", agentCreation = "AGENT_CREATION"
        case beginInvocation = "BEGIN_INVOCATION", agentAnswer = "AGENT_ANSWER"

        var title: String {
            switch self {
            case .routeStart: "route setup"
            case .agentCreation: "agent setup"
            case .beginInvocation: "request start"
            case .agentAnswer: "model reply"
            }
        }
    }

    enum Category: String, CaseIterable {
        case invalidConfiguration = "INVALID_CONFIGURATION", walletNotSetUp = "WALLET_NOT_SET_UP"
        case walletLocked = "WALLET_LOCKED", insufficientFunds = "INSUFFICIENT_FUNDS"
        case spendingDisabled = "SPENDING_DISABLED", budgetExceeded = "BUDGET_EXCEEDED"
        case paymentPending = "PAYMENT_PENDING", modelUnavailable = "MODEL_UNAVAILABLE"
        case busy = "BUSY", stopped = "STOPPED", unavailable = "UNAVAILABLE"
        case paymentRequired = "PAYMENT_REQUIRED", invalidResponse = "INVALID_RESPONSE"
        case transportSecurity = "TRANSPORT_SECURITY", networkTimeout = "NETWORK_TIMEOUT"
        case networkConnection = "NETWORK_CONNECTION", agentFailure = "AGENT_FAILURE", other = "OTHER"
        case startupWalletRefresh = "STARTUP_WALLET_REFRESH_FAILED", startupRecovery = "STARTUP_RECOVERY_FAILED"
        case startupPolicy = "STARTUP_POLICY_FAILED", startupBuyerIdentity = "STARTUP_BUYER_IDENTITY_FAILED"
        case startupNodeStart = "STARTUP_NODE_START_FAILED"

        static func network(_ error: Error) -> Self? {
            let error = error as NSError
            guard error.domain == NSURLErrorDomain else { return nil }
            switch error.code {
            case URLError.appTransportSecurityRequiresSecureConnection.rawValue: return .transportSecurity
            case URLError.timedOut.rawValue: return .networkTimeout
            case URLError.cannotConnectToHost.rawValue, URLError.networkConnectionLost.rawValue,
                 URLError.notConnectedToInternet.rawValue, URLError.cannotFindHost.rawValue:
                return .networkConnection
            default: return .unavailable
            }
        }
    }

    struct Failure: Equatable {
        let stage: Stage
        let category: Category
        var marker: String { "SIG_DEMO_PAID_FAILURE_" + stage.rawValue + "_" + category.rawValue }
        var message: String {
            let category = category.rawValue.lowercased().replacingOccurrences(of: "_", with: " ")
            return "Paid Mesh connection failed during \(stage.title) (\(category)). Check Sig agent settings and try again."
        }
    }

    private(set) var failure: Failure?

    mutating func record(_ failure: Failure) -> Bool {
        let changed = self.failure != failure
        self.failure = failure
        return changed
    }

    mutating func clear() { failure = nil }

    func walletReadyMessage(spendingEnabled: Bool, connectedModel: String?) -> String {
        if let failure { return failure.message }
        if !spendingEnabled { return "Paid Mesh spending is disabled. Set positive daily and per Sig request limits in settings." }
        if let connectedModel { return "Paid Mesh ready · \(connectedModel)." }
        return "The paid Mesh wallet is ready. The inference connection is not established."
    }
}
// END SIG_DEMO_PAID_CONNECTION_STATUS

/// Runs only for locally composed messages after their normal Signal send has
/// been persisted. Received @sig text never starts another user's agent.
@MainActor
final class SigDemoAgentService {
    static let shared = SigDemoAgentService()
    static var isAvailable: Bool {
        TSConstants.libSignalEnv == .localDemo && Bundle.main.bundleIdPrefix == "dev.matbalez.sig-demo.ios"
    }
    var currentAccountID: String? { Self.isAvailable ? registeredAccount() : nil }
    private(set) var selection = SigDemoInferenceSelection()
    private(set) var availableModels: [SigDemoInferenceModel] = []
    private(set) var status = "Open your registered test account to choose an inference provider."
    var connectionStatus: String {
        #if SIG_DEMO_LOCAL_MODEL
        if selection.provider == .localModel {
            let configured = currentAccountID.map { inferenceCredential(.braveSearch, account: $0) != nil } ?? false
            var value = status + (configured
                ? "\nWeb search access configured (credential present; API access not checked)."
                : "\nWeb search access unavailable. Refresh demo access.")
            if let last = localLastAttempt, selectionAccountID == last.account,
               selection.localPreferredModel == last.model, status != last.status {
                value += "\nLast local attempt: " + last.status
            }
            return value
        }
        #endif
        return status
    }
    private(set) var isUpdatingSelection = false
    private(set) var isUpdatingWallet = false
    private(set) var paidWallet: PaidMeshWalletSnapshot?
    private(set) var isPaidInferenceActive = false
    private(set) var isFinalizingPaidInference = false
    var hasPaidInferenceJobs: Bool { selection.provider == .paidMesh && (!jobs.isEmpty || paidInvalidationID != nil) }
    private var observers: [NSObjectProtocol] = []
    private var agent: ChatGPTSigAgent?
    private var accountId: String?
    private var selectionAccountID: String?
    private var mesh: PublicMeshRuntime?
    private var paidMesh: PaidMeshRuntime?
    #if SIG_DEMO_LOCAL_MODEL
    private var localModel: LocalModelRuntime?
    private var localRoute: LocalModelRoute?
    private var localStartTask: Task<LocalModelRoute, Error>?
    private var localStartID: UUID?
    private var localReplyAdmission = SigDemoLocalReplyAdmission()
    private var activeLocalReply: (id: UUID, thread: String, started: ContinuousClock.Instant, eligible: Int, readingHistory: Bool)?
    private var localProgressTicker: Task<Void, Never>?
    static let localProgressDidChange = Notification.Name("SigDemoLocalProgressDidChange")

    func localProgress(for thread: String) -> (subtitle: String, spoken: String)? {
        guard let reply = activeLocalReply, reply.thread == thread else { return nil }
        let seconds = max(0, reply.started.duration(to: .now).components.seconds)
        let elapsed = String(format: "%lld:%02lld", seconds / 60, seconds % 60)
        let messages = reply.eligible == 1 ? "message" : "messages"
        if reply.readingHistory {
            return ("Reading chat · \(elapsed) · \(reply.eligible) available",
                    "Sig is reading chat history on this iPhone. \(seconds) seconds elapsed. \(reply.eligible) eligible \(messages) available.")
        }
        return ("Sig on iPhone · \(elapsed)", "Sig is working on this iPhone. \(seconds) seconds elapsed.")
    }

    private func beginLocalProgress(id: UUID, snapshot: Snapshot) {
        let eligible = snapshot.history.lazy.filter { !$0.text.isEmpty }.count
        activeLocalReply = (id, snapshot.thread, .now, eligible, false)
        NotificationCenter.default.post(name: Self.localProgressDidChange, object: snapshot.thread)
        localProgressTicker?.cancel()
        localProgressTicker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let reply = self?.activeLocalReply, reply.id == id else { return }
                NotificationCenter.default.post(name: Self.localProgressDidChange, object: reply.thread)
            }
        }
    }

    private func setLocalHistoryActivity(_ reading: Bool, id: UUID) {
        guard let reply = activeLocalReply, reply.id == id, reply.readingHistory != reading else { return }
        activeLocalReply?.readingHistory = reading
        NotificationCenter.default.post(name: Self.localProgressDidChange, object: reply.thread)
    }

    private func endLocalProgress(id: UUID? = nil) {
        guard let reply = activeLocalReply, id == nil || id == reply.id else { return }
        activeLocalReply = nil
        localProgressTicker?.cancel()
        localProgressTicker = nil
        NotificationCenter.default.post(name: Self.localProgressDidChange, object: reply.thread)
    }
    private var localPauseTask: Task<Void, Never>?
    #if DEBUG
    private var localProbeStarted = false
    private var localProbeTask: Task<Void, Never>?
    #endif
    private var localAgentHasBraveAccess = false
    private var localLastAttempt: (account: String, model: String, status: String)?
    #endif
    private var route: PublicMeshRoute?
    private var meshStartTask: Task<PublicMeshRoute, Error>?
    private var meshStartID: UUID?
    private var walletTask: Task<WalletResult, Error>?
    private var walletTaskID: UUID?
    private var paidInferenceID: UUID?
    private var walletMonitor: Task<Void, Never>?
    private var walletObservations: [UUID: Task<Void, Never>] = [:]
    private var fundingDefaultsRetryAttempts = 0
    private var fundingDefaultsRetryAfter = Date.distantPast
    private var fundingPaymentConfirmed = false
    private enum WalletObservationStage: String {
        case snapshot = "SNAPSHOT", balance = "BALANCE", funding = "FUNDING"
        case history = "HISTORY", confirmedFunding = "CONFIRMED_FUNDING"
    }
    private var paidInvalidationTask: Task<Void, Never>?
    private var paidInvalidationID: UUID?
    private var paidRouteInvalidationNeeded = false
    private var paidConnectionStatus = SigDemoPaidConnectionStatus()
    private let paidDeploymentID: String? = {
        guard let configuration = try? JSONSerialization.jsonObject(with: SigDemoRuntimeConfiguration.publicClientConfigurationData),
              let canonical = try? JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }()
    private var teardownTask: Task<Void, Never>?
    private var teardownID: UUID?
    private var suspended = true
    private var generation: UInt64 = 0
    private var seen = Set<String>()
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private let localRunId = UUID()
    private var recoveryTask: Task<Void, Never>?
    private var recoveryTaskId: UUID?
    private var credentialBootstrapTask: Task<Void, Never>?
    private var credentialBootstrapID: UUID?
    private var credentialBootstrapEpoch: UInt64?
    private(set) var isRefreshingDemoAccess = false
    private var recoveredAccounts = Set<String>()
    #if DEBUG && targetEnvironment(simulator)
    private var smokeStarted = false
    private var paidContractSmokeStarted = false
    private var paidContractSmokeTask: Task<Void, Never>?
    #endif

    func start() {
        guard Self.isAvailable, observers.isEmpty else { return }
        #if DEBUG && SIG_DEMO_LOCAL_MODEL
        if startLocalDeviceProbeIfRequested() { return }
        #endif
        observers.append(NotificationCenter.default.addObserver(
            forName: SigDemoAgentMessages.didPersistLocalMessage, object: nil, queue: .main
        ) { [weak self] notification in
            guard let id = notification.userInfo?["messageId"] as? String else { return }
            Task { @MainActor [weak self] in self?.invoke(messageId: id) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in await self?.shutdown() } })
        #if SIG_DEMO_LOCAL_MODEL
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // UIKit delivers this on main. Close app admission synchronously;
            // the following task then cancels/drains/unloads the GPU lease.
            MainActor.assumeIsolated { self?.pauseLocalInferenceBeforeInactive() }
        })
        #endif
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in await self?.resumeIfAvailable() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: .registrationStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in await self?.accountStateChanged() } })
        Task { await resumeIfAvailable() }
        #if DEBUG && targetEnvironment(simulator)
        runSimulatorSmokeIfRequested()
        #endif
    }

    #if DEBUG && SIG_DEMO_LOCAL_MODEL
    private enum LocalProbeScenario: String {
        case pi = "1", recap, recapLong = "recap-long", piTools = "pi-tools", searchTools = "search-tools"
        case sinceMe = "since-me", sinceMeFull = "since-me-full", sinceMeEmpty = "since-me-empty"
        case mathInChat = "math-in-chat", followUp = "follow-up"

        var usesToolFixture: Bool { [.piTools, .searchTools, .mathInChat, .followUp].contains(self) }

        var prompt: String {
            switch self {
            case .pi, .piTools: return "what is pi to 15 digits"
            case .mathInChat: return "what is 5+2"
            case .followUp: return "where is that meeting again?"
            case .recap, .recapLong: return "Catch me up on this chat. Where is pickup, and who is bringing the badges?"
            case .searchTools: return "What time does the Harbor Lantern Aquarium close this Saturday?"
            case .sinceMe, .sinceMeEmpty: return "what happened since i last checked in?"
            case .sinceMeFull: return "summarize the whole chat, including before my last message"
            }
        }

        var history: [SigHistoryMessage] {
            guard self != .pi else { return [] }
            if self == .mathInChat || self == .followUp {
                return (0..<66).map { index in
                    if self == .followUp && index == 65 {
                        return SigHistoryMessage(id: "planning-65", role: .user, author: "Morgan",
                            text: "Tomorrow’s meeting is in the Lantern Room.")
                    }
                    let sentByRequester = index.isMultiple(of: 4)
                    return SigHistoryMessage(id: "planning-\(index)", role: sentByRequester ? .requester : .user,
                        author: sentByRequester ? "Alex" : "Morgan",
                        text: index.isMultiple(of: 2) ? "The Harbor Market booth has the blue badges." : "The Indigo Pavilion pickup is Saturday.")
                }
            }
            if self == .sinceMe || self == .sinceMeFull || self == .sinceMeEmpty {
                var rows = (0..<100).map { index in
                    SigHistoryMessage(id: "catchup-\(index)", role: .user, author: "Alex",
                        text: "Earlier discussion \(index): pickup was at Indigo Pavilion.")
                }
                // Both participants have the same display name. Only the role
                // and chronological order establish whose message is the anchor.
                rows[40] = SigHistoryMessage(id: "catchup-40", role: .requester, author: "Alex", text: "Thanks.")
                if self == .sinceMeEmpty {
                    rows[99] = SigHistoryMessage(id: "catchup-99", role: .requester, author: "Alex", text: "Got it.")
                } else {
                    rows[98].text = "Pickup has moved to Cedar Hall."
                    rows[99].text = "I will bring the green badges."
                    rows.insert(SigHistoryMessage(id: SigDemoAgentMessages.requesterBoundaryID, role: .requester,
                        author: "", text: ""), at: 98)
                }
                return rows
            }
            let padding = self == .recapLong ? String(repeating: " Earlier discussion of the weather and picnic planning.", count: 8) : ""
            return (0..<100).map { index in
                let text: String
                switch index {
                case 0: text = "We chose the Indigo Pavilion for pickup."
                case 99: text = "Morgan will bring the badges."
                default: text = "Packaging update \(index) is complete." + padding
                }
                return SigHistoryMessage(id: "chat-\(index)", role: .user, author: "Ari", text: text)
            }
        }
    }

    private nonisolated static func emitLocalProbe(_ marker: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((marker + "\n").utf8))
        Logger.info(marker)
    }

    private nonisolated static func emitProbeAvailableMemory(stage: String) {
        let availableMiB = os_proc_available_memory() / 1_048_576
        emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_REPLY_MEMORY stage=\(stage) available_mib=\(availableMiB)")
    }

    /// Separate diagnostic modes. The Rust warmup flag intentionally blocks
    /// agent leases. A synthetic GDK reply uses only the Swift reply flag.
    private func startLocalDeviceProbeIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let warmupModel = environment["SIG_DEMO_GDK_LOCAL_PROBE"]
        let scenario = environment["SIG_DEMO_LOCAL_PROBE_REPLY"].flatMap(LocalProbeScenario.init(rawValue:))
        guard let id = warmupModel ?? (scenario == nil ? nil : LocalModelCatalog.defaultModelID) else { return false }
        guard !localProbeStarted else { return true }
        localProbeStarted = true
        guard let descriptor = LocalModelCatalog.model(id: id),
              let url = Bundle.main.url(forResource: descriptor.filename, withExtension: nil, subdirectory: "LocalModels") else {
            Self.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_PROBE_INVALID_MODEL")
            return true
        }
        let accountID = "synthetic-device-local-probe"
        let runtime = LocalModelRuntime(accountID: accountID, modelURL: url)
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { _ in runtime.cancel() }
        localProbeTask = Task {
            Self.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_PROBE_STARTED model=" + descriptor.id)
            do {
                let ready = try await runtime.start(modelID: descriptor.id)
                Self.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_PROBE_READY model=" + descriptor.id
                    + " engine=\(ready.status.engine) backend=\(ready.status.backend) warmup_input_tokens=\(ready.status.warmupInputTokens) warmup_output_tokens=\(ready.status.warmupOutputTokens)")
                if warmupModel == nil, let scenario {
                    Self.emitLocalProbe(await Self.probeLocalReply(accountID: accountID, route: ready, scenario: scenario))
                }
            } catch LocalModelError.insufficientMemory {
                Self.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_PROBE_INSUFFICIENT_MEMORY")
            } catch {
                Self.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_PROBE_FAILED")
            }
            await runtime.stop()
            NotificationCenter.default.removeObserver(observer)
            Self.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_PROBE_STOPPED")
        }
        return true
    }

    private actor ProbeReply {
        private let startedAt = ContinuousClock.now
        private var firstVisibleMS: Int64?
        private var elapsedMS: Int64 {
            let time = startedAt.duration(to: .now).components
            return max(0, time.seconds * 1_000 + time.attoseconds / 1_000_000_000_000_000)
        }
        var text = ""
        var done = false
        var failed = false
        var diagnostics = SigDemoLocalReplyDiagnostics()

        func receive(_ event: SigAgentEvent) {
            switch event {
            case .text(let chunk):
                text += chunk
                if firstVisibleMS == nil && !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let ms = elapsedMS
                    firstVisibleMS = ms
                    SigDemoAgentService.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_FIRST_VISIBLE_TEXT elapsed_ms=\(ms)")
                }
            case .done: done = true
            case .error: failed = true
            case .status(.searching):
                diagnostics.searching()
                SigDemoAgentService.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_REPLY_SEARCH_STARTED count=\(diagnostics.searchStarted)")
            case .timing(let phase, let ms):
                diagnostics.timing(phase, durationMS: ms)
                if phase == "model-turn" {
                    SigDemoAgentService.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_REPLY_MODEL_TURN count=\(diagnostics.modelTurns)")
                } else if phase == "search" {
                    SigDemoAgentService.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_REPLY_SEARCH_COMPLETED count=\(diagnostics.searchCompleted)")
                } else if phase == "local-first-token" || phase == "local-decode" {
                    SigDemoAgentService.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_INFERENCE_TIMING phase=\(phase) duration_ms=\(ms)")
                } else if phase == "history-started" {
                    SigDemoAgentService.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_REPLY_HISTORY_STARTED count=\(diagnostics.historyStarted)")
                } else if phase == "history" {
                    SigDemoAgentService.emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_REPLY_HISTORY_COMPLETED count=\(diagnostics.historyCompleted)")
                }
            default: break
            }
        }

        func marker(streamCompleted: Bool, scenario: LocalProbeScenario) -> String {
            let answered: Bool
            let checkedFacts: String
            switch scenario {
            case .pi, .piTools:
                // Shared prefix for 15 significant digits or 15 decimal places.
                let number = text.replacingOccurrences(of: #"(?<=[0-9])[\s_]+(?=[0-9])"#,
                    with: "", options: .regularExpression)
                answered = number.range(of: #"(?<![0-9.])3\.14159265358979"#, options: .regularExpression) != nil
                checkedFacts = "pi_prefix=" + (answered ? "3.14159265358979" : "UNMATCHED")
            case .recap, .recapLong:
                let pickup = text.localizedCaseInsensitiveContains("Indigo Pavilion")
                let badges = text.localizedCaseInsensitiveContains("Morgan")
                answered = pickup && badges
                checkedFacts = "pickup_match=\(pickup) badges_match=\(badges)"
            case .followUp:
                answered = text.localizedCaseInsensitiveContains("Lantern Room")
                checkedFacts = "meeting_room_match=\(answered)"
            case .mathInChat:
                let seven = text.range(of: #"(?i)\b(?:7|seven)\b"#, options: .regularExpression) != nil
                let recalledPlanning = ["harbor", "market", "badge", "indigo", "pavilion", "pickup", "saturday"].contains {
                    text.localizedCaseInsensitiveContains($0)
                }
                answered = seven && !recalledPlanning
                checkedFacts = "seven_match=\(seven) unrelated_chat_omitted=\(!recalledPlanning)"
            case .sinceMe, .sinceMeFull:
                let newPickup = text.localizedCaseInsensitiveContains("Cedar Hall")
                let newBadges = text.localizedCaseInsensitiveContains("green")
                let earlierPickup = text.localizedCaseInsensitiveContains("Indigo Pavilion")
                let priorMatchesScope = scenario == .sinceMeFull ? earlierPickup : !earlierPickup
                answered = newPickup && newBadges && priorMatchesScope
                checkedFacts = "new_pickup_match=\(newPickup) new_badges_match=\(newBadges) earlier_detail_present=\(earlierPickup)"
            case .sinceMeEmpty:
                let response = text.lowercased().replacingOccurrences(of: "’", with: "'")
                let noUpdates = ["no new", "no messages", "no other", "no further", "no updates",
                    "nothing", "haven't", "hasn't", "no one", "nobody", "you were the last"].contains(where: response.contains)
                answered = noUpdates && !response.contains("indigo pavilion")
                checkedFacts = "no_newer_messages_match=\(answered)"
            case .searchTools:
                answered = text.range(of: #"(?i)\b(?:7:42\s*p\.?\s*m\b|19:42\b)"#, options: .regularExpression) != nil
                checkedFacts = "closing_time_match=\(answered)"
            }
            let searchPassed: Bool
            if scenario == .searchTools {
                searchPassed = diagnostics.modelTurns >= 2 && diagnostics.searchStarted > 0
                    && diagnostics.searchCompleted == diagnostics.searchStarted
            } else {
                searchPassed = diagnostics.searchStarted == 0 && diagnostics.searchCompleted == 0
            }
            let historyPassed: Bool
            switch scenario {
            case .sinceMe, .sinceMeEmpty, .sinceMeFull, .recap, .recapLong:
                let scope = (scenario == .sinceMe || scenario == .sinceMeEmpty) ? "since_last_message" : "recent"
                historyPassed = diagnostics.historyStarted > 0 && diagnostics.historyCompleted == diagnostics.historyStarted
                    && diagnostics.historyScope == scope && diagnostics.modelTurns >= 2
            case .mathInChat, .followUp:
                historyPassed = diagnostics.historyStarted == 0 && diagnostics.historyCompleted == 0 && diagnostics.modelTurns == 1
            case .pi, .piTools, .searchTools:
                historyPassed = diagnostics.historyStarted == 0 && diagnostics.historyCompleted == 0
            }
            let passed = streamCompleted && done && !failed && answered && diagnostics.modelTurns > 0 && searchPassed && historyPassed
            return "SIG_DEMO_LOCAL_DEVICE_REPLY_" + (passed ? "PASS" : "FAIL")
                + " " + checkedFacts
                + " model_turns=\(diagnostics.modelTurns) search_started=\(diagnostics.searchStarted) search_completed=\(diagnostics.searchCompleted)"
                + " history_started=\(diagnostics.historyStarted) history_completed=\(diagnostics.historyCompleted) history_scope=\(diagnostics.historyScope ?? "none")"
                + " first_visible_ms=\(firstVisibleMS.map(String.init) ?? "NONE") elapsed_ms=\(elapsedMS)"
        }
    }

    private static func probeLocalReply(accountID: String, route: LocalModelRoute, scenario: LocalProbeScenario) async -> String {
        let result = ProbeReply()
        let history = scenario.history
        let bytes = history.reduce(0) { $0 + $1.text.utf8.count }
        let eligible = history.lazy.filter { !$0.text.isEmpty }.count
        emitLocalProbe("SIG_DEMO_LOCAL_DEVICE_REPLY_STARTED fixture=\(scenario.rawValue) history_count=\(eligible) history_text_bytes=\(bytes) brave_fixture_enabled=\(scenario.usesToolFixture) history_tool_enabled=true")
        let demoToolMarker = scenario.usesToolFixture ? "sig-device-probe-fixture-v1" : nil
        guard let agent = try? ChatGPTSigAgent(accountID: accountID, localEngine: route.engine, model: route.model,
                                                braveApiKey: demoToolMarker)
        else { return await result.marker(streamCompleted: false, scenario: scenario) }
        let prompt = scenario.prompt
        let queryID = scenario.usesToolFixture ? "sig-device-probe-" + scenario.rawValue : UUID().uuidString.lowercased()
        let request = SigAgentRequest(mode: .answer, queryId: queryID,
            responseId: UUID().uuidString.lowercased(), sourceText: "@sig " + prompt,
            prompt: prompt, author: nil, history: history, currentDate: nil, replyTo: nil, replyTargetUnavailable: false)
        var memorySampling: Task<Void, Never>?
        if scenario != .pi {
            emitProbeAvailableMemory(stage: "START")
            memorySampling = Task.detached(priority: .utility) {
                for _ in 0..<60 {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    Self.emitProbeAvailableMemory(stage: "RUNNING")
                }
            }
        }
        defer {
            memorySampling?.cancel()
            if scenario != .pi { Self.emitProbeAvailableMemory(stage: "END") }
        }
        let completed: Bool
        do {
            try await agent.answer(chatID: "synthetic-probe-chat", request: request) { await result.receive($0) }
            completed = true
        } catch {
            completed = false
        }
        await agent.shutdown()
        return await result.marker(streamCompleted: completed, scenario: scenario)
    }
    #endif

    #if DEBUG && targetEnvironment(simulator)
    private static func logPaidMeshDiagnostic(_ error: Error, stage: String) {
        guard let error = error as? PaidMeshError else { return }
        let code: String
        switch error {
        case .invalidConfiguration: code = "INVALID_CONFIGURATION"
        case .walletNotSetUp: code = "WALLET_NOT_SET_UP"
        case .walletLocked: code = "WALLET_LOCKED"
        case .insufficientFunds: code = "INSUFFICIENT_FUNDS"
        case .spendingDisabled: code = "SPENDING_DISABLED"
        case .budgetExceeded: code = "BUDGET_EXCEEDED"
        case .paymentPending: code = "PAYMENT_PENDING"
        case .modelUnavailable: code = "MODEL_UNAVAILABLE"
        case .busy: code = "BUSY"
        case .stopped: code = "STOPPED"
        case .unavailable: code = "UNAVAILABLE"
        case .startupFailed(let stage): code = Self.paidStartupFailureCategory(stage).rawValue
        @unknown default: return
        }
        Logger.info("SIG_DEMO_PAID_DIAGNOSTIC_" + stage + "_" + code)
    }

    private static func emitSimulatorSmokeStatus(_ marker: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((marker + "\n").utf8))
        Logger.info(marker)
    }

    private static var simulatorSmokeSource: String? {
        guard let prompt = ProcessInfo.processInfo.environment["SIG_DEMO_TEST_PROMPT"],
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 512 else { return nil }
        return SigDemoAgentFrame.prompt(in: prompt) == nil ? "@sig " + prompt : prompt
    }
    private func runSimulatorSmokeIfRequested() {
        guard !smokeStarted, let source = Self.simulatorSmokeSource else { return }
        smokeStarted = true
        Task { @MainActor in
            let requireFreeMesh = ProcessInfo.processInfo.environment["SIG_DEMO_TEST_REQUIRE_FREE_MESH"] == "1"
            let requireLocalModel = ProcessInfo.processInfo.environment["SIG_DEMO_TEST_REQUIRE_LOCAL_MODEL"] == "1"
            for _ in 0..<120 {
                var providerSkipped = false
                let thread: TSContactThread? = SSKEnvironment.shared.databaseStorageRef.write { tx in
                    let manager = DependenciesBridge.shared.tsAccountManager
                    guard manager.registrationState(tx: tx).isRegistered,
                          let local = manager.localIdentifiers(tx: tx) else { return nil }
                    if requireFreeMesh || requireLocalModel {
                        guard let saved = try? SigDemoInferenceSettings.load(
                            accountID: local.aci.serviceIdUppercaseString, tx: tx),
                              (!requireFreeMesh || saved.provider == .publicMesh),
                              (!requireLocalModel || Self.usesLocalModel(saved)) else {
                            providerSkipped = true
                            return nil
                        }
                    }
                    return TSContactThread.getOrCreateThread(withContactAddress: local.aciAddress, transaction: tx)
                }
                if providerSkipped {
                    Self.emitSimulatorSmokeStatus("SIG_DEMO_AGENT_SMOKE_PROVIDER_SKIPPED")
                    return
                }
                if let thread {
                    ThreadUtil.addThreadToProfileWhitelistIfEmptyOrPendingRequestAndSetDefaultTimerWithSneakyTransaction(thread)
                    ThreadUtil.enqueueMessage(body: MessageBody(text: source, ranges: .empty), thread: thread)
                    Self.emitSimulatorSmokeStatus("SIG_DEMO_AGENT_SMOKE_ENQUEUED")
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            Self.emitSimulatorSmokeStatus("SIG_DEMO_AGENT_SMOKE_ACCOUNT_NOT_READY")
        }
    }

    private func runPaidContractSmokeIfRequested(account: String) {
        guard !paidContractSmokeStarted, Self.isAvailable,
              registeredAccount() == account,
              ProcessInfo.processInfo.environment["SIG_DEMO_PAID_MESH_CONTRACT_SMOKE"] == "1" else { return }
        paidContractSmokeStarted = true
        let deployment = paidDeploymentID
        paidContractSmokeTask = Task {
            guard let deployment else {
                Self.emitSimulatorSmokeStatus("SIG_DEMO_PAID_MESH_CONTRACT_FAILED")
                return
            }
            let runtime = PaidMeshRuntime(accountID: "sig-demo-ios-paid-contract-v1", deploymentID: deployment)
            let marker = await Self.qualifyUnfundedPaidRuntime(runtime)
            Self.emitSimulatorSmokeStatus(marker)
        }
    }

    /// This fixture uses the real iOS Keychain/FFI under a synthetic account
    /// namespace. It never calls wallet setup, funding, or inference admission.
    private static func qualifyUnfundedPaidRuntime(_ runtime: PaidMeshRuntime) async -> String {
        let initial = await runtime.walletSnapshot()
        guard !Task.isCancelled, initial.state == .notSetUp else {
            await runtime.stop()
            return "SIG_DEMO_PAID_MESH_CONTRACT_SKIPPED"
        }
        guard PaidMeshRuntime.defaultModel == "Qwen3.6-27B-Q6_K",
              SigDemoInferenceSelection.defaultPaidModel == PaidMeshRuntime.defaultModel else {
            await runtime.stop()
            return "SIG_DEMO_PAID_MESH_CONTRACT_FAILED"
        }
        var zeroRejected = false
        do {
            _ = try await runtime.start(preferredModel: PaidMeshRuntime.defaultModel,
                dailyBudgetBaseUnits: 0, perRequestBudgetBaseUnits: 0)
        } catch let error as PaidMeshError {
            zeroRejected = error == .spendingDisabled
        } catch {}
        guard zeroRejected, !Task.isCancelled else {
            await runtime.stop()
            return Task.isCancelled ? "SIG_DEMO_PAID_MESH_CONTRACT_SKIPPED" : "SIG_DEMO_PAID_MESH_CONTRACT_FAILED"
        }
        var missingWalletRejected = false
        do {
            _ = try await runtime.start(preferredModel: PaidMeshRuntime.defaultModel,
                dailyBudgetBaseUnits: 1, perRequestBudgetBaseUnits: 1)
        } catch let error as PaidMeshError {
            missingWalletRejected = error == .walletNotSetUp
        } catch {}
        await runtime.stop()
        guard !Task.isCancelled else { return "SIG_DEMO_PAID_MESH_CONTRACT_SKIPPED" }
        let final = await runtime.walletSnapshot()
        await runtime.stop()
        guard !Task.isCancelled else { return "SIG_DEMO_PAID_MESH_CONTRACT_SKIPPED" }
        return missingWalletRejected && final.state == .notSetUp
            ? "SIG_DEMO_PAID_MESH_CONTRACT_PASSED" : "SIG_DEMO_PAID_MESH_CONTRACT_FAILED"
    }
    #endif

    #if SIG_DEMO_LOCAL_MODEL
    private func pauseLocalInferenceBeforeInactive() {
        guard selection.provider == .localModel, localPauseTask == nil else { return }
        endLocalProgress()
        suspended = true
        localModel?.cancel()
        localStartTask?.cancel()
        for job in jobs.values { job.cancel() }
        localPauseTask = Task { [weak self] in
            guard let self else { return }
            await shutdown()
            localPauseTask = nil
        }
    }
    #endif

    func shutdown() async {
        // Close the gate before the first suspension. Already queued database
        // notifications must not create an untracked invocation during drain.
        suspended = true
        generation &+= 1
        let earlierTeardown = teardownTask
        #if DEBUG && targetEnvironment(simulator)
        let contractSmoke = paidContractSmokeTask
        contractSmoke?.cancel()
        paidContractSmokeTask = nil
        #endif
        let recovery = recoveryTask
        recovery?.cancel()
        recoveryTask = nil
        recoveryTaskId = nil
        let credentialBootstrap = credentialBootstrapTask
        credentialBootstrap?.cancel()
        credentialBootstrapTask = nil
        credentialBootstrapID = nil
        credentialBootstrapEpoch = nil
        isRefreshingDemoAccess = false
        let pending = jobs
        for job in pending.values { job.cancel() }
        let previous = agent
        agent = nil
        #if SIG_DEMO_LOCAL_MODEL
        endLocalProgress()
        localAgentHasBraveAccess = false
        #endif
        accountId = nil
        selectionAccountID = nil
        let previousMesh = mesh
        mesh = nil
        let previousPaidMesh = paidMesh
        paidMesh = nil
        #if SIG_DEMO_LOCAL_MODEL
        let previousLocalModel = localModel
        previousLocalModel?.cancel()
        localModel = nil
        localRoute = nil
        let startingLocalModel = localStartTask
        startingLocalModel?.cancel()
        localStartTask = nil
        localStartID = nil
        #endif
        let invalidation = paidInvalidationTask
        paidInvalidationTask = nil
        paidInvalidationID = nil
        paidRouteInvalidationNeeded = false
        paidConnectionStatus.clear()
        paidWallet = nil
        fundingDefaultsRetryAttempts = 0
        fundingDefaultsRetryAfter = .distantPast
        fundingPaymentConfirmed = false
        isPaidInferenceActive = false
        isFinalizingPaidInference = false
        paidInferenceID = nil
        let walletObserver = walletMonitor
        walletObserver?.cancel()
        walletMonitor = nil
        let observations = walletObservations
        for observation in observations.values { observation.cancel() }
        walletObservations.removeAll()
        let walletOperation = walletTask
        walletOperation?.cancel()
        walletTask = nil
        walletTaskID = nil
        route = nil
        let startingMesh = meshStartTask
        startingMesh?.cancel()
        meshStartTask = nil
        meshStartID = nil
        availableModels = []
        switch selection.provider {
        case .chatGPT: status = "ChatGPT is paused."
        case .publicMesh: status = "Public Mesh is paused. It connects only while this app is in the foreground."
        case .paidMesh: status = "Paid Mesh is paused. Outstanding settlements still require reconciliation."
        #if SIG_DEMO_LOCAL_MODEL
        case .localModel: status = "Local inference is paused. Models run only while this app is in the foreground."
        #endif
        }
        notifyStateChanged()
        let id = UUID()
        teardownID = id
        let task = Task { [weak self] in
            // Stop fences native payment admission before its first await.
            // Do not delay that fence behind a GDK or earlier teardown drain.
            await previousPaidMesh?.shutdown()
            await earlierTeardown?.value
            await previous?.shutdown()
            #if SIG_DEMO_LOCAL_MODEL
            // Admission was closed synchronously above. Drain GDK streams,
            // then wait for all GPU work before evicting the local model.
            await previousLocalModel?.stop()
            _ = try? await startingLocalModel?.value
            #endif
            await invalidation?.value
            await previousMesh?.stop()
            _ = try? await walletOperation?.value
            await walletObserver?.value
            for observation in observations.values { await observation.value }
            _ = try? await startingMesh?.value
            for job in pending.values { await job.value }
            await recovery?.value
            await credentialBootstrap?.value
            #if DEBUG && targetEnvironment(simulator)
            await contractSmoke?.value
            #endif
            guard let self else { return }
            for id in pending.keys { jobs.removeValue(forKey: id) }
            if walletTask == nil { isUpdatingWallet = false }
            if teardownID == id {
                teardownTask = nil
                teardownID = nil
            }
            notifyStateChanged()
        }
        teardownTask = task
        await task.value
    }

    private func registeredAccount() -> String? {
        SSKEnvironment.shared.databaseStorageRef.read { tx in
            let manager = DependenciesBridge.shared.tsAccountManager
            guard manager.registrationState(tx: tx).isRegistered else { return nil }
            return manager.localIdentifiers(tx: tx)?.aci.serviceIdUppercaseString
        }
    }

    private func isCurrentInferenceContext(account: String, epoch: UInt64) -> Bool {
        Self.isAvailable && !Task.isCancelled && !suspended && epoch == generation
            && selectionAccountID == account && registeredAccount() == account
            && UIApplication.shared.applicationState != .background
            && (!Self.usesLocalModel(selection) || UIApplication.shared.applicationState == .active)
    }

    /// A discarded callback must not open a native context on its old runtime.
    /// Permanent shutdown also fences the cross-actor race after this check.
    private func walletSnapshotIfCurrent(_ runtime: PaidMeshRuntime, account: String,
        epoch: UInt64
    ) async -> PaidMeshWalletSnapshot? {
        guard isCurrentInferenceContext(account: account, epoch: epoch),
              selection.provider == .paidMesh else { return nil }
        let snapshot = await runtime.walletSnapshot()
        guard isCurrentInferenceContext(account: account, epoch: epoch),
              selection.provider == .paidMesh else { return nil }
        return snapshot
    }
    private func resumeIfAvailable() async {
        #if SIG_DEMO_LOCAL_MODEL
        while let localPauseTask { await localPauseTask.value }
        #endif
        while let teardownTask { await teardownTask.value }
        guard Self.isAvailable, !isUpdatingSelection, !isUpdatingWallet,
              UIApplication.shared.applicationState != .background, let account = registeredAccount() else { return }
        let saved: SigDemoInferenceSelection
        do {
            saved = try SSKEnvironment.shared.databaseStorageRef.read { tx in
                try SigDemoInferenceSettings.load(accountID: account, tx: tx)
            }
        } catch {
            status = "Sig's inference settings could not be loaded. Choose a provider again."
            suspended = true
            notifyStateChanged()
            return
        }
        if let selectionAccountID, selectionAccountID != account || selection != saved {
            await shutdown()
            await resumeIfAvailable()
            return
        }
        selectionAccountID = account
        selection = saved
        #if SIG_DEMO_LOCAL_MODEL
        restoreLocalAttempt(account: account, selection: saved)
        if saved.provider == .localModel, UIApplication.shared.applicationState != .active {
            suspended = true
            return
        }
        #endif
        suspended = false
        let credentialEpoch = generation
        if !Self.usesLocalModel(saved) {
            Task { await bootstrapDemoCredentials(account: account, epoch: credentialEpoch) }
        }
        #if SIG_DEMO_LOCAL_MODEL
        if Self.usesLocalModel(saved) {
            beginLocalBraveBootstrapIfNeeded(account: account, epoch: credentialEpoch)
        }
        #endif
        recoverInterruptedResponsesIfNeeded(account: account)
        #if DEBUG && targetEnvironment(simulator)
        runPaidContractSmokeIfRequested(account: account)
        #endif
        switch saved.provider {
        case .chatGPT:
            status = inferenceCredential(.openAI, account: account) != nil ? "ChatGPT is selected." : "Connecting to private demo access. Public Mesh does not require an API key."
            notifyStateChanged()
        case .publicMesh, .paidMesh:
            if saved.provider == .paidMesh {
                do {
                    let runtime = try paidRuntime(account: account)
                    startWalletMonitor(runtime: runtime, account: account, epoch: generation)
                } catch {
                    #if DEBUG && targetEnvironment(simulator)
                    Self.logPaidMeshDiagnostic(error, stage: "RESUME_CONFIGURATION")
                    #endif
                    suspended = true
                    status = "Paid Mesh could not validate this test deployment."
                    notifyStateChanged()
                    return
                }
            }
            do { _ = try await meshRoute(account: account, selection: saved, epoch: generation) }
            catch { /* meshRoute publishes only sanitized connection status. */ }
        #if SIG_DEMO_LOCAL_MODEL
        case .localModel:
            do { _ = try await localModelRoute(account: account, selection: saved, epoch: generation) }
            catch { /* The local route publishes only fixed connection status. */ }
        #endif
        }
    }

    nonisolated private static func usesLocalModel(_ selection: SigDemoInferenceSelection) -> Bool {
        #if SIG_DEMO_LOCAL_MODEL
        return selection.provider == .localModel
        #else
        return false
        #endif
    }

    /// Fixed stage names and numeric process headroom only. Ordinary messages,
    /// simulator runs and the other providers do not emit this device trace.
    private nonisolated static func traceLocalDeviceStage(_ stage: StaticString,
        selection: SigDemoInferenceSelection, historyCount: Int? = nil) {
        #if DEBUG && SIG_DEMO_LOCAL_MODEL && !targetEnvironment(simulator)
        guard selection.provider == .localModel else { return }
        let availableMiB = os_proc_available_memory() / 1_048_576
        let count = historyCount.map { " history_count=\($0)" } ?? ""
        emitLocalProbe("SIG_DEMO_LOCAL_LIVE_\(stage) available_mib=\(availableMiB)" + count)
        #endif
    }

    private func credentialStore(account: String) throws -> SigDemoInferenceCredentialStore {
        guard let accountID = UUID(uuidString: account), let deployment = paidDeploymentID else {
            throw SigDemoInferenceCredentialError.invalidScope
        }
        let identity = try SigDemoAppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            appGroupIdentifier: TSConstants.applicationGroup, keychainService: "dev.matbalez.sig-demo.ios.registration")
        return try SigDemoInferenceCredentialStore(accountID: accountID, deploymentID: deployment, identity: identity)
    }

    private func inferenceCredential(_ provider: SigDemoInferenceCredential, account: String) -> String? {
        #if DEBUG
        let variable = provider == .openAI ? "SIG_DEMO_OPENAI_API_KEY" : "SIG_DEMO_BRAVE_SEARCH_API_KEY"
        if let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty { return value }
        #endif
        return try? credentialStore(account: account).credential(for: provider)
    }

    #if SIG_DEMO_LOCAL_MODEL
    /// Optional web access warms alongside the model. Never gate offline chat on it.
    private func beginLocalBraveBootstrapIfNeeded(account: String, epoch: UInt64) {
        guard isCurrentInferenceContext(account: account, epoch: epoch), selection.provider == .localModel,
              inferenceCredential(.braveSearch, account: account) == nil,
              credentialBootstrapTask == nil else { return }
        Task { await bootstrapDemoCredentials(account: account, epoch: epoch, force: true, localDeadline: true) }
    }

    private func restoreLocalAttempt(account: String, selection expected: SigDemoInferenceSelection) {
        guard expected.provider == .localModel else { return }
        if let last = localLastAttempt, last.account == account, last.model == expected.localPreferredModel { return }
        localLastAttempt = nil
        guard let deployment = paidDeploymentID,
              let key = SigDemoLocalAttemptRecord.storageKey(account: account, deployment: deployment,
                model: expected.localPreferredModel),
              let data = UserDefaults.standard.data(forKey: key),
              let record = SigDemoLocalAttemptRecord.decode(data) else { return }
        localLastAttempt = (account, expected.localPreferredModel, record.summary)
    }

    private func persistLocalAttempt(_ diagnostic: SigDemoLocalReplyDiagnostics, account: String,
        model: String, epoch: UInt64
    ) {
        guard isCurrentInferenceContext(account: account, epoch: epoch), selection.provider == .localModel,
              selection.localPreferredModel == model, diagnostic.isValidTerminalRecord,
              let deployment = paidDeploymentID,
              let key = SigDemoLocalAttemptRecord.storageKey(account: account, deployment: deployment, model: model),
              let data = try? JSONEncoder().encode(SigDemoLocalAttemptRecord(diagnostic: diagnostic)),
              data.count <= 8_192 else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    #endif

    private func bootstrapDemoCredentials(account: String, epoch: UInt64, force: Bool = false,
        localDeadline: Bool = false
    ) async {
        guard isCurrentInferenceContext(account: account, epoch: epoch) else { return }
        if let task = credentialBootstrapTask { await task.value; return }
        guard force || credentialBootstrapEpoch != epoch else { return }
        credentialBootstrapEpoch = epoch
        let id = UUID()
        credentialBootstrapID = id
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if credentialBootstrapID == id {
                    credentialBootstrapTask = nil
                    credentialBootstrapID = nil
                    if isCurrentInferenceContext(account: account, epoch: epoch), selection.provider == .chatGPT {
                        status = inferenceCredential(.openAI, account: account) != nil ? "ChatGPT is selected."
                            : "Demo ChatGPT access is unavailable. Refresh demo access or contact your inviter; Public Mesh works without an API key."
                    }
                    notifyStateChanged()
                }
            }
            do {
                let manager = DependenciesBridge.shared.tsAccountManager
                guard let local = manager.localIdentifiersWithMaybeSneakyTransaction,
                      local.aci.serviceIdUppercaseString == account,
                      let password = manager.storedServerAuthTokenWithMaybeTransaction else { return }
                let configuration = try JSONDecoder().decode(SigDemoConfiguration.self,
                    from: SigDemoRuntimeConfiguration.publicClientConfigurationData)
                let identity = try SigDemoAppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                    appGroupIdentifier: TSConstants.applicationGroup, keychainService: "dev.matbalez.sig-demo.ios.registration")
                let api = try SigDemoPrivateAPI(configuration: configuration, identity: identity)
                let authentication = try SigDemoCredentials(accountID: local.aci.rawUUID, generatedPassword: password)
                let provision = try await api.demoInferenceCredentials(credentials: authentication)
                guard isCurrentInferenceContext(account: account, epoch: epoch) else { return }
                try provision.save(to: credentialStore(account: account))
            } catch {
                // Missing/disabled bootstrap, transport failures and provider
                // credentials never enter logs or Signal messages. Existing
                // account-scoped Keychain credentials remain usable offline.
            }
        }
        credentialBootstrapTask = task
        let deadline: Task<Void, Never>? = localDeadline ? Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            task.cancel()
        } : nil
        defer { deadline?.cancel() }
        await task.value
    }

    func refreshDemoAccess() async {
        guard let account = currentAccountID, !suspended, jobs.isEmpty, !isRefreshingDemoAccess else { return }
        let epoch = generation
        isRefreshingDemoAccess = true
        notifyStateChanged()
        await bootstrapDemoCredentials(account: account, epoch: epoch, force: true)
        if isCurrentInferenceContext(account: account, epoch: epoch) {
            let previous = agent
            agent = nil
            await previous?.shutdown()
        }
        if epoch == generation { isRefreshingDemoAccess = false; notifyStateChanged() }
    }

    private func notifyStateChanged() {
        NotificationCenter.default.post(name: SigDemoInferenceSettings.stateDidChange, object: nil)
    }

    private func paidRuntime(account: String) throws -> PaidMeshRuntime {
        if let paidMesh { return paidMesh }
        guard let paidDeploymentID else { throw PaidMeshError.invalidConfiguration }
        let runtime = PaidMeshRuntime(accountID: account, deploymentID: paidDeploymentID)
        paidMesh = runtime
        return runtime
    }

    private func startWalletMonitor(runtime: PaidMeshRuntime, account: String, epoch: UInt64) {
        guard walletMonitor == nil else { return }
        // Snapshot reads do not provision or refresh the network wallet. The
        // lifecycle owner observes cached payment/reservation changes only.
        walletMonitor = Task { [weak self] in
            guard let self else { return }
            // Observe existing funding when this provider resumes. This never
            // provisions a wallet or attempts payment reconciliation.
            _ = await refreshPaidWalletObservation(accountID: account)
            while !Task.isCancelled, !suspended, epoch == generation,
                  selectionAccountID == account, registeredAccount() == account {
                let snapshot = await observePaidWallet(accountID: account, stage: .snapshot, operation: { _ in
                    guard let snapshot = await self.walletSnapshotIfCurrent(runtime,
                        account: account, epoch: epoch) else { throw CancellationError() }
                    return snapshot
                })
                guard !Task.isCancelled, !suspended, epoch == generation,
                      selectionAccountID == account, registeredAccount() == account else { return }
                if let snapshot, paidWallet != snapshot {
                    updatePaidWallet(snapshot)
                    notifyStateChanged()
                }
                await retryConfirmedFundingDefaultsIfNeeded(account: account, epoch: epoch)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func updatePaidWallet(_ wallet: PaidMeshWalletSnapshot?) {
        paidWallet = wallet
        guard selection.provider == .paidMesh, !isPaidInferenceActive, let wallet else { return }
        if wallet.state == .ready {
            status = paidConnectionStatus.walletReadyMessage(
                spendingEnabled: selection.paidDailyBudgetBaseUnits > 0 && selection.paidPerRequestBudgetBaseUnits > 0,
                connectedModel: route?.model)
        } else if wallet.state == .reconciliationNeeded {
            status = "Paid Mesh has an outstanding settlement. Retry reconciliation before another paid reply."
        } else {
            // Answer completion does not prove payment settlement. Preserve a
            // visible recovery state even when the model route still exists.
            status = wallet.status
        }
    }

    private func recordPaidConnectionFailure(_ error: Error, stage: SigDemoPaidConnectionStatus.Stage) {
        let failure = SigDemoPaidConnectionStatus.Failure(stage: stage, category: Self.paidFailureCategory(error))
        if paidConnectionStatus.record(failure) { Logger.warn(failure.marker) }
        status = failure.message
    }

    private static func paidFailureCategory(_ error: Error) -> SigDemoPaidConnectionStatus.Category {
        if let error = error as? PaidMeshError {
            switch error {
            case .invalidConfiguration: return .invalidConfiguration
            case .walletNotSetUp: return .walletNotSetUp
            case .walletLocked: return .walletLocked
            case .insufficientFunds: return .insufficientFunds
            case .spendingDisabled: return .spendingDisabled
            case .budgetExceeded: return .budgetExceeded
            case .paymentPending: return .paymentPending
            case .modelUnavailable: return .modelUnavailable
            case .busy: return .busy
            case .stopped: return .stopped
            case .unavailable: return .unavailable
            case .startupFailed(let stage): return paidStartupFailureCategory(stage)
            @unknown default: return .other
            }
        }
        if let category = SigDemoPaidConnectionStatus.Category.network(error) { return category }
        if let error = error as? MeshInferenceError {
            switch error {
            case .invalidConfiguration: return .invalidConfiguration
            case .unavailable: return .unavailable
            case .paymentRequired: return .paymentRequired
            case .invalidResponse: return .invalidResponse
            case .stopped: return .stopped
            @unknown default: return .other
            }
        }
        if let error = error as? SigChatAgentError {
            switch error {
            case .invalidConfiguration: return .invalidConfiguration
            case .closed: return .stopped
            case .warmupForbidden: return .agentFailure
            @unknown default: return .other
            }
        }
        return .other
    }

    private static func paidStartupFailureCategory(_ stage: PaidMeshStartupStage) -> SigDemoPaidConnectionStatus.Category {
        switch stage {
        case .walletRefresh: .startupWalletRefresh
        case .recovery: .startupRecovery
        case .policy: .startupPolicy
        case .buyerIdentity: .startupBuyerIdentity
        case .nodeStart: .startupNodeStart
        @unknown default: .other
        }
    }

    /// Saving is account-scoped and serialized with teardown. An old settings
    /// screen cannot modify a replacement account, and no request changes
    /// providers while it is streaming.
    func updateSelection(_ next: SigDemoInferenceSelection, accountID: String) async -> Bool {
        guard Self.isAvailable, !isUpdatingSelection, registeredAccount() == accountID else { return false }
        do { try next.validate() } catch { return false }
        if selectionAccountID == accountID, selection == next { return true }
        isUpdatingSelection = true
        notifyStateChanged()
        await shutdown()
        var saved = false
        do {
            try SSKEnvironment.shared.databaseStorageRef.write { tx in
                let manager = DependenciesBridge.shared.tsAccountManager
                guard manager.registrationState(tx: tx).isRegistered,
                      manager.localIdentifiers(tx: tx)?.aci.serviceIdUppercaseString == accountID else {
                    throw SigDemoInferenceSettings.SettingsError.accountChanged
                }
                try SigDemoInferenceSettings.save(next, accountID: accountID, tx: tx)
            }
            selection = next
            #if SIG_DEMO_LOCAL_MODEL
            localLastAttempt = nil
            #endif
            saved = true
        } catch {
            status = "Sig could not save this inference choice. Try again."
        }
        isUpdatingSelection = false
        notifyStateChanged()
        await resumeIfAvailable()
        return saved
    }

    func refreshMeshModels() async {
        guard Self.isAvailable, !suspended, !isUpdatingSelection,
              selection.provider == .publicMesh || selection.provider == .paidMesh,
              UIApplication.shared.applicationState != .background,
              let account = registeredAccount(), selectionAccountID == account else { return }
        // Discovery is bounded by the owned client's lifecycle. Refresh follows
        // the same drain/stop/restart path as a model change and never creates
        // an independent HTTP catalog request.
        isUpdatingSelection = true
        notifyStateChanged()
        await shutdown()
        isUpdatingSelection = false
        notifyStateChanged()
        await resumeIfAvailable()
    }

    private enum WalletResult: Sendable {
        case snapshot(PaidMeshWalletSnapshot)
        case invoice(PaidMeshFundingInvoice, PaidMeshWalletSnapshot)

        var snapshot: PaidMeshWalletSnapshot {
            switch self {
            case .snapshot(let snapshot), .invoice(_, let snapshot): snapshot
            }
        }
    }

    func setupPaidWallet(accountID: String) async -> Bool {
        let result = await performWalletOperation(accountID: accountID, operation: { runtime in
            .snapshot(try await runtime.setupWallet())
        })
        await resumeIfAvailable()
        guard case .snapshot? = result else { return false }
        return true
    }

    func refreshPaidWallet(accountID: String) async -> Bool {
        let limits: SigDemoInferenceSelection
        do {
            limits = try SSKEnvironment.shared.databaseStorageRef.read { tx in
                let manager = DependenciesBridge.shared.tsAccountManager
                guard manager.registrationState(tx: tx).isRegistered,
                      manager.localIdentifiers(tx: tx)?.aci.serviceIdUppercaseString == accountID else {
                    throw SigDemoInferenceSettings.SettingsError.accountChanged
                }
                return try SigDemoInferenceSettings.load(accountID: accountID, tx: tx)
            }
        } catch { return false }
        guard jobs.isEmpty, !isUpdatingWallet, !isUpdatingSelection,
              limits == selection,
              await invalidatePaidRoute(account: accountID, epoch: generation, jobID: nil),
              limits == selection else { return false }
        let result = await performWalletOperation(accountID: accountID, operation: { runtime in
            .snapshot(try await runtime.refreshWallet(
                dailyBudgetBaseUnits: limits.paidDailyBudgetBaseUnits,
                perRequestBudgetBaseUnits: limits.paidPerRequestBudgetBaseUnits))
        })
        await resumeIfAvailable()
        guard case .snapshot? = result else { return false }
        return true
    }

    func createPaidFundingInvoice(amountBaseUnits: UInt64, accountID: String) async -> PaidMeshFundingInvoice? {
        guard amountBaseUnits > 0, amountBaseUnits <= SigDemoInferenceSelection.maximumBudgetBaseUnits else { return nil }
        let epoch = generation
        let result = await performWalletOperation(accountID: accountID, operation: { [weak self] runtime in
            let invoice = try await runtime.createFundingInvoice(amountBaseUnits: amountBaseUnits)
            guard let self, let snapshot = await self.walletSnapshotIfCurrent(runtime,
                account: accountID, epoch: epoch) else { throw CancellationError() }
            return .invoice(invoice, snapshot)
        })
        await resumeIfAvailable()
        guard case .invoice(let invoice, _)? = result else { return nil }
        return invoice
    }

    func paidFundingStatus(for invoice: PaidMeshFundingInvoice, accountID: String) async -> PaidMeshFundingStatus? {
        let epoch = generation
        guard let result = await observePaidWallet(accountID: accountID, stage: .funding, operation: {
            try await $0.fundingStatus(for: invoice)
        }), isCurrentInferenceContext(account: accountID, epoch: epoch) else { return nil }
        if result.state == .paid { fundingPaymentConfirmed = true }
        updatePaidWallet(result.wallet)
        notifyStateChanged()
        return result
    }

    func paidTransactionHistory(cursor: String?, accountID: String) async -> PaidMeshTransactionPage? {
        await observePaidWallet(accountID: accountID, stage: .history, operation: {
            try await $0.transactionHistory(cursor: cursor, limit: 50)
        })
    }

    @discardableResult
    func refreshPaidWalletObservation(accountID: String) async -> Bool {
        guard let snapshot = await observePaidWallet(accountID: accountID, stage: .balance, operation: {
            try await $0.refreshWalletObservation()
        }) else { return false }
        updatePaidWallet(snapshot)
        notifyStateChanged()
        await applyConfirmedFundingDefaultsIfNeeded(accountID: accountID)
        return true
    }

    /// Finish a first-funding lookup independently of a disappearing invoice
    /// screen. A balance is only a cue to query history, never the limit basis.
    /// Unfunded wallets do not poll history without a confirmed invoice result.
    private func retryConfirmedFundingDefaultsIfNeeded(account: String, epoch: UInt64) async {
        guard isCurrentInferenceContext(account: account, epoch: epoch),
              selection.provider == .paidMesh, selection.paidFundingDefaults.state == .pending,
              jobs.isEmpty, !isUpdatingWallet, !isUpdatingSelection,
              walletObservations.isEmpty, meshStartTask == nil,
              fundingDefaultsRetryAttempts < 3, Date() >= fundingDefaultsRetryAfter,
              fundingPaymentConfirmed || (paidWallet?.balanceBaseUnits.map { $0 > 0 } ?? false) else { return }
        let delay: TimeInterval = [3, 10, 30][fundingDefaultsRetryAttempts]
        fundingDefaultsRetryAttempts += 1
        fundingDefaultsRetryAfter = Date().addingTimeInterval(delay)
        await applyConfirmedFundingDefaultsIfNeeded(accountID: account)
    }

    /// The native summary identifies the earliest completed inbound payment
    /// only after its history scan is complete. Never infer funding from an
    /// invoice request or a balance change, and never overwrite edited limits.
    func applyConfirmedFundingDefaultsIfNeeded(accountID: String) async {
        guard selection.paidFundingDefaults.state == .pending, jobs.isEmpty,
              !isUpdatingSelection, !isUpdatingWallet else { return }
        let epoch = generation
        guard let summary = await observePaidWallet(accountID: accountID, stage: .confirmedFunding, operation: {
            try await $0.confirmedFunding()
        }), summary.historyComplete, let funding = summary.initialFunding,
              !Task.isCancelled, !suspended, epoch == generation, jobs.isEmpty,
              !isUpdatingSelection, !isUpdatingWallet,
              selectionAccountID == accountID, registeredAccount() == accountID else { return }
        do {
            let next: SigDemoInferenceSelection? = try SSKEnvironment.shared.databaseStorageRef.write { tx in
                let manager = DependenciesBridge.shared.tsAccountManager
                guard manager.registrationState(tx: tx).isRegistered,
                      manager.localIdentifiers(tx: tx)?.aci.serviceIdUppercaseString == accountID else {
                    throw SigDemoInferenceSettings.SettingsError.accountChanged
                }
                var saved = try SigDemoInferenceSettings.load(accountID: accountID, tx: tx)
                guard saved == selection,
                      let limits = saved.paidFundingDefaults.consumeConfirmedFunding(
                        amountBaseUnits: funding.amountBaseUnits,
                        daily: saved.paidDailyBudgetBaseUnits,
                        perRequest: saved.paidPerRequestBudgetBaseUnits,
                        maximum: SigDemoInferenceSelection.maximumBudgetBaseUnits) else { return nil }
                saved.paidDailyBudgetBaseUnits = limits.daily
                saved.paidPerRequestBudgetBaseUnits = limits.perRequest
                try SigDemoInferenceSettings.save(saved, accountID: accountID, tx: tx)
                return saved
            }
            if let next {
                // No inference is active. The next request must recreate any
                // old route with the newly persisted spending policy.
                if route != nil { paidRouteInvalidationNeeded = true }
                selection = next
                updatePaidWallet(paidWallet)
                notifyStateChanged()
            }
        } catch { /* Keep zero limits if the account or database changed. */ }
    }

    /// Observation has its own cancellation ownership and defers when the
    /// runtime is busy. It never enters settlement recovery or cancels inference.
    private func observePaidWallet<Value: Sendable>(accountID: String, stage: WalletObservationStage,
        operation: @escaping @Sendable (PaidMeshRuntime) async throws -> Value
    ) async -> Value? {
        guard Self.isAvailable, !Task.isCancelled, !suspended, jobs.isEmpty,
              !isUpdatingSelection, !isUpdatingWallet,
              selection.provider == .paidMesh, selectionAccountID == accountID,
              registeredAccount() == accountID,
              UIApplication.shared.applicationState != .background else { return nil }
        let epoch = generation
        let runtime: PaidMeshRuntime
        do { runtime = try paidRuntime(account: accountID) }
        catch {
            #if DEBUG && targetEnvironment(simulator)
            Self.logPaidMeshDiagnostic(error, stage: "OBSERVE_CONFIGURATION")
            #endif
            return nil
        }
        let id = UUID()
        let operationTask = Task { try await operation(runtime) }
        let drain = Task {
            _ = try? await withTaskCancellationHandler {
                try await operationTask.value
            } onCancel: { operationTask.cancel() }
        }
        walletObservations[id] = drain
        defer { walletObservations.removeValue(forKey: id) }
        do {
            let result = try await withTaskCancellationHandler {
                try await operationTask.value
            } onCancel: { operationTask.cancel() }
            try Task.checkCancellation()
            guard !suspended, epoch == generation, selectionAccountID == accountID,
                  selection.provider == .paidMesh, registeredAccount() == accountID else { return nil }
            return result
        } catch {
            #if DEBUG && targetEnvironment(simulator)
            Self.logPaidMeshDiagnostic(error, stage: "OBSERVE_" + stage.rawValue)
            #endif
            return nil
        }
    }

    /// A failed native scope can close the old loopback endpoint. Keep its GDK
    /// and route from being reused, without interrupting a different paid job.
    /// Cleanup is retained separately so lifecycle teardown also drains refresh.
    private func invalidatePaidRoute(account: String, epoch: UInt64, jobID: UUID?) async -> Bool {
        guard Self.isAvailable, !suspended, epoch == generation, !isPaidInferenceActive,
              selection.provider == .paidMesh, selectionAccountID == account,
              registeredAccount() == account, paidInvalidationID == nil,
              jobs.keys.allSatisfy({ $0 == jobID }) else { return false }
        let id = UUID()
        paidInvalidationID = id
        let previous = agent
        agent = nil
        accountId = nil
        route = nil
        paidRouteInvalidationNeeded = false
        let starting = meshStartTask
        starting?.cancel()
        meshStartTask = nil
        meshStartID = nil
        let runtime = paidMesh
        let task = Task {
            // Fence payment admission before waiting for the old GDK.
            await runtime?.stop()
            await previous?.shutdown()
            _ = try? await starting?.value
        }
        paidInvalidationTask = task
        notifyStateChanged()
        await task.value
        if paidInvalidationID == id {
            paidInvalidationID = nil
            paidInvalidationTask = nil
            notifyStateChanged()
        }
        return !suspended && epoch == generation && selectionAccountID == account && registeredAccount() == account
    }

    private func performWalletOperation(accountID: String,
        operation: @escaping @Sendable (PaidMeshRuntime) async throws -> WalletResult
    ) async -> WalletResult? {
        guard Self.isAvailable, !suspended, !isUpdatingSelection, !isUpdatingWallet, jobs.isEmpty,
              selection.provider == .paidMesh, selectionAccountID == accountID,
              registeredAccount() == accountID,
              UIApplication.shared.applicationState != .background else { return nil }
        let epoch = generation
        let runtime: PaidMeshRuntime
        do { runtime = try paidRuntime(account: accountID) }
        catch { return nil }
        let id = UUID()
        let task = Task { try await operation(runtime) }
        walletTask = task
        walletTaskID = id
        isUpdatingWallet = true
        notifyStateChanged()
        defer {
            if walletTaskID == id {
                walletTask = nil
                walletTaskID = nil
                isUpdatingWallet = false
                notifyStateChanged()
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !suspended, epoch == generation, selectionAccountID == accountID,
                  registeredAccount() == accountID else { return nil }
            updatePaidWallet(result.snapshot)
            return result
        } catch {
            if let wallet = await walletSnapshotIfCurrent(runtime, account: accountID, epoch: epoch) {
                // Only fixed local messages enter settings. Native wallet
                // errors may contain invoice or payment metadata.
                status = "The paid Mesh wallet could not complete this action. Refresh the wallet and try again."
                updatePaidWallet(wallet)
            }
            return nil
        }
    }

    private func updateModels(_ models: [MeshInferenceModel]) {
        var unique: [String: SigDemoInferenceModel] = [:]
        for model in models {
            guard !model.id.isEmpty, model.id.utf8.count <= 128,
                  !model.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { continue }
            let label = String(String.UnicodeScalarView(model.name.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            })).trimmingCharacters(in: .whitespacesAndNewlines)
            unique[model.id] = .init(id: model.id, name: String(label.prefix(160)).isEmpty ? model.id : String(label.prefix(160)))
        }
        availableModels = unique.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    #if SIG_DEMO_LOCAL_MODEL
    private func localModelRoute(account: String, selection expected: SigDemoInferenceSelection,
        epoch: UInt64
    ) async throws -> LocalModelRoute {
        guard isCurrentInferenceContext(account: account, epoch: epoch), selection == expected,
              expected.provider == .localModel else { throw CancellationError() }
        if let localRoute { return localRoute }
        let task: Task<LocalModelRoute, Error>
        if let pending = localStartTask {
            task = pending
        } else {
            guard let descriptor = LocalModelCatalog.model(id: expected.localPreferredModel),
                  let url = Bundle.main.url(forResource: descriptor.filename, withExtension: nil,
                    subdirectory: "LocalModels") else {
                status = "The selected local model is missing from this build. Rebuild with both pinned model files."
                notifyStateChanged()
                throw LocalModelError.modelUnavailable
            }
            let runtime = LocalModelRuntime(accountID: account, modelURL: url)
            localModel = runtime
            let id = UUID()
            localStartID = id
            status = "Loading \(descriptor.title) on this iPhone…"
            notifyStateChanged()
            task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                defer {
                    if localStartID == id { localStartTask = nil; localStartID = nil }
                }
                do {
                    let result = try await runtime.start()
                    try Task.checkCancellation()
                    guard isCurrentInferenceContext(account: account, epoch: epoch), selection == expected else {
                        throw CancellationError()
                    }
                    localRoute = result
                    status = "Local model ready · \(descriptor.title). Inference uses this iPhone's GPU."
                    notifyStateChanged()
                    return result
                } catch {
                    if epoch == generation, localModel === runtime { localModel = nil }
                    await runtime.stop()
                    if isCurrentInferenceContext(account: account, epoch: epoch), selection == expected {
                        status = Self.localModelFailureMessage(error)
                        notifyStateChanged()
                    }
                    throw error
                }
            }
            localStartTask = task
        }
        let result = try await task.value
        try Task.checkCancellation()
        guard isCurrentInferenceContext(account: account, epoch: epoch), selection == expected else {
            throw CancellationError()
        }
        return result
    }

    private static func localModelFailureMessage(_ error: Error) -> String {
        guard let error = error as? LocalModelError else {
            return SigDemoLocalReplyPresentation.genericFailure
        }
        switch error {
        case .invalidModel, .modelUnavailable:
            return "The bundled local model is missing or does not match its pinned version. Rebuild with the verified model files."
        case .loadFailed:
            return "This iPhone could not load the selected local model. Free memory and try again."
        case .busy: return "The local model is handling another request. Wait for it to finish."
        case .stopped: return "Local inference is paused. Reopen the app to load the model."
        case .timedOut: return "The local model took too long to reply. Try a shorter question."
        case .hostUnavailable:
            return "The local inference engine is unavailable. Reopen the app and try again."
        case .gpuUnavailable:
            return "The local model could not start Metal inference on this iPhone."
        case .insufficientMemory:
            return "Available memory is too low to load the local model. Free memory and try again."
        case .invalidRequest, .inferenceFailed:
            return SigDemoLocalReplyPresentation.genericFailure
        @unknown default:
            return "Local inference is unavailable. No cloud model was used."
        }
    }
    #endif

    private func meshRoute(account: String, selection expected: SigDemoInferenceSelection, epoch: UInt64) async throws -> PublicMeshRoute {
        guard !suspended, epoch == generation, selectionAccountID == account,
              registeredAccount() == account, selection == expected,
              expected.provider != .chatGPT else { throw CancellationError() }
        if let route { return route }
        let task: Task<PublicMeshRoute, Error>
        if let pending = meshStartTask {
            task = pending
        } else {
            let runtime: PublicMeshRuntime?
            let paidRuntime: PaidMeshRuntime?
            switch expected.provider {
            case .publicMesh:
                runtime = mesh ?? PublicMeshRuntime(accountID: account)
                mesh = runtime
                paidRuntime = nil
            case .paidMesh:
                runtime = nil
                paidRuntime = try self.paidRuntime(account: account)
            case .chatGPT: throw CancellationError()
            #if SIG_DEMO_LOCAL_MODEL
            case .localModel: throw CancellationError()
            #endif
            }
            let id = UUID()
            meshStartID = id
            if expected.provider == .paidMesh { paidConnectionStatus.clear() }
            status = expected.provider == .paidMesh ? "Preparing paid Mesh…" : "Connecting to Public Mesh…"
            notifyStateChanged()
            task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                defer {
                    if meshStartID == id {
                        meshStartTask = nil
                        meshStartID = nil
                    }
                }
                do {
                    let result: PublicMeshRoute
                    let models: [MeshInferenceModel]
                    var wallet: PaidMeshWalletSnapshot?
                    if let paidRuntime {
                        result = try await paidRuntime.start(preferredModel: expected.paidPreferredModel,
                            dailyBudgetBaseUnits: expected.paidDailyBudgetBaseUnits,
                            perRequestBudgetBaseUnits: expected.paidPerRequestBudgetBaseUnits)
                        models = await paidRuntime.models()
                        wallet = await walletSnapshotIfCurrent(paidRuntime, account: account, epoch: epoch)
                    } else if let runtime {
                        result = try await runtime.start(preferredModel: expected.preferredModel)
                        models = await runtime.models()
                    } else { throw CancellationError() }
                    try Task.checkCancellation()
                    guard !suspended, epoch == generation, registeredAccount() == account,
                          selectionAccountID == account, selection == expected else { throw CancellationError() }
                    route = result
                    updateModels(models)
                    if expected.provider == .paidMesh { paidConnectionStatus.clear() }
                    status = expected.provider == .paidMesh
                        ? "Paid Mesh ready · \(result.model)."
                        : "Public Mesh ready · \(result.model). Free peer availability can change."
                    updatePaidWallet(wallet)
                    notifyStateChanged()
                    return result
                } catch {
                    #if DEBUG && targetEnvironment(simulator)
                    if expected.provider == .paidMesh {
                        Self.logPaidMeshDiagnostic(error, stage: "ROUTE_START")
                    }
                    #endif
                    let wallet: PaidMeshWalletSnapshot?
                    if let paidRuntime {
                        wallet = await walletSnapshotIfCurrent(paidRuntime, account: account, epoch: epoch)
                    } else { wallet = nil }
                    if isCurrentInferenceContext(account: account, epoch: epoch) {
                        status = Self.meshFailureMessage(error, provider: expected.provider)
                        if expected.provider == .paidMesh, !(error is CancellationError) {
                            recordPaidConnectionFailure(error, stage: .routeStart)
                        }
                        updatePaidWallet(wallet)
                        notifyStateChanged()
                    }
                    throw error
                }
            }
            meshStartTask = task
        }
        let result = try await task.value
        try Task.checkCancellation()
        guard !suspended, epoch == generation, registeredAccount() == account,
              selectionAccountID == account, selection == expected else { throw CancellationError() }
        return result
    }

    private static func meshFailureMessage(_ error: Error, provider: SigDemoInferenceSelection.Provider = .publicMesh) -> String {
        if provider == .paidMesh {
            if let error = error as? PaidMeshError {
                switch error {
                case .walletNotSetUp: return "Set up this test account's paid Mesh wallet in Sig agent settings."
                case .walletLocked: return "The paid Mesh wallet is locked. Unlock the device and refresh the wallet in Sig agent settings."
                case .insufficientFunds: return "The paid Mesh wallet needs funds. Create a funding invoice in Sig agent settings."
                case .spendingDisabled: return "Paid inference is disabled. Set positive daily and per Sig request limits in Sig agent settings."
                case .budgetExceeded: return "Paid inference reached a spending limit. Review the daily and per Sig request limits in Sig agent settings."
                case .paymentPending: return "A paid Mesh settlement is still outstanding. Retry reconciliation in Sig agent settings before another paid reply."
                case .modelUnavailable: return "The selected paid Mesh model is unavailable. Choose another model or try again later."
                case .busy: return "Paid Mesh is handling another request or wallet action. Wait for it to finish before asking again."
                case .stopped: return "Paid Mesh is paused. Reopen the app to use this provider."
                case .startupFailed(let stage):
                    let stage: String = switch stage {
                    case .walletRefresh: "wallet refresh"
                    case .recovery: "payment recovery"
                    case .policy: "payment policy setup"
                    case .buyerIdentity: "buyer identity setup"
                    case .nodeStart: "Mesh node startup"
                    @unknown default: "an unknown startup stage"
                    }
                    return "Paid Mesh could not start during \(stage). Check Sig agent settings and try again."
                default: break
                }
            }
            return "Paid Mesh is unavailable. Check your wallet, spending limits, and selected model in Sig agent settings."
        }
        if let error = error as? MeshInferenceError {
            switch error {
            case .paymentRequired: return "Only free Public Mesh inference is enabled. Choose another model or try again later."
            case .invalidConfiguration: return "Public Mesh could not use this model. Choose Automatic or another available model."
            case .stopped: return "Public Mesh is paused. It connects only while this app is in the foreground."
            case .unavailable, .invalidResponse: return "Free Public Mesh inference is unavailable for this choice. Choose Automatic, refresh models, or try again later."
            }
        }
        return "Free Public Mesh inference is unavailable. Refresh models or try again later."
    }

    private func recoverInterruptedResponsesIfNeeded(account: String) {
        guard recoveryTask == nil, !recoveredAccounts.contains(account) else { return }
        let id = UUID()
        let epoch = generation
        let runId = localRunId
        recoveryTaskId = id
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if recoveryTaskId == id {
                    recoveryTask = nil
                    recoveryTaskId = nil
                }
            }
            var cursor: SigDemoAgentMessages.InterruptedResponseCursor?
            do {
                while !Task.isCancelled, !suspended, epoch == generation,
                      UIApplication.shared.applicationState != .background,
                      registeredAccount() == account {
                    let currentCursor = cursor
                    let next = try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
                        try SigDemoAgentMessages.reconcileInterruptedLocalResponses(
                            accountId: account, localRunId: runId, after: currentCursor, tx: tx)
                    }
                    guard !Task.isCancelled, !suspended, epoch == generation,
                          registeredAccount() == account else { return }
                    guard let next else {
                        recoveredAccounts.insert(account)
                        return
                    }
                    cursor = next
                    await Task.yield()
                }
            } catch {
                // Avoid logging database descriptions or message identifiers.
                Logger.warn("Interrupted Sig reply reconciliation could not complete.")
            }
        }
    }
    private func accountStateChanged() async {
        if registeredAccount() != selectionAccountID { await shutdown() }
        await resumeIfAvailable()
    }

    private struct Snapshot: Sendable {
        let account: String
        let thread: String
        let query: String
        let timestamp: UInt64
        let source: String
        let prompt: String
        let author: String
        let history: [SigDemoAgentHistoryRecord]
        let replyTo: SigDemoAgentHistoryRecord?
        let replyTargetUnavailable: Bool
        let selection: SigDemoInferenceSelection
    }

    private func invoke(messageId: String) {
        guard Self.isAvailable, !suspended, !isUpdatingSelection,
              UIApplication.shared.applicationState != .background,
              !Self.usesLocalModel(selection) || UIApplication.shared.applicationState == .active,
              !seen.contains(messageId) else { return }
        let snapshot: Snapshot? = SSKEnvironment.shared.databaseStorageRef.read { tx in
            guard let query = TSMessage.fetchMessageViaCache(uniqueId: messageId, transaction: tx) as? TSOutgoingMessage,
                  !query.wasRemotelyDeleted, !SigDemoAgentMessages.isResponse(query, tx: tx),
                  DependenciesBridge.shared.tsAccountManager.registrationState(tx: tx).isRegistered,
                  let source = query.rawBody(transaction: tx), let prompt = SigDemoAgentFrame.prompt(in: source),
                  let account = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci,
                  account.serviceIdUppercaseString == selectionAccountID else { return nil }
            Self.traceLocalDeviceStage("HISTORY_BEGIN", selection: selection)
            let history = SigDemoAgentMessages.history(before: query, forLocalModel: Self.usesLocalModel(selection), tx: tx)
            Self.traceLocalDeviceStage("HISTORY_END", selection: selection, historyCount: history.lazy.filter { !$0.text.isEmpty }.count)
            let replyTo = SigDemoAgentMessages.replyTarget(for: query, tx: tx)
            return Snapshot(account: account.serviceIdUppercaseString, thread: query.uniqueThreadId,
                query: query.uniqueId, timestamp: query.timestamp, source: source, prompt: prompt,
                author: SigDemoAgentMessages.authorName(query, tx: tx),
                history: history, replyTo: replyTo,
                replyTargetUnavailable: query.quotedMessage != nil && replyTo == nil, selection: selection)
        }
        guard let snapshot else { return }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["SIG_DEMO_TEST_REQUIRE_FREE_MESH"] == "1",
           snapshot.source == Self.simulatorSmokeSource, snapshot.selection.provider != .publicMesh {
            Self.emitSimulatorSmokeStatus("SIG_DEMO_AGENT_SMOKE_PROVIDER_SKIPPED")
            return
        }
        if ProcessInfo.processInfo.environment["SIG_DEMO_TEST_REQUIRE_LOCAL_MODEL"] == "1",
           snapshot.source == Self.simulatorSmokeSource, !Self.usesLocalModel(snapshot.selection) {
            Self.emitSimulatorSmokeStatus("SIG_DEMO_AGENT_SMOKE_PROVIDER_SKIPPED")
            return
        }
        #endif
        seen.insert(messageId)
        let epoch = generation
        let id = UUID()
        #if SIG_DEMO_LOCAL_MODEL
        // Acquire synchronously before scheduling or publishing. Two chats can
        // otherwise race for the single local engine while a tool is running.
        let localReplyAdmitted = snapshot.selection.provider != .localModel || localReplyAdmission.acquire(id)
        if snapshot.selection.provider == .localModel, localReplyAdmitted {
            beginLocalProgress(id: id, snapshot: snapshot)
        }
        #endif
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                jobs.removeValue(forKey: id)
                #if SIG_DEMO_LOCAL_MODEL
                if snapshot.selection.provider == .localModel, localReplyAdmitted {
                    endLocalProgress(id: id)
                    localReplyAdmission.release(id)
                }
                #endif
            }
            let publisher = SigDemoReplyPublisher(snapshot: snapshot, localRunId: localRunId)
            await publisher.begin()
            var paidInference: (PaidMeshRuntime, UUID)?
            var paidFailureStage: SigDemoPaidConnectionStatus.Stage?
            #if DEBUG && targetEnvironment(simulator)
            var paidScopeCompleted = snapshot.selection.provider != .paidMesh
            #endif
            do {
                try Task.checkCancellation()
                guard !suspended, epoch == generation else { throw CancellationError() }
                #if SIG_DEMO_LOCAL_MODEL
                if !localReplyAdmitted {
                    await publisher.fail(Self.localModelFailureMessage(LocalModelError.busy))
                    #if DEBUG && targetEnvironment(simulator)
                    if snapshot.source == Self.simulatorSmokeSource {
                        Self.emitSimulatorSmokeStatus("SIG_DEMO_AGENT_SMOKE_FAILED")
                    }
                    #endif
                    return
                }
                #endif
                if snapshot.selection.provider == .paidMesh {
                    let observations = Array(walletObservations.values)
                    if !observations.isEmpty {
                        status = "Checking the paid Mesh wallet before this Sig request…"
                        notifyStateChanged()
                    }
                    // Reads admitted before this job are bounded and own no
                    // payment authority. Wait without cancelling the runtime;
                    // no new read is admitted while a job is queued or active.
                    for observation in observations {
                        await observation.value
                        try Task.checkCancellation()
                        guard !suspended, epoch == generation,
                              selectionAccountID == snapshot.account,
                              registeredAccount() == snapshot.account,
                              selection == snapshot.selection,
                              UIApplication.shared.applicationState != .background else {
                            throw CancellationError()
                        }
                    }
                    try Task.checkCancellation()
                    guard !suspended, epoch == generation,
                          selectionAccountID == snapshot.account,
                          registeredAccount() == snapshot.account,
                          selection == snapshot.selection,
                          UIApplication.shared.applicationState != .background else {
                        throw CancellationError()
                    }
                }
                if snapshot.selection.provider == .paidMesh, paidRouteInvalidationNeeded {
                    guard await invalidatePaidRoute(account: snapshot.account, epoch: epoch, jobID: id) else {
                        throw PaidMeshError.busy
                    }
                    try Task.checkCancellation()
                    guard !suspended, epoch == generation else { throw CancellationError() }
                }
                guard !snapshot.prompt.isEmpty else {
                    await publisher.fail("Ask Sig a question after @sig.")
                    return
                }
                if snapshot.selection.provider == .paidMesh, isUpdatingWallet || paidInvalidationID != nil {
                    throw PaidMeshError.busy
                }
                if accountId != snapshot.account {
                    await agent?.shutdown()
                    try Task.checkCancellation()
                    guard !suspended, epoch == generation else { throw CancellationError() }
                    agent = nil
                    accountId = snapshot.account
                }
                guard !isRefreshingDemoAccess else { throw PaidMeshError.busy }
                #if SIG_DEMO_LOCAL_MODEL
                if snapshot.selection.provider == .localModel {
                    beginLocalBraveBootstrapIfNeeded(account: snapshot.account, epoch: epoch)
                    // Bootstrap may complete after an offline-only agent was
                    // created. Refresh between whole replies, never mid-tool-run.
                    if agent != nil, !localAgentHasBraveAccess,
                       inferenceCredential(.braveSearch, account: snapshot.account) != nil {
                        let previous = agent
                        agent = nil
                        await previous?.shutdown()
                        try Task.checkCancellation()
                        guard isCurrentInferenceContext(account: snapshot.account, epoch: epoch) else { throw CancellationError() }
                    }
                }
                #endif
                if agent == nil {
                    if !Self.usesLocalModel(snapshot.selection) {
                        await bootstrapDemoCredentials(account: snapshot.account, epoch: epoch)
                    }
                    try Task.checkCancellation()
                    guard !suspended, epoch == generation else { throw CancellationError() }
                    switch snapshot.selection.provider {
                    case .chatGPT:
                        guard let key = inferenceCredential(.openAI, account: snapshot.account) else {
                            await publisher.fail("Sig's demo ChatGPT access is unavailable. Refresh demo access in Sig agent settings or contact your inviter. Public Mesh works without an API key.")
                            return
                        }
                        agent = try ChatGPTSigAgent(accountID: snapshot.account, apiKey: key,
                            braveApiKey: inferenceCredential(.braveSearch, account: snapshot.account))
                    case .publicMesh, .paidMesh:
                        paidFailureStage = .routeStart
                        let route = try await meshRoute(account: snapshot.account, selection: snapshot.selection, epoch: epoch)
                        try Task.checkCancellation()
                        guard !suspended, epoch == generation else { throw CancellationError() }
                        if agent == nil {
                            paidFailureStage = .agentCreation
                            agent = try ChatGPTSigAgent(accountID: snapshot.account,
                                publicMeshBaseURL: route.baseURL, model: route.model,
                                braveApiKey: inferenceCredential(.braveSearch, account: snapshot.account))
                        }
                    #if SIG_DEMO_LOCAL_MODEL
                    case .localModel:
                        let local = try await localModelRoute(account: snapshot.account, selection: snapshot.selection, epoch: epoch)
                        try Task.checkCancellation()
                        guard isCurrentInferenceContext(account: snapshot.account, epoch: epoch) else { throw CancellationError() }
                        if agent == nil {
                            let braveKey = inferenceCredential(.braveSearch, account: snapshot.account)
                            agent = try ChatGPTSigAgent(accountID: snapshot.account,
                                localEngine: local.engine, model: local.model, braveApiKey: braveKey)
                            localAgentHasBraveAccess = braveKey != nil
                        }
                    #endif
                    }
                }
                guard let agent else { return }
                if snapshot.selection.provider == .paidMesh {
                    guard let runtime = paidMesh else { throw CancellationError() }
                    paidFailureStage = .beginInvocation
                    let invocation = try await runtime.beginInference()
                    paidInference = (runtime, invocation)
                    paidInferenceID = invocation
                    isPaidInferenceActive = true
                    notifyStateChanged()
                    try Task.checkCancellation()
                    guard !suspended, epoch == generation else { throw CancellationError() }
                }
                let date = DateFormatter()
                date.locale = Locale(identifier: "en_US_POSIX")
                date.dateFormat = "yyyy-MM-dd"
                let request = SigAgentRequest(mode: .answer, queryId: snapshot.query,
                    responseId: await publisher.responseId, sourceText: snapshot.source,
                    prompt: snapshot.prompt, author: snapshot.author,
                    history: snapshot.history.map(\.gdkMessage),
                    currentDate: date.string(from: Date()), replyTo: snapshot.replyTo?.gdkMessage,
                    replyTargetUnavailable: snapshot.replyTargetUnavailable)
                #if SIG_DEMO_LOCAL_MODEL
                if snapshot.selection.provider == .localModel {
                    await publisher.prepareLocalDiagnostics(braveAvailable: localAgentHasBraveAccess)
                }
                #endif
                paidFailureStage = .agentAnswer
                do {
                    Self.traceLocalDeviceStage("AGENT_ANSWER_BEGIN", selection: snapshot.selection)
                    defer { Self.traceLocalDeviceStage("AGENT_ANSWER_END", selection: snapshot.selection) }
                    try await agent.answer(chatID: snapshot.thread, request: request) { event in
                        #if SIG_DEMO_LOCAL_MODEL
                        if snapshot.selection.provider == .localModel, case .timing(let phase, _) = event,
                           phase == "history-started" || phase == "history" {
                            await self.setLocalHistoryActivity(phase == "history-started", id: id)
                        }
                        #endif
                        await publisher.consume(event)
                    }
                }
                paidFailureStage = nil
                await publisher.finish()
                #if SIG_DEMO_LOCAL_MODEL
                if snapshot.selection.provider == .localModel {
                    let report = await publisher.localAttemptResult()
                    // Check scope after the actor hop; no late callback may
                    // persist into a replacement account/provider/model.
                    if isCurrentInferenceContext(account: snapshot.account, epoch: epoch) {
                        if report.succeeded {
                            if let descriptor = LocalModelCatalog.model(id: snapshot.selection.localPreferredModel) {
                                status = "Local model ready · \(descriptor.title). Inference uses this iPhone's GPU."
                            }
                        } else {
                            status = report.status ?? Self.localModelFailureMessage(LocalModelError.inferenceFailed)
                        }
                        localLastAttempt = (snapshot.account, snapshot.selection.localPreferredModel, report.status ?? status)
                        if let diagnostic = report.diagnostic {
                            persistLocalAttempt(diagnostic, account: snapshot.account,
                                model: snapshot.selection.localPreferredModel, epoch: epoch)
                        }
                        notifyStateChanged()
                    }
                }
                #endif
                if snapshot.selection.provider == .paidMesh, !(await publisher.succeeded), epoch == generation {
                    paidRouteInvalidationNeeded = true
                }
            } catch is CancellationError {
                await publisher.fail("Sig's reply was cancelled.")
                if snapshot.selection.provider == .paidMesh, epoch == generation {
                    paidRouteInvalidationNeeded = true
                }
            } catch {
                // Never render arbitrary error descriptions: a transport error
                // can contain a request URL, model payload, or credential.
                if Task.isCancelled { await publisher.fail("Sig's reply was cancelled.") }
                else {
                    #if SIG_DEMO_LOCAL_MODEL
                    if snapshot.selection.provider == .localModel {
                        let message = Self.localModelFailureMessage(error)
                        await publisher.fail(message)
                        let report = await publisher.localAttemptResult()
                        if isCurrentInferenceContext(account: snapshot.account, epoch: epoch) {
                            status = report.status ?? message
                            localLastAttempt = (snapshot.account, snapshot.selection.localPreferredModel, status)
                            if let diagnostic = report.diagnostic {
                                persistLocalAttempt(diagnostic, account: snapshot.account,
                                    model: snapshot.selection.localPreferredModel, epoch: epoch)
                            }
                            notifyStateChanged()
                        }
                    } else if snapshot.selection.provider != .chatGPT {
                        await publisher.fail(Self.meshFailureMessage(error, provider: snapshot.selection.provider))
                    } else { await publisher.fail("Sig could not complete this reply. Please try again.") }
                    #else
                    if snapshot.selection.provider != .chatGPT { await publisher.fail(Self.meshFailureMessage(error, provider: snapshot.selection.provider)) }
                    else { await publisher.fail("Sig could not complete this reply. Please try again.") }
                    #endif
                }
                if snapshot.selection.provider == .paidMesh, !Task.isCancelled,
                   isCurrentInferenceContext(account: snapshot.account, epoch: epoch), let paidFailureStage {
                    recordPaidConnectionFailure(error, stage: paidFailureStage)
                    notifyStateChanged()
                }
                if snapshot.selection.provider == .paidMesh, epoch == generation,
                   (error as? PaidMeshError) != .busy {
                    paidRouteInvalidationNeeded = true
                }
            }
            // Every Goose tool/LLM round in this reply shares one paid scope.
            // Await reconciliation on all exits rather than spawning cleanup
            // from defer, so account/provider teardown can drain this job.
            if let (runtime, invocation) = paidInference {
                if !suspended, epoch == generation, paidInferenceID == invocation {
                    isFinalizingPaidInference = true
                    status = "Finalizing payment status for this Sig reply…"
                    notifyStateChanged()
                }
                let completed = await runtime.endInference(invocation)
                let wallet = await walletSnapshotIfCurrent(runtime, account: snapshot.account, epoch: epoch)
                #if DEBUG && targetEnvironment(simulator)
                paidScopeCompleted = completed && (wallet.map {
                    $0.pendingPayments == 0 && ($0.state == .ready || $0.state == .unfunded)
                } ?? false)
                #endif
                if !suspended, epoch == generation, registeredAccount() == snapshot.account,
                   selectionAccountID == snapshot.account {
                    if paidInferenceID == invocation {
                        paidInferenceID = nil
                        isPaidInferenceActive = false
                        isFinalizingPaidInference = false
                    }
                    if let wallet { updatePaidWallet(wallet) }
                    if !completed { paidRouteInvalidationNeeded = true }
                    notifyStateChanged()
                }
            }
            if snapshot.selection.provider == .paidMesh, paidRouteInvalidationNeeded {
                _ = await invalidatePaidRoute(account: snapshot.account, epoch: epoch, jobID: id)
            }
            #if DEBUG && targetEnvironment(simulator)
            if snapshot.source == Self.simulatorSmokeSource {
                let succeeded = await publisher.succeeded
                Self.emitSimulatorSmokeStatus(succeeded && paidScopeCompleted && !suspended && epoch == generation
                    ? "SIG_DEMO_AGENT_SMOKE_COMPLETE" : "SIG_DEMO_AGENT_SMOKE_FAILED")
            }
            #endif
        }
    }

    private actor SigDemoReplyPublisher {
        private let wireQueryId = UUID().uuidString.lowercased()
        private(set) var responseId = ""
        private let snapshot: Snapshot
        private let localRunId: UUID
        private var sequence: UInt32 = 0
        private var text = ""
        private var terminal = false
        private(set) var succeeded = false
        private var lastPublished = Date.distantPast
        #if SIG_DEMO_LOCAL_MODEL
        private var localDiagnostics = SigDemoLocalReplyDiagnostics()
        private(set) var localFailureStatus: String?
        private(set) var localCompletionStatus: String?
        var localTerminalDiagnostics: SigDemoLocalReplyDiagnostics? {
            guard terminal, snapshot.selection.provider == .localModel,
                  localDiagnostics.isValidTerminalRecord else { return nil }
            return localDiagnostics
        }
        func localAttemptResult() -> (succeeded: Bool, status: String?, diagnostic: SigDemoLocalReplyDiagnostics?) {
            (succeeded, succeeded ? localCompletionStatus : localFailureStatus, localTerminalDiagnostics)
        }
        private var localStartedAt: ContinuousClock.Instant?
        private var localAgentStartedAt: ContinuousClock.Instant?
        func prepareLocalDiagnostics(braveAvailable: Bool) {
            localDiagnostics.braveAvailable = braveAvailable
            localAgentStartedAt = .now
            emitLocalDiagnostic("STARTED")
        }
        private func refreshLocalLatency() {
            func milliseconds(since start: ContinuousClock.Instant?) -> UInt64 {
                guard let start else { return 0 }
                let duration = start.duration(to: .now).components
                let seconds = max(0, min(3_600, duration.seconds))
                return UInt64(max(0, min(3_600_000, seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)))
            }
            localDiagnostics.elapsed(totalMS: milliseconds(since: localStartedAt),
                agentMS: milliseconds(since: localAgentStartedAt))
        }
        private func emitLocalDiagnostic(_ event: String) {
            refreshLocalLatency()
            #if DEBUG
            let marker = "SIG_DEMO_LOCAL_REPLY_" + event + " " + localDiagnostics.metadata
            try? FileHandle.standardOutput.write(contentsOf: Data((marker + "\n").utf8))
            Logger.info(marker)
            #endif
        }
        #endif
        init(snapshot: Snapshot, localRunId: UUID) {
            self.snapshot = snapshot
            self.localRunId = localRunId
        }

        func begin() async {
            SigDemoAgentService.traceLocalDeviceStage("PUBLISHER_BEGIN", selection: snapshot.selection)
            #if SIG_DEMO_LOCAL_MODEL
            if snapshot.selection.provider == .localModel { localStartedAt = .now }
            #endif
            await publish(.streaming)
            SigDemoAgentService.traceLocalDeviceStage("PUBLISHER_READY", selection: snapshot.selection)
        }
        func consume(_ event: SigAgentEvent) async {
            guard !terminal else { return }
            #if SIG_DEMO_LOCAL_MODEL
            if snapshot.selection.provider == .localModel {
                switch event {
                case .status(.responding): localDiagnostics.responding(); emitLocalDiagnostic("MODEL")
                case .status(.searching): localDiagnostics.searching(); emitLocalDiagnostic("SEARCH_STARTED")
                case .timing(let phase, let durationMS):
                    localDiagnostics.timing(phase, durationMS: durationMS)
                    if phase == "search" { emitLocalDiagnostic("SEARCH_COMPLETED") }
                    if phase == "history-started" { emitLocalDiagnostic("HISTORY_STARTED") }
                    if phase == "history" { emitLocalDiagnostic("HISTORY_COMPLETED") }
                default: break
                }
            }
            #endif
            #if DEBUG && targetEnvironment(simulator)
            if snapshot.source == (await SigDemoAgentService.simulatorSmokeSource) {
                switch event {
                case .status(.searching):
                    await SigDemoAgentService.emitSimulatorSmokeStatus("SIG_DEMO_AGENT_LOCAL_SEARCH_STARTED")
                case .timing(let phase, _) where phase == "search":
                    await SigDemoAgentService.emitSimulatorSmokeStatus("SIG_DEMO_AGENT_LOCAL_SEARCH_FINISHED")
                default: break
                }
            }
            #endif
            switch event {
            case .text(let chunk):
                guard !chunk.isEmpty else { return }
                let firstLocalText = text.isEmpty && SigDemoAgentService.usesLocalModel(snapshot.selection)
                text = String(decoding: Array((text + chunk).utf16.prefix(65_536)), as: UTF16.self)
                if firstLocalText || Date().timeIntervalSince(lastPublished) >= 0.5 { await publish(.streaming) }
            case .error(let code, let message, let httpStatus, let reason):
                #if SIG_DEMO_LOCAL_MODEL
                if snapshot.selection.provider == .localModel {
                    localDiagnostics.fail(code: code, reason: reason, httpStatus: httpStatus)
                    await fail(SigDemoLocalReplyPresentation.failureMessage(code: code, reason: reason))
                    return
                }
                #endif
                if snapshot.selection.provider == .paidMesh {
                    await fail("Paid Mesh could not complete this reply. Check your wallet and spending limits in Sig agent settings before trying again.")
                } else if snapshot.selection.provider == .publicMesh {
                    await fail(httpStatus == 402
                        ? "Only free Public Mesh inference is enabled. Choose another model or try again later."
                        : "Free Public Mesh could not complete this reply. Choose Automatic, refresh models, or try again later.")
                } else {
                    await fail(message)
                }
            case .done: await finish()
            default: break
            }
        }
        func finish() async {
            guard !terminal else { return }
            terminal = true
            succeeded = true
            if text.isEmpty { text = "Sig returned an empty answer." }
            await publish(.complete)
            #if SIG_DEMO_LOCAL_MODEL
            if snapshot.selection.provider == .localModel {
                localDiagnostics.completed()
                emitLocalDiagnostic("COMPLETED")
                localCompletionStatus = localDiagnostics.completionSummary + "\n" + localDiagnostics.metadata
            }
            #endif
        }
        func fail(_ message: String) async {
            guard !terminal else { return }
            terminal = true
            #if SIG_DEMO_LOCAL_MODEL
            if snapshot.selection.provider == .localModel {
                if localDiagnostics.code == "none" {
                    localDiagnostics.fail(code: "swift-error", reason: nil, httpStatus: nil)
                }
                emitLocalDiagnostic("FAILED")
                localFailureStatus = message + "\n" + localDiagnostics.metadata
                text = SigDemoLocalReplyPresentation.failedText(provisional: text, message: message)
            } else {
                text = String(decoding: Array((text.isEmpty ? message : text + "\n\n" + message).utf16.prefix(65_536)), as: UTF16.self)
            }
            #else
            text = String(decoding: Array((text.isEmpty ? message : text + "\n\n" + message).utf16.prefix(65_536)), as: UTF16.self)
            #endif
            await publish(.error)
        }
        private func publish(_ status: SigDemoAgentFrame.Status) async {
            // Sequence zero is the placeholder written by begin().
            let firstReply = sequence == 1
            if firstReply { SigDemoAgentService.traceLocalDeviceStage("FIRST_REPLY_WRITE_BEGIN", selection: snapshot.selection) }
            guard let frame = try? SigDemoAgentFrame(queryId: wireQueryId, queryTimestamp: snapshot.timestamp,
                sequence: sequence, status: status, text: text) else { return }
            sequence += 1
            lastPublished = Date()
            let runId = localRunId
            let showLocalThinking = SigDemoAgentService.usesLocalModel(snapshot.selection)
            let localId: String? = await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
                guard let thread = TSThread.fetchViaCache(uniqueId: snapshot.thread, transaction: tx),
                      DependenciesBridge.shared.tsAccountManager.registrationState(tx: tx).isRegistered,
                      let origin = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci,
                      origin.serviceIdUppercaseString == snapshot.account else { return nil }
                return SigDemoAgentMessages.publish(frame, thread: thread, origin: origin,
                    localRunId: runId, showLocalThinking: showLocalThinking, tx: tx)
            }
            if let localId { responseId = localId }
            if firstReply { SigDemoAgentService.traceLocalDeviceStage("FIRST_REPLY_WRITE_END", selection: snapshot.selection) }
        }
    }
}

private extension SigDemoAgentHistoryRecord {
    var gdkMessage: SigHistoryMessage {
        let role: SigHistoryRole
        if isAssistant { role = .assistant }
        else if isRequester { role = .requester }
        else { role = .user }
        return SigHistoryMessage(id: id, role: role, author: author, text: text)
    }
}
