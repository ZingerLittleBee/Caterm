import AppKit

/// Drag-drop support for `GhosttySurfaceNSView`.
///
/// File URLs from Finder are shell-quoted and joined with spaces, then fed
/// through the same paste path as ⌘V (`pendingPasteText` + the
/// `paste_from_clipboard` binding action). String drags pass through
/// unmodified.
extension GhosttySurfaceNSView {
	public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
		.copy
	}

	public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
		let pb = sender.draggingPasteboard
		let composed: String?
		if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
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
