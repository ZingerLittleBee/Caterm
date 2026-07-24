#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import CredentialIdentityRuntime

struct SecureEnclaveSSHAgentSessionTests {
	@Test
	func openSSHListsOnlyTheConstrainedIdentity() throws {
		let session = try SecureEnclaveSSHAgentSession(
			signer: SessionSoftwareP256Signer(),
			comment: "Caterm device-bound test"
		)
		defer { session.stop() }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
		process.arguments = ["-L"]
		process.environment = [
			"SSH_AUTH_SOCK": session.socketURL.path,
		]
		let output = Pipe()
		let errors = Pipe()
		process.standardOutput = output
		process.standardError = errors

		try process.run()
		process.waitUntilExit()
		let standardOutput = String(
			decoding:
				output.fileHandleForReading.readDataToEndOfFile(),
			as: UTF8.self
		)
		let standardError = String(
			decoding:
				errors.fileHandleForReading.readDataToEndOfFile(),
			as: UTF8.self
		)

		#expect(process.terminationStatus == 0)
		#expect(
			standardOutput.hasPrefix("ecdsa-sha2-nistp256 ")
		)
		#expect(
			standardOutput.contains("Caterm device-bound test")
		)
		#expect(
			standardOutput
				.split(separator: "\n")
				.count == 1
		)
		#expect(standardError.isEmpty)
	}

	@Test
	func stopRemovesSocketAndPrivateDirectory() throws {
		let session = try SecureEnclaveSSHAgentSession(
			signer: SessionSoftwareP256Signer(),
			comment: "identity"
		)
		let socketURL = session.socketURL
		let directoryURL = socketURL.deletingLastPathComponent()
		let directoryMode = try #require(
			FileManager.default.attributesOfItem(
				atPath: directoryURL.path
			)[.posixPermissions] as? NSNumber
		)
		let socketMode = try #require(
			FileManager.default.attributesOfItem(
				atPath: socketURL.path
			)[.posixPermissions] as? NSNumber
		)

		#expect(directoryMode.intValue & 0o777 == 0o700)
		#expect(socketMode.intValue & 0o777 == 0o600)

		session.stop()

		#expect(
			!FileManager.default.fileExists(
				atPath: socketURL.path
			)
		)
		#expect(
			!FileManager.default.fileExists(
				atPath: directoryURL.path
			)
		)
	}

	@Test
	func openSSHVerifiesAgentSignature() throws {
		let signer = SessionSoftwareP256Signer()
		let session = try SecureEnclaveSSHAgentSession(
			signer: signer,
			comment: "Caterm signature test"
		)
		defer { session.stop() }
		let keyBlob = try SecureEnclaveSSHAgentCodec.publicKeyBlob(
			x963Representation: signer.publicKeyX963Representation
		)
		let keyURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: keyURL) }
		let authorizedKey = [
			"ecdsa-sha2-nistp256",
			keyBlob.base64EncodedString(),
			"Caterm signature test\n",
		].joined(separator: " ")
		try Data(authorizedKey.utf8).write(
			to: keyURL,
			options: .atomic
		)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: keyURL.path
		)
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
		process.arguments = ["-T", keyURL.path]
		process.environment = [
			"SSH_AUTH_SOCK": session.socketURL.path,
		]
		let errors = Pipe()
		process.standardOutput = Pipe()
		process.standardError = errors

		try process.run()
		process.waitUntilExit()
		let standardError = String(
			decoding:
				errors.fileHandleForReading.readDataToEndOfFile(),
			as: UTF8.self
		)

		#expect(process.terminationStatus == 0)
		#expect(standardError.isEmpty)
	}
}

private struct SessionSoftwareP256Signer: P256SSHAgentSigning {
	private let key = P256.Signing.PrivateKey()

	var publicKeyX963Representation: Data {
		key.publicKey.x963Representation
	}

	func signature(for data: Data) throws -> Data {
		try key.signature(for: data).rawRepresentation
	}
}
#endif
