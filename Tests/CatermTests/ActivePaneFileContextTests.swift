import SessionStore
import SSHCommandBuilder
import WorkspaceCore
import XCTest
@testable import Caterm

final class ActivePaneFileContextTests: XCTestCase {
	func testConnectedSavedHostResolvesExactPaneSessionAndHost() throws {
		let host = makeHost()
		let workspace = Workspace.onePane(host: .saved(id: host.id))
		var tab = SessionStore.Tab(host: host)
		tab.state = .connected(connectedAt: Date())

		let context = ActivePaneFileContextResolver.resolve(
			workspace: workspace,
			sessionID: tab.id,
			tab: tab,
			savedHostExists: true
		)

		XCTAssertEqual(context, .ready(ActivePaneFileTarget(
			paneID: workspace.activePaneID,
			sessionID: tab.id,
			hostID: host.id
		)))
	}

	func testFocusChangeRejectsPriorPaneSessionAsStale() throws {
		let firstHost = makeHost()
		let secondHost = makeHost()
		let first = Workspace.onePane(host: .saved(id: firstHost.id))
		let picker = try first.splittingActivePane(.right)
		let workspace = try picker.assigningHost(
			.saved(id: secondHost.id),
			to: picker.activePaneID
		)
		var staleTab = SessionStore.Tab(host: firstHost)
		staleTab.state = .connected(connectedAt: Date())

		let context = ActivePaneFileContextResolver.resolve(
			workspace: workspace,
			sessionID: staleTab.id,
			tab: staleTab,
			savedHostExists: true
		)

		XCTAssertEqual(context, .unavailable(.staleSession))
	}

	func testUnavailableStatesAreExplicit() throws {
		let host = makeHost()
		let picker = try Workspace.onePane(host: .saved(id: host.id))
			.splittingActivePane(.right)
		XCTAssertEqual(resolve(picker), .unavailable(.chooseHost))

		let oneTime = Workspace.onePane(host: .oneTime(
			try OneTimeConnectionDescriptor(
				displayName: "one-time",
				hostname: "localhost",
				port: 22,
				username: "tester"
			)
		))
		XCTAssertEqual(resolve(oneTime), .unavailable(.oneTimeConnection))

		let saved = Workspace.onePane(host: .saved(id: host.id))
		XCTAssertEqual(resolve(saved, savedHostExists: false), .unavailable(.missingHost))
		XCTAssertEqual(resolve(saved), .unavailable(.disconnected))

		var connecting = SessionStore.Tab(host: host)
		connecting.state = .authenticating(startedAt: Date())
		XCTAssertEqual(
			resolve(saved, sessionID: connecting.id, tab: connecting),
			.unavailable(.connecting)
		)
		var reconnecting = connecting
		reconnecting.state = .reconnecting(attempt: 1, nextRetryAt: Date())
		XCTAssertEqual(
			resolve(saved, sessionID: reconnecting.id, tab: reconnecting),
			.unavailable(.reconnecting)
		)
	}

	func testFocusChangeRejectsLateFileResultFromPreviousPane() throws {
		let first = Workspace.onePane(host: .saved(id: UUID()))
		let split = try first.splittingActivePane(.right)
		let firstIdentity = FileDrawerTaskIdentity(
			paneID: first.activePaneID,
			context: .unavailable(.disconnected)
		)
		let secondIdentity = FileDrawerTaskIdentity(
			paneID: split.activePaneID,
			context: .unavailable(.connecting)
		)
		var gate = FileDrawerResultGate()
		gate.begin(firstIdentity)

		gate.begin(secondIdentity)

		XCTAssertFalse(gate.accepts(firstIdentity))
		XCTAssertTrue(gate.accepts(secondIdentity))
	}

	func testUploadAuthorizationRejectsCapturedTargetAfterAsyncFocusChange() async throws {
		let first = Workspace.onePane(host: .saved(id: UUID()))
		let split = try first.splittingActivePane(.right)
		let firstTarget = ActivePaneFileTarget(
			paneID: first.activePaneID,
			sessionID: UUID(),
			hostID: UUID()
		)
		let secondTarget = ActivePaneFileTarget(
			paneID: split.activePaneID,
			sessionID: UUID(),
			hostID: UUID()
		)
		let identity = FileDrawerTaskIdentity(
			paneID: firstTarget.paneID,
			context: .ready(firstTarget)
		)
		var gate = FileDrawerResultGate()
		gate.begin(identity)
		let signal = AsyncSignal()
		let release = AsyncSignal()

		let operation = Task { @MainActor in
			await signal.fire()
			await release.wait()
			return FileDrawerOperationAuthorization.permits(
				identity: identity,
				expectedTarget: firstTarget,
				gate: gate,
				currentContext: .ready(secondTarget)
			)
		}
		await signal.wait()
		await release.fire()
		let wasAuthorized = await operation.value

		XCTAssertFalse(wasAuthorized)
	}

	func testPendingWindowUploadCannotRetargetAtSheetSubmission() {
		let captured = ActivePaneFileTarget(
			paneID: PaneID(),
			sessionID: UUID(),
			hostID: UUID()
		)
		let other = ActivePaneFileTarget(
			paneID: PaneID(),
			sessionID: UUID(),
			hostID: UUID()
		)
		let upload = PendingPaneUpload(
			urls: [URL(fileURLWithPath: "/tmp/example")],
			target: captured
		)

		XCTAssertTrue(upload.canSubmit(in: .ready(captured)))
		XCTAssertFalse(upload.canSubmit(in: .ready(other)))
		XCTAssertFalse(upload.canSubmit(in: .unavailable(.reconnecting)))
	}

	private func resolve(
		_ workspace: Workspace,
		sessionID: UUID? = nil,
		tab: SessionStore.Tab? = nil,
		savedHostExists: Bool = true
	) -> ActivePaneFileContext {
		ActivePaneFileContextResolver.resolve(
			workspace: workspace,
			sessionID: sessionID,
			tab: tab,
			savedHostExists: savedHostExists
		)
	}

	private func makeHost() -> SSHHost {
		SSHHost(
			name: "local",
			hostname: "127.0.0.1",
			port: 22,
			username: "tester",
			credential: .agent
		)
	}
}

private actor AsyncSignal {
	private var fired = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func wait() async {
		guard !fired else { return }
		await withCheckedContinuation { continuation in
			waiters.append(continuation)
		}
	}

	func fire() {
		guard !fired else { return }
		fired = true
		let currentWaiters = waiters
		waiters.removeAll()
		for waiter in currentWaiters {
			waiter.resume()
		}
	}
}
