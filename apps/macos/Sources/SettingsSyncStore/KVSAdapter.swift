import Foundation

/// Slimmed-down surface of NSUbiquitousKeyValueStore so tests can substitute
/// a FakeKVS. Apple's contract:
///   - set(_:forKey:) returns Void; no in-band failure signal.
///   - synchronize() returns Bool indicating local persistence to user
///     defaults succeeded — NOT that the upload to iCloud completed.
///   - Quota / account / server / initial-sync changes arrive only via the
///     external-change notification.
public protocol KVSProtocol: AnyObject {
	func data(forKey key: String) -> Data?
	func set(_ data: Data, forKey key: String)
	func removeObject(forKey key: String)
	@discardableResult func synchronize() -> Bool
	func dictionaryRepresentation() -> [String: Any]
}

extension NSUbiquitousKeyValueStore: KVSProtocol {
	// Apple's NSUbiquitousKeyValueStore.set(_:forKey:) accepts Any?; the
	// Data overload is provided here so the protocol's strongly-typed Data
	// signature matches without ambiguity.
	public func set(_ data: Data, forKey key: String) {
		self.set(data as Any?, forKey: key)
	}

	// Apple bridges `dictionaryRepresentation` as a property; our protocol
	// declares it as a method. Resolve to Apple's property unambiguously
	// via a key path — the method we're inside cannot be referenced as a
	// key path, so this is robust to future toolchain resolution changes.
	public func dictionaryRepresentation() -> [String: Any] {
		return self[keyPath: \NSUbiquitousKeyValueStore.dictionaryRepresentation]
	}
}

public enum KVSChangeReason: Equatable {
	case serverChange
	case initialSyncChange
	case quotaViolationChange
	case accountChange
	case unknown(Int)
}

public enum KVSReasonClassifier {
	/// Classifies the integer in `userInfo[NSUbiquitousKeyValueStoreChangeReasonKey]`
	/// for `didChangeExternallyNotification`.
	public static func classify(_ raw: Int?) -> KVSChangeReason {
		guard let raw = raw else { return .unknown(-1) }
		switch raw {
		case Int(NSUbiquitousKeyValueStoreServerChange): return .serverChange
		case Int(NSUbiquitousKeyValueStoreInitialSyncChange): return .initialSyncChange
		case Int(NSUbiquitousKeyValueStoreQuotaViolationChange): return .quotaViolationChange
		case Int(NSUbiquitousKeyValueStoreAccountChange): return .accountChange
		default: return .unknown(raw)
		}
	}
}

/// Test fake. Concurrency: tests are single-threaded so internal storage
/// is not synchronized.
public final class FakeKVS: KVSProtocol {
	private var storage: [String: Data] = [:]
	public init() {}
	public func data(forKey key: String) -> Data? { storage[key] }
	public func set(_ data: Data, forKey key: String) { storage[key] = data }
	public func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
	public func synchronize() -> Bool { true }
	public func dictionaryRepresentation() -> [String: Any] { storage }
}
