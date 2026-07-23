import CredentialIdentityStore
import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct CredentialIdentityStoreTests {
	@Test
	func persistsVersionedIdentityAndOutboxState() throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let materialID = CredentialMaterialID()
		let identity = CredentialIdentity(
			id: UUID(),
			name: "Production",
			username: "deploy",
			source: .managedKey(
				materialID: materialID,
				hasPassphrase: true
			)
		)

		try fixture.store.upsert(identity)

		let reloaded = CredentialIdentityStore(fileURL: fixture.fileURL)
		try reloaded.load()
		#expect(reloaded.identities == [identity])
		#expect(reloaded.locallyDirtyIdentityIDs == [identity.id])
		#expect(reloaded.pendingDeletedIdentityIDs.isEmpty)
	}

	@Test
	func editingPreservesStableIdentityAndMaterialReferences() throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let firstDate = Date(timeIntervalSince1970: 10)
		let secondDate = Date(timeIntervalSince1970: 20)
		var dates = [firstDate, secondDate]
		let store = CredentialIdentityStore(
			fileURL: fixture.fileURL,
			now: { dates.removeFirst() }
		)
		let materialID = CredentialMaterialID()
		var identity = CredentialIdentity(
			id: UUID(),
			name: "Original",
			username: "root",
			source: .password(materialID: materialID),
			createdAt: firstDate,
			updatedAt: firstDate
		)
		try store.upsert(identity)
		identity.name = "Renamed"
		try store.upsert(identity)

		let stored = try #require(store.identity(id: identity.id))
		#expect(stored.id == identity.id)
		#expect(stored.source.materialID == materialID)
		#expect(stored.createdAt == firstDate)
		#expect(stored.updatedAt == firstDate)
		#expect(stored.revision == 2)
	}

	@Test
	func refusesDeletionWhileHostsReferenceIdentity() throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let identity = CredentialIdentity(
			name: "Shared",
			username: "ops",
			source: .password(materialID: CredentialMaterialID())
		)
		try fixture.store.upsert(identity)
		let hostIDs: Set<UUID> = [UUID(), UUID()]

		#expect(throws: CredentialIdentityStoreError.identityInUse(
			identityID: identity.id,
			hostIDs: hostIDs
		)) {
			try fixture.store.delete(
				id: identity.id,
				assignedHostIDs: hostIDs
			)
		}
		#expect(fixture.store.identity(id: identity.id) != nil)
	}

	@Test
	func deletionCreatesDurableTombstoneWithoutMaterialExposure() throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let identity = CredentialIdentity(
			name: "Disposable",
			username: "tester",
			source: .secureEnclaveP256(
				materialID: CredentialMaterialID(),
				publicKey: Data([1, 2, 3]),
				originDeviceID: UUID()
			)
		)
		try fixture.store.upsert(identity)
		try fixture.store.delete(id: identity.id)

		let reloaded = CredentialIdentityStore(fileURL: fixture.fileURL)
		try reloaded.load()
		#expect(reloaded.identities.isEmpty)
		#expect(reloaded.locallyDirtyIdentityIDs.isEmpty)
		#expect(reloaded.pendingDeletedIdentityIDs == [identity.id])
	}

	@Test
	func remoteMergeUsesRevisionThenTimestampAndClearsDirtyState() throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let id = UUID()
		let materialID = CredentialMaterialID()
		let local = CredentialIdentity(
			id: id,
			name: "Local",
			username: "ops",
			source: .password(materialID: materialID),
			updatedAt: Date(timeIntervalSince1970: 20),
			revision: 2
		)
		try fixture.store.upsert(local)
		let stale = CredentialIdentity(
			id: id,
			name: "Stale",
			username: "ops",
			source: .password(materialID: materialID),
			updatedAt: Date(timeIntervalSince1970: 30),
			revision: 1
		)
		#expect(try !fixture.store.applyRemote(stale))
		let remote = CredentialIdentity(
			id: id,
			name: "Remote",
			username: "ops",
			source: .password(materialID: materialID),
			updatedAt: Date(timeIntervalSince1970: 30),
			revision: 3
		)
		#expect(try fixture.store.applyRemote(remote))
		#expect(fixture.store.identity(id: id)?.name == "Remote")
		#expect(!fixture.store.locallyDirtyIdentityIDs.contains(id))
	}

	@Test
	func rejectsDuplicateMaterialReferencesOnLoad() throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let materialID = CredentialMaterialID()
		let first = CredentialIdentity(
			name: "One",
			username: "one",
			source: .password(materialID: materialID)
		)
		let second = CredentialIdentity(
			name: "Two",
			username: "two",
			source: .managedKey(
				materialID: materialID,
				hasPassphrase: false
			)
		)
		try fixture.store.upsert(first)

		#expect(throws: CredentialIdentityStoreError.duplicateMaterialID(
			materialID
		)) {
			try fixture.store.upsert(second)
		}
		#expect(fixture.store.identities == [first])
	}

	@Test
	func accountResetClearsMetadataWithoutCloudTombstones() throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let identity = CredentialIdentity(
			name: "Previous Account",
			username: "ops",
			source: .password(materialID: CredentialMaterialID())
		)
		try fixture.store.upsert(identity)
		try fixture.store.delete(id: identity.id)
		let replacement = CredentialIdentity(
			name: "Pending Upload",
			username: "deploy",
			source: .password(materialID: CredentialMaterialID())
		)
		try fixture.store.upsert(replacement)

		try fixture.store.resetForAccountChange()

		#expect(fixture.store.identities.isEmpty)
		#expect(fixture.store.locallyDirtyIdentityIDs.isEmpty)
		#expect(fixture.store.pendingDeletedIdentityIDs.isEmpty)
		let reloaded = CredentialIdentityStore(fileURL: fixture.fileURL)
		try reloaded.load()
		#expect(reloaded.identities.isEmpty)
		#expect(reloaded.pendingDeletedIdentityIDs.isEmpty)
	}
}

@MainActor
private struct Fixture {
	let rootURL: URL
	let fileURL: URL
	let store: CredentialIdentityStore

	init() throws {
		rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
			"credential-identities-\(UUID().uuidString)",
			isDirectory: true
		)
		fileURL = rootURL.appendingPathComponent("identities.json")
		store = CredentialIdentityStore(fileURL: fileURL)
	}

	func cleanup() {
		try? FileManager.default.removeItem(at: rootURL)
	}
}
