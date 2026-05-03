import Foundation
import SettingsStore

public enum AccountSwitchHandler {
	/// Cross-identity transitions: cloud Y is force-applied if schema-compatible
	/// (no revision LWW; local revision belonged to identity X and is meaningless
	/// under Y). Empty Y / schema-newer Y stay suspended and DO NOT persist the
	/// new token — that happens only when the user explicitly accepts identity Y
	/// by editing under it (suspendUntilFirstEdit unfreeze flow) or when Y data
	/// is force-applied.
	public static func handle(
		local: CatermSettings,
		cloudY: SyncableSettings?
	) -> Decision {
		guard let y = cloudY else {
			return Decision(
				action: .suspendUntilFirstEdit,
				finalSuspensionState: true,
				acceptIdentity: false
			)
		}
		if y.version > local.version {
			return Decision(
				action: .rejectMerge(reason: .schemaNewerThanLocal),
				finalSuspensionState: true,
				acceptIdentity: false
			)
		}
		return Decision(
			action: .forceApply(y),
			finalSuspensionState: false,
			acceptIdentity: true
		)
	}
}
