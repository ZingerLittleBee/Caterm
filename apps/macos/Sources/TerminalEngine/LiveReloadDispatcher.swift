import Foundation
import SettingsStore

@MainActor
public struct LiveReloadDispatcher {
	public let surfaceIds: () -> [String]
	public let applyToSurface: (String) -> Void
	public let applyToApp: () -> Void
	public let renderManagedSnapshot: (PartialSettings) throws -> Void
	public let buildConfig: () -> [ConfigDiagnostic]

	public init(
		surfaceIds: @escaping () -> [String],
		applyToSurface: @escaping (String) -> Void,
		applyToApp: @escaping () -> Void,
		renderManagedSnapshot: @escaping (PartialSettings) throws -> Void,
		buildConfig: @escaping () -> [ConfigDiagnostic]
	) {
		self.surfaceIds = surfaceIds
		self.applyToSurface = applyToSurface
		self.applyToApp = applyToApp
		self.renderManagedSnapshot = renderManagedSnapshot
		self.buildConfig = buildConfig
	}

	public func handle(scope: SettingsChangeScope, settings: CatermSettings) {
		try? renderManagedSnapshot(settings.global)
		let diagnostics = buildConfig()
		if !diagnostics.isEmpty {
			postDiagnosticsBanner(diagnostics)
		}
		switch scope {
		case .globalLive:
			applyToApp()
			for id in surfaceIds() {
				applyToSurface(id)
			}
		case .globalNewSurface:
			applyToApp()
			postNewSurfaceBanner()
		case .hostOverride:
			// No-op for existing surfaces; new surfaces apply patch via the
			// per-host hook in GhosttySurface.applyPerHostPatch (Task 18).
			break
		}
	}

	private func postDiagnosticsBanner(_ diagnostics: [ConfigDiagnostic]) {
		NotificationCenter.default.post(
			name: Notification.Name("catermConfigDiagnostics"),
			object: nil,
			userInfo: ["diagnostics": diagnostics.map(\.message)]
		)
	}

	private func postNewSurfaceBanner() {
		NotificationCenter.default.post(
			name: Notification.Name("catermNewSurfaceBanner"),
			object: nil
		)
	}
}
