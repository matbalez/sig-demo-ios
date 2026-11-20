// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network
import SigDemoKit
import SignalServiceKit
import UIKit

@MainActor
final class SigDemoBootstrap {
    static let shared = SigDemoBootstrap()
    private var configuration: SigDemoConfiguration?
    private var identity: SigDemoAppIdentity?
    private var relay: SigDemoTCPRelay?
    private var directory: SigDemoDirectory?
    private var startupFailed = false
    #if DEBUG && targetEnvironment(simulator)
    private var sqlCipherSmokeCompleted = false
    #endif

    /// Called before upstream lifecycle initialization can start networking.
    /// The bounded wait happens on launch; relay work runs on its own queue.
    func prepareTransport() {
        #if DEBUG && targetEnvironment(simulator)
        if !sqlCipherSmokeCompleted,
           ProcessInfo.processInfo.environment["SIG_DEMO_SQLCIPHER_SMOKE"] == "1" {
            sqlCipherSmokeCompleted = true
            let passed = SigDemoSQLCipherBridge.qualifyInMemoryDatabase()
            let marker = passed ? "SIG_DEMO_SQLCIPHER_ISOLATION_PASSED" : "SIG_DEMO_SQLCIPHER_ISOLATION_FAILED"
            try? FileHandle.standardOutput.write(contentsOf: Data((marker + "\n").utf8))
        }
        #endif
        do {
            let configuration = try JSONDecoder().decode(
                SigDemoConfiguration.self,
                from: SigDemoRuntimeConfiguration.publicClientConfigurationData
            )
            let identity = try SigDemoAppIdentity(
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                appGroupIdentifier: TSConstants.applicationGroup,
                keychainService: "dev.matbalez.sig-demo.ios.registration"
            )
            try identity.validateCurrentProcess()
            let relay = SigDemoTCPRelay()
            do {
                try relay.start(configuration: configuration)
                self.relay = relay
            } catch let error as NWError {
                guard case .posix(.EADDRINUSE) = error else { throw error }
                // The existing desktop relay is left running and is never
                // stopped by this app. Private CA authentication is mandatory.
                try SigDemoTCPRelay.verifyExistingPrivateRelay(configuration: configuration)
            }
            self.configuration = configuration
            self.identity = identity
        } catch {
            startupFailed = true
            Logger.error("The isolated private demo transport could not start.")
        }
    }

    func stopTransport() { relay?.stop() }

    func failureControllerIfNeeded() -> UIViewController? {
        guard startupFailed else { return nil }
        return failureController()
    }

    func registrationController(onRegistered: @escaping @MainActor () -> Void) -> UIViewController {
        guard let configuration, let identity, !startupFailed else { return failureController() }
        do {
            let db = DependenciesBridge.shared.db
            let api = try SigDemoPrivateAPI(configuration: configuration, identity: identity)
            let coordinator = SigDemoRegistrationCoordinator(
                scope: SigDemoRegistrationScope(identity: identity, configuration: configuration),
                api: api, store: SigDemoEncryptedDraftStore(db: db),
                adapter: SigDemoUpstreamRegistrationAdapter(
                    db: db, keychain: KeychainStorageImpl(isUsingProductionService: false)
                )
            )
            let invite = SigDemoInviteViewController(coordinator: coordinator) { [weak self] _ in
                self?.startServices()
                Task { await self?.directory?.refresh() }
                onRegistered()
            }
            return UINavigationController(rootViewController: invite)
        } catch {
            return failureController()
        }
    }

    func startServices() {
        guard let configuration, let identity, !startupFailed else { return }
        if directory == nil, let api = try? SigDemoPrivateAPI(configuration: configuration, identity: identity) {
            directory = SigDemoDirectory(api: api)
            directory?.start()
        }
        SigDemoAgentService.shared.start()
    }

    private func failureController() -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "The private demo connection could not start. Check the demo build configuration and network connection, then reopen the app."
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: controller.view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: controller.view.layoutMarginsGuide.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
        ])
        return controller
    }
}
