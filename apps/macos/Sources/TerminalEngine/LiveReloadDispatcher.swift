import Foundation
import SettingsStore

@MainActor
public struct LiveReloadDispatcher {
	public let surfaceIds: @MainActor () -> [String]
	public let applyToSurface: @MainActor (String) -> Void
	public let applyToApp: @MainActor () -> Void
	public let renderManagedSnapshot: @MainActor (PartialSettings) throws -> Void
	public let buildConfig: @MainActor () -> [ConfigDiagnostic]

	public init(
		surfaceIds: @escaping @MainActor () -> [String],
		applyToSurface: @escaping @MainActor (String) -> Void,
		applyToApp: @escaping @MainActor () -> Void,
		renderManagedSnapshot: @escaping @MainActor (PartialSettings) throws -> Void,
		buildConfig: @escaping @MainActor () -> [ConfigDiagnostic]
	) {
		self.surfaceIds = surfaceIds
		self.applyToSurface = applyToSurface
		self.applyToApp = applyToApp
		self.renderManagedSnapshot = renderManagedSnapshot
		self.buildConfig = buildConfig
	}

	public func handle(scope: SettingsChangeScope, settings: CatermSettings) {
		try? renderManagedSnapshot(settings.global)
		switch scope {
		case .globalLive:
			let diagnostics = buildConfig()
			if !diagnostics.isEmpty {
				postDiagnosticsBanner(diagnostics)
			}
			applyToApp()
			for id in surfaceIds() {
				applyToSurface(id)
			}
		case .globalNewSurface:
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
