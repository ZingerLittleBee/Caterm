import Foundation

/// Serializes account-change transitions across every account-scoped sync
/// subsystem. The transition closes both scheduling gates before either lane
/// drains, then resumes both lanes even when local reset work fails.
@MainActor
final class AccountChangeSyncCoordinator {
  struct Dependencies {
    let beginHostSuspension: @MainActor () -> Void
    let beginSnippetSuspension: @MainActor () -> Void
    let drainHost: @MainActor () async -> Void
    let drainSnippets: @MainActor () async -> Void
    let identityChanged: @MainActor () async -> Bool
    let resetCredentials: @MainActor () async throws -> Void
    let wipeSnippets: @MainActor () throws -> Void
    let acknowledgeIdentityChange: @MainActor () async -> Void
    let resumeHost: @MainActor () -> Void
    let resumeSnippets: @MainActor (_ identityChanged: Bool) -> Void
    let reportFailure: @MainActor (_ error: Error) -> Void
  }

  private let dependencies: Dependencies
  private var tail: Task<Void, Never>?

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  /// Enqueue one complete transition behind any notification already being
  /// handled. Returning the task gives tests and lifecycle owners a real drain
  /// seam without exposing the coordinator's internal queue.
  @discardableResult
  func enqueue() -> Task<Void, Never> {
    let previous = tail
    let dependencies = dependencies
    let task = Task { @MainActor in
      _ = await previous?.result
      await Self.runTransition(dependencies)
    }
    tail = task
    return task
  }

  private static func runTransition(_ dependencies: Dependencies) async {
    dependencies.beginHostSuspension()
    dependencies.beginSnippetSuspension()
    await dependencies.drainHost()
    await dependencies.drainSnippets()

    var identityChanged = false
    defer {
      dependencies.resumeHost()
      dependencies.resumeSnippets(identityChanged)
    }

    guard await dependencies.identityChanged() else { return }
    do {
      try await dependencies.resetCredentials()
      try dependencies.wipeSnippets()
      await dependencies.acknowledgeIdentityChange()
      identityChanged = true
    } catch {
      dependencies.reportFailure(error)
    }
  }
}
