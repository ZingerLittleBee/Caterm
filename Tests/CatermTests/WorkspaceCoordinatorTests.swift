import Foundation
import XCTest
import KeychainStore
import SessionStore
import SSHCommandBuilder
import WorkspaceCore
@testable import Caterm

@MainActor
final class WorkspaceCoordinatorTests: XCTestCase {
	func testOpeningSavedHostCreatesOneWorkspacePaneAndOneSession() throws {
		let store = makeStore()
		let host = makeHost(name: "prod")
		try store.addHost(host)
		let coordinator = WorkspaceCoordinator(sessionStore: store)

		let workspace = try coordinator.openSavedHost(
			host,
			installTerminfo: true
		)

		XCTAssertEqual(workspace.topology.paneCount, 1)
		XCTAssertEqual(workspace.topology.panes.first?.host, .saved(id: host.id))
		XCTAssertEqual(store.tabs.count, 1)
		let sessionID = try XCTUnwrap(coordinator.sessionID(for: workspace))
		XCTAssertEqual(store.tabs.first?.id, sessionID)
		XCTAssertEqual(store.tabs.first?.installTerminfo, true)
	}

	func testOpeningOneTimeHostKeepsOnlySafeEndpointInWorkspaceShell() throws {
		let store = makeStore()
		let host = makeHost(name: "one-off")
		let coordinator = WorkspaceCoordinator(sessionStore: store)

		let workspace = try coordinator.openOneTimeHost(
			host,
			installTerminfo: false
		)

		let descriptor = try XCTUnwrap(workspace.topology.panes.first?.host.oneTime)
		XCTAssertEqual(descriptor.displayName, host.name)
		XCTAssertEqual(descriptor.hostname, host.hostname)
		XCTAssertEqual(descriptor.port, host.port)
		XCTAssertEqual(descriptor.username, host.username)
		XCTAssertEqual(store.tabs.first?.authenticationMode, .interactive)
		let encoded = try JSONEncoder().encode(workspace)
		let body = try XCTUnwrap(String(data: encoded, encoding: .utf8))
		XCTAssertFalse(body.contains("credential"))
		XCTAssertFalse(body.contains("session"))
	}

	func testRestoredSavedWorkspaceCreatesFreshSessionAndDoesNotReplayOldID() throws {
		let store = makeStore()
		let host = makeHost(name: "restore")
		try store.addHost(host)
		let firstCoordinator = WorkspaceCoordinator(sessionStore: store)
		let original = try firstCoordinator.openSavedHost(host, installTerminfo: false)
		let oldSessionID = try XCTUnwrap(firstCoordinator.sessionID(for: original))
		let restored = try JSONDecoder().decode(
			Workspace.self,
			from: JSONEncoder().encode(original)
		)
		firstCoordinator.closeWorkspace(original.id)
		XCTAssertTrue(store.tabs.isEmpty)
		let restoredCoordinator = WorkspaceCoordinator(sessionStore: store)

		let newSessionID = try XCTUnwrap(
			try restoredCoordinator.ensureSession(
				for: restored,
				installTerminfo: true
			)
		)

		XCTAssertNotEqual(newSessionID, oldSessionID)
		XCTAssertEqual(store.tabs.map(\.id), [newSessionID])
		XCTAssertEqual(store.tabs.first?.installTerminfo, true)
	}

	func testEnsuringSessionIsIdempotentWhileRuntimeSessionExists() throws {
		let store = makeStore()
		let host = makeHost()
		try store.addHost(host)
		let coordinator = WorkspaceCoordinator(sessionStore: store)
		let workspace = try coordinator.openSavedHost(host, installTerminfo: false)
		let originalSessionID = try XCTUnwrap(coordinator.sessionID(for: workspace))

		let ensured = try coordinator.ensureSession(
			for: workspace,
			installTerminfo: true
		)

		XCTAssertEqual(ensured, originalSessionID)
		XCTAssertEqual(store.tabs.count, 1)
		XCTAssertEqual(store.tabs.first?.installTerminfo, false)
	}

	func testClosingWorkspaceClosesExactlyItsMappedSession() throws {
		let store = makeStore()
		let firstHost = makeHost(name: "first")
		let secondHost = makeHost(name: "second")
		let coordinator = WorkspaceCoordinator(sessionStore: store)
		let first = try coordinator.openSavedHost(firstHost, installTerminfo: false)
		let second = try coordinator.openSavedHost(secondHost, installTerminfo: false)
		let secondSessionID = try XCTUnwrap(coordinator.sessionID(for: second))

		coordinator.closeWorkspace(first.id)

		XCTAssertEqual(store.tabs.map(\.id), [secondSessionID])
		XCTAssertNil(coordinator.sessionID(for: first))
		XCTAssertEqual(coordinator.sessionID(for: second), secondSessionID)
		coordinator.closeWorkspace(first.id)
		XCTAssertEqual(store.tabs.map(\.id), [secondSessionID])
	}

	func testMissingSavedHostRestoresShellWithoutCreatingSession() throws {
		let store = makeStore()
		let coordinator = WorkspaceCoordinator(sessionStore: store)
		let workspace = Workspace.onePane(host: .saved(id: UUID()))

		let sessionID = try coordinator.ensureSession(
			for: workspace,
			installTerminfo: false
		)

		XCTAssertNil(sessionID)
		XCTAssertTrue(store.tabs.isEmpty)
		XCTAssertNil(coordinator.sessionID(for: workspace))
	}

	func testRestoredOneTimeWorkspaceUsesInteractiveAuthentication() throws {
		let store = makeStore()
		let coordinator = WorkspaceCoordinator(sessionStore: store)
		let descriptor = try OneTimeConnectionDescriptor(
			displayName: "ephemeral",
			hostname: "127.0.0.1",
			port: 2222,
			username: "tester"
		)
		let workspace = Workspace.onePane(host: .oneTime(descriptor))

		let sessionID = try XCTUnwrap(try coordinator.ensureSession(
			for: workspace,
			installTerminfo: false
		))

		let tab = try XCTUnwrap(store.tabs.first(where: { $0.id == sessionID }))
		XCTAssertEqual(tab.host.name, "ephemeral")
		XCTAssertEqual(tab.host.hostname, "127.0.0.1")
		XCTAssertEqual(tab.host.port, 2222)
		XCTAssertEqual(tab.host.username, "tester")
		XCTAssertEqual(tab.authenticationMode, .interactive)
	}

	private func makeStore() -> SessionStore {
		let hostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("workspace-coordinator-\(UUID()).json")
		return SessionStore(
			askpassPath: "/dev/null",
			knownHostsCaterm: "/dev/null",
			knownHostsUser: "/dev/null",
			accessGroup: nil,
			hostsURL: hostsURL,
			keychain: KeychainStore(
				service: "com.caterm.workspace-test.\(UUID())",
				accessGroup: nil
			),
			preflight: ImmediateFailurePreflight()
		)
	}

	private func makeHost(name: String = "host") -> SSHHost {
		SSHHost(
			name: name,
			hostname: "127.0.0.1",
			port: 22,
			username: "tester",
			credential: .agent
		)
	}
}

private struct ImmediateFailurePreflight: PreflightProbing {
	func probe(host _: String, port _: UInt16, timeout _: TimeInterval) async -> PreflightOutcome {
		.failed(.other(code: 1, message: "test boundary"))
	}

	func probeLocalBind(address _: String, port _: UInt16) async -> PortBindOutcome {
		.available
	}
}

private extension WorkspaceHostReference {
	var oneTime: OneTimeConnectionDescriptor? {
		guard case .oneTime(let descriptor) = self else { return nil }
		return descriptor
	}
}
