import Foundation
import SettingsStore

public enum DecisionAction: Equatable {
	case noOp
	case pushLocal
	case applyCloud(SyncableSettings)
	case rejectMerge(reason: RejectReason)
	case forceApply(SyncableSettings)
	case suspendUntilFirstEdit
}

public enum RejectReason: Equatable {
	case schemaNewerThanLocal
	/// Cloud blob present but undecodable — corruption, partial write, or a
	/// future schema with renamed/removed fields. Routed to quarantine to
	/// avoid silently overwriting cloud data we can't read.
	case unreadableCloud
}

/// Post-decision sync state. Replaces the earlier `finalSuspensionState: Bool`
/// because a single suspension flag conflated three semantically different
/// outcomes:
/// - `active`: observer-plane push allowed.
/// - `suspendUntilFirstEdit`: first user edit unfreezes, pushes, and (if
///   `acceptIdentity`) persists the new identity token. Used for the cross-
///   identity-with-empty-Y boot path.
/// - `quarantined`: first user edit does NOT push and does NOT unfreeze.
///   Used for schema-reject and unreadable-cloud outcomes — pushing local
///   would overwrite the cloud blob we deliberately refused to apply. The
///   next successful pull (e.g. cloud blob is replaced by a readable
///   compatible version) transitions out of quarantine via classifyAndApply.
public enum SyncStateOutcome: Equatable {
	case active
	case suspendUntilFirstEdit
	case quarantined
}

public struct Decision: Equatable {
	public let action: DecisionAction
	public let finalState: SyncStateOutcome
	public let acceptIdentity: Bool

	public init(action: DecisionAction, finalState: SyncStateOutcome, acceptIdentity: Bool) {
		self.action = action
		self.finalState = finalState
		self.acceptIdentity = acceptIdentity
	}
}

public extension DecisionAction {
	/// Tag-only comparison used in unit tests where the associated payload
	/// of `.applyCloud` / `.forceApply` is incidental.
	var tag: String {
		switch self {
		case .noOp: return "noOp"
		case .pushLocal: return "pushLocal"
		case .applyCloud: return "applyCloud"
		case .rejectMerge: return "rejectMerge"
		case .forceApply: return "forceApply"
		case .suspendUntilFirstEdit: return "suspendUntilFirstEdit"
		}
	}
}

/// Three-state cloud read so deciders can distinguish "key absent" from
/// "key present but undecodable". The previous shape collapsed both into
/// `nil`, allowing a corrupted/future-schema blob to be silently overwritten
/// by a local push.
public enum CloudReadResult {
	case absent
	case decoded(SyncableSettings)
	case unreadable(Error)
}
