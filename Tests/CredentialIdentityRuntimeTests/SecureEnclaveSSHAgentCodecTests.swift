import CryptoKit
import Foundation
import Testing
@testable import CredentialIdentityRuntime

struct SecureEnclaveSSHAgentCodecTests {
	@Test
	func listsExactlyOneP256Identity() throws {
		let signer = SoftwareP256Signer()
		let response = try SecureEnclaveSSHAgentCodec.response(
			to: Data([11]),
			signer: signer,
			comment: "Caterm Secure Enclave"
		)
		var reader = TestAgentReader(data: response)

		#expect(try reader.byte() == 12)
		#expect(try reader.uint32() == 1)
		#expect(
			try reader.string()
				== SecureEnclaveSSHAgentCodec.publicKeyBlob(
					x963Representation:
						signer.publicKeyX963Representation
				)
		)
		#expect(
			try String(
				data: reader.string(),
				encoding: .utf8
			) == "Caterm Secure Enclave"
		)
		#expect(reader.isAtEnd)
	}

	@Test
	func signsOnlyTheAdvertisedKey() throws {
		let signer = SoftwareP256Signer()
		let payload = Data("ssh-userauth-payload".utf8)
		let keyBlob = try SecureEnclaveSSHAgentCodec.publicKeyBlob(
			x963Representation: signer.publicKeyX963Representation
		)
		var request = Data([13])
		request.appendTestString(keyBlob)
		request.appendTestString(payload)
		request.appendTestUInt32(0)

		let response = try SecureEnclaveSSHAgentCodec.response(
			to: request,
			signer: signer,
			comment: "identity"
		)
		var reader = TestAgentReader(data: response)
		#expect(try reader.byte() == 14)
		var signatureReader = TestAgentReader(
			data: try reader.string()
		)
		#expect(
			try String(
				data: signatureReader.string(),
				encoding: .utf8
			) == "ecdsa-sha2-nistp256"
		)
		var values = TestAgentReader(
			data: try signatureReader.string()
		)
		let r = try values.string()
		let s = try values.string()

		#expect(!r.isEmpty)
		#expect(!s.isEmpty)
		#expect(values.isAtEnd)
		#expect(signatureReader.isAtEnd)
		#expect(reader.isAtEnd)
	}

	@Test
	func rejectsDifferentKeyAndSignatureFlags() throws {
		let signer = SoftwareP256Signer()
		let other = SoftwareP256Signer()
		var wrongKey = Data([13])
		wrongKey.appendTestString(
			try SecureEnclaveSSHAgentCodec.publicKeyBlob(
				x963Representation: other.publicKeyX963Representation
			)
		)
		wrongKey.appendTestString(Data("payload".utf8))
		wrongKey.appendTestUInt32(0)

		#expect(throws: SecureEnclaveSSHAgentCodecError.unexpectedKey) {
			try SecureEnclaveSSHAgentCodec.response(
				to: wrongKey,
				signer: signer,
				comment: "identity"
			)
		}

		var flags = Data([13])
		flags.appendTestString(
			try SecureEnclaveSSHAgentCodec.publicKeyBlob(
				x963Representation: signer.publicKeyX963Representation
			)
		)
		flags.appendTestString(Data("payload".utf8))
		flags.appendTestUInt32(2)

		#expect(
			throws:
				SecureEnclaveSSHAgentCodecError.unsupportedFlags(2)
		) {
			try SecureEnclaveSSHAgentCodec.response(
				to: flags,
				signer: signer,
				comment: "identity"
			)
		}
	}

	@Test
	func malformedAndUnsupportedRequestsFailClosed() {
		let signer = SoftwareP256Signer()

		#expect(
			throws:
				SecureEnclaveSSHAgentCodecError.malformedMessage
		) {
			try SecureEnclaveSSHAgentCodec.response(
				to: Data(),
				signer: signer,
				comment: "identity"
			)
		}
		#expect(
			throws:
				SecureEnclaveSSHAgentCodecError.unsupportedRequest(17)
		) {
			try SecureEnclaveSSHAgentCodec.response(
				to: Data([17]),
				signer: signer,
				comment: "identity"
			)
		}
		#expect(
			SecureEnclaveSSHAgentCodec.failureResponse() == Data([5])
		)
	}
}

private struct SoftwareP256Signer: P256SSHAgentSigning {
	private let key = P256.Signing.PrivateKey()

	var publicKeyX963Representation: Data {
		key.publicKey.x963Representation
	}

	func signature(for data: Data) throws -> Data {
		try key.signature(for: data).rawRepresentation
	}
}

private struct TestAgentReader {
	let data: Data
	private(set) var offset = 0

	var isAtEnd: Bool { offset == data.count }

	mutating func byte() throws -> UInt8 {
		guard offset < data.count else { throw TestAgentError.eof }
		defer { offset += 1 }
		return data[offset]
	}

	mutating func uint32() throws -> UInt32 {
		guard data.count - offset >= 4 else {
			throw TestAgentError.eof
		}
		let value = data[offset..<(offset + 4)].reduce(UInt32(0)) {
			($0 << 8) | UInt32($1)
		}
		offset += 4
		return value
	}

	mutating func string() throws -> Data {
		let length = Int(try uint32())
		guard length <= data.count - offset else {
			throw TestAgentError.eof
		}
		defer { offset += length }
		return data.subdata(in: offset..<(offset + length))
	}
}

private enum TestAgentError: Error {
	case eof
}

private extension Data {
	mutating func appendTestUInt32(_ value: UInt32) {
		append(UInt8((value >> 24) & 0xff))
		append(UInt8((value >> 16) & 0xff))
		append(UInt8((value >> 8) & 0xff))
		append(UInt8(value & 0xff))
	}

	mutating func appendTestString(_ value: Data) {
		appendTestUInt32(UInt32(value.count))
		append(value)
	}
}
