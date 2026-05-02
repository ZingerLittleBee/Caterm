import CloudKit
import Foundation

internal enum ServerChangeTokenError: Error, Sendable {
	case unarchiveReturnedNil
}

internal struct StoredServerChangeToken: Equatable, Sendable {
	let archivedData: Data

	init(archivedData: Data) { self.archivedData = archivedData }

	static func archive(_ token: CKServerChangeToken) throws -> StoredServerChangeToken {
		let data = try NSKeyedArchiver.archivedData(
			withRootObject: token, requiringSecureCoding: true
		)
		return StoredServerChangeToken(archivedData: data)
	}

	func unarchive() throws -> CKServerChangeToken {
		guard let token = try NSKeyedUnarchiver.unarchivedObject(
			ofClass: CKServerChangeToken.self, from: archivedData
		) else {
			throw ServerChangeTokenError.unarchiveReturnedNil
		}
		return token
	}
}

// TokenCAS / CommitOutcome / ServerChangeTokenStoring follow in Task 1.2.
