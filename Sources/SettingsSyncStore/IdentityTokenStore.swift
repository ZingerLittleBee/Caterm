import Foundation

/// What we read back from UserDefaults for the persisted token.
public enum PersistedTokenLoad: Equatable {
	case none
	case archiveFailed                              // sentinel observed
	case token(NSObject & NSCoding & NSCopying)

	public static func == (lhs: PersistedTokenLoad, rhs: PersistedTokenLoad) -> Bool {
		switch (lhs, rhs) {
		case (.none, .none), (.archiveFailed, .archiveFailed): return true
		case (.token(let a), .token(let b)): return a.isEqual(b)
		default: return false
		}
	}
}

public final class IdentityTokenStore {
	public static let userDefaultsKey = "caterm.settings.lastUbiquityIdentityToken"
	private static let sentinelString = "<archive-failed>"

	private let defaults: UserDefaults

	public init(userDefaults: UserDefaults = .standard) {
		self.defaults = userDefaults
	}

	/// Archive token with `requiringSecureCoding: false`. Apple only documents
	/// `ubiquityIdentityToken` as `NSCoding & NSCopying & NSObjectProtocol`,
	/// NOT `NSSecureCoding`. Forcing secure coding would throw on real-world
	/// tokens, drop us into firstObservation on every launch, and after an
	/// account switch reintroduce cross-identity LWW via BootstrapDecider.
	public func persist(_ token: NSObject & NSCoding & NSCopying) {
		do {
			let data = try NSKeyedArchiver.archivedData(
				withRootObject: token, requiringSecureCoding: false
			)
			defaults.set(data, forKey: Self.userDefaultsKey)
		} catch {
			NSLog("[IdentityTokenStore] archive failed: \(error). Persisting sentinel.")
			persistSentinel()
		}
	}

	public func persistSentinel() {
		let sentinel = Self.sentinelString.data(using: .utf8)!
		defaults.set(sentinel, forKey: Self.userDefaultsKey)
	}

	public func loadPersisted() -> PersistedTokenLoad {
		guard let data = defaults.data(forKey: Self.userDefaultsKey) else { return .none }
		if data == Self.sentinelString.data(using: .utf8) {
			return .archiveFailed
		}
		do {
			let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
			unarchiver.requiresSecureCoding = false
			guard let obj = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
			else { return .none }
			guard let token = obj as? (NSObject & NSCoding & NSCopying) else { return .none }
			return .token(token)
		} catch {
			return .none
		}
	}
}
