import SessionStore
import SSHCommandBuilder
@testable import CatermMobile
import XCTest

@MainActor
final class MobileHostStoreTests: XCTestCase {
	private func tempURL() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("mobile-hosts-\(UUID().uuidString).json")
	}

	private func makeHost(_ name: String) -> SSHHost {
		SSHHost(
			id: UUID(),
			name: name,
			hostname: "\(name).example.com",
			username: "deploy",
			credential: .agent
		)
	}

	func testLoadsEmptyWhenFileMissing() {
		let store = MobileHostStore(fileURL: tempURL())
		XCTAssertTrue(store.hosts.isEmpty)
	}

	func testAddPersistsAndReloadsFromSameFile() throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		let host = makeHost("prod")

		try store.add(host)

		XCTAssertEqual(store.hosts.map(\.id), [host.id])
		// A fresh store over the same file sees the persisted host: this is
		// the macOS-shared JSON format, so desktop/CloudKit stay consistent.
		let reloaded = MobileHostStore(fileURL: url)
		XCTAssertEqual(reloaded.hosts.map(\.id), [host.id])
	}

	func testUpdateReplacesHostInPlaceAndPersists() throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		var host = makeHost("prod")
		try store.add(host)

		host.name = "Renamed"
		try store.update(host)

		XCTAssertEqual(store.hosts.first?.name, "Renamed")
		XCTAssertEqual(MobileHostStore(fileURL: url).hosts.first?.name, "Renamed")
	}

	func testUpdateUnknownHostThrows() throws {
		let store = MobileHostStore(fileURL: tempURL())
		XCTAssertThrowsError(try store.update(makeHost("ghost"))) { error in
			XCTAssertEqual(error as? MobileHostStore.StoreError, .hostNotFound)
		}
	}

	func testBindingSetterPersists() throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		let host = makeHost("via-binding")

		store.binding.wrappedValue.append(host)

		XCTAssertEqual(store.hosts.map(\.id), [host.id])
		XCTAssertEqual(MobileHostStore(fileURL: url).hosts.map(\.id), [host.id])
	}

	func testDeleteRemovesAndPersists() throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		let a = makeHost("a")
		let b = makeHost("b")
		try store.add(a)
		try store.add(b)

		try store.delete(id: a.id)

		XCTAssertEqual(store.hosts.map(\.id), [b.id])
		XCTAssertEqual(MobileHostStore(fileURL: url).hosts.map(\.id), [b.id])
	}
}
