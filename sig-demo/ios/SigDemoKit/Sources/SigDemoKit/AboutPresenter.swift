// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(UIKit)
import UIKit

/// Public license/source access does not require enrollment, an invite,
/// credentials, a wallet, or any private-service request.
@MainActor
public enum SigDemoAboutPresenter {
    public static func present(from controller: UIViewController) {
        guard controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil else { return }
        let archive = SigDemoSourceArchive.bundled(in: .main)
        let sourceNotice = archive == nil
            ? "For this modified build's exact corresponding source archive and build instructions, contact the person who invited you."
            : "This build includes its corresponding source archive and build instructions. Choose Share corresponding source to save or send a copy."
        let alert = UIAlertController(title: "Sig Demo · modified private build",
            message: "Signal iOS copyright 2013–2025 Signal Messenger, LLC. Sig Demo modifications copyright 2026 Sig Demo contributors. Licensed under the GNU Affero General Public License version 3 (AGPLv3); upstream notices are retained. This build is provided without warranty. You may modify and redistribute it under AGPLv3.\n\n\(sourceNotice)\n\nFor demo support, contact the person who invited you rather than Signal support.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "GNU AGPLv3 license", style: .default) { _ in
            UIApplication.shared.open(URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
        })
        if let archive {
            alert.addAction(UIAlertAction(title: "Share corresponding source", style: .default) { [weak controller, weak alert] _ in
                guard let controller, let alert else { return }
                // Wait for the About alert to leave before verifying/presenting
                // another controller, including the already-cached fast path.
                alert.dismiss(animated: true) { [weak controller] in
                    guard let controller else { return }
                    Task { @MainActor [weak controller] in
                        do {
                            let url = try await SigDemoSourceArchiveVerifier.shared.verifiedURL(for: archive)
                            guard let controller, canPresent(from: controller) else { return }
                            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                            if let popover = activity.popoverPresentationController {
                                popover.sourceView = controller.view
                                popover.sourceRect = CGRect(x: controller.view.bounds.midX,
                                                            y: controller.view.bounds.midY, width: 1, height: 1)
                                popover.permittedArrowDirections = []
                            }
                            controller.present(activity, animated: true)
                        } catch {
                            guard let controller, canPresent(from: controller) else { return }
                            let failure = UIAlertController(title: "Source archive unavailable",
                                message: "This build's source archive could not be verified. Request the matching archive from the person who invited you.",
                                preferredStyle: .alert)
                            failure.addAction(UIAlertAction(title: "Done", style: .cancel))
                            controller.present(failure, animated: true)
                        }
                    }
                }
            })
        }
        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
        controller.present(alert, animated: true)
    }

    private static func canPresent(from controller: UIViewController) -> Bool {
        guard UIApplication.shared.applicationState != .background,
              controller.viewIfLoaded?.window != nil,
              controller.presentedViewController == nil else { return false }
        if let navigation = controller.navigationController {
            return navigation.visibleViewController === controller
        }
        return !controller.isBeingDismissed && !controller.isMovingFromParent
    }
}
#endif
