import Foundation
import SettingsStore

public enum AccountSwitchHandler {
	/// Cross-identity transitions: cloud Y is force-applied if schema-compatible
	/// (no revision LWW; local revision belonged to identity X and is meaningless
	/// under Y). Empty Y stays suspended (`.suspendUntilFirstEdit`); schema-newer
	/// or unreadable Y stays quarantined. None of the suspension paths persist
	/// the new identity token — that happens only when the user explicitly
	/// accepts identity Y by editing under it (suspendUntilFirstEdit unfreeze)
	/// or when readable Y data is force-applied.
	public static func handle(
		local: CatermSettings,
		cloudY: CloudReadResult
	) -> Decision {
		switch cloudY {
		case .absent:
			return Decision(
				action: .suspendUntilFirstEdit,
				finalState: .suspendUntilFirstEdit,
				acceptIdentity: false
			)

		case .unreadable:
			// Y has data but we can't read it. Pushing X data into Y would
			// overwrite real Y content; force-applying is impossible. Quarantine
			// until Y becomes readable (next pull retries), and refuse to
			// persist Y identity until we've actually consumed Y data.
			return Decision(
				action: .rejectMerge(reason: .unreadableCloud),
				finalState: .quarantined,
				acceptIdentity: false
			)

		case .decoded(let y):
			if y.version > local.version {
				return Decision(
					action: .rejectMerge(reason: .schemaNewerThanLocal),
					finalState: .quarantined,
					acceptIdentity: false
				)
			}
			return Decision(
				action: .forceApply(y),
				finalState: .active,
				acceptIdentity: true
			)
		}
	}
}
