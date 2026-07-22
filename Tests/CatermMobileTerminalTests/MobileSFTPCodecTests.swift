import Foundation
@testable import CatermMobileTerminal
import XCTest

final class MobileSFTPCodecTests: XCTestCase {
	func testDecodesFileDataResponse() throws {
		var payload = Data()
		payload.append(contentsOf: [0, 0, 0, 4])
		payload.append(Data("data".utf8))

		let response = try MobileSFTPCodec.decodeResponse(type: 103, payload: payload)

		guard case .data(let bytes) = response else {
			return XCTFail("Expected an SFTP DATA response")
		}
		XCTAssertEqual(bytes, Data("data".utf8))
	}

	func testDecodesNameAttributesFromSFTPV3Response() throws {
		var payload = Data()
		payload.appendUInt32(1)
		payload.appendString("hello.txt")
		payload.appendString("-rw-r--r-- hello.txt")
		payload.appendUInt32(0x1 | 0x4 | 0x8)
		payload.appendUInt64(12)
		payload.appendUInt32(0o100644)
		payload.appendUInt32(1_700_000_000)
		payload.appendUInt32(1_700_000_123)

		let response = try MobileSFTPCodec.decodeResponse(type: 104, payload: payload)

		guard case .names(let names) = response else {
			return XCTFail("Expected an SFTP NAME response")
		}
		let entry = try XCTUnwrap(names.first?.entry(parent: "/home/caterm"))
		XCTAssertEqual(entry.name, "hello.txt")
		XCTAssertEqual(entry.path, "/home/caterm/hello.txt")
		XCTAssertFalse(entry.isDirectory)
		XCTAssertEqual(entry.size, 12)
		XCTAssertEqual(entry.permissions, 0o644)
		XCTAssertEqual(
			entry.modificationDate,
			Date(timeIntervalSince1970: 1_700_000_123)
		)
	}

	func testMapsPermissionAndEndOfDirectoryStatuses() throws {
		var deniedPayload = Data()
		deniedPayload.appendUInt32(3)
		deniedPayload.appendString("Permission denied")
		deniedPayload.appendString("")
		let denied = try MobileSFTPCodec.decodeResponse(
			type: 101,
			payload: deniedPayload
		)
		XCTAssertEqual(
			denied.error(path: "/root"),
			.permissionDenied(message: "Permission denied")
		)

		var eofPayload = Data()
		eofPayload.appendUInt32(1)
		eofPayload.appendString("End of file")
		eofPayload.appendString("")
		let eof = try MobileSFTPCodec.decodeResponse(type: 101, payload: eofPayload)
		guard case .status(let status) = eof else {
			return XCTFail("Expected an SFTP STATUS response")
		}
		XCTAssertEqual(status.code, 1)
	}

	func testGenericFailureStatusRetainsStatusForPostflightDiagnosis() throws {
		var payload = Data()
		payload.appendUInt32(4)
		payload.appendString("Failure")
		payload.appendString("")

		let response = try MobileSFTPCodec.decodeResponse(type: 101, payload: payload)

		XCTAssertEqual(
			response.error(path: "/readonly/item"),
			.failure(path: "/readonly/item", message: "Failure")
		)
	}

	func testDecodesStatAttributesResponse() throws {
		var payload = Data()
		payload.appendUInt32(0x1 | 0x4 | 0x8)
		payload.appendUInt64(42)
		payload.appendUInt32(0o040755)
		payload.appendUInt32(1_700_000_000)
		payload.appendUInt32(1_700_000_123)

		let response = try MobileSFTPCodec.decodeResponse(type: 105, payload: payload)

		guard case .attributes(let attributes) = response else {
			return XCTFail("Expected an SFTP ATTRS response")
		}
		XCTAssertEqual(attributes.type, .directory)
		XCTAssertEqual(attributes.size, 42)
		XCTAssertEqual(attributes.permissions, 0o040755)
		XCTAssertEqual(
			attributes.modificationDate,
			Date(timeIntervalSince1970: 1_700_000_123)
		)
	}

	func testPreservesUnknownMetadataInsteadOfInventingFileValues() throws {
		var payload = Data()
		payload.appendUInt32(1)
		payload.appendString("mystery")
		payload.appendString("mystery")
		payload.appendUInt32(0)

		let response = try MobileSFTPCodec.decodeResponse(type: 104, payload: payload)

		guard case .names(let names) = response,
			let entry = names.first?.entry(parent: "/home/caterm") else {
			return XCTFail("Expected an SFTP NAME response")
		}
		XCTAssertEqual(entry.type, .unknown)
		XCTAssertNil(entry.size)
		XCTAssertNil(entry.permissions)
	}

	func testRejectsTruncatedFlaggedSize() {
		var payload = Data()
		payload.appendUInt32(1)
		payload.appendString("broken")
		payload.appendString("broken")
		payload.appendUInt32(0x1)
		payload.appendUInt32(12)

		assertInvalidResponse(payload)
	}

	func testRejectsTruncatedFlaggedPermissions() {
		var payload = Data()
		payload.appendUInt32(1)
		payload.appendString("broken")
		payload.appendString("broken")
		payload.appendUInt32(0x4)
		payload.append(contentsOf: [0, 1])

		assertInvalidResponse(payload)
	}

	func testRejectsTruncatedNameResponse() {
		var payload = Data()
		payload.appendUInt32(1)
		payload.appendUInt32(100)
		payload.append(Data("short".utf8))

		XCTAssertThrowsError(
			try MobileSFTPCodec.decodeResponse(type: 104, payload: payload)
		) { error in
			guard case MobileSFTPError.invalidResponse = error else {
				return XCTFail("Expected invalid response, got \(error)")
			}
		}
	}

	private func assertInvalidResponse(
		_ payload: Data,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		XCTAssertThrowsError(
			try MobileSFTPCodec.decodeResponse(type: 104, payload: payload),
			file: file,
			line: line
		) { error in
			guard case MobileSFTPError.invalidResponse = error else {
				return XCTFail(
					"Expected invalid response, got \(error)",
					file: file,
					line: line
				)
			}
		}
	}
}

private extension Data {
	mutating func appendUInt32(_ value: UInt32) {
		append(contentsOf: [
			UInt8((value >> 24) & 0xff),
			UInt8((value >> 16) & 0xff),
			UInt8((value >> 8) & 0xff),
			UInt8(value & 0xff),
		])
	}

	mutating func appendUInt64(_ value: UInt64) {
		appendUInt32(UInt32(value >> 32))
		appendUInt32(UInt32(value & 0xffff_ffff))
	}

	mutating func appendString(_ value: String) {
		let bytes = Data(value.utf8)
		appendUInt32(UInt32(bytes.count))
		append(bytes)
	}
}
