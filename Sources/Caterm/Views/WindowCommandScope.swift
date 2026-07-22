import AppKit
import Foundation
import SwiftUI

enum WindowCommandScope {
	static func shouldHandle(
		notificationObject: AnyObject?,
		receiverWindow: AnyObject?,
		receiverIsKeyWindow: Bool
	) -> Bool {
		guard let receiverWindow else { return false }
		if let notificationObject {
			return notificationObject === receiverWindow
		}
		return receiverIsKeyWindow
	}

	static func shouldHandle(_ notification: Notification, in window: NSWindow?) -> Bool {
		shouldHandle(
			notificationObject: notification.object as AnyObject?,
			receiverWindow: window,
			receiverIsKeyWindow: window?.isKeyWindow ?? false
		)
	}
}

struct WorkspaceWindowLifecycleObserver: NSViewRepresentable {
	@Binding var window: NSWindow?
	let onClose: () -> Void

	func makeNSView(context _: Context) -> WorkspaceWindowLifecycleView {
		let view = WorkspaceWindowLifecycleView()
		configure(view)
		return view
	}

	func updateNSView(_ view: WorkspaceWindowLifecycleView, context _: Context) {
		configure(view)
	}

	static func dismantleNSView(
		_ view: WorkspaceWindowLifecycleView,
		coordinator _: ()
	) {
		view.stopObserving()
	}

	private func configure(_ view: WorkspaceWindowLifecycleView) {
		view.onWindowChange = { window = $0 }
		view.onClose = onClose
	}
}

final class WorkspaceWindowLifecycleView: NSView {
	var onWindowChange: ((NSWindow?) -> Void)?
	var onClose: (() -> Void)?

	private weak var observedWindow: NSWindow?
	private var closeObserver: NSObjectProtocol?

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard observedWindow !== window else { return }
		stopObserving()
		observedWindow = window
		onWindowChange?(window)
		guard let window else { return }
		closeObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.willCloseNotification,
			object: window,
			queue: .main
		) { [weak self] _ in
			self?.onClose?()
		}
	}

	func stopObserving() {
		if let closeObserver {
			NotificationCenter.default.removeObserver(closeObserver)
		}
		closeObserver = nil
		observedWindow = nil
	}

	deinit {
		if let closeObserver {
			NotificationCenter.default.removeObserver(closeObserver)
		}
	}
}

struct SyncSettingsCommandBridge: View {
	@State private var window: NSWindow?
	let openSyncSettings: () -> Void

	var body: some View {
		WindowAccessor(window: $window)
			.frame(width: 0, height: 0)
			.onReceive(
				NotificationCenter.default.publisher(for: .catermOpenSyncSettings)
			) { notification in
				guard WindowCommandScope.shouldHandle(notification, in: window) else {
					return
				}
				openSyncSettings()
			}
	}
}
