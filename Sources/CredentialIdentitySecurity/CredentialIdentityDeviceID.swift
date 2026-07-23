import Foundation

public enum CredentialIdentityDeviceID {
	private static let defaultsKey =
		"catermCredentialIdentityDeviceID"

	public static func current(
		defaults: UserDefaults = .standard
	) -> UUID {
		if let value = defaults.string(forKey: defaultsKey),
		   let id = UUID(uuidString: value) {
			return id
		}
		let id = UUID()
		defaults.set(id.uuidString, forKey: defaultsKey)
		return id
	}
}
