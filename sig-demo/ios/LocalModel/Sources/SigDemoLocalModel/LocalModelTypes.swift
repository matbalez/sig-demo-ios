// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SigDemoAgent

public struct LocalModelRoute: Sendable {
    public let engine: SigLocalModelEngine
    public let model: String
    public let status: SigLocalModelStatus
    public init(engine: SigLocalModelEngine, model: String, status: SigLocalModelStatus) {
        self.engine = engine; self.model = model; self.status = status
    }
}
public enum LocalModelError: Error, Sendable, Equatable {
    case invalidModel, modelUnavailable, loadFailed, stopped, busy, timedOut, invalidRequest, inferenceFailed
    case hostUnavailable, gpuUnavailable
    case insufficientMemory
}
