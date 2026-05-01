import FileTransferStore
import SessionStore

// `ControlMasterManager` already exposes `tearDown(hostId:)` and
// `tearDownAll()` with matching async signatures, so the conformance is
// empty. This file lives in the Caterm executable target so SessionStore
// (a leaf library) doesn't need to depend on FileTransferStore.
extension ControlMasterManager: ControlMasterTearDowning {}
