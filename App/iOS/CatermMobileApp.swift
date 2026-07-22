import CatermMobile
import SwiftUI

/// iOS/iPadOS entry point. A thin SwiftUI shell over `MobileRootView`
/// (owned by the `CatermMobile` SwiftPM library) so the macOS app and
/// AppKit terminal surface stay isolated. Hosts persist to the same
/// `Application Support/Caterm/hosts.json` layout the macOS app uses
/// (sandbox-local on iOS); Hosts, snippets, and shared settings synchronize
/// through iCloud rather than a shared filesystem.
@main
struct CatermMobileApp: App {
	#if canImport(UIKit)
	@UIApplicationDelegateAdaptor(MobilePushDelegate.self) private var pushDelegate
	#endif
	@StateObject private var composition: MobileAppComposition

	init() {
		let supportURL = Self.applicationSupportURL
		let composition = MobileAppComposition.live(
			hostsURL: supportURL.appendingPathComponent("hosts.json"),
			applicationSupportURL: supportURL
		)
		_composition = StateObject(wrappedValue: composition)
		#if canImport(UIKit)
		pushDelegate.hostPushHandler = {
			await composition.syncCoordinator.receivedHostPush()
		}
		pushDelegate.snippetPushHandler = {
			await composition.syncCoordinator.receivedSnippetPush()
		}
		#endif
	}

	var body: some Scene {
		WindowGroup {
			MobileRootView(
				hostStore: composition.hostStore,
				credentialWriter: composition.credentialWriter,
				snippetStore: composition.snippetStore,
				snippetSyncRuntime: composition.snippetSyncRuntime,
				settingsStore: composition.settingsStore,
				syncCoordinator: composition.syncCoordinator,
				terminalSessionFactory: composition.terminalSessionFactory,
				remoteFileClientFactory: composition.remoteFileClientFactory,
				prepareCredentialSyncForSave: composition.prepareCredentialSyncForSave
			)
		}
	}

	private static var applicationSupportURL: URL {
		let supportDir = (FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory)
			.appendingPathComponent("Caterm", isDirectory: true)
		try? FileManager.default.createDirectory(
			at: supportDir, withIntermediateDirectories: true)
		return supportDir
	}
}
