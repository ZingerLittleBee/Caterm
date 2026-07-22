import CatermMobile
import KeychainStore
import SwiftUI

/// iOS/iPadOS entry point. A thin SwiftUI shell over `MobileRootView`
/// (owned by the `CatermMobile` SwiftPM library) so the macOS app and
/// AppKit terminal surface stay isolated. Hosts persist to the same
/// `Application Support/Caterm/hosts.json` layout the macOS app uses
/// (sandbox-local on iOS; cross-device consistency is via CloudKit in a
/// later phase, not a shared filesystem).
@main
struct CatermMobileApp: App {
	var body: some Scene {
		WindowGroup {
			Self.makeRootView()
		}
	}

	@MainActor
	private static func makeRootView() -> MobileRootView {
		let credentialWriter = MobileCredentialWriter(
			keychain: KeychainStore(
				service: MobileCredentialWriter.defaultService,
				accessGroup: nil
			)
		)
		let hostStore = MobileHostStore(
			fileURL: hostsURL,
			credentialWriter: credentialWriter
		)
		return MobileRootView(
			hostStore: hostStore,
			credentialWriter: credentialWriter
		)
	}

	private static var hostsURL: URL {
		let supportDir = FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("Caterm", isDirectory: true)
		try? FileManager.default.createDirectory(
			at: supportDir, withIntermediateDirectories: true)
		return supportDir.appendingPathComponent("hosts.json")
	}
}
