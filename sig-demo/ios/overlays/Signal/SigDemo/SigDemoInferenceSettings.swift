// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalServiceKit
#if SIG_DEMO_LOCAL_MODEL
import SigDemoLocalModel
#endif

struct SigDemoInferenceSelection: Codable, Equatable, Sendable {
    enum Provider: String, Codable, CaseIterable, Sendable {
        case chatGPT
        case publicMesh
        case paidMesh
        #if SIG_DEMO_LOCAL_MODEL || SIG_DEMO_LOCAL_MODEL_SETTINGS_TESTING
        case localModel
        #endif

        var title: String {
            switch self {
            case .chatGPT: "ChatGPT"
            case .publicMesh: "Public Mesh (free)"
            case .paidMesh: "Mesh-LLM (paid)"
            #if SIG_DEMO_LOCAL_MODEL || SIG_DEMO_LOCAL_MODEL_SETTINGS_TESTING
            case .localModel: "Local model"
            #endif
            }
        }
    }

    var provider: Provider = .chatGPT {
        didSet {
            #if SIG_DEMO_LOCAL_MODEL || SIG_DEMO_LOCAL_MODEL_SETTINGS_TESTING
            if provider != .localModel { localFallbackProvider = provider }
            #endif
        }
    }
    #if SIG_DEMO_LOCAL_MODEL || SIG_DEMO_LOCAL_MODEL_SETTINGS_TESTING
    // Keep the on-disk provider understood by the rollback build. Only this
    // experimental simulator honors the separate optional local selection.
    private var localFallbackProvider: Provider = .chatGPT
    var localPreferredModel = LocalModelCatalog.defaultModelID
    #endif
    var preferredModel: String?
    var paidPreferredModel: String = Self.defaultPaidModel
    var paidDailyBudgetBaseUnits: UInt64 = 0
    var paidPerRequestBudgetBaseUnits: UInt64 = 0
    var paidFundingDefaults = SigDemoFundingLimitDefaults()

    static let defaultPaidModel = "Qwen3.6-27B-Q6_K"
    // Native payment APIs use thousandths of the displayed integer unit. Keep
    // that conversion within a signed 64-bit amount without rounding.
    static let maximumBudgetBaseUnits = UInt64(Int64.max / 1_000)

    private enum CodingKeys: String, CodingKey {
        case provider, preferredModel, paidPreferredModel
        case paidDailyBudgetBaseUnits, paidPerRequestBudgetBaseUnits
        case paidFundingDefaults
        case localSelected, localPreferredModel
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(Provider.self, forKey: .provider)
        #if SIG_DEMO_LOCAL_MODEL || SIG_DEMO_LOCAL_MODEL_SETTINGS_TESTING
        localFallbackProvider = provider
        localPreferredModel = try values.decodeIfPresent(String.self, forKey: .localPreferredModel) ?? LocalModelCatalog.defaultModelID
        if ["qwen3-4b-instruct-2507-q4-k-m", "qwen3-0.6b-q4-k-m"].contains(localPreferredModel) {
            localPreferredModel = LocalModelCatalog.defaultModelID
        }
        if try values.decodeIfPresent(Bool.self, forKey: .localSelected) == true { provider = .localModel }
        #endif
        preferredModel = try values.decodeIfPresent(String.self, forKey: .preferredModel)
        paidPreferredModel = try values.decodeIfPresent(String.self, forKey: .paidPreferredModel) ?? Self.defaultPaidModel
        paidDailyBudgetBaseUnits = try values.decodeIfPresent(UInt64.self, forKey: .paidDailyBudgetBaseUnits) ?? 0
        paidPerRequestBudgetBaseUnits = try values.decodeIfPresent(UInt64.self, forKey: .paidPerRequestBudgetBaseUnits) ?? 0
        paidFundingDefaults = try values.decodeIfPresent(SigDemoFundingLimitDefaults.self, forKey: .paidFundingDefaults)
            ?? .legacy(daily: paidDailyBudgetBaseUnits, perRequest: paidPerRequestBudgetBaseUnits)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        #if SIG_DEMO_LOCAL_MODEL || SIG_DEMO_LOCAL_MODEL_SETTINGS_TESTING
        try values.encode(provider == .localModel ? localFallbackProvider : provider, forKey: .provider)
        try values.encode(provider == .localModel, forKey: .localSelected)
        try values.encode(localPreferredModel, forKey: .localPreferredModel)
        #else
        try values.encode(provider, forKey: .provider)
        #endif
        try values.encodeIfPresent(preferredModel, forKey: .preferredModel)
        try values.encode(paidPreferredModel, forKey: .paidPreferredModel)
        try values.encode(paidDailyBudgetBaseUnits, forKey: .paidDailyBudgetBaseUnits)
        try values.encode(paidPerRequestBudgetBaseUnits, forKey: .paidPerRequestBudgetBaseUnits)
        try values.encode(paidFundingDefaults, forKey: .paidFundingDefaults)
    }

    func validate() throws {
        #if SIG_DEMO_LOCAL_MODEL || SIG_DEMO_LOCAL_MODEL_SETTINGS_TESTING
        guard localFallbackProvider != .localModel, LocalModelCatalog.model(id: localPreferredModel) != nil else {
            throw SigDemoInferenceSettings.SettingsError.invalidSelection
        }
        #endif
        if let preferredModel, !Self.validModel(preferredModel) {
            throw SigDemoInferenceSettings.SettingsError.invalidSelection
        }
        guard Self.validModel(paidPreferredModel),
              paidFundingDefaults.isValid,
              paidDailyBudgetBaseUnits <= Self.maximumBudgetBaseUnits,
              paidPerRequestBudgetBaseUnits <= Self.maximumBudgetBaseUnits,
              paidPerRequestBudgetBaseUnits <= paidDailyBudgetBaseUnits else {
            throw SigDemoInferenceSettings.SettingsError.invalidSelection
        }
    }

    private static func validModel(_ model: String) -> Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.utf8.count <= 128
            && !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

enum SigDemoBitcoinAmount {
    /// A strict whole-unit editor avoids locale-dependent decimal conversion or
    /// silently rounding a payment budget upward.
    static func parseBudget(_ text: String) -> UInt64? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let amount = UInt64(digits), amount <= SigDemoInferenceSelection.maximumBudgetBaseUnits else { return nil }
        return amount
    }

    static func format(_ amount: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return "₿" + (formatter.string(from: NSNumber(value: amount)) ?? String(amount))
    }
}

struct SigDemoInferenceModel: Equatable, Sendable {
    let id: String
    let name: String
}

/// Preferences contain no credentials and live only in this account's SQLCipher
/// database. Deployment binding is checked before the database reaches the UI.
enum SigDemoInferenceSettings {
    enum SettingsError: Error { case invalidSelection, accountChanged }
    static let stateDidChange = Notification.Name("SigDemoInferenceStateDidChange")
    private static let store = NewKeyValueStore(collection: "SigDemo.InferenceSettings")

    static func load(accountID: String, tx: DBReadTransaction) throws -> SigDemoInferenceSelection {
        guard let data = try store.fetchValueOrThrow(Data.self, forKey: accountID, tx: tx) else {
            return SigDemoInferenceSelection()
        }
        let selection = try JSONDecoder().decode(SigDemoInferenceSelection.self, from: data)
        try selection.validate()
        return selection
    }

    static func save(_ selection: SigDemoInferenceSelection, accountID: String, tx: DBWriteTransaction) throws {
        try selection.validate()
        try store.writeValueOrThrow(JSONEncoder().encode(selection), forKey: accountID, tx: tx)
    }
}
