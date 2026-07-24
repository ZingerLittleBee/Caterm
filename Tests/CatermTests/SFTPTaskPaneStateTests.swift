import Foundation
import Testing
@testable import Caterm

@Suite
struct SFTPTaskPaneStateTests {
	@Test
	func navigationHistoryIsIndependentAndTruncatesForwardBranch() {
		let hostID = UUID()
		var left = SFTPTaskPaneState(
			endpoint: .remote(hostID: hostID),
			path: "~"
		)
		let right = SFTPTaskPaneState(
			endpoint: .local(locationID: UUID()),
			path: ""
		)

		left.navigate(to: "~/logs")
		left.navigate(to: "~/logs/archive")
		let movedBack = left.goBack()
		#expect(movedBack)
		#expect(left.path == "~/logs")
		#expect(left.canGoForward)
		left.navigate(to: "~/releases")

		#expect(!left.canGoForward)
		#expect(left.path == "~/releases")
		#expect(right.path == "")
		#expect(!right.canGoBack)
	}

	@Test
	func hiddenChoiceFiltersOnlyTheOwningPane() {
		let visible = SFTPTaskEntry(
			name: "report.txt",
			kind: .file,
			size: 10,
			modifiedAt: nil,
			permissions: nil
		)
		let hidden = SFTPTaskEntry(
			name: ".env",
			kind: .file,
			size: 5,
			modifiedAt: nil,
			permissions: nil
		)
		var pane = SFTPTaskPaneState(
			endpoint: .remote(hostID: UUID()),
			path: "~"
		)

		#expect(pane.visibleEntries(in: [hidden, visible]) == [visible])
		pane.showsHiddenFiles = true
		#expect(pane.visibleEntries(in: [hidden, visible]) == [hidden, visible])
	}

	@Test(arguments: [
		(
			SFTPTaskEndpoint.local(locationID: UUID()),
			SFTPTaskEndpoint.remote(hostID: UUID()),
			SFTPTaskTransferRoute.upload
		),
		(
			SFTPTaskEndpoint.remote(hostID: UUID()),
			SFTPTaskEndpoint.local(locationID: UUID()),
			SFTPTaskTransferRoute.download
		),
		(
			SFTPTaskEndpoint.remote(hostID: UUID()),
			SFTPTaskEndpoint.remote(hostID: UUID()),
			SFTPTaskTransferRoute.remoteCopyViaMac
		),
	])
	func routeIsExplicit(
		source: SFTPTaskEndpoint,
		destination: SFTPTaskEndpoint,
		expected: SFTPTaskTransferRoute
	) {
		#expect(
			SFTPTaskTransferRoute.resolve(
				source: source,
				destination: destination
			) == expected
		)
	}

	@Test
	func localToLocalIsNotMisrepresentedAsSFTPTransfer() {
		#expect(
			SFTPTaskTransferRoute.resolve(
				source: .local(locationID: UUID()),
				destination: .local(locationID: UUID())
			) == nil
		)
	}
}
