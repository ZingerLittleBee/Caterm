import Foundation
import ServerSyncClient

public enum SyncOperation: Equatable, Sendable {
	case createRemote(localHostId: UUID)
	case createLocal(remote: RemoteHost)
	case updateRemote(localHostId: UUID, serverId: String)
	case updateLocal(localHostId: UUID, remote: RemoteHost)
	case deleteLocal(localHostId: UUID)
	case updateRemoteCredentials(localHostId: UUID)
}
