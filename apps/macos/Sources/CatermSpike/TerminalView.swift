import AppKit
import SwiftUI

struct TerminalView: NSViewRepresentable {
    let bridge: GhosttyBridge

    func makeNSView(context: Context) -> NSView {
        let view = TerminalNSView()
        view.bridge = bridge
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class TerminalNSView: NSView {
    var bridge: GhosttyBridge?
    private var didCreateSurface = false

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didCreateSurface, window != nil, let bridge else { return }
        do {
            try bridge.createSurface(forView: self)
            didCreateSurface = true
            window?.makeFirstResponder(self)
            propagateSize()
            bridge.setFocus(true)
        } catch {
            print("[spike] surface creation failed: \(error)")
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard didCreateSurface else { return }
        propagateSize()
    }

    override func becomeFirstResponder() -> Bool {
        bridge?.setFocus(true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        bridge?.setFocus(false)
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard let bridge else { return super.keyDown(with: event) }
        bridge.feedKey(event: event)
    }

    private func propagateSize() {
        guard let bridge else { return }
        let scaled = convertToBacking(bounds.size)
        let width = UInt32(max(1, scaled.width))
        let height = UInt32(max(1, scaled.height))
        bridge.setSize(width: width, height: height)
    }
}
