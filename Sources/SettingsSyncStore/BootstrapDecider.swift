import Foundation
import SettingsStore

public enum BootstrapDecider {
	public static func decide(
		local: CatermSettings,
		cloud: CloudReadResult,
		bootStartedAt: Date,
		knownMigrations: Set<String>
	) -> Decision {
		let localIsSeed = IsDefaultSeedUnedited.evaluate(local, knownMigrations: knownMigrations)

		switch cloud {
		case .absent:
			if localIsSeed {
				return Decision(action: .noOp, finalState: .active, acceptIdentity: true)
			} else {
				return Decision(action: .pushLocal, finalState: .active, acceptIdentity: true)
			}

		case .unreadable:
			// Don't push local over cloud blob we can't read — that data may be
			// real user content under a future schema. Quarantine until cloud is
			// replaced with a readable compatible version (next pull retries).
			return Decision(
				action: .rejectMerge(reason: .unreadableCloud),
				finalState: .quarantined,
				acceptIdentity: true
			)

		case .decoded(let cloud):
			if cloud.version > local.version {
				// Schema-newer is the same risk class as unreadable: pushing v2
				// over v3 silently truncates fields. Quarantine until upgrade.
				return Decision(
					action: .rejectMerge(reason: .schemaNewerThanLocal),
					finalState: .quarantined,
					acceptIdentity: true
				)
			}

			if localIsSeed {
				return Decision(action: .applyCloud(cloud), finalState: .active, acceptIdentity: true)
			}

			if cloud.revision == local.revision {
				return Decision(action: .noOp, finalState: .active, acceptIdentity: true)
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
				return Decision(action: .applyCloud(cloud), finalState: .active, acceptIdentity: true)
			} else {
				return Decision(action: .pushLocal, finalState: .active, acceptIdentity: true)
			}
		}
	}
}
