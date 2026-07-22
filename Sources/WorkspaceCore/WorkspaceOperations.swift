import Foundation

public enum WorkspaceSplitPlacement: Hashable, Sendable {
	case right
	case down

	var axis: WorkspaceSplitAxis {
		switch self {
		case .right: .horizontal
		case .down: .vertical
		}
	}
}

public enum WorkspaceFocusDirection: Hashable, Sendable {
	case left
	case right
	case up
	case down
}

public enum WorkspaceFocusCycle: Hashable, Sendable {
	case previous
	case next
}

public struct WorkspacePaneCloseResult: Equatable, Sendable {
	public let workspace: Workspace?
	public let closedPaneID: PaneID
	public let shouldCloseWindow: Bool

	init(workspace: Workspace?, closedPaneID: PaneID, shouldCloseWindow: Bool) {
		self.workspace = workspace
		self.closedPaneID = closedPaneID
		self.shouldCloseWindow = shouldCloseWindow
	}
}

public extension Workspace {
	enum OperationError: Swift.Error, Equatable, Sendable {
		case paneNotFound
		case paneIdentityAlreadyExists
		case paneAlreadyConnected
		case splitNotFound
		case splitIdentityAlreadyExists
		case nonFiniteRatio
	}

	func splittingActivePane(
		_ placement: WorkspaceSplitPlacement,
		newPaneID: PaneID = PaneID(),
		splitID: SplitID = SplitID()
	) throws -> Workspace {
		guard topology.contains(activePaneID) else {
			throw OperationError.paneNotFound
		}
		guard !topology.contains(newPaneID) else {
			throw OperationError.paneIdentityAlreadyExists
		}
		guard !topology.contains(splitID: splitID) else {
			throw OperationError.splitIdentityAlreadyExists
		}
		let replacement: (WorkspaceTopology) -> WorkspaceTopology = { activeLeaf in
			.split(WorkspaceSplit(
				id: splitID,
				axis: placement.axis,
				first: activeLeaf,
				second: .pane(WorkspacePane(id: newPaneID, content: .hostPicker))
			))
		}
		guard let updatedTopology = topology.replacingPane(
			activePaneID,
			with: replacement
		) else {
			throw OperationError.paneNotFound
		}
		return Workspace(
			validatedVersion: Workspace.currentVersion,
			id: id,
			topology: updatedTopology,
			activePaneID: newPaneID,
			presentation: presentation
		)
	}

	func assigningHost(
		_ host: WorkspaceHostReference,
		to paneID: PaneID
	) throws -> Workspace {
		guard let pane = topology.pane(id: paneID) else {
			throw OperationError.paneNotFound
		}
		guard pane.host == nil else {
			throw OperationError.paneAlreadyConnected
		}
		guard let updatedTopology = topology.replacingPane(
			paneID,
			with: { _ in .pane(WorkspacePane(id: paneID, host: host)) }
		) else {
			throw OperationError.paneNotFound
		}
		return Workspace(
			validatedVersion: Workspace.currentVersion,
			id: id,
			topology: updatedTopology,
			activePaneID: activePaneID,
			presentation: presentation
		)
	}

	func activatingPane(_ paneID: PaneID) throws -> Workspace {
		guard topology.contains(paneID) else {
			throw OperationError.paneNotFound
		}
		return replacing(activePaneID: paneID)
	}

	func focusing(_ direction: WorkspaceFocusDirection) -> Workspace {
		let frames = topology.paneFrames()
		guard let active = frames.first(where: { $0.paneID == activePaneID }) else {
			return self
		}
		let candidates = frames.filter { frame in
			guard frame.paneID != activePaneID else { return false }
			switch direction {
			case .left: return frame.rect.midX < active.rect.midX
			case .right: return frame.rect.midX > active.rect.midX
			case .up: return frame.rect.midY < active.rect.midY
			case .down: return frame.rect.midY > active.rect.midY
			}
		}
		guard let target = candidates.min(by: { lhs, rhs in
			let lhsScore = lhs.rect.focusScore(from: active.rect, direction: direction)
			let rhsScore = rhs.rect.focusScore(from: active.rect, direction: direction)
			if lhsScore.primary != rhsScore.primary {
				return lhsScore.primary < rhsScore.primary
			}
			if lhsScore.secondary != rhsScore.secondary {
				return lhsScore.secondary < rhsScore.secondary
			}
			return lhs.order < rhs.order
		}) else {
			return self
		}
		return replacing(activePaneID: target.paneID)
	}

	func cyclingFocus(_ cycle: WorkspaceFocusCycle) -> Workspace {
		let paneIDs = topology.paneIDs
		guard paneIDs.count > 1,
		      let activeIndex = paneIDs.firstIndex(of: activePaneID) else {
			return self
		}
		let targetIndex: Int
		switch cycle {
		case .previous:
			targetIndex = (activeIndex - 1 + paneIDs.count) % paneIDs.count
		case .next:
			targetIndex = (activeIndex + 1) % paneIDs.count
		}
		return replacing(activePaneID: paneIDs[targetIndex])
	}

	func togglingPresentation() -> Workspace {
		let next: WorkspacePresentation = presentation == .split ? .focus : .split
		return replacing(presentation: next)
	}

	func updatingSplitRatio(
		_ ratio: Double,
		splitID: SplitID
	) throws -> Workspace {
		guard ratio.isFinite else { throw OperationError.nonFiniteRatio }
		guard let updatedTopology = topology.updatingSplit(splitID, with: { split in
			WorkspaceSplit(
				id: split.id,
				axis: split.axis,
				ratio: ratio,
				first: split.first,
				second: split.second
			)
		}) else {
			throw OperationError.splitNotFound
		}
		return Workspace(
			validatedVersion: Workspace.currentVersion,
			id: id,
			topology: updatedTopology,
			activePaneID: activePaneID,
			presentation: presentation
		)
	}

	func closingActivePane() -> WorkspacePaneCloseResult {
		guard topology.paneCount > 1 else {
			return WorkspacePaneCloseResult(
				workspace: nil,
				closedPaneID: activePaneID,
				shouldCloseWindow: true
			)
		}
		let removal = topology.removingPane(activePaneID)
		guard let updatedTopology = removal.topology,
		      let nextActivePaneID = removal.nearestPaneID else {
			return WorkspacePaneCloseResult(
				workspace: nil,
				closedPaneID: activePaneID,
				shouldCloseWindow: true
			)
		}
		let updated = Workspace(
			validatedVersion: Workspace.currentVersion,
			id: id,
			topology: updatedTopology,
			activePaneID: nextActivePaneID,
			presentation: presentation
		)
		return WorkspacePaneCloseResult(
			workspace: updated,
			closedPaneID: activePaneID,
			shouldCloseWindow: false
		)
	}

	private func replacing(
		activePaneID: PaneID? = nil,
		presentation: WorkspacePresentation? = nil
	) -> Workspace {
		Workspace(
			validatedVersion: Workspace.currentVersion,
			id: id,
			topology: topology,
			activePaneID: activePaneID ?? self.activePaneID,
			presentation: presentation ?? self.presentation
		)
	}
}

private extension WorkspaceTopology {
	func contains(splitID: SplitID) -> Bool {
		splitIDs.contains(splitID)
	}

	func replacingPane(
		_ paneID: PaneID,
		with transform: (WorkspaceTopology) -> WorkspaceTopology
	) -> WorkspaceTopology? {
		switch self {
		case .pane(let pane):
			return pane.id == paneID ? transform(self) : nil
		case .split(let split):
			if let first = split.first.replacingPane(paneID, with: transform) {
				return .split(WorkspaceSplit(
					id: split.id,
					axis: split.axis,
					ratio: split.ratio,
					first: first,
					second: split.second
				))
			}
			if let second = split.second.replacingPane(paneID, with: transform) {
				return .split(WorkspaceSplit(
					id: split.id,
					axis: split.axis,
					ratio: split.ratio,
					first: split.first,
					second: second
				))
			}
			return nil
		}
	}

	func updatingSplit(
		_ splitID: SplitID,
		with transform: (WorkspaceSplit) -> WorkspaceSplit
	) -> WorkspaceTopology? {
		switch self {
		case .pane:
			return nil
		case .split(let split):
			if split.id == splitID {
				return .split(transform(split))
			}
			if let first = split.first.updatingSplit(splitID, with: transform) {
				return .split(WorkspaceSplit(
					id: split.id,
					axis: split.axis,
					ratio: split.ratio,
					first: first,
					second: split.second
				))
			}
			if let second = split.second.updatingSplit(splitID, with: transform) {
				return .split(WorkspaceSplit(
					id: split.id,
					axis: split.axis,
					ratio: split.ratio,
					first: split.first,
					second: second
				))
			}
			return nil
		}
	}

	func removingPane(_ paneID: PaneID) -> (topology: WorkspaceTopology?, nearestPaneID: PaneID?) {
		switch self {
		case .pane(let pane):
			return pane.id == paneID ? (nil, nil) : (self, nil)
		case .split(let split):
			if split.first.contains(paneID) {
				let removal = split.first.removingPane(paneID)
				guard let first = removal.topology else {
					return (split.second, split.second.panes.first?.id)
				}
				return (
					.split(WorkspaceSplit(
						id: split.id,
						axis: split.axis,
						ratio: split.ratio,
						first: first,
						second: split.second
					)),
					removal.nearestPaneID
				)
			}
			if split.second.contains(paneID) {
				let removal = split.second.removingPane(paneID)
				guard let second = removal.topology else {
					return (split.first, split.first.panes.last?.id)
				}
				return (
					.split(WorkspaceSplit(
						id: split.id,
						axis: split.axis,
						ratio: split.ratio,
						first: split.first,
						second: second
					)),
					removal.nearestPaneID
				)
			}
			return (self, nil)
		}
	}

	func paneFrames() -> [PaneFrame] {
		var frames: [PaneFrame] = []
		appendPaneFrames(in: UnitRect(x: 0, y: 0, width: 1, height: 1), to: &frames)
		return frames
	}

	func appendPaneFrames(in rect: UnitRect, to frames: inout [PaneFrame]) {
		switch self {
		case .pane(let pane):
			frames.append(PaneFrame(paneID: pane.id, rect: rect, order: frames.count))
		case .split(let split):
			let firstRect: UnitRect
			let secondRect: UnitRect
			switch split.axis {
			case .horizontal:
				let firstWidth = rect.width * split.ratio
				firstRect = UnitRect(
					x: rect.x,
					y: rect.y,
					width: firstWidth,
					height: rect.height
				)
				secondRect = UnitRect(
					x: rect.x + firstWidth,
					y: rect.y,
					width: rect.width - firstWidth,
					height: rect.height
				)
			case .vertical:
				let firstHeight = rect.height * split.ratio
				firstRect = UnitRect(
					x: rect.x,
					y: rect.y,
					width: rect.width,
					height: firstHeight
				)
				secondRect = UnitRect(
					x: rect.x,
					y: rect.y + firstHeight,
					width: rect.width,
					height: rect.height - firstHeight
				)
			}
			split.first.appendPaneFrames(in: firstRect, to: &frames)
			split.second.appendPaneFrames(in: secondRect, to: &frames)
		}
	}
}

private struct PaneFrame {
	let paneID: PaneID
	let rect: UnitRect
	let order: Int
}

private struct UnitRect {
	let x: Double
	let y: Double
	let width: Double
	let height: Double

	var midX: Double { x + width / 2 }
	var midY: Double { y + height / 2 }

	func focusScore(
		from source: UnitRect,
		direction: WorkspaceFocusDirection
	) -> (primary: Double, secondary: Double) {
		switch direction {
		case .left, .right:
			(abs(midX - source.midX), abs(midY - source.midY))
		case .up, .down:
			(abs(midY - source.midY), abs(midX - source.midX))
		}
	}
}
