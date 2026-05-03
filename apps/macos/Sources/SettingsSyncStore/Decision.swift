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
}

public struct Decision: Equatable {
	public let action: DecisionAction
	public let finalSuspensionState: Bool
	public let acceptIdentity: Bool

	public init(action: DecisionAction, finalSuspensionState: Bool, acceptIdentity: Bool) {
		self.action = action
		self.finalSuspensionState = finalSuspensionState
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
