import Foundation

/// SSH credential method shared by `CredentialSetupView` (small "fill in
/// missing credential" sheet) and `HostFormView` (full add/edit sheet).
/// Owns no state of its own — both sheets bind their own `credKind`
/// value to a `Picker(selection:)` typed against this enum.
enum CredKind: String, CaseIterable, Identifiable {
	case password
	case keyFile = "key file"
	case agent

	var id: String { rawValue }

	/// User-visible label for the segmented picker. The raw values are
	/// kept lowercase for backwards compatibility (Identifiable.id is
	/// the rawValue), but every visible string uses title case.
	var displayName: String {
		switch self {
		case .password: return "Password"
		case .keyFile:  return "Key File"
		case .agent:    return "Agent"
		}
	}
}
