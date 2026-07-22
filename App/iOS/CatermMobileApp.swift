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
	}

	var body: some Scene {
		WindowGroup {
			MobileRootView(
				hostStore: composition.hostStore,
				credentialWriter: composition.credentialWriter,
				syncRuntime: composition.syncRuntime,
				terminalSessionFactory: composition.terminalSessionFactory,
				prepareCredentialSyncForSave: composition.prepareCredentialSyncForSave,
				startObservingAccountChanges: composition.startObservingAccountChanges
			)
			#if canImport(UIKit)
			.task {
				pushDelegate.hostPushHandler = {
					await composition.syncRuntime.receivedCloudKitPush()
				}
			}
			#endif
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
