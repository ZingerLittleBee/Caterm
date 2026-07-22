import AppKit
import SessionStore
import SnippetSyncClient
import SwiftUI
import WorkspaceBroadcast
import WorkspaceCore

struct WorkspaceBroadcastComposerSheet: View {
	let workspaceID: WorkspaceID
	let candidates: [WorkspaceBroadcastRecipient]
	let snippets: [Snippet]
	let onArm: (WorkspaceBroadcastPlan) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var sourceMode = SourceMode.command
	@State private var commandText = ""
	@State private var selectedSnippetID: UUID?
	@State private var selectedPaneIDs: Set<PaneID> = []
	@State private var errorMessage: String?

	private enum SourceMode: String, CaseIterable, Identifiable {
		case command = "Command"
		case snippet = "Snippet"

		var id: Self { self }
	}

	private var selectedSnippet: Snippet? {
		guard let selectedSnippetID else { return nil }
		return snippets.first(where: { $0.id == selectedSnippetID })
	}

	private var reviewText: String {
		switch sourceMode {
		case .command:
			commandText
		case .snippet:
			selectedSnippet?.content ?? ""
		}
	}

	private var selectedRecipients: [WorkspaceBroadcastRecipient] {
		candidates.filter { selectedPaneIDs.contains($0.paneID) }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			VStack(alignment: .leading, spacing: 4) {
				Label("Review Command Broadcast", systemImage: "antenna.radiowaves.left.and.right")
					.font(.title2.weight(.semibold))
				Text("Nothing is sent until you arm this exact text, review the frozen recipients, and deliver once.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}

			Picker("Source", selection: $sourceMode) {
				ForEach(SourceMode.allCases) { mode in
					Text(mode.rawValue).tag(mode)
				}
			}
			.pickerStyle(.segmented)

			sourceEditor
			recipientSelection

			HStack {
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Spacer()
				Button("Arm Broadcast") { arm() }
					.buttonStyle(.borderedProminent)
					.tint(.orange)
					.disabled(!canArm)
			}
		}
		.padding(22)
		.frame(width: 620)
		.frame(minHeight: 650)
		.onChange(of: candidates.map(\.paneID)) { _, candidateIDs in
			selectedPaneIDs.formIntersection(candidateIDs)
		}
		.alert(
			"Broadcast Could Not Be Armed",
			isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			),
			presenting: errorMessage
		) { _ in
			Button("OK") { errorMessage = nil }
		} message: { message in
			Text(message)
		}
	}

	@ViewBuilder
	private var sourceEditor: some View {
		if sourceMode == .snippet {
			Picker("Existing Snippet", selection: $selectedSnippetID) {
				Text("Choose a Snippet").tag(Optional<UUID>.none)
				ForEach(snippets) { snippet in
					Text(snippet.name).tag(Optional(snippet.id))
				}
			}
			.pickerStyle(.menu)
		}

		VStack(alignment: .leading, spacing: 6) {
			Text("Exact text").font(.headline)
			if sourceMode == .command {
				TextEditor(text: $commandText)
					.font(.body.monospaced())
					.scrollContentBackground(.hidden)
					.padding(8)
					.background(Color(NSColor.textBackgroundColor))
					.accessibilityLabel("Command to broadcast")
			} else {
				snippetReview
			}
		}
		.frame(height: 150)
		.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.stroke(Color(NSColor.separatorColor), lineWidth: 1)
		}
	}

	private var snippetReview: some View {
		let text = reviewText
		return ScrollView {
			Text(text.isEmpty ? "Choose a Snippet to review its exact text." : text)
				.font(.body.monospaced())
				.foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(10)
		}
		.background(Color(NSColor.textBackgroundColor))
		.accessibilityLabel("Snippet text to broadcast")
	}

	@ViewBuilder
	private var recipientSelection: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Text("Connected recipients").font(.headline)
				Spacer()
				Text("\(selectedRecipients.count) selected, 2 minimum")
					.font(.caption)
					.foregroundStyle(selectedRecipients.count >= 2 ? Color.secondary : Color.orange)
			}
			if candidates.isEmpty {
				ContentUnavailableView(
					"No Connected Panes",
					systemImage: "terminal",
					description: Text("Connect at least two terminal Panes in this Workspace.")
				)
				.frame(maxWidth: .infinity, minHeight: 150)
			} else {
				List(candidates) { recipient in
					recipientToggle(recipient)
				}
				.listStyle(.inset)
				.frame(minHeight: 150)
			}
		}
	}

	private func recipientToggle(_ recipient: WorkspaceBroadcastRecipient) -> some View {
		Toggle(isOn: selectionBinding(for: recipient.paneID)) {
			VStack(alignment: .leading, spacing: 3) {
				Text("\(recipient.paneLabel) · \(recipient.hostName)").fontWeight(.medium)
				Text(recipient.address)
					.font(.caption.monospaced())
					.foregroundStyle(.secondary)
			}
		}
		.toggleStyle(.checkbox)
		.accessibilityLabel("Broadcast to \(recipient.paneLabel), \(recipient.hostName), \(recipient.address)")
	}

	private var canArm: Bool {
		selectedRecipients.count >= 2
			&& !reviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	private func selectionBinding(for paneID: PaneID) -> Binding<Bool> {
		Binding(
			get: { selectedPaneIDs.contains(paneID) },
			set: { selected in
				if selected {
					selectedPaneIDs.insert(paneID)
				} else {
					selectedPaneIDs.remove(paneID)
				}
			}
		)
	}

	private func arm() {
		do {
			let source: WorkspaceBroadcastSource
			switch sourceMode {
			case .command:
				source = .command(commandText)
			case .snippet:
				guard let selectedSnippet else {
					throw WorkspaceBroadcastError.emptyCommand
				}
				source = .snippet(
					id: selectedSnippet.id,
					name: selectedSnippet.name,
					text: selectedSnippet.content
				)
			}
			let plan = try WorkspaceBroadcastPlan(
				workspaceID: workspaceID,
				source: source,
				recipients: selectedRecipients
			)
			onArm(plan)
			dismiss()
		} catch {
			errorMessage = error.localizedDescription
		}
	}
}

struct WorkspaceBroadcastBanner: View {
	let plan: WorkspaceBroadcastPlan
	let isDelivering: Bool
	let onReview: () -> Void
	let onStop: () -> Void

	var body: some View {
		HStack(spacing: 10) {
			Label(
				isDelivering ? "Broadcasting to \(plan.recipients.count) receivers" : "Broadcast armed for \(plan.recipients.count) receivers",
				systemImage: "antenna.radiowaves.left.and.right"
			)
			.font(.callout.weight(.semibold))
			.foregroundStyle(.orange)
			if isDelivering {
				ProgressView().controlSize(.small)
			}
			Spacer()
			Button("Review & Deliver…", action: onReview)
				.disabled(isDelivering)
			Button("Stop", role: .destructive, action: onStop)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(Color.orange.opacity(0.12))
		.overlay(alignment: .bottom) {
			Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 1)
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(
			isDelivering
				? "Command broadcast in progress to \(plan.recipients.count) receivers"
				: "Command broadcast armed for \(plan.recipients.count) receivers"
		)
	}
}

struct WorkspaceBroadcastReviewSheet: View {
	let plan: WorkspaceBroadcastPlan
	let onDeliver: () -> Void
	let onStop: () -> Void
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Deliver Broadcast Once?")
					.font(.title2.weight(.semibold))
				Text("This frozen snapshot will not include any new or reconnected Pane.")
					.foregroundStyle(.secondary)
			}

			Text(plan.source.label)
				.font(.headline)
			ScrollView {
				Text(plan.source.text)
					.font(.body.monospaced())
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(10)
			}
			.frame(height: 140)
			.background(Color(NSColor.textBackgroundColor))
			.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

			Text("Frozen recipients")
				.font(.headline)
			List(plan.recipients) { recipient in
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text("\(recipient.paneLabel) · \(recipient.hostName)")
						Text(recipient.address)
							.font(.caption.monospaced())
							.foregroundStyle(.secondary)
					}
				} icon: {
					Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
				}
			}
			.listStyle(.inset)
			.frame(minHeight: 150)

			HStack {
				Button("Stop Broadcast", role: .destructive) {
					onStop()
					dismiss()
				}
				Spacer()
				Button("Keep Armed") { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Deliver Once") {
					dismiss()
					Task { @MainActor in
						await Task.yield()
						onDeliver()
					}
				}
				.buttonStyle(.borderedProminent)
				.tint(.orange)
			}
		}
		.padding(22)
		.frame(width: 580)
		.frame(minHeight: 560)
	}
}

struct WorkspaceBroadcastReportSheet: View {
	let report: WorkspaceBroadcastReport
	let onDone: () -> Void
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Broadcast Results")
					.font(.title2.weight(.semibold))
				Text(summary)
					.foregroundStyle(.secondary)
			}

			ScrollView {
				Text(report.plan.source.text)
					.font(.body.monospaced())
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(10)
			}
			.frame(height: 110)
			.background(Color(NSColor.textBackgroundColor))
			.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

			List(report.outcomes) { outcome in
				HStack(spacing: 10) {
					Image(systemName: outcome.status.systemImage)
						.foregroundStyle(outcome.status.color)
						.frame(width: 18)
					VStack(alignment: .leading, spacing: 2) {
						Text("\(outcome.recipient.paneLabel) · \(outcome.recipient.hostName)")
						Text(outcome.recipient.address)
							.font(.caption.monospaced())
							.foregroundStyle(.secondary)
					}
					Spacer()
					Text(outcome.status.label)
						.font(.callout.weight(.medium))
						.foregroundStyle(outcome.status.color)
				}
				.accessibilityElement(children: .combine)
				.accessibilityLabel(
					"\(outcome.recipient.paneLabel), \(outcome.recipient.hostName), \(outcome.status.label)"
				)
			}
			.listStyle(.inset)
			.frame(minHeight: 220)

			HStack {
				Spacer()
				Button("Done") {
					onDone()
					dismiss()
				}
				.keyboardShortcut(.defaultAction)
			}
		}
		.padding(22)
		.frame(width: 580)
		.frame(minHeight: 520)
	}

	private var summary: String {
		let delivered = report.outcomes.filter { $0.status == .delivered }.count
		let skipped = report.outcomes.filter {
			if case .skipped = $0.status { return true }
			return false
		}.count
		let failed = report.outcomes.count - delivered - skipped
		return "\(delivered) delivered, \(skipped) skipped, \(failed) failed"
	}
}

struct WorkspaceBroadcastWindowModifier: ViewModifier {
	@ObservedObject var session: WorkspaceBroadcastSession
	@Binding var workspace: Workspace
	@Binding var presentingComposer: Bool
	@Binding var reviewedPlan: WorkspaceBroadcastPlan?
	@Binding var message: String?
	let candidates: [WorkspaceBroadcastRecipient]
	let snippets: [Snippet]
	let hostWindow: NSWindow?
	let onReconcile: () -> Void
	let onDeliver: () -> Void
	let onStop: () -> Void
	@EnvironmentObject private var store: SessionStore
	@EnvironmentObject private var surfaceRegistry: SurfaceRegistry

	func body(content: Content) -> some View {
		content
			.onReceive(NotificationCenter.default
				.publisher(for: .catermStartWorkspaceBroadcast)) { note in
				guard WindowCommandScope.shouldHandle(note, in: hostWindow),
				      session.activePlan == nil else { return }
				presentingComposer = true
			}
			.onReceive(NotificationCenter.default
				.publisher(for: .catermStopWorkspaceBroadcast)) { note in
				guard WindowCommandScope.shouldHandle(note, in: hostWindow) else { return }
				onStop()
			}
			.onReceive(store.$tabs) { _ in onReconcile() }
			.onReceive(surfaceRegistry.$revision) { _ in onReconcile() }
			.onChange(of: workspace) { _, _ in onReconcile() }
			.sheet(isPresented: $presentingComposer) {
				WorkspaceBroadcastComposerSheet(
					workspaceID: workspace.id,
					candidates: candidates,
					snippets: snippets,
					onArm: session.arm
				)
			}
			.sheet(item: $reviewedPlan) { plan in
				WorkspaceBroadcastReviewSheet(
					plan: plan,
					onDeliver: onDeliver,
					onStop: onStop
				)
			}
			.sheet(item: reportBinding) { report in
				WorkspaceBroadcastReportSheet(
					report: report,
					onDone: session.consumeReport
				)
			}
			.alert(
				"Broadcast Stopped",
				isPresented: messageBinding,
				presenting: message
			) { _ in
				Button("OK") { message = nil }
			} message: { message in
				Text(message)
			}
	}

	private var reportBinding: Binding<WorkspaceBroadcastReport?> {
		Binding(
			get: { session.latestReport },
			set: { report in
				if report == nil { session.consumeReport() }
			}
		)
	}

	private var messageBinding: Binding<Bool> {
		Binding(
			get: { message != nil },
			set: { presented in
				if !presented { message = nil }
			}
		)
	}
}

private extension WorkspaceBroadcastOutcomeStatus {
	var label: String {
		switch self {
		case .delivered:
			"Delivered"
		case .skipped(let reason):
			"Skipped: \(reason.description)"
		case .failed(let message):
			"Failed: \(message)"
		}
	}

	var systemImage: String {
		switch self {
		case .delivered:
			"checkmark.circle.fill"
		case .skipped:
			"forward.end.circle.fill"
		case .failed:
			"xmark.octagon.fill"
		}
	}

	var color: Color {
		switch self {
		case .delivered:
			.green
		case .skipped:
			.orange
		case .failed:
			.red
		}
	}
}
