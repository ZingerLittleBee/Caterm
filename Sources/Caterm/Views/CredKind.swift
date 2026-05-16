import Foundation

/// SSH credential method shared by `CredentialSetupView` (small "fill in
/// missing credential" sheet) and `HostFormView` (full add/edit sheet).
/// Owns no state of its own — both sheets bind their own `credKind`
/// value to a `Picker(selection:)` typed against this enum.
///
/// `.agent` was removed in v1.7: a Finder-launched .app inherits no
/// `SSH_AUTH_SOCK`, and Caterm never forwarded an agent socket into the
/// ssh subprocess, so `BatchMode=yes` agent auth could never succeed.
/// `CredentialSource.agent` is still decoded for backward compatibility
/// (legacy hosts.json / CloudKit records) — see `HostFormView.populate`,
/// which surfaces such hosts as `.password` so the user can reconfigure.
enum CredKind: String, CaseIterable, Identifiable {
	case password
	case keyFile = "key file"

	var id: String { rawValue }

	/// User-visible label for the segmented picker. The raw values are
	/// kept lowercase for backwards compatibility (Identifiable.id is
	/// the rawValue), but every visible string uses title case.
	var displayName: String {
		switch self {
		case .password: return "Password"
		case .keyFile:  return "Key File"
		}
	}
}
