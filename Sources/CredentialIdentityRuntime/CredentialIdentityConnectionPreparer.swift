import CredentialIdentitySecurity
import CredentialIdentityStore
import Darwin
import Foundation
import ManagedKeyStore
import os
import SSHCommandBuilder

public enum CredentialIdentityPreparationError: Error, Equatable {
	case missingIdentity(UUID)
	case secureEnclaveUnsupported
	case temporaryResourceCreationFailed(Int32)
	case temporaryResourceWriteFailed(Int32)
	case temporaryResourceCleanupFailed(
		operation: String,
		cleanup: String
	)
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
	private let runtimeSecrets:
		any IdentitySecretStoring & IdentityRuntimeSecretScavenging
	private let runtimeRootURL: URL
	private var preparedRuntimeNamespace:
		PreparedCredentialIdentityRuntimeNamespace?

	public init(
		materialStore: CredentialIdentityMaterialStore,
		managedKeyStore _: ManagedKeyStore,
		runtimeSecrets:
			any IdentitySecretStoring & IdentityRuntimeSecretScavenging =
			IdentityKeychainSecretStore(),
		runtimeRootURL: URL = FileManager.default.temporaryDirectory
	) {
		self.materialStore = materialStore
		self.runtimeSecrets = runtimeSecrets
		self.runtimeRootURL = runtimeRootURL
	}

	public func prepare(
		host: SSHHost,
		identity: CredentialIdentity?
	) async throws -> PreparedCredentialIdentityConnection {
		guard let reference = host.credentialIdentity else {
			return PreparedCredentialIdentityConnection(host: host)
		}
		guard let identity, identity.id == reference.identityID else {
			if reference.migrationState == .reversible {
				return PreparedCredentialIdentityConnection(host: host)
			}
			throw CredentialIdentityPreparationError.missingIdentity(
				reference.identityID
			)
		}
		let material: CredentialIdentityMaterial
		let resolved: ResolvedIdentityConnection
		do {
			material = try await materialStore.snapshot(for: identity)
			resolved = try CredentialIdentityConnectionResolver.resolve(
				host: host,
				identities: [identity],
				material: material
			)
		} catch {
			guard reference.migrationState == .reversible else {
				throw error
			}
			return PreparedCredentialIdentityConnection(host: host)
		}
		var preparedHost = resolved.host

		switch identity.source {
		case .password:
			guard let password = material.password else {
				throw CredentialIdentityMaterialStoreError
					.materialUnavailable
			}
			let resource = try PreparedCredentialIdentityResource(
				runtimeNamespace: try runtimeNamespace(),
				secrets: runtimeSecrets,
				password: password
			)
			return PreparedCredentialIdentityConnection(
				host: preparedHost,
				credentialLookup: .init(
					service:
						CredentialIdentityKeychainContract.service,
					passwordAccount:
						resource.passwordAccount,
					useDataProtectionKeychain: true
				),
				resource: resource
			)

		case .managedKey(_, let hasPassphrase):
			guard let privateKey = material.privateKey else {
				throw CredentialIdentityMaterialStoreError
					.materialUnavailable
			}
			let resource = try PreparedCredentialIdentityResource(
				runtimeNamespace: try runtimeNamespace(),
				secrets: runtimeSecrets,
				privateKey: privateKey,
				passphrase: material.passphrase
			)
			preparedHost.credential = .keyFile(
				keyPath: resource.privateKeyURL.path,
				hasPassphrase: hasPassphrase
			)
			return PreparedCredentialIdentityConnection(
				host: preparedHost,
				credentialLookup: credentialLookup(
					passphraseAccount: resource.passphraseAccount,
					hasPassphrase: hasPassphrase
				),
				resource: resource
			)

		case .sshCertificate(
			_,
			let publicCertificate,
			let hasPassphrase
		):
			guard let privateKey = material.privateKey else {
				throw CredentialIdentityMaterialStoreError
					.materialUnavailable
			}
			let resource = try PreparedCredentialIdentityResource(
				runtimeNamespace: try runtimeNamespace(),
				secrets: runtimeSecrets,
				privateKey: privateKey,
				publicCertificate: publicCertificate,
				passphrase: material.passphrase
			)
			preparedHost.credential = .keyFile(
				keyPath: resource.privateKeyURL.path,
				hasPassphrase: hasPassphrase
			)
			return PreparedCredentialIdentityConnection(
				host: preparedHost,
				credentialLookup: credentialLookup(
					passphraseAccount: resource.passphraseAccount,
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
		passphraseAccount: String?,
		hasPassphrase: Bool
	) -> SSHCommandBuilder.CredentialLookup? {
		guard hasPassphrase, let passphraseAccount else { return nil }
		return .init(
			service: CredentialIdentityKeychainContract.service,
			passphraseAccount: passphraseAccount,
			useDataProtectionKeychain: true
		)
	}

	private func runtimeNamespace() throws
		-> PreparedCredentialIdentityRuntimeNamespace {
		if let preparedRuntimeNamespace {
			return preparedRuntimeNamespace
		}
		let namespace = try PreparedCredentialIdentityRuntimeNamespace(
			rootURL: runtimeRootURL,
			secrets: runtimeSecrets
		)
		preparedRuntimeNamespace = namespace
		return namespace
	}
}

private final class PreparedCredentialIdentityRuntimeNamespace:
	@unchecked Sendable {
	private static let directoryPrefix = "caterm-identity-runtime-"
	private static let lockFileName = ".lock"

	let accountPrefix: String
	let directoryURL: URL

	private let lockFileDescriptor: Int32

	init(
		rootURL: URL,
		secrets: any IdentityRuntimeSecretScavenging
	) throws {
		try FileManager.default.createDirectory(
			at: rootURL,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		try Self.scavengeStaleNamespaces(
			rootURL: rootURL,
			secrets: secrets
		)
		let identifier = UUID().uuidString.lowercased()
		accountPrefix = "runtime.\(identifier)."
		let staging = rootURL.appendingPathComponent(
			".caterm-identity-runtime-staging-\(identifier)",
			isDirectory: true
		)
		let published = rootURL.appendingPathComponent(
			"\(Self.directoryPrefix)\(getpid())-\(identifier)",
			isDirectory: true
		)
		guard mkdir(staging.path, 0o700) == 0 else {
			throw CredentialIdentityPreparationError
				.temporaryResourceCreationFailed(errno)
		}
		let lockURL = staging.appendingPathComponent(Self.lockFileName)
		let descriptor = open(
			lockURL.path,
			O_CREAT | O_EXCL | O_RDWR,
			0o600
		)
		guard descriptor >= 0 else {
			let operationError = errno
			_ = try? FileManager.default.removeItem(at: staging)
			throw CredentialIdentityPreparationError
				.temporaryResourceCreationFailed(operationError)
		}
		guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
			let operationError = errno
			Darwin.close(descriptor)
			_ = try? FileManager.default.removeItem(at: staging)
			throw CredentialIdentityPreparationError
				.temporaryResourceCreationFailed(operationError)
		}
		do {
			try FileManager.default.moveItem(at: staging, to: published)
		} catch {
			Darwin.close(descriptor)
			_ = try? FileManager.default.removeItem(at: staging)
			throw error
		}
		directoryURL = published
		lockFileDescriptor = descriptor
	}

	deinit {
		Darwin.close(lockFileDescriptor)
	}

	func createPrivateDirectory() throws -> URL {
		for _ in 0..<8 {
			let url = directoryURL.appendingPathComponent(
				UUID().uuidString.lowercased(),
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

	private static func scavengeStaleNamespaces(
		rootURL: URL,
		secrets: any IdentityRuntimeSecretScavenging
	) throws {
		let entries = try FileManager.default.contentsOfDirectory(
			at: rootURL,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		)
		for directory in entries
		where directory.lastPathComponent.hasPrefix(directoryPrefix) {
			guard let identifier = namespaceIdentifier(
				directory.lastPathComponent
			) else {
				continue
			}
			let lockURL = directory.appendingPathComponent(lockFileName)
			let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
			guard descriptor >= 0 else { continue }
			guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
				Darwin.close(descriptor)
				continue
			}
			do {
				try secrets.deleteAll(
					accountPrefix: "runtime.\(identifier)."
				)
				try FileManager.default.removeItem(at: directory)
				Darwin.close(descriptor)
			} catch {
				Darwin.close(descriptor)
				throw error
			}
		}
	}

	private static func namespaceIdentifier(
		_ directoryName: String
	) -> String? {
		let suffix = directoryName.dropFirst(directoryPrefix.count)
		guard let separator = suffix.firstIndex(of: "-") else {
			return nil
		}
		let identifier = suffix[suffix.index(after: separator)...]
		guard UUID(uuidString: String(identifier)) != nil else {
			return nil
		}
		return String(identifier)
	}
}

private final class PreparedCredentialIdentityResource:
	@unchecked Sendable {
	private static let log = Logger(
		subsystem: "com.caterm.app",
		category: "credential-identity-resource"
	)
	let certificateURL: URL?
	let privateKeyURL: URL
	let passwordAccount: String?
	let passphraseAccount: String?
	#if os(macOS)
	let agentSession: SecureEnclaveSSHAgentSession?
	#endif

	private let directoryURL: URL?
	private let secrets: (any IdentitySecretStoring)?
	private var runtimeNamespace:
		PreparedCredentialIdentityRuntimeNamespace?
	private let lock = NSLock()
	private var isStopped = false

	init(
		runtimeNamespace: PreparedCredentialIdentityRuntimeNamespace,
		secrets: any IdentitySecretStoring,
		password: Data? = nil,
		privateKey: Data? = nil,
		publicCertificate: Data? = nil,
		passphrase: Data? = nil
	) throws {
		let directory = privateKey == nil && publicCertificate == nil
			? nil
			: try runtimeNamespace.createPrivateDirectory()
		let keyURL = directory?.appendingPathComponent("identity")
		let certificate = directory?.appendingPathComponent("identity-cert.pub")
		let passwordAccount = password.map { _ in
			"\(runtimeNamespace.accountPrefix)\(UUID().uuidString).password"
		}
		let passphraseAccount = passphrase.map { _ in
			"\(runtimeNamespace.accountPrefix)\(UUID().uuidString).passphrase"
		}
		var writtenAccounts: [String] = []
		do {
			if let privateKey, let keyURL {
				try Self.write(privateKey, to: keyURL)
			}
			if let publicCertificate, let certificate {
				try Self.write(publicCertificate, to: certificate)
			}
			if let password, let passwordAccount {
				try secrets.write(password, account: passwordAccount)
				writtenAccounts.append(passwordAccount)
			}
			if let passphrase, let passphraseAccount {
				try secrets.write(passphrase, account: passphraseAccount)
				writtenAccounts.append(passphraseAccount)
			}
		} catch {
			let operationError = error
			var cleanupErrors: [String] = []
			for account in writtenAccounts {
				do {
					try secrets.delete(account: account)
				} catch {
					cleanupErrors.append(String(describing: error))
				}
			}
			if let directory {
				do {
					try FileManager.default.removeItem(at: directory)
				} catch {
					cleanupErrors.append(String(describing: error))
				}
			}
			guard cleanupErrors.isEmpty else {
				throw CredentialIdentityPreparationError
					.temporaryResourceCleanupFailed(
						operation: String(describing: operationError),
						cleanup: cleanupErrors.joined(separator: "; ")
					)
			}
			throw operationError
		}
		directoryURL = directory
		certificateURL = certificate
		privateKeyURL = keyURL ?? URL(fileURLWithPath: "/dev/null")
		self.passwordAccount = passwordAccount
		self.passphraseAccount = passphraseAccount
		self.secrets = secrets
		self.runtimeNamespace = runtimeNamespace
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
		privateKeyURL = URL(fileURLWithPath: "/dev/null")
		passwordAccount = nil
		passphraseAccount = nil
		secrets = nil
		runtimeNamespace = nil
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
		for account in [passwordAccount, passphraseAccount].compactMap({ $0 }) {
			do {
				try secrets?.delete(account: account)
			} catch {
				Self.log.error(
					"temporary identity secret cleanup failed: \(String(describing: error), privacy: .public)"
				)
			}
		}
		if let directoryURL {
			do {
				try FileManager.default.removeItem(at: directoryURL)
			} catch {
				Self.log.error(
					"temporary identity cleanup failed: \(String(describing: error), privacy: .public)"
				)
			}
		}
		runtimeNamespace = nil
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
