// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import SigDemoAgent

/// A tiny synchronous fence for UIKit's pre-background callback. The model
/// actor still owns loading and teardown; this never waits for GPU work.
private final class LocalModelRetirement: @unchecked Sendable {
    private let lock = NSLock()
    private var retired = false
    private var engine: SigLocalModelEngine?
    private var validation: Task<Void, Error>?

    var isRetired: Bool {
        lock.lock(); defer { lock.unlock() }
        return retired
    }
    func trackValidation(_ task: Task<Void, Error>?) {
        lock.lock()
        validation = task
        let shouldCancel = retired
        lock.unlock()
        if shouldCancel { task?.cancel() }
    }
    func register(_ native: SigLocalModelEngine) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !retired else { return false }
        engine = native
        return true
    }
    func clear(_ native: SigLocalModelEngine?) {
        lock.lock(); defer { lock.unlock() }
        if engine === native { engine = nil }
    }
    func cancel() {
        lock.lock()
        retired = true
        let native = engine; let pendingValidation = validation
        lock.unlock()
        pendingValidation?.cancel()
        native?.cancel()
    }
}

/// One account/model's foreground-only in-process GDK engine. stop is irreversible.
public actor LocalModelRuntime {
    private let accountID: String
    private let directory: URL?
    private let explicitURL: URL?
    private var retired = false
    private var selectedID: String?
    private var engine: SigLocalModelEngine?
    private var route: LocalModelRoute?
    private var starting: Task<LocalModelRoute, Error>?
    private nonisolated let retirement = LocalModelRetirement()

    public init(accountID: String, modelURL: URL) {
        self.accountID = accountID; explicitURL = modelURL; directory = nil
    }
    public init(accountID: String, modelsDirectory: URL? = nil) {
        self.accountID = accountID; explicitURL = nil
        directory = modelsDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("LocalModels", isDirectory: true)
    }
    public func start(modelID: String? = nil) async throws -> LocalModelRoute {
        try check()
        guard !accountID.isEmpty, accountID.utf8.count <= 256 else { throw LocalModelError.invalidModel }
        let id = modelID ?? explicitURL.flatMap { url in LocalModelCatalog.models.first { $0.filename == url.lastPathComponent }?.id } ?? LocalModelCatalog.defaultModelID
        guard let descriptor = LocalModelCatalog.model(id: id), selectedID == nil || selectedID == id else { throw LocalModelError.invalidModel }
        if let route { return route }
        if let starting { return try await starting.value }
        guard let url = explicitURL ?? directory?.appendingPathComponent(descriptor.filename), url.isFileURL,
              url.lastPathComponent == descriptor.filename else { throw LocalModelError.modelUnavailable }
        selectedID = id
        let task = Task { try await self.connect(url: url, descriptor: descriptor) }
        starting = task
        defer { starting = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func connect(url: URL, descriptor: LocalModelDescriptor) async throws -> LocalModelRoute {
        let validation = Task.detached(priority: .userInitiated) { try Self.validate(url: url, descriptor: descriptor) }
        retirement.trackValidation(validation)
        defer { retirement.trackValidation(nil) }
        try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
        try check()
        let native: SigLocalModelEngine
        do { native = try SigLocalModelEngine(modelId: descriptor.id, modelPath: url.path) }
        catch { throw LocalModelError.loadFailed }
        guard retirement.register(native) else {
            native.cancel()
            await native.stop()
            throw LocalModelError.stopped
        }
        engine = native
        do {
            let status = try await withTaskCancellationHandler { try await native.load() } onCancel: { native.cancel() }
            try check()
            guard status.modelId == descriptor.id, status.engine == "goose-local-inference",
                  status.backend == "metal", status.gpuRequired,
                  status.warmupInputTokens > 0, status.warmupOutputTokens > 0 else {
                throw LocalModelError.gpuUnavailable
            }
            let ready = LocalModelRoute(engine: native, model: descriptor.id, status: status)
            route = ready
            return ready
        } catch {
            await native.stop()
            retirement.clear(native)
            if engine === native { engine = nil; route = nil }
            if error is CancellationError { throw CancellationError() }
            throw (error as? LocalModelError) ?? LocalModelError.loadFailed
        }
    }
    private func check() throws {
        try Task.checkCancellation()
        guard !retired, !retirement.isRetired else { throw LocalModelError.stopped }
    }
    public nonisolated func cancel() { retirement.cancel() }
    public func stop() async {
        cancel()
        retired = true
        let task = starting; let native = engine
        starting = nil; route = nil; engine = nil
        task?.cancel()
        await native?.stop()
        retirement.clear(native)
        _ = try? await task?.value
    }
    private static func validate(url: URL, descriptor: LocalModelDescriptor) throws {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              size.isRegularFile == true, UInt64(size.fileSize ?? 0) == descriptor.byteCount else { throw LocalModelError.modelUnavailable }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            // Drain temporary Foundation buffers after each bounded read,
            // before the native model starts allocating its own resources.
            let hasData = try autoreleasepool {
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: 4*1024*1024), !chunk.isEmpty else { return false }
                hash.update(data: chunk)
                return true
            }
            if !hasData { break }
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.sha256 else { throw LocalModelError.invalidModel }
    }
}
