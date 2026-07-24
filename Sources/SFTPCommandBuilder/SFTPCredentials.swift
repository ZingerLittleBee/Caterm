import Foundation

public struct SFTPCredentials: Sendable {
	public let askpassPath: URL?
	public let identityFiles: [URL]
	public let knownHostsCaterm: URL
	public let knownHostsUser: URL
	public let strictHostKeyChecking: StrictHostKeyChecking
	public let extraSSHOptions: [String: String]

	public init(knownHostsCaterm: URL, knownHostsUser: URL,
	            strictHostKeyChecking: StrictHostKeyChecking,
	            extraSSHOptions: [String: String] = [:]) {
		askpassPath = nil
		identityFiles = []
		self.knownHostsCaterm = knownHostsCaterm
		self.knownHostsUser = knownHostsUser
		self.strictHostKeyChecking = strictHostKeyChecking
		self.extraSSHOptions = extraSSHOptions
	}

	@available(*, deprecated, message: "SFTP ignores fresh-auth material and only reuses ControlMaster")
	public init(
		askpassPath: URL?,
		identityFiles: [URL],
		knownHostsCaterm: URL,
		knownHostsUser: URL,
		strictHostKeyChecking: StrictHostKeyChecking,
		extraSSHOptions: [String: String] = [:]
	) {
		self.askpassPath = askpassPath
		self.identityFiles = identityFiles
		self.knownHostsCaterm = knownHostsCaterm
		self.knownHostsUser = knownHostsUser
		self.strictHostKeyChecking = strictHostKeyChecking
		self.extraSSHOptions = extraSSHOptions
	}
}

public enum StrictHostKeyChecking: String, Sendable {
	case yes = "yes"
	case acceptNew = "accept-new"
	case no = "no"
}

public let SFTPCredentialsDenylist: Set<String> = [
	"controlmaster", "controlpath", "controlpersist",
	"batchmode", "preferredauthentications",
	"proxycommand", "proxyjump", "hostname",
]

public enum SFTPBatchLineError: Error, Equatable {
	case lineTooLong(bytes: Int, limit: Int)
}
