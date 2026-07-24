import CredentialIdentitySecurity
import CryptoKit
import Foundation
import XCTest

final class CredentialIdentityIntegrationTests: XCTestCase {
	func testRealDataProtectionKeychainRoundTrip() throws {
		let service = "com.caterm.tests.identity.\(UUID().uuidString)"
		let account = "round-trip"
		let store = IdentityKeychainSecretStore(service: service)
		defer { try? store.delete(account: account) }
		let expected = Data("identity-secret".utf8)

		do {
			try store.write(expected, account: account)
			XCTAssertEqual(try store.read(account: account), expected)
			try store.delete(account: account)
			XCTAssertNil(try store.read(account: account))
		} catch IdentityKeychainError.interactionNotAllowed {
			throw XCTSkip(
				"Data Protection Keychain requires an interactive signed test host."
			)
		} catch IdentityKeychainError.osStatus(let status)
			where status == errSecMissingEntitlement
				|| status == errSecInternalComponent {
			throw XCTSkip(
				"Data Protection Keychain is unavailable to this test host: \(status)."
			)
		}
	}

	func testRealSecureEnclaveSignsAndVerifies() throws {
		guard ProcessInfo.processInfo.environment[
			"CATERM_RUN_SECURE_ENCLAVE_TESTS"
		] == "1" else {
			throw XCTSkip(
				"Set CATERM_RUN_SECURE_ENCLAVE_TESTS=1 on signed physical hardware."
			)
		}
		let provider = SystemSecureEnclaveIdentityKeyProvider()
		guard provider.isAvailable else {
			throw XCTSkip("Secure Enclave is unavailable on this hardware.")
		}

		let key = try provider.create(
			localizedReason: "Verify Caterm Secure Enclave identity support"
		)
		let payload = Data("caterm-ssh-identity".utf8)
		let signature = try key.privateKey.signature(for: payload)

		XCTAssertTrue(
			key.privateKey.publicKey.isValidSignature(
				signature,
				for: payload
			)
		)
		XCTAssertFalse(key.dataRepresentation.isEmpty)
		XCTAssertFalse(key.publicKeyDER.isEmpty)
	}
}
