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

	func testWindowIdentityStaysStableWhileWorkspaceValueTracksPresentation() throws {
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
			host: try XCTUnwrap(split.topology.panes[0].host),
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

	func testSeveralWindowStatesRestoreStableSafeLayoutWithoutRuntimeContinuity() throws {
		let firstHostID = UUID()
		let secondHostID = UUID()
		var first = Workspace.onePane(host: .saved(id: firstHostID))
		first = try first.splittingActivePane(.right)
		first = try first.assigningHost(.saved(id: secondHostID), to: first.activePaneID)
		let splitID = try XCTUnwrap(first.topology.splitIDs.first)
		first = try first.updatingSplitRatio(0.37, splitID: splitID)
		first = first.togglingPresentation()
		let second = Workspace.onePane(host: .saved(id: UUID()))
		let landingID = UUID()
		let states = [
			WorkspaceWindowState.workspace(first),
			WorkspaceWindowState.workspace(second),
			WorkspaceWindowState.landing(id: landingID),
		]
		let runtimeSessionIDs = [UUID(), UUID(), UUID()]
		var runtime = WorkspaceRuntimeMap()
		for (pane, sessionID) in zip(first.topology.panes, runtimeSessionIDs) {
			try runtime.bind(sessionID: sessionID, to: pane.id, in: first)
		}

		let data = try JSONEncoder().encode(states)
		let body = try XCTUnwrap(String(data: data, encoding: .utf8))
		let restored = try JSONDecoder().decode(
			[WorkspaceWindowState].self,
			from: data
		)

		XCTAssertEqual(restored.count, 3)
		XCTAssertEqual(restored[0].workspace?.id, first.id)
		XCTAssertEqual(restored[0].workspace?.topology, first.topology)
		XCTAssertEqual(restored[0].workspace?.activePaneID, first.activePaneID)
		XCTAssertEqual(restored[0].workspace?.presentation, .focus)
		XCTAssertEqual(restored[1].workspace?.id, second.id)
		XCTAssertEqual(restored[2], .landing(id: landingID))
		for sessionID in runtimeSessionIDs {
			XCTAssertFalse(body.contains(sessionID.uuidString))
		}
		XCTAssertTrue(body.contains(firstHostID.uuidString))
		XCTAssertTrue(body.contains(secondHostID.uuidString))
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

	func testVersionOneOnePaneFixtureStillDecodes() throws {
		let workspaceID = UUID()
		let paneID = UUID()
		let hostID = UUID()
		let fixture = """
		{
		  "version": 1,
		  "id": "\(workspaceID.uuidString)",
		  "topology": {
		    "kind": "pane",
		    "pane": {
		      "id": "\(paneID.uuidString)",
		      "host": {
		        "kind": "saved",
		        "savedHostID": "\(hostID.uuidString)"
		      }
		    }
		  },
		  "activePaneID": "\(paneID.uuidString)",
		  "presentation": "split"
		}
		"""

		let workspace = try JSONDecoder().decode(
			Workspace.self,
			from: Data(fixture.utf8)
		)

		XCTAssertEqual(workspace.version, 1)
		XCTAssertEqual(workspace.id, WorkspaceID(rawValue: workspaceID))
		XCTAssertEqual(workspace.activePaneID, PaneID(rawValue: paneID))
		XCTAssertEqual(workspace.topology.panes.first?.host, .saved(id: hostID))
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

	func testSplitRightReplacesActiveLeafWithHostPickerAndFocusesIt() throws {
		let originalPaneID = PaneID(rawValue: UUID())
		let newPaneID = PaneID(rawValue: UUID())
		let splitID = SplitID(rawValue: UUID())
		let original = Workspace.onePane(
			paneID: originalPaneID,
			host: .saved(id: UUID())
		)

		let split = try original.splittingActivePane(
			.right,
			newPaneID: newPaneID,
			splitID: splitID
		)

		XCTAssertEqual(split.id, original.id)
		XCTAssertEqual(split.activePaneID, newPaneID)
		XCTAssertEqual(split.topology.paneIDs, [originalPaneID, newPaneID])
		let root = try XCTUnwrap(split.topology.split)
		XCTAssertEqual(root.id, splitID)
		XCTAssertEqual(root.axis, .horizontal)
		XCTAssertEqual(root.ratio, 0.5)
		XCTAssertEqual(split.topology.pane(id: originalPaneID)?.host,
		               original.topology.pane(id: originalPaneID)?.host)
		XCTAssertEqual(split.topology.pane(id: newPaneID)?.content, .hostPicker)
	}

	func testNestedSplitDownKeepsEveryPaneIdentityUnique() throws {
		let first = PaneID(rawValue: UUID())
		let second = PaneID(rawValue: UUID())
		let third = PaneID(rawValue: UUID())
		let original = Workspace.onePane(paneID: first, host: .saved(id: UUID()))
		let horizontal = try original.splittingActivePane(.right, newPaneID: second)
		let secondConnected = try horizontal.assigningHost(.saved(id: UUID()), to: second)

		let nested = try secondConnected.splittingActivePane(.down, newPaneID: third)

		XCTAssertEqual(nested.topology.paneCount, 3)
		XCTAssertEqual(Set(nested.topology.paneIDs).count, 3)
		XCTAssertEqual(nested.activePaneID, third)
		let root = try XCTUnwrap(nested.topology.split)
		XCTAssertEqual(root.axis, .horizontal)
		XCTAssertEqual(root.second.split?.axis, .vertical)
	}

	func testSplitRatioClampsAndRoundTrips() throws {
		let splitID = SplitID(rawValue: UUID())
		let original = Workspace.onePane(host: .saved(id: UUID()))
		let split = try original.splittingActivePane(.right, splitID: splitID)

		let tooSmall = try split.updatingSplitRatio(-10, splitID: splitID)
		let tooLarge = try split.updatingSplitRatio(10, splitID: splitID)
		let decoded = try JSONDecoder().decode(
			Workspace.self,
			from: JSONEncoder().encode(tooLarge)
		)

		XCTAssertEqual(tooSmall.topology.split?.ratio, WorkspaceSplit.minimumRatio)
		XCTAssertEqual(tooLarge.topology.split?.ratio, WorkspaceSplit.maximumRatio)
		XCTAssertEqual(decoded, tooLarge)
		XCTAssertThrowsError(try split.updatingSplitRatio(.nan, splitID: splitID))
	}

	func testAssigningHostChangesOnlyPickerPane() throws {
		let pickerID = PaneID(rawValue: UUID())
		let originalHost = WorkspaceHostReference.saved(id: UUID())
		let selectedHost = WorkspaceHostReference.saved(id: UUID())
		let original = Workspace.onePane(host: originalHost)
		let split = try original.splittingActivePane(.down, newPaneID: pickerID)

		let connected = try split.assigningHost(selectedHost, to: pickerID)

		XCTAssertEqual(connected.topology.pane(id: pickerID)?.host, selectedHost)
		XCTAssertEqual(connected.topology.panes.first?.host, originalHost)
		XCTAssertThrowsError(try connected.assigningHost(selectedHost, to: pickerID))
	}

	func testReplacingHostPreservesPaneAndWorkspaceIdentity() throws {
		let paneID = PaneID(rawValue: UUID())
		let originalHost = WorkspaceHostReference.saved(id: UUID())
		let replacementHost = WorkspaceHostReference.saved(id: UUID())
		let workspace = Workspace.onePane(paneID: paneID, host: originalHost)

		let replaced = try workspace.replacingHost(replacementHost, in: paneID)

		XCTAssertEqual(replaced.id, workspace.id)
		XCTAssertEqual(replaced.activePaneID, paneID)
		XCTAssertEqual(replaced.topology.pane(id: paneID)?.host, replacementHost)
		XCTAssertThrowsError(try workspace.replacingHost(replacementHost, in: PaneID()))
	}

	func testDirectionalAndCyclicFocusUseTopologyGeometry() throws {
		let topLeft = PaneID(rawValue: UUID())
		let topRight = PaneID(rawValue: UUID())
		let bottomLeft = PaneID(rawValue: UUID())
		let bottomRight = PaneID(rawValue: UUID())
		let host = WorkspaceHostReference.saved(id: UUID())
		let top = WorkspaceTopology.split(WorkspaceSplit(
			axis: .horizontal,
			first: .pane(WorkspacePane(id: topLeft, host: host)),
			second: .pane(WorkspacePane(id: topRight, host: host))
		))
		let bottom = WorkspaceTopology.split(WorkspaceSplit(
			axis: .horizontal,
			first: .pane(WorkspacePane(id: bottomLeft, host: host)),
			second: .pane(WorkspacePane(id: bottomRight, host: host))
		))
		let workspace = try Workspace(
			id: WorkspaceID(),
			topology: .split(WorkspaceSplit(axis: .vertical, first: top, second: bottom)),
			activePaneID: topLeft,
			presentation: .split
		)

		XCTAssertEqual(workspace.focusing(.right).activePaneID, topRight)
		XCTAssertEqual(workspace.focusing(.down).activePaneID, bottomLeft)
		XCTAssertEqual(workspace.focusing(.left).activePaneID, topLeft)
		XCTAssertEqual(workspace.focusing(.up).activePaneID, topLeft)
		XCTAssertEqual(workspace.cyclingFocus(.previous).activePaneID, bottomRight)
		XCTAssertEqual(workspace.cyclingFocus(.next).activePaneID, topRight)
	}

	func testClosingPaneCollapsesParentAndFocusesNearestSibling() throws {
		let first = PaneID(rawValue: UUID())
		let second = PaneID(rawValue: UUID())
		let third = PaneID(rawValue: UUID())
		let original = Workspace.onePane(paneID: first, host: .saved(id: UUID()))
		let two = try original.splittingActivePane(.right, newPaneID: second)
		let connected = try two.assigningHost(.saved(id: UUID()), to: second)
		let three = try connected.splittingActivePane(.down, newPaneID: third)

		let result = three.closingActivePane()
		let collapsed = try XCTUnwrap(result.workspace)

		XCTAssertEqual(result.closedPaneID, third)
		XCTAssertEqual(collapsed.topology.paneIDs, [first, second])
		XCTAssertEqual(collapsed.activePaneID, second)
		XCTAssertEqual(collapsed.topology.split?.axis, .horizontal)
	}

	func testClosingFinalPaneRequestsNativeWindowClosure() {
		let paneID = PaneID(rawValue: UUID())
		let workspace = Workspace.onePane(paneID: paneID, host: .saved(id: UUID()))

		let result = workspace.closingActivePane()

		XCTAssertTrue(result.shouldCloseWindow)
		XCTAssertEqual(result.closedPaneID, paneID)
		XCTAssertNil(result.workspace)
	}

	func testLegalOperationSequencePreservesCodecAndPaneInvariants() throws {
		let second = PaneID(rawValue: UUID())
		let third = PaneID(rawValue: UUID())
		var workspace = Workspace.onePane(host: .saved(id: UUID()))
		workspace = try workspace.splittingActivePane(.right, newPaneID: second)
		workspace = try workspace.assigningHost(.saved(id: UUID()), to: second)
		workspace = try workspace.splittingActivePane(.down, newPaneID: third)
		workspace = try workspace.assigningHost(.saved(id: UUID()), to: third)
		workspace = workspace.focusing(.left)
		workspace = workspace.togglingPresentation()
		workspace = try XCTUnwrap(workspace.closingActivePane().workspace)

		let restored = try JSONDecoder().decode(
			Workspace.self,
			from: JSONEncoder().encode(workspace)
		)

		XCTAssertEqual(restored, workspace)
		XCTAssertEqual(Set(restored.topology.paneIDs).count, restored.topology.paneCount)
		XCTAssertTrue(restored.topology.contains(restored.activePaneID))
		XCTAssertEqual(restored.presentation, .focus)
	}
}
