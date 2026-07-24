import Foundation
import TerminalEngine

/// Maps runtime session UUIDs to live `GhosttySurface` instances using weak references,
/// so the registry never prevents a surface from being deallocated when its
/// owning view is torn down by SwiftUI.
///
/// Lifecycle:
///  - `register(_:for:)` is called in `TerminalContainerView` once the surface
///    becomes non-nil (polled in the post-`makeNSView` task).
///  - `unregister(_:)` is called when the owning Workspace window explicitly
///    closes, before its runtime session is removed from `SessionStore`.
///
/// All methods are `@MainActor`-isolated because `GhosttySurface` and
/// `SessionStore` are both main-actor-only.
@MainActor
public final class SurfaceRegistry: ObservableObject {
	private var surfaces: [UUID: WeakSurfaceBox] = [:]
	@Published public private(set) var revision: UInt64 = 0

	private final class WeakSurfaceBox {
		weak var surface: GhosttySurface?
		let leaseID: UUID

		init(_ surface: GhosttySurface, leaseID: UUID = UUID()) {
			self.surface = surface
			self.leaseID = leaseID
		}
	}

	public init() {}

	public func register(_ surface: GhosttySurface, for tabId: UUID) {
		surfaces[tabId] = WeakSurfaceBox(surface)
		revision &+= 1
	}

	public func surface(for tabId: UUID) -> GhosttySurface? {
		surfaces[tabId]?.surface
	}

	public func leaseID(for tabId: UUID) -> UUID? {
		guard let box = surfaces[tabId], box.surface != nil else {
			surfaces.removeValue(forKey: tabId)
			return nil
		}
		return box.leaseID
	}

	public func surface(for tabId: UUID, leaseID: UUID) -> GhosttySurface? {
		guard let box = surfaces[tabId], box.leaseID == leaseID else { return nil }
		return box.surface
	}

	public func activeTabIds() -> [UUID] {
		surfaces = surfaces.filter { $0.value.surface != nil }
		return Array(surfaces.keys)
	}

	public func unregister(_ tabId: UUID) {
		guard surfaces.removeValue(forKey: tabId) != nil else { return }
		revision &+= 1
	}
}
