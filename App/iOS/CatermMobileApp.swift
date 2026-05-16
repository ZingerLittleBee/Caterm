import CatermMobile
import SwiftUI

/// iOS/iPadOS entry point. The runnable app is intentionally a thin shell
/// over `MobileCatermShell` (owned by the `CatermMobile` SwiftPM library)
/// so the macOS app and AppKit terminal surface stay isolated. Phase-1
/// injects no production stores yet; the shell renders its own mobile UI.
@main
struct CatermMobileApp: App {
	var body: some Scene {
		WindowGroup {
			MobileCatermShell()
		}
	}
}
