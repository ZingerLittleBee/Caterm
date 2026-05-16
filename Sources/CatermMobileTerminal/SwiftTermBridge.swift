#if canImport(UIKit)
import SwiftTerm
import SwiftUI
import UIKit

/// Displays a `TerminalScreenModel`'s **retained** `TerminalView`. The
/// view (and therefore the SSH session + scrollback) is owned by the
/// model, so switching tabs only re-parents it — it never tears the
/// session down.
public struct SwiftTermBridge: UIViewRepresentable {
	@ObservedObject var model: TerminalScreenModel

	public init(model: TerminalScreenModel) {
		self.model = model
	}

	public func makeUIView(context: Context) -> TerminalHostView {
		let host = TerminalHostView()
		host.mount(model.terminalView)
		return host
	}

	public func updateUIView(_ uiView: TerminalHostView, context: Context) {
		uiView.mount(model.terminalView)
	}
}

/// Plain container that re-parents whichever tab's terminal is visible.
public final class TerminalHostView: UIView {
	private weak var mounted: TerminalView?

	func mount(_ tv: TerminalView) {
		guard mounted !== tv else { return }
		mounted?.removeFromSuperview()
		tv.removeFromSuperview()
		tv.translatesAutoresizingMaskIntoConstraints = false
		addSubview(tv)
		NSLayoutConstraint.activate([
			tv.leadingAnchor.constraint(equalTo: leadingAnchor),
			tv.trailingAnchor.constraint(equalTo: trailingAnchor),
			tv.topAnchor.constraint(equalTo: topAnchor),
			tv.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
		mounted = tv
	}
}

public final class TerminalCoordinator: NSObject, TerminalViewDelegate {
	weak var model: TerminalScreenModel?
	weak var terminalView: TerminalView?

	func feed(_ bytes: [UInt8]) {
		terminalView?.feed(byteArray: bytes[...])
	}

	public func send(source: TerminalView, data: ArraySlice<UInt8>) {
		guard let model else { return }
		Task { await model.session?.send(Array(data)) }
	}

	public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
		guard let model else { return }
		Task { await model.session?.resize(.init(cols: newCols, rows: newRows)) }
	}

	public func setTerminalTitle(source: TerminalView, title: String) {}
	public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
	public func scrolled(source: TerminalView, position: Double) {}
	public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
	public func bell(source: TerminalView) {}
	public func clipboardCopy(source: TerminalView, content: Data) {}
	public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
	public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
