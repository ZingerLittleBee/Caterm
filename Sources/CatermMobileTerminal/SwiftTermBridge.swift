#if canImport(UIKit)
import SwiftTerm
import SwiftUI
import UIKit

public struct SwiftTermBridge: UIViewRepresentable {
	@ObservedObject var model: TerminalScreenModel

	public init(model: TerminalScreenModel) {
		self.model = model
	}

	public func makeUIView(context: Context) -> TerminalView {
		let tv = TerminalView(frame: .zero)
		tv.terminalDelegate = context.coordinator
		tv.backgroundColor = .black
		context.coordinator.attach(terminalView: tv)
		model.bindTerminal(context.coordinator)
		return tv
	}

	public func updateUIView(_ uiView: TerminalView, context: Context) {}

	public func makeCoordinator() -> TerminalCoordinator {
		TerminalCoordinator(model: model)
	}
}

public final class TerminalCoordinator: NSObject, TerminalViewDelegate {
	private let model: TerminalScreenModel
	weak var terminalView: TerminalView?

	init(model: TerminalScreenModel) {
		self.model = model
	}

	func attach(terminalView: TerminalView) {
		self.terminalView = terminalView
	}

	public func feed(_ bytes: [UInt8]) {
		terminalView?.feed(byteArray: bytes[...])
	}

	public func send(source: TerminalView, data: ArraySlice<UInt8>) {
		Task { await model.session?.send(Array(data)) }
	}

	public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
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
