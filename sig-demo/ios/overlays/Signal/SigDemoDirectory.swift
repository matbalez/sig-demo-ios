// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SigDemoKit
import SignalServiceKit

/// Imports only the private invite roster into this isolated Signal database.
/// Profile keys travel in real encrypted Signal messages, never in the roster.
@MainActor
final class SigDemoDirectory {
    private let api: SigDemoPrivateAPI
    private var task: Task<Void, Never>?
    private var refreshing = false
    private let store = NewKeyValueStore(collection: "SigDemo.Directory")

    init(api: SigDemoPrivateAPI) { self.api = api }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
    }

    func refresh() async {
        guard !refreshing, CurrentAppContext().isMainAppAndActive else { return }
        let bridge = DependenciesBridge.shared
        guard bridge.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered,
              let local = bridge.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction,
              let password = bridge.tsAccountManager.storedServerAuthTokenWithMaybeTransaction else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let credentials = try SigDemoCredentials(accountID: local.aci.rawUUID, generatedPassword: password)
            let accounts = try await api.directory(credentials: credentials)
            try Task.checkCancellation()
            bridge.db.write { tx in
                for account in accounts where account.uuid != local.aci.rawUUID {
                    let aci = Aci(fromUUID: account.uuid)
                    let key = aci.serviceIdUppercaseString
                    var recipient = bridge.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                    bridge.recipientManager.markAsRegisteredAndSave(&recipient, shouldUpdateStorageService: false, tx: tx)
                    let previousName = store.fetchValue(String.self, forKey: "name/" + key, tx: tx)
                    let nickname = bridge.nicknameManager.fetchNickname(for: recipient, tx: tx)
                    // Preserve a name explicitly customized inside the app.
                    if nickname == nil || (nickname?.givenName == previousName && nickname?.familyName == nil) {
                        if nickname?.givenName != account.displayName {
                            bridge.nicknameManager.createOrUpdate(
                                nicknameRecord: NicknameRecord(recipient: recipient, givenName: account.displayName, familyName: nil, note: nickname?.note),
                                updateStorageServiceFor: nil, tx: tx
                            )
                        }
                    }
                    store.writeValue(account.displayName, forKey: "name/" + key, tx: tx)
                    let profileManager = SSKEnvironment.shared.profileManagerRef
                    profileManager.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .localUser, tx: tx)
                    if store.fetchValue(Bool.self, forKey: "shared/" + key, tx: tx) != true,
                       profileManager.isRecipientInProfileWhitelist(recipient, tx: tx),
                       let profileKey = profileManager.localProfileKey(tx: tx) {
                        let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(aci), transaction: tx)
                        let message = ProfileKeyMessage(thread: thread, profileKey: profileKey, tx: tx)
                        SSKEnvironment.shared.messageSenderJobQueueRef.add(
                            message: .preprepared(transientMessageWithoutAttachments: message), transaction: tx
                        )
                        store.writeValue(true, forKey: "shared/" + key, tx: tx)
                    }
                }
            }
        } catch {
            // Do not log names, account IDs, auth tokens, roster data or errors
            // containing request context. The next foreground interval retries.
            Logger.warn("Private demo directory refresh will retry.")
        }
    }
}
