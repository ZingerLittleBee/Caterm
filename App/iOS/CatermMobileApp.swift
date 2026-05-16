import CatermMobile
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
			MobileRootView(hostStore: MobileHostStore(fileURL: Self.hostsURL))
		}
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
