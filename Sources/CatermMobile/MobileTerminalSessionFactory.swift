import CatermMobileTerminal
import SwiftUI
import SSHCommandBuilder

public struct MobileTerminalSessionFactory {
	public let make: @MainActor (SSHHost) async throws -> SSHTerminalSession

	public init(
		make: @escaping @MainActor (SSHHost) async throws -> SSHTerminalSession
	) {
		self.make = make
	}
}

private struct MobileTerminalSessionFactoryKey: EnvironmentKey {
	static let defaultValue: MobileTerminalSessionFactory? = nil
}

public extension EnvironmentValues {
	var mobileTerminalSessionFactory: MobileTerminalSessionFactory? {
		get { self[MobileTerminalSessionFactoryKey.self] }
		set { self[MobileTerminalSessionFactoryKey.self] = newValue }
	}
}
