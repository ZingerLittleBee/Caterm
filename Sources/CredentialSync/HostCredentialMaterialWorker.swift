import CredentialSyncStore
import CredentialSyncTypes
import CryptoKit
import Foundation
import SessionStore

struct LocalCredentialEncryptionRequest: Sendable {
    let serverId: String
    let fallbackPrivateKeyPath: String?
    let revision: Int64
}

struct EncryptedLocalCredentialBlob: Sendable {
    let blob: CredentialBlob
    let materialGeneration: UInt64
}

typealias CredentialMaterialLoader = @Sendable () async throws
    -> StoredCredentialMaterialSnapshot

enum RemoteCredentialMaterialResult: Equatable, Sendable {
    case missingKey(keyID: String?)
    case material(HostSecrets)
}

protocol HostCredentialMaterialWorking: Sendable {
    func makeEncryptedBlob(
        from request: LocalCredentialEncryptionRequest,
        loadMaterial: @escaping CredentialMaterialLoader
    ) async throws -> EncryptedLocalCredentialBlob?

    func decrypt(
        serverId: String,
        blob: CredentialBlob
    ) async throws -> RemoteCredentialMaterialResult
}

/// Performs private-key reads and cryptography away from the main actor. The
/// engine owns synchronization and commits the resulting credential material.
actor HostCredentialMaterialWorker: HostCredentialMaterialWorking {
    private let masterKeyStore: KeychainSyncMasterKeyStore

    init(masterKeyStore: KeychainSyncMasterKeyStore) {
        self.masterKeyStore = masterKeyStore
    }

    func makeEncryptedBlob(
        from request: LocalCredentialEncryptionRequest,
        loadMaterial: @escaping CredentialMaterialLoader
    ) async throws -> EncryptedLocalCredentialBlob? {
        guard let resolved = try await masterKeyStore.lookupAny() else { return nil }
        try Task.checkCancellation()
        let material = try await loadMaterial()
        try Task.checkCancellation()

        let privateKey = material.managedPrivateKey
            ?? request.fallbackPrivateKeyPath
            .flatMap { FileManager.default.contents(atPath: $0) }
        let aadFor: (FieldKind) -> Data = { kind in
            EnvelopeCrypto.aad(
                serverId: request.serverId,
                fieldKind: kind,
                revision: request.revision
            )
        }

        return EncryptedLocalCredentialBlob(
            blob: CredentialBlob(
                state: .payload,
                revision: request.revision,
                keyID: resolved.keyID,
                cryptoVersion: Int64(EnvelopeCrypto.schemaVersion),
                passwordCiphertext: try material.password.map {
                    try EnvelopeCrypto.seal(
                        $0,
                        key: resolved.key,
                        aad: aadFor(.password)
                    )
                },
                passphraseCiphertext: try material.passphrase.map {
                    try EnvelopeCrypto.seal(
                        $0,
                        key: resolved.key,
                        aad: aadFor(.passphrase)
                    )
                },
                privateKeyCiphertext: try privateKey.map {
                    try EnvelopeCrypto.seal(
                        $0,
                        key: resolved.key,
                        aad: aadFor(.privateKey)
                    )
                }
            ),
            materialGeneration: material.generation
        )
    }

    func decrypt(
        serverId: String,
        blob: CredentialBlob
    ) async throws -> RemoteCredentialMaterialResult {
        guard let keyID = blob.keyID else {
            return .missingKey(keyID: nil)
        }
        guard let masterKey = try await masterKeyStore.lookup(keyID: keyID) else {
            return .missingKey(keyID: keyID)
        }
        try Task.checkCancellation()

        let aadFor: (FieldKind) -> Data = { kind in
            EnvelopeCrypto.aad(
                serverId: serverId,
                fieldKind: kind,
                revision: blob.revision
            )
        }
        let password = try blob.passwordCiphertext.map {
            try EnvelopeCrypto.open(
                $0,
                key: masterKey,
                aad: aadFor(.password)
            )
        }
        let passphrase = try blob.passphraseCiphertext.map {
            try EnvelopeCrypto.open(
                $0,
                key: masterKey,
                aad: aadFor(.passphrase)
            )
        }
        let privateKey = try blob.privateKeyCiphertext.map {
            try EnvelopeCrypto.open(
                $0,
                key: masterKey,
                aad: aadFor(.privateKey)
            )
        }

        return .material(
            HostSecrets(
                password: password,
                passphrase: passphrase,
                privateKeyBytes: privateKey
            )
        )
    }
}
