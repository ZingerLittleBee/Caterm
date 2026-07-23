import CredentialIdentitySecurity
import CredentialIdentityStore
import Darwin
import Foundation
import ManagedKeyStore
import SSHCommandBuilder

public enum CredentialIdentityPreparationError: Error, Equatable {
	case missingIdentity(UUID)
	case secureEnclaveUnsupported
	case temporaryResourceCreationFailed(Int32)
	case temporaryResourceWriteFailed(Int32)
}

public final class PreparedCredentialIdentityConnection:
	@unchecked Sendable {
	public let host: SSHHost
	public let credentialLookup: SSHCommandBuilder.CredentialLookup?
	public let runtimeIdentity: SSHRuntimeIdentityOptions?

	private let resource: PreparedCredentialIdentityResource?

	fileprivate init(
		host: SSHHost,
		credentialLookup: SSHCommandBuilder.CredentialLookup? = nil,
		runtimeIdentity: SSHRuntimeIdentityOptions? = nil,
		resource: PreparedCredentialIdentityResource? = nil
	) {
		self.host = host
		self.credentialLookup = credentialLookup
		self.runtimeIdentity = runtimeIdentity
		self.resource = resource
	}

	public func stop() {
		resource?.stop()
	}

	deinit {
		stop()
	}
}

public actor CredentialIdentityConnectionPreparer {
	private let materialStore: CredentialIdentityMaterialStore
	private let managedKeyStore: ManagedKeyStore

	public init(
		materialStore: CredentialIdentityMaterialStore,
		managedKeyStore: ManagedKeyStore
	) {
		self.materialStore = materialStore
		self.managedKeyStore = managedKeyStore
	}

	public func prepare(
		host: SSHHost,
		identity: CredentialIdentity?
	) async throws -> PreparedCredentialIdentityConnection {
		guard let reference = host.credentialIdentity else {
			return PreparedCredentialIdentityConnection(host: host)
		}
		guard let identity, identity.id == reference.identityID else {
			throw CredentialIdentityPreparationError.missingIdentity(
				reference.identityID
			)
		}
		let material = try await materialStore.snapshot(for: identity)
		let resolved = try CredentialIdentityConnectionResolver.resolve(
			host: host,
			identities: [identity],
			material: material
		)
		var preparedHost = resolved.host
		let materialID = identity.source.materialID

		switch identity.source {
		case .password:
			return PreparedCredentialIdentityConnection(
				host: preparedHost,
				credentialLookup: .init(
					service:
						CredentialIdentityKeychainContract.service,
					passwordAccount:
						CredentialIdentityKeychainContract.account(
							materialID: materialID,
							kind: .password
						),
					useDataProtectionKeychain: true
				)
			)

		case .managedKey(_, let hasPassphrase):
			preparedHost.credential = .keyFile(
				keyPath: managedKeyStore.path(
					materialID: materialID.rawValue
				).path,
				hasPassphrase: hasPassphrase
			)
			return PreparedCredentialIdentityConnection(
				host: preparedHost,
				credentialLookup: credentialLookup(
					materialID: materialID,
					hasPassphrase: hasPassphrase
				)
			)

		case .sshCertificate(
			_,
			let publicCertificate,
			let hasPassphrase
		):
			preparedHost.credential = .keyFile(
				keyPath: managedKeyStore.path(
					materialID: materialID.rawValue
				).path,
				hasPassphrase: hasPassphrase
			)
			let resource = try PreparedCredentialIdentityResource(
				publicCertificate: publicCertificate
			)
			return PreparedCredentialIdentityConnection(
				host: preparedHost,
				credentialLookup: credentialLookup(
					materialID: materialID,
					hasPassphrase: hasPassphrase
				),
				runtimeIdentity: .init(
					certificatePath: resource.certificateURL?.path
				),
				resource: resource
			)

		case .secureEnclaveP256:
			#if os(macOS)
			let key = try await materialStore.secureEnclaveKey(
				for: identity,
				localizedReason:
					"Use \(identity.name) to authenticate this SSH connection."
			)
			let resource = try PreparedCredentialIdentityResource(
				secureEnclaveKey: key,
				comment: identity.name
			)
			return PreparedCredentialIdentityConnection(
				host: preparedHost,
				runtimeIdentity: .init(
					identityAgentPath:
						resource.agentSession?.socketURL.path
				),
				resource: resource
			)
			#else
			throw CredentialIdentityPreparationError
				.secureEnclaveUnsupported
			#endif
		}
	}

	private func credentialLookup(
		materialID: CredentialMaterialID,
		hasPassphrase: Bool
	) -> SSHCommandBuilder.CredentialLookup? {
		guard hasPassphrase else { return nil }
		return .init(
			service: CredentialIdentityKeychainContract.service,
			passphraseAccount:
				CredentialIdentityKeychainContract.account(
					materialID: materialID,
					kind: .passphrase
				),
			useDataProtectionKeychain: true
		)
	}
}

private final class PreparedCredentialIdentityResource:
	@unchecked Sendable {
	let certificateURL: URL?
	#if os(macOS)
	let agentSession: SecureEnclaveSSHAgentSession?
	#endif

	private let directoryURL: URL?
	private let lock = NSLock()
	private var isStopped = false

	init(publicCertificate: Data) throws {
		let directory = try Self.createPrivateDirectory()
		let certificate = directory.appendingPathComponent(
			"user-cert.pub"
		)
		do {
			try Self.write(
				publicCertificate,
				to: certificate
			)
		} catch {
			try? FileManager.default.removeItem(at: directory)
			throw error
		}
		directoryURL = directory
		certificateURL = certificate
		#if os(macOS)
		agentSession = nil
		#endif
	}

	#if os(macOS)
	init(
		secureEnclaveKey: SecureEnclaveIdentityKey,
		comment: String
	) throws {
		agentSession = try SecureEnclaveSSHAgentSession(
			key: secureEnclaveKey,
			comment: comment
		)
		directoryURL = nil
		certificateURL = nil
	}
	#endif

	deinit {
		stop()
	}

	func stop() {
		lock.lock()
		guard !isStopped else {
			lock.unlock()
			return
		}
		isStopped = true
		lock.unlock()

		#if os(macOS)
		agentSession?.stop()
		#endif
		if let directoryURL {
			try? FileManager.default.removeItem(at: directoryURL)
		}
	}

	private static func createPrivateDirectory() throws -> URL {
		for _ in 0..<8 {
			let suffix = UUID().uuidString
				.replacingOccurrences(of: "-", with: "")
				.lowercased()
			let url = URL(
				fileURLWithPath:
					"/tmp/caterm-identity-\(suffix)",
				isDirectory: true
			)
			if mkdir(url.path, 0o700) == 0 {
				return url
			}
			guard errno == EEXIST else {
				throw CredentialIdentityPreparationError
					.temporaryResourceCreationFailed(errno)
			}
		}
		throw CredentialIdentityPreparationError
			.temporaryResourceCreationFailed(EEXIST)
	}

	private static func write(
		_ data: Data,
		to url: URL
	) throws {
		let fileDescriptor = open(
			url.path,
			O_CREAT | O_EXCL | O_WRONLY,
			0o600
		)
		guard fileDescriptor >= 0 else {
			throw CredentialIdentityPreparationError
				.temporaryResourceCreationFailed(errno)
		}
		defer { Darwin.close(fileDescriptor) }
		try data.withUnsafeBytes { buffer in
			guard let baseAddress = buffer.baseAddress else { return }
			var offset = 0
			while offset < buffer.count {
				let result = Darwin.write(
					fileDescriptor,
					baseAddress.advanced(by: offset),
					buffer.count - offset
				)
				if result > 0 {
					offset += result
				} else if result < 0, errno == EINTR {
					continue
				} else {
					throw CredentialIdentityPreparationError
						.temporaryResourceWriteFailed(errno)
				}
			}
		}
		guard fsync(fileDescriptor) == 0 else {
			throw CredentialIdentityPreparationError
				.temporaryResourceWriteFailed(errno)
		}
	}
}
