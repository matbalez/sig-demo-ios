// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalServiceKit
import SigDemoKit
import SignalUI
import SigDemoPaidMesh
import UIKit
import CoreImage.CIFilterBuiltins
#if SIG_DEMO_LOCAL_MODEL
import SigDemoLocalModel
#endif

@MainActor
final class SigDemoInferenceSettingsViewController: OWSTableViewController2 {
    private let service = SigDemoAgentService.shared
    private let accountID: String? = SigDemoAgentService.shared.currentAccountID
    private var observer: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var passiveRefreshTask: Task<Void, Never>?
    private var passiveRefreshID: UUID?
    private var observedPaidAccountID: String?
    private var needsPassiveRefresh = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sig agent"
        observedPaidAccountID = paidSettingsAccountID
        observer = NotificationCenter.default.addObserver(
            forName: SigDemoInferenceSettings.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.inferenceStateChanged() } }
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.cancelPassiveRefresh() } })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.requestPassiveRefresh() } })
        updateContents()
    }

    deinit {
        passiveRefreshTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestPassiveRefresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelPassiveRefresh()
    }

    private func cancelPassiveRefresh() {
        passiveRefreshTask?.cancel()
        passiveRefreshTask = nil
        passiveRefreshID = nil
        needsPassiveRefresh = false
    }

    private var paidSettingsAccountID: String? {
        guard let accountID, service.currentAccountID == accountID,
              service.selection.provider == .paidMesh else { return nil }
        return accountID
    }

    private func inferenceStateChanged() {
        let next = paidSettingsAccountID
        if next != observedPaidAccountID {
            observedPaidAccountID = next
            cancelPassiveRefresh()
            needsPassiveRefresh = next != nil
        }
        // A foreground drain can outlast the short busy retry. Keep the one
        // requested refresh pending until readiness changes allow it to finish.
        if needsPassiveRefresh { refreshVisiblePaidWallet() }
        updateContents()
    }

    private func requestPassiveRefresh() {
        needsPassiveRefresh = true
        refreshVisiblePaidWallet()
    }

    private func refreshVisiblePaidWallet() {
        guard needsPassiveRefresh, passiveRefreshTask == nil, let accountID,
              service.currentAccountID == accountID, service.selection.provider == .paidMesh,
              viewIfLoaded?.window != nil, navigationController?.topViewController === self,
              UIApplication.shared.applicationState != .background else { return }
        let id = UUID()
        passiveRefreshID = id
        passiveRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if passiveRefreshID == id { passiveRefreshTask = nil; passiveRefreshID = nil }
            }
            // Foreground service teardown may still be finishing when the
            // settings screen reappears. Retry observation briefly, never recovery.
            for _ in 0..<3 {
                guard !Task.isCancelled, passiveRefreshID == id,
                      service.currentAccountID == accountID, service.selection.provider == .paidMesh,
                      navigationController?.topViewController === self,
                      UIApplication.shared.applicationState != .background else { return }
                if await service.refreshPaidWalletObservation(accountID: accountID) {
                    if passiveRefreshID == id { needsPassiveRefresh = false }
                    return
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    override func themeDidChange() {
        super.themeDidChange()
        updateContents()
    }

    private func updateContents() {
        let contents = OWSTableContents()
        guard SigDemoAgentService.isAvailable, let accountID,
              service.currentAccountID == accountID else {
            contents.add(OWSTableSection(title: nil, items: [], footerTitle: "Open your registered test account to choose Sig's inference provider."))
            contents.add(demoAboutSection())
            self.contents = contents
            return
        }

        let providers = OWSTableSection(title: "Inference provider")
        providers.footerTitle = "Sig sends your question and eligible chat context to the selected provider. When you reply to a message, its eligible text is included even if it is older. Changing providers or models cancels replies in progress."
        #if SIG_DEMO_LOCAL_MODEL
        if service.selection.provider == .localModel {
            providers.footerTitle = "The GDK runs the bundled model on this iPhone’s GPU using llama.cpp and Metal. When you reply to a message, Sig can read its eligible text regardless of age. For other questions, Sig gets short excerpts from up to 10 recent messages and can read up to 100 eligible messages from this chat when needed. When Sig searches the web, the search query goes to Brave."
        }
        #endif
        for provider in SigDemoInferenceSelection.Provider.allCases {
            providers.add(OWSTableItem(
                text: provider.title,
                actionBlock: service.isUpdatingSelection ? nil : { [weak self] in
                    guard let self else { return }
                    var selection = self.service.selection
                    selection.provider = provider
                    self.select(selection, accountID: accountID)
                },
                accessoryType: service.selection.provider == provider ? .checkmark : .none
            ))
        }
        contents.add(providers)

        let connection = OWSTableSection(title: "Connection")
        // A section footer can remain cached while its rows update on iOS 26.
        // Keep changing connection state in the row's regular reload path.
        connection.add(.item(name: service.selection.provider.title, subtitle: service.connectionStatus,
            accessibilityIdentifier: "sig-demo-inference-connection"))
        connection.add(.actionItem(withText: "Refresh demo access", actionBlock: service.isRefreshingDemoAccess ? nil : { [weak self] in
            guard let self else { return }
            Task { await self.service.refreshDemoAccess() }
        }))
        connection.footerTitle = "Invited testers can receive the organizer's shared ChatGPT and Brave credentials through the private demo service. Credentials stay in this account's device-only Keychain. Mesh inference does not require an OpenAI key."
        #if SIG_DEMO_LOCAL_MODEL
        if service.selection.provider == .localModel {
            connection.footerTitle = "Local inference needs no API key or Mesh wallet and never falls back to a cloud model. Existing demo Brave access enables optional web search."
        }
        #endif
        contents.add(connection)

        if service.selection.provider == .publicMesh {
            let models = OWSTableSection(title: "Discovered Public Mesh models")
            models.footerTitle = "Automatic chooses a discovered model. Free peer availability can change. Public Mesh requires no API key and connects only in the foreground. Refreshing models cancels replies in progress."
            models.add(modelItem(title: "Automatic", model: nil, accountID: accountID))
            for model in service.availableModels {
                let title = model.name == model.id ? model.id : "\(model.name) · \(model.id)"
                models.add(modelItem(title: title, model: model.id, accountID: accountID))
            }
            if let preferred = service.selection.preferredModel,
               !service.availableModels.contains(where: { $0.id == preferred }) {
                models.add(OWSTableItem(text: "\(preferred) (unavailable)", actionBlock: nil, accessoryType: .checkmark))
            }
            models.add(.actionItem(withText: "Refresh models", actionBlock: service.isUpdatingSelection ? nil : { [weak self] in
                guard let self else { return }
                Task { await self.service.refreshMeshModels() }
            }))
            contents.add(models)
        } else if service.selection.provider == .paidMesh {
            contents.add(paidWalletSection(accountID: accountID))
            let models = OWSTableSection(title: "Paid Mesh model")
            models.footerTitle = "Paid Mesh uses only the selected model. Changing the model cancels replies in progress."
            let defaultModel = SigDemoInferenceSelection.defaultPaidModel
            if !service.availableModels.contains(where: { $0.id == defaultModel }) {
                models.add(modelItem(title: defaultModel, model: defaultModel, accountID: accountID))
            }
            for model in service.availableModels {
                let title = model.name == model.id ? model.id : "\(model.name) · \(model.id)"
                models.add(modelItem(title: title, model: model.id, accountID: accountID))
            }
            let preferred = service.selection.paidPreferredModel
            if preferred != defaultModel, !service.availableModels.contains(where: { $0.id == preferred }) {
                models.add(OWSTableItem(text: "\(preferred) (unavailable)", actionBlock: nil, accessoryType: .checkmark))
            }
            models.add(.actionItem(withText: "Refresh models", actionBlock: service.isUpdatingSelection ? nil : { [weak self] in
                guard let self else { return }
                Task { await self.service.refreshMeshModels() }
            }))
            contents.add(models)

            let budgets = OWSTableSection(title: "Spending limits")
            let defaults: String
            switch service.selection.paidFundingDefaults.state {
            case .pending:
                defaults = "Unless you edit them first, both limits will be set once to half your first confirmed funding, rounded down. Later funding will not reset them."
            case .automatic:
                defaults = "Both limits were initialized once from half your first confirmed funding, rounded down. You can edit them below; later funding will not reset them."
            case .userEdited:
                defaults = "Your saved limits take priority. Funding will not change them."
            }
            budgets.footerTitle = defaults + "\nA limit of ₿0 disables new payments, including recovery payments. The per Sig request limit covers all model calls and payment fees in one reply and cannot exceed the daily limit. Recovered settlements must fit both the current limits and their original authorization caps. The daily limit resets at midnight UTC. Pending payments remain reserved across days. Changing limits cancels replies in progress."
            budgets.add(budgetItem(.daily, accountID: accountID))
            budgets.add(budgetItem(.perRequest, accountID: accountID))
            contents.add(budgets)
        }
        #if SIG_DEMO_LOCAL_MODEL
        if service.selection.provider == .localModel {
            let models = OWSTableSection(title: "Bundled local model")
            for model in LocalModelCatalog.models {
                let size = ByteCountFormatter.string(fromByteCount: Int64(model.byteCount), countStyle: .file)
                models.add(OWSTableItem(text: "\(model.title) · \(size)", actionBlock: nil, accessoryType: .none))
            }
            contents.add(models)
        }
        #endif
        contents.add(demoAboutSection())
        self.contents = contents
    }

    private func demoAboutSection() -> OWSTableSection {
        let section = OWSTableSection(title: "About Sig Demo")
        section.footerTitle = "A modified private test build based on Signal iOS. Independent of Signal Messenger."
        section.add(.actionItem(withText: "License and corresponding source", actionBlock: { [weak self] in
            guard let self else { return }
            Self.presentDemoAbout(from: self)
        }))
        return section
    }

    static func presentDemoAbout(from controller: UIViewController) {
        SigDemoAboutPresenter.present(from: controller)
    }

    private func modelItem(title: String, model: String?, accountID: String) -> OWSTableItem {
        OWSTableItem(text: title, actionBlock: service.isUpdatingSelection ? nil : { [weak self] in
            guard let self else { return }
            var selection = self.service.selection
            if selection.provider == .paidMesh {
                guard let model else { return }
                selection.paidPreferredModel = model
            } else {
                selection.preferredModel = model
            }
            self.select(selection, accountID: accountID)
        }, accessoryType: (service.selection.provider == .paidMesh
            ? service.selection.paidPreferredModel == model
            : service.selection.preferredModel == model) ? .checkmark : .none)
    }

    private enum Budget {
        case daily, perRequest

        var title: String { self == .daily ? "Daily limit" : "Per Sig request limit" }
        func value(in selection: SigDemoInferenceSelection) -> UInt64 {
            self == .daily ? selection.paidDailyBudgetBaseUnits : selection.paidPerRequestBudgetBaseUnits
        }
        func assign(_ value: UInt64, to selection: inout SigDemoInferenceSelection) {
            switch self {
            case .daily: selection.paidDailyBudgetBaseUnits = value
            case .perRequest: selection.paidPerRequestBudgetBaseUnits = value
            }
        }
    }

    private func budgetItem(_ budget: Budget, accountID: String) -> OWSTableItem {
        OWSTableItem(text: "\(budget.title) · \(SigDemoBitcoinAmount.format(budget.value(in: service.selection)))",
            actionBlock: service.isUpdatingSelection ? nil : { [weak self] in
                self?.editBudget(budget, accountID: accountID)
            }, accessoryType: .disclosureIndicator)
    }

    private func editBudget(_ budget: Budget, accountID: String) {
        guard service.currentAccountID == accountID, !service.isUpdatingSelection else { return }
        let alert = UIAlertController(title: budget.title,
            message: "Enter a whole amount. ₿0 disables paid inference. The per Sig request limit must be no greater than the daily limit.", preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.text = String(budget.value(in: self.service.selection))
            field.placeholder = "0"
            let symbol = UILabel()
            symbol.text = "₿"
            symbol.sizeToFit()
            field.leftView = symbol
            field.leftViewMode = .always
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, service.currentAccountID == accountID else { return }
            var selection = service.selection
            guard let amount = SigDemoBitcoinAmount.parseBudget(alert?.textFields?.first?.text ?? "") else {
                showInvalidBudget()
                return
            }
            budget.assign(amount, to: &selection)
            selection.paidFundingDefaults.markUserEdited()
            do { try selection.validate() } catch {
                showInvalidBudget()
                return
            }
            select(selection, accountID: accountID)
        })
        present(alert, animated: true)
    }

    private func showInvalidBudget() {
        let alert = UIAlertController(title: "Check spending limits",
            message: "Use a whole amount with digits only. The per Sig request limit cannot exceed the daily limit.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func paidWalletSection(accountID: String) -> OWSTableSection {
        let section = OWSTableSection(title: "Paid Mesh wallet")
        let updating = service.isUpdatingWallet || service.isUpdatingSelection
        let busy = updating || service.hasPaidInferenceJobs
        guard let wallet = service.paidWallet else {
            section.footerTitle = "Checking this test account's wallet…"
            return section
        }
        let walletStatus = wallet.state == .reconciliationNeeded
            ? "Paid Mesh has an outstanding settlement. This can include usage not yet invoiced or an unresolved wallet payment. A new settlement payment needs positive current spending limits and must stay within the original authorization caps. With zero limits, refresh only observes payments already submitted. Retry reconciliation before another paid reply."
            : (wallet.state == .ready ? "The wallet is ready. Paid inference uses your saved spending limits." : wallet.status)
        section.footerTitle = walletStatus + "\nThis separate wallet pays only for your inference. It does not receive payments for serving models. Wallet setup and funding are optional."
        let state: String
        switch wallet.state {
        case .notSetUp: state = "Not set up"
        case .locked: state = "Locked"
        case .syncing: state = "Syncing"
        case .unfunded: state = "Needs funding"
        case .ready: state = "Ready"
        case .reconciliationNeeded: state = "Outstanding settlement"
        case .unavailable: state = "Unavailable"
        @unknown default: state = "Unavailable"
        }
        section.add(OWSTableItem(title: updating ? "Updating wallet…" : state, actionBlock: nil))
        section.add(OWSTableItem(title: "Balance · " + (wallet.balanceBaseUnits.map(SigDemoBitcoinAmount.format) ?? "Unavailable"), actionBlock: nil))
        if let spent = wallet.spentTodayBaseUnits {
            section.add(OWSTableItem(title: "Spent today · \(SigDemoBitcoinAmount.format(spent))", actionBlock: nil))
        }
        if let reserved = wallet.reservedBaseUnits {
            section.add(OWSTableItem(title: "Reserved · \(SigDemoBitcoinAmount.format(reserved))", actionBlock: nil))
        }
        if wallet.pendingPayments > 0 {
            section.add(OWSTableItem(title: "Pending wallet payments · \(wallet.pendingPayments)", actionBlock: nil))
        }
        if service.isPaidInferenceActive {
            section.add(OWSTableItem(title: service.isFinalizingPaidInference
                ? "Finalizing payments for this Sig reply" : "Paid Sig request in progress", actionBlock: nil))
        }
        if wallet.state == .notSetUp || wallet.state == .syncing {
            let resuming = wallet.state == .syncing
            section.add(.actionItem(withText: resuming ? "Resume wallet setup" : "Set up test wallet", actionBlock: busy ? nil : { [weak self] in
                self?.confirmWalletSetup(accountID: accountID, resuming: resuming)
            }))
        }
        if wallet.state == .ready || wallet.state == .unfunded || wallet.state == .reconciliationNeeded {
            section.add(.actionItem(withText: "Create funding invoice", actionBlock: busy ? nil : { [weak self] in
                self?.requestFundingInvoice(accountID: accountID)
            }))
            section.add(.disclosureItem(withText: "Transaction history", actionBlock: { [weak self] in
                self?.navigationController?.pushViewController(SigDemoWalletHistoryViewController(accountID: accountID), animated: true)
            }))
        }
        let refreshTitle = wallet.state == .reconciliationNeeded ? "Retry settlement reconciliation" : "Refresh wallet"
        section.add(.actionItem(withText: refreshTitle, actionBlock: busy ? nil : { [weak self] in
            guard let self else { return }
            Task {
                let refreshed = await self.service.refreshPaidWallet(accountID: accountID)
                if !refreshed, self.service.currentAccountID == accountID {
                    self.showWalletActionFailure()
                }
            }
        }))
        return section
    }

    private func confirmWalletSetup(accountID: String, resuming: Bool) {
        guard service.currentAccountID == accountID else { return }
        let explanation = resuming
            ? "Resume setup using this test account's saved wallet key. It stays in this app's Keychain. Resuming does not fund the wallet or enable spending."
            : "Create a separate Lexe wallet for this test account. Its private key stays in this app's Keychain. Setup does not fund the wallet or enable spending; inference also needs funds and positive spending limits."
        let limitation = "This demo has no wallet recovery or export, so keep only a small test balance: losing the app, account, or device can make funds inaccessible."
        let alert = UIAlertController(title: resuming ? "Resume wallet setup?" : "Set up test wallet?",
            message: explanation + "\n\n" + limitation, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: resuming ? "Resume setup" : "Set up wallet", style: .default) { [weak self] _ in
            guard let self else { return }
            Task {
                let created = await self.service.setupPaidWallet(accountID: accountID)
                if !created, self.service.currentAccountID == accountID { self.showWalletActionFailure() }
            }
        })
        present(alert, animated: true)
    }

    private func requestFundingInvoice(accountID: String) {
        guard service.currentAccountID == accountID else { return }
        let alert = UIAlertController(title: "Fund paid Mesh wallet",
            message: "Enter the amount for a Lightning invoice. Creating an invoice does not move funds. Pay it separately only when you want to fund this test wallet.", preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.placeholder = "0"
            let symbol = UILabel()
            symbol.text = "₿"
            symbol.sizeToFit()
            field.leftView = symbol
            field.leftViewMode = .always
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create invoice", style: .default) { [weak self, weak alert] _ in
            guard let self, service.currentAccountID == accountID else { return }
            guard let amount = SigDemoBitcoinAmount.parseBudget(alert?.textFields?.first?.text ?? ""), amount > 0 else {
                showWalletActionFailure(message: "Enter a positive whole amount using digits only.")
                return
            }
            Task {
                let invoice = await self.service.createPaidFundingInvoice(amountBaseUnits: amount, accountID: accountID)
                guard self.service.currentAccountID == accountID,
                      UIApplication.shared.applicationState != .background else { return }
                if let invoice {
                    self.navigationController?.pushViewController(SigDemoFundingInvoiceViewController(invoice: invoice, accountID: accountID), animated: true)
                } else { self.showWalletActionFailure() }
            }
        })
        present(alert, animated: true)
    }

    private func showWalletActionFailure(message: String = "The wallet could not complete this action. Refresh it and try again.") {
        let alert = UIAlertController(title: "Wallet unavailable", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func select(_ selection: SigDemoInferenceSelection, accountID: String) {
        Task { [weak self] in
            guard let self else { return }
            let saved = await service.updateSelection(selection, accountID: accountID)
            updateContents()
            if !saved {
                let alert = UIAlertController(title: "Settings unavailable", message: "Sig could not save this choice. Check that your test account is still open and try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

/// History is an observation of the account's existing wallet. Opening or
/// refreshing it cannot fund the wallet or retry an outgoing payment.
@MainActor
private final class SigDemoWalletHistoryViewController: OWSTableViewController2 {
    private let accountID: String
    private let service = SigDemoAgentService.shared
    private var transactions: [PaidMeshTransaction] = []
    private var nextCursor: String?
    private var hasMore = false
    private var loaded = false
    private var failed = false
    private var loadTask: Task<Void, Never>?
    private var loadID: UUID?
    private var observers: [NSObjectProtocol] = []

    init(accountID: String) {
        self.accountID = accountID
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Transaction history"
        for name in [UIApplication.didEnterBackgroundNotification, .registrationStateDidChange, SigDemoInferenceSettings.stateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.isCurrentAccount { self.closeHistory() }
                }
            })
        }
        updateContents()
    }

    deinit {
        loadTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard isCurrentAccount else { closeHistory(); return }
        if !loaded { load(reset: true) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelLoad()
    }

    override func themeDidChange() {
        super.themeDidChange()
        updateContents()
    }

    private var isCurrentAccount: Bool {
        service.currentAccountID == accountID && service.selection.provider == .paidMesh
            && UIApplication.shared.applicationState != .background
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadID = nil
    }

    private func closeHistory() {
        cancelLoad()
        guard navigationController?.topViewController === self else { return }
        navigationController?.popViewController(animated: false)
    }

    private func load(reset: Bool) {
        guard loadTask == nil, isCurrentAccount else { return }
        let id = UUID()
        loadID = id
        let cursor = reset ? nil : nextCursor
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if loadID == id { loadTask = nil; loadID = nil; updateContents() }
            }
            guard let page = await service.paidTransactionHistory(cursor: cursor, accountID: accountID),
                  !Task.isCancelled, isCurrentAccount, loadID == id else {
                if !Task.isCancelled, isCurrentAccount, loadID == id { failed = true }
                return
            }
            if reset { transactions.removeAll() }
            var latest = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
            for transaction in page.transactions { latest[transaction.id] = transaction }
            transactions = Array(latest.values)
            transactions.sort {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            }
            nextCursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
            loaded = true
            failed = false
            updateContents()
            _ = await service.refreshPaidWalletObservation(accountID: accountID)
        }
        updateContents()
    }

    private func updateContents() {
        let contents = OWSTableContents()
        let controls = OWSTableSection(title: nil)
        controls.footerTitle = "Only this test account's wallet transactions are shown. Refresh observes payments and balance; it does not retry inference payments."
        controls.add(.actionItem(withText: loadTask == nil ? "Refresh history" : "Loading history…", actionBlock: loadTask == nil ? { [weak self] in self?.load(reset: true) } : nil))
        if failed { controls.add(OWSTableItem(title: "History could not be loaded. Try refreshing again.", actionBlock: nil)) }
        contents.add(controls)
        if transactions.isEmpty, loaded {
            contents.add(OWSTableSection(title: nil, items: [], footerTitle: "No wallet transactions yet."))
        }
        for transaction in transactions {
            let direction: String
            switch transaction.direction {
            case .inbound: direction = "Received"
            case .outbound: direction = "Sent"
            case .info: direction = "Wallet activity"
            @unknown default: direction = "Wallet activity"
            }
            let state: String
            switch transaction.status {
            case .pending: state = "Pending"
            case .completed: state = "Completed"
            case .failed: state = "Failed"
            @unknown default: state = "Unavailable"
            }
            let section = OWSTableSection(title: nil)
            section.add(OWSTableItem(title: direction + " · " + (transaction.amountBaseUnits.map(SigDemoBitcoinAmount.format) ?? "Amount unavailable"), actionBlock: nil))
            section.footerTitle = state + " · " + DateFormatter.localizedString(from: transaction.confirmedAt ?? transaction.createdAt, dateStyle: .medium, timeStyle: .short)
            if transaction.feeBaseUnits > 0 { section.footerTitle! += "\nFee · " + SigDemoBitcoinAmount.format(transaction.feeBaseUnits) }
            contents.add(section)
        }
        if hasMore {
            let more = OWSTableSection(title: nil)
            more.add(.actionItem(withText: "Load more transactions", actionBlock: loadTask == nil ? { [weak self] in self?.load(reset: false) } : nil))
            contents.add(more)
        }
        self.contents = contents
    }
}

/// The funding invoice is displayed only after an explicit action. No wallet
/// secret is displayed, copied, or included in a Signal message.
@MainActor
private final class SigDemoFundingInvoiceViewController: OWSViewController {
    private let invoice: PaidMeshFundingInvoice
    private let accountID: String
    private var observers: [NSObjectProtocol] = []
    private let statusLabel = UILabel()
    private let balanceLabel = UILabel()
    private let defaultsLabel = UILabel()
    private var copyButton: UIButton?
    private var pollingTask: Task<Void, Never>?
    private var pollingID: UUID?
    private let service = SigDemoAgentService.shared

    init(invoice: PaidMeshFundingInvoice, accountID: String) {
        self.invoice = invoice
        self.accountID = accountID
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Funding invoice"
        view.backgroundColor = .systemBackground
        let amount = UILabel()
        amount.text = SigDemoBitcoinAmount.format(invoice.amountBaseUnits)
        amount.font = .preferredFont(forTextStyle: .title1)
        amount.textAlignment = .center
        let qr = UIImageView(image: Self.qrCode(invoice.bolt11))
        qr.contentMode = .scaleAspectFit
        qr.layer.magnificationFilter = .nearest
        qr.layer.minificationFilter = .nearest
        qr.heightAnchor.constraint(equalToConstant: 250).isActive = true
        let details = UILabel()
        details.numberOfLines = 0
        details.font = .preferredFont(forTextStyle: .body)
        details.text = "Pay this invoice from another Lightning wallet to fund only this test account's paid inference wallet."
        if let expiresAt = invoice.expiresAt {
            details.text! += "\nExpires " + DateFormatter.localizedString(from: expiresAt, dateStyle: .medium, timeStyle: .short) + "."
        }
        let copy = UIButton(configuration: .filled(), primaryAction: UIAction(title: "Copy invoice") { [weak self] _ in
            guard let self, SigDemoAgentService.shared.currentAccountID == accountID,
                  invoice.expiresAt.map({ $0 > Date() }) ?? true else { return }
            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: invoice.bolt11]], options: [
                .localOnly: true, .expirationDate: Date().addingTimeInterval(120),
            ])
        })
        copyButton = copy
        for label in [statusLabel, balanceLabel, defaultsLabel] {
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .body)
        }
        statusLabel.text = "Checking invoice payment…"
        let stack = UIStackView(arrangedSubviews: [amount, statusLabel, balanceLabel, qr, details, defaultsLabel, copy])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.stopPolling() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isCurrentAccount { self.startPolling() } else { self.closeInvoice() }
        } })
        observers.append(NotificationCenter.default.addObserver(
            forName: .registrationStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.closeInvoice() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: SigDemoInferenceSettings.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.isCurrentAccount { self.closeInvoice() }
        } })
    }

    deinit {
        pollingTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !isCurrentAccount { closeInvoice() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPolling()
    }

    private var isCurrentAccount: Bool {
        service.currentAccountID == accountID && service.selection.provider == .paidMesh
    }

    private var canObserveInvoice: Bool {
        isCurrentAccount && UIApplication.shared.applicationState != .background
            && viewIfLoaded?.window != nil && navigationController?.topViewController === self
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        pollingID = nil
    }

    private func startPolling() {
        guard pollingTask == nil, canObserveInvoice else { return }
        let id = UUID()
        pollingID = id
        pollingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if pollingID == id { pollingTask = nil; pollingID = nil }
            }
            while !Task.isCancelled, canObserveInvoice {
                if let status = await service.paidFundingStatus(for: invoice, accountID: accountID) {
                    guard !Task.isCancelled, canObserveInvoice, pollingID == id else { return }
                    balanceLabel.text = "Wallet balance · " + (status.wallet.balanceBaseUnits.map(SigDemoBitcoinAmount.format) ?? "Unavailable")
                    switch status.state {
                    case .pending:
                        statusLabel.text = "Awaiting payment"
                    case .paid:
                        statusLabel.text = "Funding confirmed" + (status.receivedBaseUnits.map { " · " + SigDemoBitcoinAmount.format($0) } ?? "")
                        copyButton?.isEnabled = false
                        // Both calls are observation only. Confirmed history,
                        // never this requested invoice amount, sets defaults.
                        _ = await service.refreshPaidWalletObservation(accountID: accountID)
                        guard !Task.isCancelled, canObserveInvoice, pollingID == id else { return }
                        balanceLabel.text = "Wallet balance · " + (service.paidWallet?.balanceBaseUnits.map(SigDemoBitcoinAmount.format) ?? "Unavailable")
                        if service.selection.paidFundingDefaults.state == .automatic {
                            defaultsLabel.text = "Daily and per Sig request limits were set once to "
                                + SigDemoBitcoinAmount.format(service.selection.paidDailyBudgetBaseUnits)
                                + ", half your first confirmed funding rounded down. You can edit them in Sig agent settings."
                        } else if service.selection.paidFundingDefaults.state == .userEdited {
                            defaultsLabel.text = "Your saved spending limits were kept. You can edit them in Sig agent settings."
                        } else {
                            defaultsLabel.text = "Your balance is updated. Spending limits will remain unchanged until the first confirmed funding can be verified from wallet history."
                        }
                        return
                    case .expired:
                        statusLabel.text = "Invoice expired. Create a new invoice to fund this wallet."
                        copyButton?.isEnabled = false
                        return
                    case .failed:
                        statusLabel.text = "Invoice payment failed. Create a new invoice to try again."
                        copyButton?.isEnabled = false
                        return
                    @unknown default:
                        statusLabel.text = "Invoice status unavailable. Checking again…"
                    }
                } else {
                    guard !Task.isCancelled, canObserveInvoice, pollingID == id else { return }
                    statusLabel.text = "Invoice status unavailable. Checking again…"
                }
                if invoice.expiresAt.map({ $0 <= Date() }) ?? false { copyButton?.isEnabled = false }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func closeInvoice() {
        stopPolling()
        guard navigationController?.topViewController === self else { return }
        navigationController?.popViewController(animated: false)
    }

    private static func qrCode(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.uppercased().utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let code = UIImage(cgImage: cgImage)
        // Preserve the four-module quiet zone even when the app uses a dark
        // theme. This is a payment invoice, so scan reliability matters.
        let border: CGFloat = 32
        let size = CGSize(width: code.size.width + border * 2, height: code.size.height + border * 2)
        return UIGraphicsImageRenderer(size: size).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                code.draw(at: CGPoint(x: border, y: border))
            }
    }
}
