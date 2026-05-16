import Combine
import Foundation

/// Observes notifications about Ghostty config diagnostics and "new-surface
/// only" settings changes, and exposes them as `@Published` state for the
/// MainWindow banner UI. Posters:
/// - `catermConfigDiagnostics` (userInfo["diagnostics"] = [String]) — emitted
///   by GhosttyConfigBuilder/diagnostic surfacing when reload finds bad keys.
/// - `catermNewSurfaceBanner` — emitted when a setting that only takes effect
///   on new surfaces (scrollback memory, titlebar style) is changed.
@MainActor
public final class SettingsBannerState: ObservableObject {
    @Published public private(set) var diagnosticMessages: [String] = []
    @Published public private(set) var showNewSurfaceBanner: Bool = false

    private var observers: [NSObjectProtocol] = []

    public init() {
        // Observers run on `.main` queue (NotificationQueue) so direct
        // assignment from inside the block is already main-actor-safe. We
        // intentionally avoid `Task { @MainActor in ... }` here because the
        // hop would fall outside the synchronous tick that XCTest's RunLoop
        // drain expects, making `RunLoop.current.run(until:)` flaky.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: Notification.Name("catermConfigDiagnostics"),
                object: nil,
                queue: .main
            ) { [weak self] note in
                let messages = note.userInfo?["diagnostics"] as? [String] ?? []
                MainActor.assumeIsolated {
                    self?.diagnosticMessages = messages
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: Notification.Name("catermNewSurfaceBanner"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.showNewSurfaceBanner = true
                }
            }
        )
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public func dismissDiagnostics() { diagnosticMessages = [] }
    public func dismissNewSurface() { showNewSurfaceBanner = false }
}
