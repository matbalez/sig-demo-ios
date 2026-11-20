// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct LocalModelDescriptor: Sendable, Equatable {
    public let id: String
    public let title: String
    public let filename: String
    public let byteCount: UInt64
    public let sha256: String
}
public enum LocalModelCatalog {
    public static let defaultModelID = "lfm3-1.7b-q4-k-m"
    public static let models: [LocalModelDescriptor] = [
        .init(id: defaultModelID, title: "Liquid LFM3 1.7B", filename: "LFM3-1.7B-Q4_K_M.gguf",
              byteCount: 1_099_627_808, sha256: "3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4"),
    ]
    public static func model(id: String) -> LocalModelDescriptor? { models.first { $0.id == id } }
}
