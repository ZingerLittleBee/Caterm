import AppKit

public extension Notification.Name {
	/// Posted by `GhosttySurfaceNSView.performDragOperation` when the user
	/// drops file URLs onto a terminal surface while holding ⌥. Consumers
	/// (e.g. `MainWindow`) read `userInfo["urls"] as? [URL]` and present a
	/// "choose remote target dir" sheet, then enqueue an upload via
	/// `FileTransferStore`. Defined here so this target needs no dependency
	/// on `FileTransferStore` or higher-level UI code.
	static let catermOptionDragUpload = Notification.Name("CatermOptionDragUploadNotification")
}

/// Drag-drop support for `GhosttySurfaceNSView`.
///
/// File URLs from Finder are shell-quoted and joined with spaces, then fed
/// through the same paste path as ⌘V (`pendingPasteText` + the
/// `paste_from_clipboard` binding action). String drags pass through
/// unmodified.
///
/// **⌥-drag exception:** when the user holds Option while dropping file
/// URLs, the paste path is bypassed entirely and a notification is posted
/// (`.catermOptionDragUpload`) so the host app can present an upload sheet.
extension GhosttySurfaceNSView {
	public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
		.copy
	}

	public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
		let pb = sender.draggingPasteboard
		let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
		let optionHeld = NSEvent.modifierFlags.contains(.option)

		// ⌥-drag with file URLs → upload branch. Skip the paste path entirely.
		if optionHeld, !urls.isEmpty {
			NotificationCenter.default.post(
				name: .catermOptionDragUpload,
				object: nil,
				userInfo: ["urls": urls]
			)
			return true
		}

		let composed: String?
		if !urls.isEmpty {
			composed = urls.map { shellEscape($0.path) }.joined(separator: " ")
		} else if let str = pb.string(forType: .string) {
			composed = str
		} else {
			composed = nil
		}
		guard let composed, let surface else { return false }

		surface.pendingPasteText = composed
		surface.pendingLocalPaste = true
		if !surface.triggerBindingAction("paste_from_clipboard") {
			surface.pendingPasteText = nil
			surface.pendingLocalPaste = false
			return false
		}
		return true
	}
}
