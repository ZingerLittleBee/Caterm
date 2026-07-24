import AppKit
import SwiftUI
import WorkspaceCore

struct NativeWorkspaceTreeView: NSViewRepresentable {
	let topology: WorkspaceTopology
	let activePaneID: PaneID
	let presentation: WorkspacePresentation
	let paneAccessibilityLabel: (WorkspacePane) -> String?
	let paneContent: (WorkspacePane) -> AnyView
	let onRatioChange: (SplitID, Double) -> Void

	init(
		topology: WorkspaceTopology,
		activePaneID: PaneID,
		presentation: WorkspacePresentation,
		paneAccessibilityLabel: @escaping (WorkspacePane) -> String? = { _ in nil },
		paneContent: @escaping (WorkspacePane) -> AnyView,
		onRatioChange: @escaping (SplitID, Double) -> Void
	) {
		self.topology = topology
		self.activePaneID = activePaneID
		self.presentation = presentation
		self.paneAccessibilityLabel = paneAccessibilityLabel
		self.paneContent = paneContent
		self.onRatioChange = onRatioChange
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(onRatioChange: onRatioChange)
	}

	func makeNSView(context: Context) -> WorkspaceTreeContainerView {
		let container = WorkspaceTreeContainerView()
		context.coordinator.update(
			container,
			topology: topology,
			activePaneID: activePaneID,
			presentation: presentation,
			paneAccessibilityLabel: paneAccessibilityLabel,
			paneContent: paneContent,
			onRatioChange: onRatioChange
		)
		return container
	}

	func updateNSView(_ container: WorkspaceTreeContainerView, context: Context) {
		context.coordinator.update(
			container,
			topology: topology,
			activePaneID: activePaneID,
			presentation: presentation,
			paneAccessibilityLabel: paneAccessibilityLabel,
			paneContent: paneContent,
			onRatioChange: onRatioChange
		)
	}

	@MainActor
	final class Coordinator {
		private var paneHosts: [PaneID: NSHostingView<AnyView>] = [:]
		private var splitViews: [SplitID: ManagedWorkspaceSplitView] = [:]
		private var onRatioChange: (SplitID, Double) -> Void

		init(onRatioChange: @escaping (SplitID, Double) -> Void) {
			self.onRatioChange = onRatioChange
		}

		func update(
			_ container: WorkspaceTreeContainerView,
			topology: WorkspaceTopology,
			activePaneID: PaneID,
			presentation: WorkspacePresentation,
			paneAccessibilityLabel: (WorkspacePane) -> String? = { _ in nil },
			paneContent: (WorkspacePane) -> AnyView,
			onRatioChange: @escaping (SplitID, Double) -> Void
		) {
			self.onRatioChange = onRatioChange
			let root = view(
				for: topology,
				activePaneID: activePaneID,
				presentation: presentation,
				paneAccessibilityLabel: paneAccessibilityLabel,
				paneContent: paneContent
			)
			container.install(root)

			let livePaneIDs = Set(topology.paneIDs)
			for paneID in Array(paneHosts.keys) where !livePaneIDs.contains(paneID) {
				paneHosts.removeValue(forKey: paneID)
			}
			let liveSplitIDs = Set(topology.splitIDs)
			for splitID in Array(splitViews.keys) where !liveSplitIDs.contains(splitID) {
				splitViews.removeValue(forKey: splitID)
			}
		}

		private func view(
			for topology: WorkspaceTopology,
			activePaneID: PaneID,
			presentation: WorkspacePresentation,
			paneAccessibilityLabel: (WorkspacePane) -> String?,
			paneContent: (WorkspacePane) -> AnyView
		) -> NSView {
			switch topology {
			case .pane(let pane):
				let host: NSHostingView<AnyView>
				if let existing = paneHosts[pane.id] {
					host = existing
					host.rootView = paneContent(pane)
				} else {
					host = NSHostingView(rootView: paneContent(pane))
					paneHosts[pane.id] = host
				}
				configureAccessibility(
					host,
					paneID: pane.id,
					label: paneAccessibilityLabel(pane)
				)
				return host
			case .split(let split):
				let splitView = splitViews[split.id] ?? ManagedWorkspaceSplitView()
				splitViews[split.id] = splitView
				let first = view(
					for: split.first,
					activePaneID: activePaneID,
					presentation: presentation,
					paneAccessibilityLabel: paneAccessibilityLabel,
					paneContent: paneContent
				)
				let second = view(
					for: split.second,
					activePaneID: activePaneID,
					presentation: presentation,
					paneAccessibilityLabel: paneAccessibilityLabel,
					paneContent: paneContent
				)
				let geometry = displayedGeometry(
					for: split,
					activePaneID: activePaneID,
					presentation: presentation
				)
				splitView.configure(
					axis: split.axis,
					ratio: geometry.ratio,
					firstMinimumLength: geometry.firstMinimumLength,
					secondMinimumLength: geometry.secondMinimumLength,
					first: first,
					second: second,
					onRatioChange: { [weak self] ratio in
						guard presentation == .split else { return }
						self?.onRatioChange(split.id, ratio)
					}
				)
				return splitView
			}
		}

		private func configureAccessibility(
			_ host: NSHostingView<AnyView>,
			paneID: PaneID,
			label: String?
		) {
			guard let label else { return }
			host.setAccessibilityElement(true)
			host.setAccessibilityRole(.group)
			host.setAccessibilityLabel(label)
			host.setAccessibilityIdentifier("workspace-pane-\(paneID.rawValue.uuidString)")
		}

		private func displayedGeometry(
			for split: WorkspaceSplit,
			activePaneID: PaneID,
			presentation: WorkspacePresentation
		) -> (ratio: Double, firstMinimumLength: CGFloat, secondMinimumLength: CGFloat) {
			let firstMinimum = WorkspaceTreeMinimumLength.length(
				for: split.first,
				along: split.axis,
				activePaneID: activePaneID,
				presentation: presentation
			)
			let secondMinimum = WorkspaceTreeMinimumLength.length(
				for: split.second,
				along: split.axis,
				activePaneID: activePaneID,
				presentation: presentation
			)
			let ratio: Double
			if presentation == .focus, split.first.contains(activePaneID) {
				ratio = 0.92
			} else if presentation == .focus, split.second.contains(activePaneID) {
				ratio = 0.08
			} else {
				ratio = split.ratio
			}
			return (ratio, firstMinimum, secondMinimum)
		}
	}
}

final class WorkspaceTreeContainerView: NSView {
	private weak var installedView: NSView?
	private var installedConstraints: [NSLayoutConstraint] = []

	func install(_ view: NSView) {
		guard installedView !== view else { return }
		NSLayoutConstraint.deactivate(installedConstraints)
		installedConstraints.removeAll()
		if installedView?.superview === self {
			installedView?.removeFromSuperview()
		}
		installedView = view
		view.translatesAutoresizingMaskIntoConstraints = false
		addSubview(view)
		installedConstraints = [
			view.leadingAnchor.constraint(equalTo: leadingAnchor),
			view.trailingAnchor.constraint(equalTo: trailingAnchor),
			view.topAnchor.constraint(equalTo: topAnchor),
			view.bottomAnchor.constraint(equalTo: bottomAnchor),
		]
		NSLayoutConstraint.activate(installedConstraints)
	}
}

@MainActor
final class ManagedWorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
	private var desiredRatio = 0.5
	private var firstMinimumLength: CGFloat = 160
	private var secondMinimumLength: CGFloat = 160
	private var isApplyingRatio = false
	private var onRatioChange: (Double) -> Void = { _ in }

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		dividerStyle = .thin
		delegate = self
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		dividerStyle = .thin
		delegate = self
	}

	override func layout() {
		super.layout()
		guard !isApplyingRatio else { return }
		applyDesiredRatio()
	}

	func configure(
		axis: WorkspaceSplitAxis,
		ratio: Double,
		firstMinimumLength: CGFloat,
		secondMinimumLength: CGFloat,
		first: NSView,
		second: NSView,
		onRatioChange: @escaping (Double) -> Void
	) {
		isVertical = axis == .horizontal
		desiredRatio = ratio
		self.firstMinimumLength = firstMinimumLength
		self.secondMinimumLength = secondMinimumLength
		self.onRatioChange = onRatioChange
		isApplyingRatio = true
		installArrangedSubviews([first, second])
		isApplyingRatio = false
		DispatchQueue.main.async { [weak self] in
			self?.applyDesiredRatio()
		}
	}

	func splitViewDidResizeSubviews(_ notification: Notification) {
		guard !isApplyingRatio, notification.object as? NSSplitView === self,
		      subviews.count == 2 else {
			return
		}
		let available = availableLength
		guard available > 0 else { return }
		let firstLength = isVertical ? subviews[0].frame.width : subviews[0].frame.height
		let ratio = min(max(firstLength / available, 0), 1)
		guard abs(ratio - desiredRatio) > 0.002 else { return }
		desiredRatio = ratio
		onRatioChange(ratio)
	}

	func splitView(
		_ splitView: NSSplitView,
		constrainMinCoordinate proposedMinimumPosition: CGFloat,
		ofSubviewAt dividerIndex: Int
	) -> CGFloat {
		guard dividerIndex == 0 else { return proposedMinimumPosition }
		return max(proposedMinimumPosition, firstMinimumLength)
	}

	func splitView(
		_ splitView: NSSplitView,
		constrainMaxCoordinate proposedMaximumPosition: CGFloat,
		ofSubviewAt dividerIndex: Int
	) -> CGFloat {
		guard dividerIndex == 0 else { return proposedMaximumPosition }
		let maximum = availableLength - secondMinimumLength
		return min(proposedMaximumPosition, max(firstMinimumLength, maximum))
	}

	private func installArrangedSubviews(_ desired: [NSView]) {
		guard arrangedSubviews.count != desired.count
			|| zip(arrangedSubviews, desired).contains(where: { $0 !== $1 }) else {
			return
		}
		for subview in arrangedSubviews {
			removeArrangedSubview(subview)
			if subview.superview === self {
				subview.removeFromSuperview()
			}
		}
		for subview in desired {
			subview.translatesAutoresizingMaskIntoConstraints = true
			addArrangedSubview(subview)
		}
	}

	private func applyDesiredRatio() {
		let available = availableLength
		guard available > 0, subviews.count == 2 else { return }
		let requested = CGFloat(desiredRatio) * available
		let maximum = max(firstMinimumLength, available - secondMinimumLength)
		let position = min(max(requested, firstMinimumLength), maximum)
		let current = isVertical ? subviews[0].frame.width : subviews[0].frame.height
		guard abs(current - position) > 0.5 else { return }
		isApplyingRatio = true
		setPosition(position, ofDividerAt: 0)
		isApplyingRatio = false
	}

	private var availableLength: CGFloat {
		let total = isVertical ? bounds.width : bounds.height
		return max(0, total - dividerThickness)
	}
}

enum WorkspaceTreeMinimumLength {
	static let pane: CGFloat = 160
	static let compactPane: CGFloat = 48
	static let divider: CGFloat = 1

	static func length(
		for topology: WorkspaceTopology,
		along axis: WorkspaceSplitAxis,
		activePaneID: PaneID,
		presentation: WorkspacePresentation
	) -> CGFloat {
		switch topology {
		case .pane(let paneNode):
			return presentation == .focus && paneNode.id != activePaneID
				? compactPane
				: pane
		case .split(let split):
			let first = length(
				for: split.first,
				along: axis,
				activePaneID: activePaneID,
				presentation: presentation
			)
			let second = length(
				for: split.second,
				along: axis,
				activePaneID: activePaneID,
				presentation: presentation
			)
			return split.axis == axis
				? first + divider + second
				: max(first, second)
		}
	}
}
