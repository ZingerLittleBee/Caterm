import XCTest
@testable import SSHCommandBuilder

final class PortForwardValidationTests: XCTestCase {

	func test_local_happyPath() throws {
		let f = PortForward(kind: .local, bindPort: 5432,
							remoteHost: "db.internal", remotePort: 5432)
		XCTAssertNoThrow(try f.validate())
	}

	func test_dynamic_happyPath() throws {
		let f = PortForward(kind: .dynamic, bindPort: 1080)
		XCTAssertNoThrow(try f.validate())
	}

	func test_bindPort_belowRange_throws() {
		let f = PortForward(kind: .local, bindPort: 0,
							remoteHost: "h", remotePort: 22)
		XCTAssertThrowsError(try f.validate()) { error in
			XCTAssertEqual(error as? PortForward.ValidationError,
						   .bindPortOutOfRange(0))
		}
	}

	func test_bindPort_aboveRange_throws() {
		let f = PortForward(kind: .local, bindPort: 65_536,
							remoteHost: "h", remotePort: 22)
		XCTAssertThrowsError(try f.validate()) { error in
			XCTAssertEqual(error as? PortForward.ValidationError,
						   .bindPortOutOfRange(65_536))
		}
	}

	func test_local_missingRemote_throws() {
		let f = PortForward(kind: .local, bindPort: 5432)
		XCTAssertThrowsError(try f.validate()) { error in
			XCTAssertEqual(error as? PortForward.ValidationError,
						   .missingRemoteForLocalOrRemote)
		}
	}

	func test_remote_missingPort_throws() {
		let f = PortForward(kind: .remote, bindPort: 9090,
							remoteHost: "h", remotePort: nil)
		XCTAssertThrowsError(try f.validate()) { error in
			XCTAssertEqual(error as? PortForward.ValidationError,
						   .missingRemoteForLocalOrRemote)
		}
	}

	func test_dynamic_withRemoteHost_throws() {
		let f = PortForward(kind: .dynamic, bindPort: 1080,
							remoteHost: "h", remotePort: nil)
		XCTAssertThrowsError(try f.validate()) { error in
			XCTAssertEqual(error as? PortForward.ValidationError,
						   .unexpectedRemoteForDynamic)
		}
	}

	func test_collection_duplicateBindings_throws() {
		let f1 = PortForward(kind: .local, bindPort: 5432,
							 remoteHost: "a", remotePort: 5432)
		let f2 = PortForward(kind: .local, bindPort: 5432,
							 remoteHost: "b", remotePort: 5432)
		XCTAssertThrowsError(try PortForward.validateCollection([f1, f2])) { error in
			guard case .duplicateBinding(let k, let addr, let port) =
					(error as? PortForward.ValidationError)
			else { return XCTFail("wrong error: \(error)") }
			XCTAssertEqual(k, .local)
			XCTAssertEqual(addr, "localhost")
			XCTAssertEqual(port, 5432)
		}
	}

	func test_collection_differentBindAddressNotDuplicate() throws {
		let f1 = PortForward(kind: .local, bindAddress: nil,  bindPort: 5432,
							 remoteHost: "a", remotePort: 5432)
		let f2 = PortForward(kind: .local, bindAddress: "*",  bindPort: 5432,
							 remoteHost: "a", remotePort: 5432)
		XCTAssertNoThrow(try PortForward.validateCollection([f1, f2]))
	}
}
