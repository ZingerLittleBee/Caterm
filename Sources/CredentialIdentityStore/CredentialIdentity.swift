import Foundation

public struct CredentialMaterialID: RawRepresentable, Codable, Hashable,
	Sendable, CustomStringConvertible {
	public let rawValue: UUID

	public init(rawValue: UUID) {
		self.rawValue = rawValue
	}

	public init() {
		self.init(rawValue: UUID())
	}

	public var description: String {
		rawValue.uuidString
	}
}

public enum CredentialIdentitySource: Codable, Equatable, Sendable {
	case password(materialID: CredentialMaterialID)
	case managedKey(
		materialID: CredentialMaterialID,
		hasPassphrase: Bool
	)
	case sshCertificate(
		materialID: CredentialMaterialID,
		publicCertificate: Data,
		hasPassphrase: Bool
	)
	case secureEnclaveP256(
		materialID: CredentialMaterialID,
		publicKey: Data,
		originDeviceID: UUID
	)

	public var materialID: CredentialMaterialID {
		switch self {
		case .password(let materialID),
		     .managedKey(let materialID, _),
		     .sshCertificate(let materialID, _, _),
		     .secureEnclaveP256(let materialID, _, _):
			materialID
		}
	}

	public var isDeviceBound: Bool {
		if case .secureEnclaveP256 = self {
			return true
		}
		return false
	}
}

public struct CredentialIdentity: Codable, Identifiable, Equatable, Sendable {
	public static let currentSchemaVersion = 1

	public let schemaVersion: Int
	public let id: UUID
	public var serverID: String?
	public var name: String
	public var username: String
	public var source: CredentialIdentitySource
	public var createdAt: Date
	public var updatedAt: Date
	public var revision: Int64

	public init(
		schemaVersion: Int = Self.currentSchemaVersion,
		id: UUID = UUID(),
		serverID: String? = nil,
		name: String,
		username: String,
		source: CredentialIdentitySource,
		createdAt: Date = Date(),
		updatedAt: Date = Date(),
		revision: Int64 = 1
	) {
		self.schemaVersion = schemaVersion
		self.id = id
		self.serverID = serverID
		self.name = name
		self.username = username
		self.source = source
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.revision = revision
	}

	public func validated() throws -> Self {
		guard schemaVersion == Self.currentSchemaVersion else {
			throw CredentialIdentityValidationError.unsupportedSchemaVersion(
				found: schemaVersion,
				supported: Self.currentSchemaVersion
			)
		}
		guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw CredentialIdentityValidationError.emptyName
		}
		guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw CredentialIdentityValidationError.emptyUsername
		}
		guard revision > 0 else {
			throw CredentialIdentityValidationError.invalidRevision
		}
		if case .sshCertificate(_, let certificate, _) = source,
		   certificate.isEmpty {
			throw CredentialIdentityValidationError.emptyPublicCertificate
		}
		if case .secureEnclaveP256(_, let publicKey, _) = source,
		   publicKey.isEmpty {
			throw CredentialIdentityValidationError.emptyPublicKey
		}
		return self
	}
}

public enum CredentialIdentityValidationError: Error, Equatable {
	case unsupportedSchemaVersion(found: Int, supported: Int)
	case emptyName
	case emptyUsername
	case emptyPublicCertificate
	case emptyPublicKey
	case invalidRevision
}
