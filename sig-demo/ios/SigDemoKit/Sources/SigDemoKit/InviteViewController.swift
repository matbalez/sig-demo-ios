// Copyright 2026 sig demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(UIKit)
import UIKit

/// Native onboarding for a real Signal registration adapter. It never enters
/// upstream phone-number registration or device linking. The fork must supply
/// its SQLCipher/libsignal coordinator before presenting this controller.
@MainActor
public final class SigDemoInviteViewController: UIViewController {
    private let coordinator: SigDemoRegistrationCoordinator
    private let onRegistered: @MainActor (SigDemoAccount) -> Void
    private let invitation = UITextField()
    private let displayName = UITextField()
    private let action = UIButton(type: .system)
    private let status = UILabel()
    private let progress = UIActivityIndicatorView(style: .medium)
    private var operation: Task<Void, Never>?
    private var retryPending = false
    private var configurationBlocked = false
    private var isVisible = false
    private var registeredAccount: SigDemoAccount?
    private var deliveredRegistration = false
    #if DEBUG && targetEnvironment(simulator)
    private var attemptedSimulatorRegistration = false
    #endif

    private enum Attempt {
        case resume
        case create(invitation: String, displayName: String)
    }

    public init(coordinator: SigDemoRegistrationCoordinator,
                onRegistered: @escaping @MainActor (SigDemoAccount) -> Void) {
        self.coordinator = coordinator
        self.onRegistered = onRegistered
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use the isolated registration coordinator.") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "sig demo"
        let heading = UILabel()
        heading.text = "Join with an invitation"
        heading.font = .preferredFont(forTextStyle: .title1)
        heading.adjustsFontForContentSizeCategory = true
        heading.numberOfLines = 0
        let explanation = UILabel()
        explanation.text = "Create a separate test account. Your production Signal account and messages stay separate. No phone number or SMS is needed."
        explanation.font = .preferredFont(forTextStyle: .body)
        explanation.adjustsFontForContentSizeCategory = true
        explanation.numberOfLines = 0

        invitation.placeholder = "Invitation code"
        invitation.accessibilityLabel = "Invitation code"
        invitation.isSecureTextEntry = true
        invitation.autocapitalizationType = .none
        invitation.autocorrectionType = .no
        invitation.spellCheckingType = .no
        invitation.textContentType = nil
        displayName.placeholder = "Display name"
        displayName.accessibilityLabel = "Display name"
        displayName.textContentType = .nickname
        displayName.autocapitalizationType = .words
        for field in [invitation, displayName] {
            field.borderStyle = .roundedRect
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.addTarget(self, action: #selector(updateAction), for: .editingChanged)
        }
        action.configuration = .filled()
        action.setTitle("Create test account", for: .normal)
        action.addTarget(self, action: #selector(register), for: .touchUpInside)
        status.font = .preferredFont(forTextStyle: .footnote)
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0
        status.accessibilityTraits = .updatesFrequently

        let license = UIButton(type: .system)
        license.setTitle("License and source", for: .normal)
        license.addTarget(self, action: #selector(showLicenseAndSource), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [heading, explanation, invitation, displayName, action, progress, status, license])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
        updateAction()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        if registeredAccount != nil { deliverRegistrationIfVisible(); return }
        guard !configurationBlocked else { return }
        begin(.resume)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        operation?.cancel()
        // Ambiguous redemption and local commit failures retain their encrypted
        // draft. The next presentation resumes instead of generating new keys.
    }

    @objc private func showLicenseAndSource() {
        SigDemoAboutPresenter.present(from: self)
    }

    @objc private func updateAction() {
        let code = invitation.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = displayName.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        action.setTitle(retryPending ? "Retry setup" : "Create test account", for: .normal)
        action.isEnabled = operation == nil && !configurationBlocked && registeredAccount == nil &&
            (retryPending || ((20...128).contains(code.utf16.count) && (1...100).contains(name.utf16.count)))
    }

    @objc private func register() {
        guard operation == nil else { return }
        if retryPending { begin(.resume); return }
        let code = invitation.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = displayName.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (20...128).contains(code.utf16.count), (1...100).contains(name.utf16.count) else { return }
        begin(.create(invitation: code, displayName: name))
    }

    private func begin(_ attempt: Attempt) {
        guard operation == nil, !configurationBlocked, registeredAccount == nil else { return }
        setBusy(true)
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                self.operation = nil
                self.setBusy(false)
                // If the user returns while cancellation is still draining,
                // resume once that operation has actually released its draft.
                if Task.isCancelled && self.isVisible && self.registeredAccount == nil && !self.configurationBlocked {
                    self.begin(.resume)
                }
                #if DEBUG && targetEnvironment(simulator)
                if !Task.isCancelled && self.isVisible && !self.retryPending && !self.configurationBlocked && self.registeredAccount == nil {
                    self.registerSimulatorAccountIfRequested()
                }
                #endif
            }
            do {
                let account: SigDemoAccount?
                switch attempt {
                case .resume:
                    account = try await coordinator.resumeIfNeeded()
                case let .create(code, name):
                    account = try await coordinator.register(inviteCode: code, displayName: name)
                }
                if let account {
                    // A successful commit can finish after the view is hidden.
                    // Retain it and notify only when this view is visible again.
                    self.registeredAccount = account
                    self.retryPending = false
                    self.deliverRegistrationIfVisible()
                } else {
                    self.retryPending = false
                    self.status.text = nil
                }
            } catch {
                if Task.isCancelled {
                    self.retryPending = true
                    self.status.text = nil
                } else {
                    self.show(error)
                }
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        let canEnterAccount = !busy && !retryPending && !configurationBlocked && registeredAccount == nil
        invitation.isEnabled = canEnterAccount
        displayName.isEnabled = canEnterAccount
        action.isEnabled = false
        if busy { progress.startAnimating(); status.text = "Preparing your test account…" }
        else { progress.stopAnimating(); updateAction() }
    }

    private func deliverRegistrationIfVisible() {
        guard isVisible, !deliveredRegistration, let account = registeredAccount else { return }
        deliveredRegistration = true
        invitation.text = nil
        status.text = "Test account ready."
        onRegistered(account)
    }

    private func show(_ error: any Error) {
        switch error {
        case SigDemoError.rejected(let code) where [400, 401, 403, 409].contains(code):
            retryPending = false
            status.text = "This invitation could not be used. Check the code or request a new invitation."
        case SigDemoError.invalidConfiguration, SigDemoError.draftBelongsToAnotherEnvironment,
             SigDemoError.unsupportedDraftVersion, SigDemoError.unsupportedPlatform:
            configurationBlocked = true
            retryPending = false
            status.text = "This build is not configured for your private demo."
        default:
            retryPending = true
            status.text = "Setup could not finish. Retry to resume the same test account."
        }
        UIAccessibility.post(notification: .announcement, argument: status.text)
    }

    #if DEBUG && targetEnvironment(simulator)
    /// End-to-end verification still runs the visible native controller and
    /// real coordinator. Values remain in memory and are never logged/saved
    /// outside the adapter's normal encrypted pending-registration draft.
    private func registerSimulatorAccountIfRequested() {
        guard !attemptedSimulatorRegistration,
              let code = ProcessInfo.processInfo.environment["SIG_DEMO_INVITE_CODE"],
              let name = ProcessInfo.processInfo.environment["SIG_DEMO_DISPLAY_NAME"],
              (20...128).contains(code.utf16.count), (1...100).contains(name.utf16.count) else { return }
        attemptedSimulatorRegistration = true
        invitation.text = code
        displayName.text = name
        updateAction()
        register()
    }
    #endif
}
#endif
