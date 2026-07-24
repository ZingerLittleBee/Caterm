import XCTest
@testable import Caterm

@MainActor
final class AccountChangeSyncCoordinatorTests: XCTestCase {
  private final class EventRecorder {
    var events: [String] = []
  }

  private enum ExpectedFailure: Error {
    case reset
    case resetIdentities
    case wipe
  }

  func testIdentityChangeRunsOrderedTransaction() async {
    let recorder = EventRecorder()
    let coordinator = makeCoordinator(recorder: recorder, identityChanged: true)

    await coordinator.enqueue().value

    XCTAssertEqual(recorder.events, [
      "begin-host", "begin-snippets",
      "drain-host", "drain-snippets", "identity",
      "reset-credentials", "reset-identities", "wipe-snippets", "acknowledge",
      "resume-host", "resume-snippets:true",
    ])
  }

  func testResetFailureStillResumesBothLanesWithoutAcknowledging() async {
    let recorder = EventRecorder()
    let coordinator = makeCoordinator(
      recorder: recorder,
      identityChanged: true,
      resetError: ExpectedFailure.reset
    )

    await coordinator.enqueue().value

    XCTAssertEqual(recorder.events, [
      "begin-host", "begin-snippets",
      "drain-host", "drain-snippets", "identity",
      "reset-credentials", "failure:reset",
      "resume-host", "resume-snippets:false",
    ])
  }

  func testWipeFailureStillResumesBothLanesWithoutAcknowledging() async {
    let recorder = EventRecorder()
    let coordinator = makeCoordinator(
      recorder: recorder,
      identityChanged: true,
      wipeError: ExpectedFailure.wipe
    )

    await coordinator.enqueue().value

    XCTAssertEqual(recorder.events, [
      "begin-host", "begin-snippets",
      "drain-host", "drain-snippets", "identity",
      "reset-credentials", "reset-identities", "wipe-snippets", "failure:wipe",
      "resume-host", "resume-snippets:false",
    ])
  }

  func testIdentityResetFailureDoesNotAcknowledgeAccountChange() async {
    let recorder = EventRecorder()
    let coordinator = makeCoordinator(
      recorder: recorder,
      identityChanged: true,
      identityResetError: ExpectedFailure.resetIdentities
    )

    await coordinator.enqueue().value

    XCTAssertEqual(recorder.events, [
      "begin-host", "begin-snippets",
      "drain-host", "drain-snippets", "identity",
      "reset-credentials", "reset-identities",
      "failure:resetIdentities",
      "resume-host", "resume-snippets:false",
    ])
  }

  func testRepeatedNotificationsRunSerially() async {
    var events: [String] = []
    var transition = 0
    var firstDrainContinuation: CheckedContinuation<Void, Never>?
    let coordinator = AccountChangeSyncCoordinator(
      dependencies: AccountChangeSyncCoordinator.Dependencies(
        beginHostSuspension: {
          transition += 1
          events.append("begin-host-\(transition)")
        },
        beginSnippetSuspension: {
          events.append("begin-snippets-\(transition)")
        },
        drainHost: {
          events.append("drain-host-\(transition)")
          if transition == 1 {
            await withCheckedContinuation { continuation in
              firstDrainContinuation = continuation
            }
          }
        },
        drainSnippets: {
          events.append("drain-snippets-\(transition)")
        },
        identityChanged: {
          events.append("identity-\(transition)")
          return false
        },
        resetCredentials: {},
        resetCredentialIdentities: {},
        wipeSnippets: {},
        acknowledgeIdentityChange: {},
        resumeHost: {
          events.append("resume-host-\(transition)")
        },
        resumeSnippets: { changed in
          events.append("resume-snippets-\(transition):\(changed)")
        },
        reportFailure: { _ in
          XCTFail("unexpected failure")
        }
      )
    )

    let first = coordinator.enqueue()
    await waitUntil { firstDrainContinuation != nil }
    let second = coordinator.enqueue()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(events.contains("begin-host-2"))

    firstDrainContinuation?.resume()
    firstDrainContinuation = nil
    await first.value
    await second.value

    XCTAssertEqual(events, [
      "begin-host-1", "begin-snippets-1", "drain-host-1",
      "drain-snippets-1", "identity-1", "resume-host-1", "resume-snippets-1:false",
      "begin-host-2", "begin-snippets-2", "drain-host-2",
      "drain-snippets-2", "identity-2", "resume-host-2", "resume-snippets-2:false",
    ])
  }

  private func makeCoordinator(
    recorder: EventRecorder,
    identityChanged: Bool,
    resetError: Error? = nil,
    identityResetError: Error? = nil,
    wipeError: Error? = nil
  ) -> AccountChangeSyncCoordinator {
    AccountChangeSyncCoordinator(
      dependencies: AccountChangeSyncCoordinator.Dependencies(
        beginHostSuspension: { recorder.events.append("begin-host") },
        beginSnippetSuspension: { recorder.events.append("begin-snippets") },
        drainHost: { recorder.events.append("drain-host") },
        drainSnippets: { recorder.events.append("drain-snippets") },
        identityChanged: {
          recorder.events.append("identity")
          return identityChanged
        },
        resetCredentials: {
          recorder.events.append("reset-credentials")
          if let resetError { throw resetError }
        },
        resetCredentialIdentities: {
          recorder.events.append("reset-identities")
          if let identityResetError { throw identityResetError }
        },
        wipeSnippets: {
          recorder.events.append("wipe-snippets")
          if let wipeError { throw wipeError }
        },
        acknowledgeIdentityChange: { recorder.events.append("acknowledge") },
        resumeHost: { recorder.events.append("resume-host") },
        resumeSnippets: { changed in recorder.events.append("resume-snippets:\(changed)") },
        reportFailure: { error in recorder.events.append("failure:\(error)") }
      )
    )
  }

  private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0..<1_000 {
      if predicate() { return }
      await Task.yield()
    }
    XCTFail("condition was not reached")
  }
}
