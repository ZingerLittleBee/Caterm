import Foundation

extension Notification.Name {
	/// Posted when the user invokes the View > Toggle Files Drawer command
	/// (⌘⇧F). `MainWindow` listens and flips its local `fileDrawerOpen`
	/// state.
	static let toggleFileDrawer = Notification.Name("CatermToggleFileDrawerNotification")
}
