import AppKit

/// Responder-chain targets for `copy(_:)`, `paste(_:)`, and
/// `pasteAsPlainText(_:)` plus the right-click context menu.
///
/// AppKit's stock Edit menu items dispatch via `NSApp.sendAction(#selector,
/// to: nil, …)`, which walks the responder chain looking for any object that
/// responds to the selector. Our `GhosttySurfaceNSView` is the first
/// responder while focused, so these methods are the receivers.
///
/// Menu-item enable/disable state is driven via `NSMenuItemValidation`. The
/// stock SwiftUI `CommandGroup(replacing: .pasteboard)` items send their
/// selector through `NSApp.sendAction`, which calls this protocol method on
/// the eventual target before firing.
extension GhosttySurfaceNSView: NSMenuItemValidation {

	@objc public func copy(_ sender: Any?) {
		guard let text = surface?.readSelection(), !text.isEmpty else { return }
		let pb = NSPasteboard.general
		pb.clearContents()
		pb.setString(text, forType: .string)
	}

	@objc public func paste(_ sender: Any?) {
		guard let surface else { return }
		surface.pendingLocalPaste = true
		if !surface.triggerBindingAction("paste_from_clipboard") {
			surface.pendingLocalPaste = false
		}
	}

	@objc public func pasteAsPlainText(_ sender: Any?) {
		// Terminals don't render styled text — same path as paste.
		paste(sender)
	}

	public func validateMenuItem(_ item: NSMenuItem) -> Bool {
		switch item.action {
		case #selector(copy(_:)):
			return surface?.hasSelection == true
		case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
			return NSPasteboard.general.string(forType: .string) != nil
		default:
			return true
		}
	}

	public override func menu(for event: NSEvent) -> NSMenu? {
		let m = NSMenu()
		m.addItem(.init(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
		m.addItem(.init(title: "Paste", action: #selector(paste(_:)), keyEquivalent: ""))
		return m
	}
}
