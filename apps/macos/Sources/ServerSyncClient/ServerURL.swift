import Foundation

/// User-configurable server base URL. Persisted in UserDefaults under
/// `caterm.server.baseURL`. Default is the local dev server.
public enum ServerURL {
	public static let defaultURL = URL(string: "http://localhost:3002")!
	private static let key = "caterm.server.baseURL"

	public static var current: URL {
		if let s = UserDefaults.standard.string(forKey: key),
		   let u = URL(string: s) { return u }
		return defaultURL
	}

	public static func set(_ url: URL) {
		UserDefaults.standard.set(url.absoluteString, forKey: key)
	}

	public static func reset() {
		UserDefaults.standard.removeObject(forKey: key)
	}
}
