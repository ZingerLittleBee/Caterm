import Foundation
import XCTest
@testable import WorkspaceCore

final class WorkspaceCoreTests: XCTestCase {
	func testOnePaneWorkspaceHasStableDistinctIdentitiesAndActivePane() throws {
		let workspaceID = WorkspaceID(rawValue: UUID())
		let paneID = PaneID(rawValue: UUID())
		let workspace = Workspace.onePane(
			id: workspaceID,
			paneID: paneID,
			host: .saved(id: UUID()),
			presentation: .split
		)

		XCTAssertEqual(workspace.id, workspaceID)
		XCTAssertEqual(workspace.topology.paneCount, 1)
		XCTAssertEqual(workspace.topology.paneIDs, [paneID])
		XCTAssertEqual(workspace.activePaneID, paneID)
		XCTAssertEqual(workspace.presentation, .split)
		XCTAssertNotEqual(workspaceID.rawValue, paneID.rawValue)
	}

	func testWindowIdentityStaysStableWhileWorkspaceValueTracksPresentation() {
		let id = WorkspaceID(rawValue: UUID())
		let paneID = PaneID(rawValue: UUID())
		let split = Workspace.onePane(
			id: id,
			paneID: paneID,
			host: .saved(id: UUID()),
			presentation: .split
		)
		let focus = Workspace.onePane(
			id: id,
			paneID: paneID,
			host: split.topology.panes[0].host,
			presentation: .focus
		)

		XCTAssertEqual(split.id, focus.id)
		XCTAssertNotEqual(split, focus)
		XCTAssertEqual(Set([split, focus]).count, 2)
		XCTAssertEqual(
			WorkspaceWindowState.workspace(split),
			WorkspaceWindowState.workspace(focus)
		)
	}

	func testWindowStateRoundTripsWithoutRuntimeSessionIdentity() throws {
		let descriptor = try OneTimeConnectionDescriptor(
			displayName: "staging",
			hostname: "staging.example.com",
			port: 2222,
			username: "deploy"
		)
		let workspace = Workspace.onePane(host: .oneTime(descriptor))
		let state = WorkspaceWindowState.workspace(workspace)
		let runtimeSessionID = UUID()
		var runtime = WorkspaceRuntimeMap()
		try runtime.bind(
			sessionID: runtimeSessionID,
			to: workspace.activePaneID,
			in: workspace
		)

		let encoded = try JSONEncoder().encode(state)
		let body = try XCTUnwrap(String(data: encoded, encoding: .utf8))
		let decoded = try JSONDecoder().decode(WorkspaceWindowState.self, from: encoded)

		XCTAssertEqual(decoded.workspace?.id, workspace.id)
		XCTAssertEqual(decoded.workspace?.topology.panes.first?.host, .oneTime(descriptor))
		XCTAssertFalse(body.contains(runtimeSessionID.uuidString))
		XCTAssertNil(WorkspaceRuntimeMap().sessionID(
			for: workspace.activePaneID,
			in: workspace.id
		))
		XCTAssertEqual(runtime.sessionID(
			for: workspace.activePaneID,
			in: workspace.id
		), runtimeSessionID)
	}

	func testDecodedWorkspaceCanBindAFreshRuntimeSession() throws {
		let originalSessionID = UUID()
		let workspace = Workspace.onePane(host: .saved(id: UUID()))
		var originalRuntime = WorkspaceRuntimeMap()
		try originalRuntime.bind(
			sessionID: originalSessionID,
			to: workspace.activePaneID,
			in: workspace
		)
		let data = try JSONEncoder().encode(workspace)
		let restored = try JSONDecoder().decode(Workspace.self, from: data)
		let freshSessionID = UUID()
		var restoredRuntime = WorkspaceRuntimeMap()
		try restoredRuntime.bind(
			sessionID: freshSessionID,
			to: restored.activePaneID,
			in: restored
		)

		XCTAssertNotEqual(originalSessionID, freshSessionID)
		XCTAssertEqual(restoredRuntime.sessionID(
			for: restored.activePaneID,
			in: restored.id
		), freshSessionID)
	}

	func testRuntimeMapRejectsUnknownPaneAndDuplicateSessionOwnership() throws {
		let first = Workspace.onePane(host: .saved(id: UUID()))
		let second = Workspace.onePane(host: .saved(id: UUID()))
		let sessionID = UUID()
		var runtime = WorkspaceRuntimeMap()

		XCTAssertThrowsError(try runtime.bind(
			sessionID: sessionID,
			to: PaneID(rawValue: UUID()),
			in: first
		)) { error in
			XCTAssertEqual(error as? WorkspaceRuntimeMap.Error, .paneNotFound)
		}
		try runtime.bind(
			sessionID: sessionID,
			to: first.activePaneID,
			in: first
		)
		XCTAssertThrowsError(try runtime.bind(
			sessionID: sessionID,
			to: second.activePaneID,
			in: second
		)) { error in
			XCTAssertEqual(error as? WorkspaceRuntimeMap.Error, .sessionAlreadyBound)
		}
	}

	func testDecodingRejectsUnsupportedVersionAndInvalidActivePane() throws {
		let workspace = Workspace.onePane(host: .saved(id: UUID()))
		let encoded = try JSONEncoder().encode(workspace)
		let object = try XCTUnwrap(
			JSONSerialization.jsonObject(with: encoded) as? [String: Any]
		)

		var future = object
		future["version"] = Workspace.currentVersion + 1
		let futureData = try JSONSerialization.data(withJSONObject: future)
		XCTAssertThrowsError(try JSONDecoder().decode(Workspace.self, from: futureData))

		var invalidActive = object
		invalidActive["activePaneID"] = UUID().uuidString
		let invalidData = try JSONSerialization.data(withJSONObject: invalidActive)
		XCTAssertThrowsError(try JSONDecoder().decode(Workspace.self, from: invalidData))
	}

	func testDecodingIgnoresUnknownFutureFieldsWithinCurrentVersion() throws {
		let workspace = Workspace.onePane(host: .saved(id: UUID()))
		let encoded = try JSONEncoder().encode(workspace)
		var object = try XCTUnwrap(
			JSONSerialization.jsonObject(with: encoded) as? [String: Any]
		)
		object["futureDisplayPreference"] = ["accent": "mint"]
		let expanded = try JSONSerialization.data(withJSONObject: object)

		let decoded = try JSONDecoder().decode(Workspace.self, from: expanded)

		XCTAssertEqual(decoded.id, workspace.id)
		XCTAssertEqual(decoded.activePaneID, workspace.activePaneID)
	}

	func testOneTimeDescriptorRejectsInvalidEndpointData() {
		XCTAssertThrowsError(try OneTimeConnectionDescriptor(
			displayName: "bad",
			hostname: "",
			port: 22,
			username: "user"
		))
		XCTAssertThrowsError(try OneTimeConnectionDescriptor(
			displayName: "bad",
			hostname: "example.com",
			port: 70_000,
			username: "user"
		))
	}

	func testLandingAndWorkspaceWindowValuesUseDifferentIdentityDomains() {
		let raw = UUID()
		let landing = WorkspaceWindowState.landing(id: raw)
		let workspace = Workspace.onePane(
			id: WorkspaceID(rawValue: raw),
			host: .saved(id: UUID())
		)
		let workspaceState = WorkspaceWindowState.workspace(workspace)

		XCTAssertNotEqual(landing, workspaceState)
		XCTAssertNil(landing.workspaceID)
		XCTAssertEqual(workspaceState.workspaceID, workspace.id)
	}
}
