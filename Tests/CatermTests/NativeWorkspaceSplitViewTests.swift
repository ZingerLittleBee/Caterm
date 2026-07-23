import AppKit
import SwiftUI
import XCTest
import WorkspaceCore
@testable import Caterm

@MainActor
final class NativeWorkspaceSplitViewTests: XCTestCase {
	func testDelegateKeepsBothPanesReadableAndReportsDragRatio() throws {
		var reportedRatio: Double?
		let splitView = ManagedWorkspaceSplitView(
			frame: CGRect(x: 0, y: 0, width: 600, height: 400)
		)
		splitView.configure(
			axis: .horizontal,
			ratio: 0.5,
			firstMinimumLength: 160,
			secondMinimumLength: 160,
			first: NSView(),
			second: NSView(),
			onRatioChange: { ratio in reportedRatio = ratio }
		)

		XCTAssertEqual(
			splitView.splitView(
				splitView,
				constrainMinCoordinate: 20,
				ofSubviewAt: 0
			),
			160
		)
		XCTAssertLessThan(
			splitView.splitView(
				splitView,
				constrainMaxCoordinate: 590,
				ofSubviewAt: 0
			),
			450
		)

		let available = 600 - splitView.dividerThickness
		splitView.subviews[0].frame = CGRect(x: 0, y: 0, width: 400, height: 400)
		splitView.subviews[1].frame = CGRect(
			x: 400 + splitView.dividerThickness,
			y: 0,
			width: available - 400,
			height: 400
		)
		splitView.splitViewDidResizeSubviews(
			Notification(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
		)

		XCTAssertEqual(
			try XCTUnwrap(reportedRatio),
			Double(400 / available),
			accuracy: 0.01
		)
	}

	func testNestedMinimumLengthAggregatesAlongMatchingAxis() throws {
		let original = Workspace.onePane(host: .saved(id: UUID()))
		let two = try original.splittingActivePane(.down)
		let connected = try two.assigningHost(.saved(id: UUID()), to: two.activePaneID)
		let three = try connected.splittingActivePane(.down)

		XCTAssertEqual(
			WorkspaceTreeMinimumLength.length(
				for: three.topology,
				along: .vertical,
				activePaneID: three.activePaneID,
				presentation: .split
			),
			482
		)
		XCTAssertEqual(
			WorkspaceTreeMinimumLength.length(
				for: three.topology,
				along: .horizontal,
				activePaneID: three.activePaneID,
				presentation: .split
			),
			160
		)
	}

	func testAddingSplitReparentsExistingPaneHostWithoutRecreatingIt() throws {
		let originalPaneID = PaneID(rawValue: UUID())
		let original = Workspace.onePane(
			paneID: originalPaneID,
			host: .saved(id: UUID())
		)
		let coordinator = NativeWorkspaceTreeView.Coordinator { _, _ in }
		let container = WorkspaceTreeContainerView()
		let content: (WorkspacePane) -> AnyView = { pane in
			AnyView(Text(pane.id.rawValue.uuidString))
		}
		coordinator.update(
			container,
			topology: original.topology,
			activePaneID: original.activePaneID,
			presentation: .split,
			paneContent: content,
			onRatioChange: { _, _ in }
		)
		let originalHost = try XCTUnwrap(
			container.descendants.compactMap { $0 as? NSHostingView<AnyView> }.first
		)

		let split = try original.splittingActivePane(.right)
		coordinator.update(
			container,
			topology: split.topology,
			activePaneID: split.activePaneID,
			presentation: .split,
			paneContent: content,
			onRatioChange: { _, _ in }
		)
		let paneHosts = container.descendants.compactMap { $0 as? NSHostingView<AnyView> }

		XCTAssertEqual(paneHosts.count, 2)
		XCTAssertTrue(paneHosts.contains { $0 === originalHost })
		XCTAssertTrue(originalHost.superview is ManagedWorkspaceSplitView)

		coordinator.update(
			container,
			topology: split.topology,
			activePaneID: split.activePaneID,
			presentation: .focus,
			paneContent: content,
			onRatioChange: { _, _ in }
		)
		let focusedHosts = container.descendants.compactMap {
			$0 as? NSHostingView<AnyView>
		}

		XCTAssertEqual(focusedHosts.count, 2)
		XCTAssertTrue(focusedHosts.contains { $0 === originalHost })
	}

	func testReparentingPaneDoesNotDismantleItsRepresentable() throws {
		let originalPaneID = PaneID(rawValue: UUID())
		let original = Workspace.onePane(
			paneID: originalPaneID,
			host: .saved(id: UUID())
		)
		let lifecycle = ViewLifecycleProbe()
		let coordinator = NativeWorkspaceTreeView.Coordinator { _, _ in }
		let container = WorkspaceTreeContainerView(
			frame: CGRect(x: 0, y: 0, width: 700, height: 500)
		)
		let window = NSWindow(
			contentRect: container.frame,
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = container
		let content: (WorkspacePane) -> AnyView = { pane in
			if pane.id == originalPaneID {
				return AnyView(
					LifecycleProbeRepresentable(lifecycle: lifecycle)
						.id(pane.id)
				)
			}
			return AnyView(Text("Picker").id(pane.id))
		}
		coordinator.update(
			container,
			topology: original.topology,
			activePaneID: original.activePaneID,
			presentation: .split,
			paneContent: content,
			onRatioChange: { _, _ in }
		)
		container.layoutSubtreeIfNeeded()

		let split = try original.splittingActivePane(.right)
		coordinator.update(
			container,
			topology: split.topology,
			activePaneID: split.activePaneID,
			presentation: .split,
			paneContent: content,
			onRatioChange: { _, _ in }
		)
		container.layoutSubtreeIfNeeded()

		XCTAssertEqual(lifecycle.makeCount, 1)
		XCTAssertEqual(lifecycle.dismantleCount, 0)
		window.close()
	}

	func testPaneHostsExposeAndRefreshAccessibleGroupLabels() throws {
		let original = Workspace.onePane(host: .saved(id: UUID()))
		let split = try original.splittingActivePane(.right)
		let coordinator = NativeWorkspaceTreeView.Coordinator { _, _ in }
		let container = WorkspaceTreeContainerView()
		var labels = Dictionary(uniqueKeysWithValues: split.topology.panes.enumerated().map {
			($0.element.id, "Host Local \($0.offset + 1), Connecting, Pane \($0.offset + 1) of 2, Inactive, Not a broadcast receiver")
		})
		coordinator.update(
			container,
			topology: split.topology,
			activePaneID: split.activePaneID,
			presentation: .split,
			paneAccessibilityLabel: { labels[$0.id] },
			paneContent: { AnyView(Text($0.id.rawValue.uuidString)) },
			onRatioChange: { _, _ in }
		)
		let hosts = container.descendants.compactMap { $0 as? NSHostingView<AnyView> }
		let identities = Set(hosts.map(ObjectIdentifier.init))
		XCTAssertEqual(hosts.count, 2)
		for host in hosts {
			XCTAssertTrue(host.isAccessibilityElement())
			XCTAssertEqual(host.accessibilityRole(), .group)
			XCTAssertNotNil(host.accessibilityLabel())
			XCTAssertTrue(host.accessibilityIdentifier().hasPrefix("workspace-pane-"))
		}

		let activePaneID = split.activePaneID
		labels[activePaneID] = "Host Local 2, Connected, Pane 2 of 2, Active, Broadcast receiver 1"
		coordinator.update(
			container,
			topology: split.topology,
			activePaneID: activePaneID,
			presentation: .split,
			paneAccessibilityLabel: { labels[$0.id] },
			paneContent: { AnyView(Text($0.id.rawValue.uuidString)) },
			onRatioChange: { _, _ in }
		)
		let updatedHosts = container.descendants.compactMap { $0 as? NSHostingView<AnyView> }
		XCTAssertEqual(Set(updatedHosts.map(ObjectIdentifier.init)), identities)
		XCTAssertTrue(updatedHosts.contains {
			$0.accessibilityLabel() == "Host Local 2, Connected, Pane 2 of 2, Active, Broadcast receiver 1"
		})
	}

	func testFourAndEightPaneTreesKeepStableHostsAcrossWindowResize() throws {
		for paneCount in [4, 8] {
			let workspace = try populatedWorkspace(paneCount: paneCount)
			let lifecycle = ViewLifecycleProbe()
			let coordinator = NativeWorkspaceTreeView.Coordinator { _, _ in }
			let container = WorkspaceTreeContainerView(
				frame: CGRect(x: 0, y: 0, width: 1_000, height: 650)
			)
			let window = NSWindow(
				contentRect: container.frame,
				styleMask: [.titled, .resizable],
				backing: .buffered,
				defer: false
			)
			window.isReleasedWhenClosed = false
			window.contentView = container
			let content: (WorkspacePane) -> AnyView = { pane in
				AnyView(
					LifecycleProbeRepresentable(lifecycle: lifecycle)
						.id(pane.id)
				)
			}

			coordinator.update(
				container,
				topology: workspace.topology,
				activePaneID: workspace.activePaneID,
				presentation: .split,
				paneContent: content,
				onRatioChange: { _, _ in }
			)
			container.layoutSubtreeIfNeeded()
			let originalHosts = container.descendants.compactMap {
				$0 as? NSHostingView<AnyView>
			}
			let originalIdentities = Set(originalHosts.map(ObjectIdentifier.init))

			for size in [
				CGSize(width: 1_800, height: 1_000),
				CGSize(width: 1_000, height: 650),
				CGSize(width: 1_440, height: 900),
			] {
				window.setContentSize(size)
				container.layoutSubtreeIfNeeded()
				coordinator.update(
					container,
					topology: workspace.topology,
					activePaneID: workspace.activePaneID,
					presentation: .split,
					paneContent: content,
					onRatioChange: { _, _ in }
				)
				container.layoutSubtreeIfNeeded()

				let hosts = container.descendants.compactMap {
					$0 as? NSHostingView<AnyView>
				}
				XCTAssertEqual(hosts.count, paneCount)
				XCTAssertEqual(Set(hosts.map(ObjectIdentifier.init)), originalIdentities)
				for view in container.descendants {
					XCTAssertTrue(view.frame.origin.x.isFinite)
					XCTAssertTrue(view.frame.origin.y.isFinite)
					XCTAssertTrue(view.frame.width.isFinite)
					XCTAssertTrue(view.frame.height.isFinite)
					XCTAssertGreaterThanOrEqual(view.frame.width, 0)
					XCTAssertGreaterThanOrEqual(view.frame.height, 0)
				}
			}

			XCTAssertEqual(originalIdentities.count, paneCount)
			XCTAssertEqual(lifecycle.makeCount, paneCount)
			XCTAssertEqual(lifecycle.dismantleCount, 0)
			window.close()
		}
	}

	private func populatedWorkspace(paneCount: Int) throws -> Workspace {
		var workspace = Workspace.onePane(host: .saved(id: UUID()))
		for index in 1..<paneCount {
			workspace = try workspace.splittingActivePane(
				index.isMultiple(of: 2) ? .down : .right
			)
			workspace = try workspace.assigningHost(
				.saved(id: UUID()),
				to: workspace.activePaneID
			)
		}
		return workspace
	}
}

private extension NSView {
	var descendants: [NSView] {
		subviews + subviews.flatMap(\.descendants)
	}
}

@MainActor
private final class ViewLifecycleProbe {
	var makeCount = 0
	var dismantleCount = 0
}

private final class LifecycleProbeNSView: NSView {
	let lifecycle: ViewLifecycleProbe

	init(lifecycle: ViewLifecycleProbe) {
		self.lifecycle = lifecycle
		super.init(frame: .zero)
	}

	required init?(coder: NSCoder) {
		nil
	}
}

private struct LifecycleProbeRepresentable: NSViewRepresentable {
	let lifecycle: ViewLifecycleProbe

	func makeNSView(context: Context) -> LifecycleProbeNSView {
		lifecycle.makeCount += 1
		return LifecycleProbeNSView(lifecycle: lifecycle)
	}

	func updateNSView(_ nsView: LifecycleProbeNSView, context: Context) {}

	static func dismantleNSView(
		_ nsView: LifecycleProbeNSView,
		coordinator: ()
	) {
		nsView.lifecycle.dismantleCount += 1
	}
}
