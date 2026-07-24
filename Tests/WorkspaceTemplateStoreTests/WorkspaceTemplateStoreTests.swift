import Foundation
import WorkspaceCore
import XCTest
@testable import WorkspaceTemplateStore

@MainActor
final class WorkspaceTemplateStoreTests: XCTestCase {
	func test_saveRenameDuplicateDeletePersistAcrossRestart() async throws {
		let directory = temporaryDirectory()
		let workspace = try makeWorkspace()
		let store = WorkspaceTemplateStore(directory: directory)

		let saved = try await store.save(workspace: workspace, name: "Production")
		try await store.rename(id: saved.id, to: "Primary")
		let duplicate = try await store.duplicate(id: saved.id)

		let reloaded = WorkspaceTemplateStore(directory: directory)
		try await reloaded.load()
		XCTAssertEqual(reloaded.templates.map(\.name), ["Primary", "Primary Copy"])

		try await reloaded.delete(id: duplicate.id)
		let afterDelete = WorkspaceTemplateStore(directory: directory)
		try await afterDelete.load()
		XCTAssertEqual(afterDelete.templates.map(\.name), ["Primary"])
	}

	func test_concurrentSavesPublishCompleteActorSnapshot() async throws {
		let directory = temporaryDirectory()
		let store = WorkspaceTemplateStore(directory: directory)
		let firstWorkspace = try makeWorkspace()
		let secondWorkspace = try makeWorkspace()

		async let first = store.save(workspace: firstWorkspace, name: "Alpha")
		async let second = store.save(workspace: secondWorkspace, name: "Beta")
		_ = try await (first, second)

		XCTAssertEqual(store.templates.map(\.name), ["Alpha", "Beta"])
		let reloaded = WorkspaceTemplateStore(directory: directory)
		try await reloaded.load()
		XCTAssertEqual(reloaded.templates.map(\.name), ["Alpha", "Beta"])
	}

	func test_permissionFailureDoesNotCommitTemplate() async throws {
		let directory = temporaryDirectory()
		let store = WorkspaceTemplateStore(
			directory: directory,
			permissionSetter: { _ in throw PermissionFailure() }
		)

		do {
			_ = try await store.save(workspace: makeWorkspace(), name: "Rejected")
			XCTFail("Expected permission failure")
		} catch {}

		XCTAssertTrue(store.templates.isEmpty)
		let records = directory.appendingPathComponent("WorkspaceTemplates", isDirectory: true)
		let files = try FileManager.default.contentsOfDirectory(
			at: records,
			includingPropertiesForKeys: nil
		).filter { $0.pathExtension == "json" }
		XCTAssertTrue(files.isEmpty)
	}

	func test_committedTemplateHasPrivateFilePermissions() async throws {
		let directory = temporaryDirectory()
		let store = WorkspaceTemplateStore(directory: directory)
		let template = try await store.save(workspace: makeWorkspace(), name: "Private")
		let url = directory
			.appendingPathComponent("WorkspaceTemplates", isDirectory: true)
			.appendingPathComponent("\(template.id.rawValue.uuidString).json")

		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
		XCTAssertEqual(permissions.intValue & 0o777, 0o600)
	}

	func test_openCreatesFreshWorkspaceAndPaneIdentities() throws {
		let hostIDs = [UUID(), UUID()]
		let template = try WorkspaceTemplate(
			workspace: makeWorkspace(hostIDs: hostIDs),
			name: "Operations"
		)

		let first = try template.instantiate(availableHostIDs: Set(hostIDs))
		let second = try template.instantiate(availableHostIDs: Set(hostIDs))

		XCTAssertNotEqual(first.workspace.id, second.workspace.id)
		XCTAssertEqual(first.workspace.presentation, .focus)
		XCTAssertEqual(first.workspace.topology.panes.compactMap(\.savedHostID), hostIDs)
		XCTAssertEqual(first.workspace.topology.split?.ratio, 0.35)
		XCTAssertNotEqual(first.workspace.topology.paneIDs, second.workspace.topology.paneIDs)
		XCTAssertNotEqual(first.workspace.topology.splitIDs, second.workspace.topology.splitIDs)
		XCTAssertEqual(first.workspace.activePaneID, first.workspace.topology.paneIDs[1])
		XCTAssertTrue(first.resolutions.allSatisfy { $0.availability == .available })
	}

	func test_missingHostIsPreservedByExactIdentity() throws {
		let present = UUID()
		let missing = UUID()
		let template = try WorkspaceTemplate(
			workspace: makeWorkspace(hostIDs: [present, missing]),
			name: "Mixed"
		)

		let opening = try template.instantiate(availableHostIDs: [present])

		XCTAssertEqual(opening.workspace.topology.panes.compactMap(\.savedHostID), [present, missing])
		XCTAssertEqual(opening.resolutions.map(\.availability), [.available, .missing])
		XCTAssertEqual(opening.resolutions.last?.savedHostID, missing)
	}

	func test_captureRejectsRuntimeOnlyAndIncompletePaneContent() throws {
		let descriptor = try OneTimeConnectionDescriptor(
			displayName: "Ephemeral",
			hostname: "example.test",
			port: 22,
			username: "root"
		)
		let oneTime = Workspace.onePane(host: .oneTime(descriptor))
		XCTAssertThrowsError(try WorkspaceTemplate(workspace: oneTime, name: "Unsafe")) {
			XCTAssertEqual($0 as? WorkspaceTemplateError, .oneTimeHostNotAllowed)
		}

		let connected = Workspace.onePane(host: .saved(id: UUID()))
		let incomplete = try connected.splittingActivePane(.right)
		XCTAssertThrowsError(try WorkspaceTemplate(workspace: incomplete, name: "Incomplete")) {
			XCTAssertEqual($0 as? WorkspaceTemplateError, .emptyPaneNotAllowed)
		}
	}

	func test_encodedTemplateContainsOnlyDeclarativeWhitelist() throws {
		let template = try WorkspaceTemplate(workspace: makeWorkspace(), name: "Safe")
		let data = try JSONEncoder().encode(template)
		let json = try XCTUnwrap(String(data: data, encoding: .utf8))

		for forbidden in [
			"credential", "password", "privateKey", "output", "scrollback",
			"clipboard", "socket", "pid", "sessionID", "reconnect", "broadcast",
			"workingDirectory", "startupCommand"
		] {
			XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden), forbidden)
		}
		XCTAssertTrue(json.contains("savedHostID"))
	}

	func test_loadMigratesVersionOneRecord() async throws {
		let directory = temporaryDirectory()
		let records = directory.appendingPathComponent("WorkspaceTemplates", isDirectory: true)
		try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
		let paneID = UUID()
		let hostID = UUID()
		let templateID = UUID()
		let json = """
		{
		  "version": 1,
		  "id": "\(templateID.uuidString)",
		  "name": "Legacy",
		  "topology": {
		    "kind": "pane",
		    "pane": {
		      "id": "\(paneID.uuidString)",
		      "savedHostID": "\(hostID.uuidString)"
		    }
		  }
		}
		"""
		try Data(json.utf8).write(to: records.appendingPathComponent("legacy.json"))

		let store = WorkspaceTemplateStore(directory: directory)
		try await store.load()

		let migrated = try XCTUnwrap(store.templates.first)
		XCTAssertEqual(migrated.version, WorkspaceTemplate.currentVersion)
		XCTAssertEqual(migrated.initialPresentation, .split)
		XCTAssertEqual(migrated.preferredPaneID, PaneID(rawValue: paneID))
		let migratedURL = records.appendingPathComponent("\(templateID.uuidString).json")
		let migratedData = try Data(contentsOf: migratedURL)
		let migratedJSON = try XCTUnwrap(String(data: migratedData, encoding: .utf8))
		XCTAssertTrue(migratedJSON.contains("\"version\" : 2"))
		XCTAssertFalse(FileManager.default.fileExists(
			atPath: records.appendingPathComponent("legacy.json").path
		))
	}

	func test_loadQuarantinesDuplicateTemplateIdentity() async throws {
		let directory = temporaryDirectory()
		let store = WorkspaceTemplateStore(directory: directory)
		let saved = try await store.save(workspace: makeWorkspace(), name: "Original")
		let records = directory.appendingPathComponent("WorkspaceTemplates", isDirectory: true)
		let canonical = records.appendingPathComponent("\(saved.id.rawValue.uuidString).json")
		try FileManager.default.copyItem(
			at: canonical,
			to: records.appendingPathComponent("duplicate.json")
		)

		let reloaded = WorkspaceTemplateStore(directory: directory)
		try await reloaded.load()

		XCTAssertEqual(reloaded.templates.map(\.id), [saved.id])
		XCTAssertEqual(reloaded.quarantinedRecordCount, 1)
	}

	func test_loadPrefersCanonicalRecordOverDifferingDuplicate() async throws {
		let directory = temporaryDirectory()
		let store = WorkspaceTemplateStore(directory: directory)
		let saved = try await store.save(workspace: makeWorkspace(), name: "Canonical")
		let records = directory.appendingPathComponent("WorkspaceTemplates", isDirectory: true)
		let canonical = records.appendingPathComponent("\(saved.id.rawValue.uuidString).json")
		let data = try Data(contentsOf: canonical)
		var object = try XCTUnwrap(
			JSONSerialization.jsonObject(with: data) as? [String: Any]
		)
		object["name"] = "Imposter"
		try JSONSerialization.data(withJSONObject: object).write(
			to: records.appendingPathComponent("000-duplicate.json")
		)

		let reloaded = WorkspaceTemplateStore(directory: directory)
		try await reloaded.load()

		XCTAssertEqual(reloaded.templates.map(\.name), ["Canonical"])
		XCTAssertEqual(reloaded.quarantinedRecordCount, 1)
	}

	func test_nonCanonicalRecordNormalizesAndCannotResurrectAfterDelete() async throws {
		let directory = temporaryDirectory()
		let store = WorkspaceTemplateStore(directory: directory)
		let saved = try await store.save(workspace: makeWorkspace(), name: "Movable")
		let records = directory.appendingPathComponent("WorkspaceTemplates", isDirectory: true)
		let canonical = records.appendingPathComponent("\(saved.id.rawValue.uuidString).json")
		let moved = records.appendingPathComponent("backup.json")
		try FileManager.default.moveItem(at: canonical, to: moved)

		let normalized = WorkspaceTemplateStore(directory: directory)
		try await normalized.load()
		XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))

		try await normalized.rename(id: saved.id, to: "Renamed")
		let renamed = WorkspaceTemplateStore(directory: directory)
		try await renamed.load()
		XCTAssertEqual(renamed.templates.map(\.name), ["Renamed"])

		try await renamed.delete(id: saved.id)
		let deleted = WorkspaceTemplateStore(directory: directory)
		try await deleted.load()
		XCTAssertTrue(deleted.templates.isEmpty)
	}

	func test_loadQuarantinesCurrentRecordWithRuntimeField() async throws {
		let directory = temporaryDirectory()
		let store = WorkspaceTemplateStore(directory: directory)
		let valid = try await store.save(workspace: makeWorkspace(), name: "Valid")
		let records = directory.appendingPathComponent("WorkspaceTemplates", isDirectory: true)
		let canonical = records.appendingPathComponent("\(valid.id.rawValue.uuidString).json")
		let data = try Data(contentsOf: canonical)
		var object = try XCTUnwrap(
			JSONSerialization.jsonObject(with: data) as? [String: Any]
		)
		object["sessionID"] = UUID().uuidString
		try JSONSerialization.data(withJSONObject: object).write(
			to: records.appendingPathComponent("malicious.json")
		)

		let reloaded = WorkspaceTemplateStore(directory: directory)
		try await reloaded.load()

		XCTAssertEqual(reloaded.templates.map(\.id), [valid.id])
		XCTAssertEqual(reloaded.quarantinedRecordCount, 1)
	}

	func test_decodeRejectsPayloadHiddenInInactiveTopologyBranch() throws {
		let template = try WorkspaceTemplate(
			workspace: Workspace.onePane(host: .saved(id: UUID())),
			name: "Strict"
		)
		let data = try JSONEncoder().encode(template)
		var object = try XCTUnwrap(
			JSONSerialization.jsonObject(with: data) as? [String: Any]
		)
		var topology = try XCTUnwrap(object["topology"] as? [String: Any])
		topology["split"] = ["startupCommand": "curl example.invalid"]
		object["topology"] = topology
		let malicious = try JSONSerialization.data(withJSONObject: object)

		XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceTemplate.self, from: malicious)) {
			XCTAssertEqual($0 as? WorkspaceTemplateError, .unexpectedField("split"))
		}
	}

	func test_unreadableRecordDoesNotBlockValidTemplates() async throws {
		let directory = temporaryDirectory()
		let store = WorkspaceTemplateStore(directory: directory)
		let valid = try await store.save(workspace: makeWorkspace(), name: "Valid")
		let records = directory.appendingPathComponent("WorkspaceTemplates", isDirectory: true)
		try FileManager.default.createDirectory(
			at: records.appendingPathComponent("unreadable.json", isDirectory: true),
			withIntermediateDirectories: false
		)

		let reloaded = WorkspaceTemplateStore(directory: directory)
		try await reloaded.load()

		XCTAssertEqual(reloaded.templates.map(\.id), [valid.id])
		XCTAssertEqual(reloaded.recordIssueCount, 1)
		XCTAssertEqual(reloaded.quarantinedRecordCount, 0)
	}

	func test_loadQuarantinesBadRecordsWithoutHarmingValidTemplates() async throws {
		let directory = temporaryDirectory()
		let store = WorkspaceTemplateStore(directory: directory)
		let valid = try await store.save(workspace: makeWorkspace(), name: "Valid")
		let records = directory.appendingPathComponent("WorkspaceTemplates", isDirectory: true)
		try Data("not json".utf8).write(to: records.appendingPathComponent("corrupt.json"))
		let future = """
		{"version":999,"id":"\(UUID().uuidString)","name":"Future","topology":{}}
		"""
		try Data(future.utf8).write(to: records.appendingPathComponent("future.json"))

		let reloaded = WorkspaceTemplateStore(directory: directory)
		try await reloaded.load()

		XCTAssertEqual(reloaded.templates.map(\.id), [valid.id])
		XCTAssertEqual(reloaded.quarantinedRecordCount, 2)
		let quarantined = try FileManager.default.contentsOfDirectory(
			at: records.appendingPathComponent("Quarantine", isDirectory: true),
			includingPropertiesForKeys: nil
		)
		XCTAssertEqual(quarantined.count, 2)
	}

	private func makeWorkspace(hostIDs: [UUID] = [UUID(), UUID()]) throws -> Workspace {
		let first = PaneID()
		let second = PaneID()
		return try Workspace(
			id: WorkspaceID(),
			topology: .split(WorkspaceSplit(
				axis: .horizontal,
				ratio: 0.35,
				first: .pane(WorkspacePane(id: first, host: .saved(id: hostIDs[0]))),
				second: .pane(WorkspacePane(id: second, host: .saved(id: hostIDs[1])))
			)),
			activePaneID: second,
			presentation: .focus
		)
	}

	private func temporaryDirectory() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("WorkspaceTemplateStoreTests-\(UUID().uuidString)", isDirectory: true)
	}
}

private struct PermissionFailure: Error {}

private extension WorkspacePane {
	var savedHostID: UUID? {
		guard case .saved(let id) = host else { return nil }
		return id
	}
}
