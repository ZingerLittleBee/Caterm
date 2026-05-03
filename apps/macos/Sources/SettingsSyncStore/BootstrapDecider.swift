import Foundation
import SettingsStore

public enum BootstrapDecider {
	public static func decide(
		local: CatermSettings,
		cloud: SyncableSettings?,
		bootStartedAt: Date,
		knownMigrations: Set<String>
	) -> Decision {
		let localIsSeed = IsDefaultSeedUnedited.evaluate(local, knownMigrations: knownMigrations)

		guard let cloud = cloud else {
			if localIsSeed {
				return Decision(action: .noOp, finalSuspensionState: false, acceptIdentity: true)
			} else {
				return Decision(action: .pushLocal, finalSuspensionState: false, acceptIdentity: true)
			}
		}

		if cloud.version > local.version {
			return Decision(
				action: .rejectMerge(reason: .schemaNewerThanLocal),
				finalSuspensionState: false,
				acceptIdentity: true
			)
		}

		if localIsSeed {
			return Decision(action: .applyCloud(cloud), finalSuspensionState: false, acceptIdentity: true)
		}

		if cloud.revision == local.revision {
			return Decision(action: .noOp, finalSuspensionState: false, acceptIdentity: true)
		}

		// Both have real edits. Doc-level revision LWW with clock-skew sanity.
		// String compare is total-order-safe because makeRevision() emits a
		// fixed-width timestamp prefix at current epoch scales (see
		// SettingsStore.makeRevision docstring).
		let cloudWins = cloud.revision > local.revision
		let clockSkewSuspect: Bool = {
			guard cloudWins, let firstEdit = local.firstUserEditedAt else { return false }
			return firstEdit > bootStartedAt
		}()

		if cloudWins && !clockSkewSuspect {
			return Decision(action: .applyCloud(cloud), finalSuspensionState: false, acceptIdentity: true)
		} else {
			return Decision(action: .pushLocal, finalSuspensionState: false, acceptIdentity: true)
		}
	}
}
