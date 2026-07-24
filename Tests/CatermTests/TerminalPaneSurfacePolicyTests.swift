import SessionStore
import SSHCommandBuilder
import XCTest
@testable import Caterm

final class TerminalPaneSurfacePolicyTests: XCTestCase {
	func testExitedAndReconnectablePanesRetainTerminalOutput() {
		for state in [
			ConnectionState.connected(connectedAt: Date()),
			.reconnecting(attempt: 1, nextRetryAt: Date()),
			.failed(.cleanExit),
			.failed(.connectionDropped),
			.preflight(startedAt: Date()),
			.failed(.networkUnreachable(.timedOut)),
		] {
			XCTAssertTrue(TerminalPaneSurfacePolicy.retainsSurface(
				for: makeTab(state: state, surfaceGeneration: 1)
			))
		}
	}

	func testPreSurfaceFailuresDoNotStartGhostty() {
		for state in [
			ConnectionState.idle,
			.preflight(startedAt: Date()),
			.failed(.authOrSetupFail),
		] {
			XCTAssertFalse(TerminalPaneSurfacePolicy.retainsSurface(
				for: makeTab(state: state, surfaceGeneration: 0)
			))
		}
	}

	private func makeTab(
		state: ConnectionState,
		surfaceGeneration: Int
	) -> SessionStore.Tab {
		var tab = SessionStore.Tab(host: SSHHost(
			name: "local",
			hostname: "127.0.0.1",
			port: 22,
			username: "tester",
			credential: .agent
		))
		tab.state = state
		tab.surfaceGeneration = surfaceGeneration
		return tab
	}
}
