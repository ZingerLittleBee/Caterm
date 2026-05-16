import Foundation

/// Read/write façade for the `sshHost` data plane. The HTTP / oRPC concrete
/// implementation has been removed (Plan E); `CloudKitSyncClient` is the
/// surviving conformer. Protocol kept so `IncrementalHostSyncClient` and the
/// `HostSyncStore` test fakes still compile.
public protocol ServerSyncClient: Sendable {
	func listHosts() async throws -> [RemoteHost]
	func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput
	func updateHost(_ input: RemoteHostUpdateInput) async throws
	func deleteHost(id: String) async throws
}
