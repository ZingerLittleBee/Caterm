import Foundation
import SSHCommandBuilder

public enum MobileHostRoute: Hashable {
	case detail(UUID)
	case edit(UUID)
	case credentialSetup(UUID)
	case terminalPlaceholder(UUID)
}

public enum MobileHostDestructiveAction: Hashable {
	case confirmDelete(UUID)
}

public enum MobileHostActions {
	public static func connectRoute(for host: SSHHost, needsCredentialSetup: Bool) -> MobileHostRoute {
		needsCredentialSetup ? .credentialSetup(host.id) : .terminalPlaceholder(host.id)
	}

	public static func editRoute(for host: SSHHost) -> MobileHostRoute {
		.edit(host.id)
	}

	public static func deleteAction(for host: SSHHost) -> MobileHostDestructiveAction {
		.confirmDelete(host.id)
	}
}
