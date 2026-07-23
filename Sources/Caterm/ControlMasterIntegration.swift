import FileTransferStore
import SessionStore

// `ControlMasterManager` already exposes the required path and lifecycle
// methods. This conformance lives in the executable target so SessionStore
// remains independent from FileTransferStore.
extension ControlMasterManager: ControlMasterManaging {}
