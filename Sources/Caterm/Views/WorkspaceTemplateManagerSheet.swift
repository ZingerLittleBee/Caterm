import SessionStore
import SwiftUI
import WorkspaceCore
import WorkspaceTemplateStore

struct WorkspaceTemplateManagerSheet: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject private var sessionStore: SessionStore
	@EnvironmentObject private var templateStore: WorkspaceTemplateStore
	let currentWorkspace: Workspace?
	let onOpen: (Workspace) -> Void

	@State private var selection: WorkspaceTemplateID?
	@State private var nameOperation: NameOperation?
	@State private var pendingDelete: WorkspaceTemplate?
	@State private var errorMessage: String?

	var body: some View {
		VStack(spacing: 0) {
			header
			if templateStore.quarantinedRecordCount > 0 || templateStore.recordIssueCount > 0 {
				Label(
					templateRecordNotice,
					systemImage: "exclamationmark.triangle.fill"
				)
				.font(.caption)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 20)
				.padding(.bottom, 10)
			}
			Divider()
			if templateStore.templates.isEmpty {
				ContentUnavailableView(
					"No Workspace Templates",
					systemImage: "rectangle.stack",
					description: Text("Save a connected Workspace to reopen its layout later.")
				)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				List(templateStore.templates, selection: $selection) { template in
					WorkspaceTemplateRow(template: template)
						.tag(template.id)
						.contextMenu { rowMenu(for: template) }
						.onTapGesture(count: 2) { open(template) }
				}
				.listStyle(.inset)
			}
			Divider()
			footer
		}
		.frame(width: 620, height: 470)
		.onAppear {
			if selection == nil {
				selection = templateStore.templates.first?.id
			}
		}
		.sheet(item: $nameOperation) { operation in
			SimpleTextSheet(
				title: operation.title,
				prompt: "Name",
				initialValue: operation.initialValue,
				submitLabel: operation.submitLabel,
				onSubmit: { name in
					nameOperation = nil
					perform(operation, name: name)
				},
				onCancel: { nameOperation = nil }
			)
		}
		.alert(
			"Delete Workspace Template?",
			isPresented: Binding(
				get: { pendingDelete != nil },
				set: { if !$0 { pendingDelete = nil } }
			),
			presenting: pendingDelete
		) { template in
			Button("Delete", role: .destructive) { delete(template) }
			Button("Cancel", role: .cancel) { pendingDelete = nil }
		} message: { template in
			Text("“\(template.name)” will be removed from this Mac.")
		}
		.alert(
			"Workspace Template Error",
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

	private var header: some View {
		HStack(spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text("Workspace Templates")
					.font(.title2.weight(.semibold))
				Text("Layouts reopen with fresh SSH sessions.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			if currentWorkspace != nil {
				Button {
					nameOperation = .save
				} label: {
					Label("Save Current Workspace", systemImage: "plus")
				}
				.buttonStyle(.borderedProminent)
			}
		}
		.padding(20)
	}

	private var footer: some View {
		HStack {
			Button("Rename…") {
				guard let selectedTemplate else { return }
				nameOperation = .rename(selectedTemplate)
			}
			.disabled(selectedTemplate == nil)
			Button("Duplicate") {
				guard let selectedTemplate else { return }
				duplicate(selectedTemplate)
			}
			.disabled(selectedTemplate == nil)
			Button("Delete", role: .destructive) {
				pendingDelete = selectedTemplate
			}
			.disabled(selectedTemplate == nil)
			Spacer()
			Button("Done") { dismiss() }
			Button("Open") {
				guard let selectedTemplate else { return }
				open(selectedTemplate)
			}
			.keyboardShortcut(.defaultAction)
			.disabled(selectedTemplate == nil)
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 14)
	}

	private var selectedTemplate: WorkspaceTemplate? {
		guard let selection else { return nil }
		return templateStore.templates.first { $0.id == selection }
	}

	private var templateRecordNotice: String {
		var parts: [String] = []
		if templateStore.quarantinedRecordCount > 0 {
			parts.append("\(templateStore.quarantinedRecordCount) incompatible record(s) isolated")
		}
		if templateStore.recordIssueCount > 0 {
			parts.append("\(templateStore.recordIssueCount) record(s) could not be processed")
		}
		return parts.joined(separator: "; ") + "."
	}

	@ViewBuilder
	private func rowMenu(for template: WorkspaceTemplate) -> some View {
		Button("Open") { open(template) }
		Divider()
		Button("Rename…") { nameOperation = .rename(template) }
		Button("Duplicate") { duplicate(template) }
		Button("Delete", role: .destructive) { pendingDelete = template }
	}

	private func perform(_ operation: NameOperation, name: String) {
		Task { @MainActor in
			do {
				switch operation {
				case .save:
					guard let currentWorkspace else { return }
					let template = try await templateStore.save(
						workspace: currentWorkspace,
						name: name
					)
					selection = template.id
				case .rename(let template):
					try await templateStore.rename(id: template.id, to: name)
					selection = template.id
				}
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}

	private func duplicate(_ template: WorkspaceTemplate) {
		Task { @MainActor in
			do {
				selection = try await templateStore.duplicate(id: template.id).id
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}

	private func delete(_ template: WorkspaceTemplate) {
		Task { @MainActor in
			do {
				try await templateStore.delete(id: template.id)
				pendingDelete = nil
				selection = templateStore.templates.first?.id
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}

	private func open(_ template: WorkspaceTemplate) {
		do {
			let opening = try template.instantiate(
				availableHostIDs: Set(sessionStore.hosts.map(\.id))
			)
			onOpen(opening.workspace)
			dismiss()
		} catch {
			errorMessage = error.localizedDescription
		}
	}
}

private struct WorkspaceTemplateRow: View {
	let template: WorkspaceTemplate

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: "rectangle.split.2x1")
				.font(.title3)
				.foregroundStyle(.secondary)
				.frame(width: 28)
			VStack(alignment: .leading, spacing: 3) {
				Text(template.name)
					.fontWeight(.medium)
				Text(summary)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
		}
		.padding(.vertical, 4)
		.accessibilityElement(children: .combine)
	}

	private var summary: String {
		let count = template.topology.panes.count
		let panes = count == 1 ? "1 Pane" : "\(count) Panes"
		let presentation = template.initialPresentation == .focus ? "Focus" : "Split"
		return "\(panes) · \(presentation)"
	}
}

private enum NameOperation: Identifiable {
	case save
	case rename(WorkspaceTemplate)

	var id: String {
		switch self {
		case .save: "save"
		case .rename(let template): "rename-\(template.id.rawValue.uuidString)"
		}
	}

	var title: String {
		switch self {
		case .save: "Save Workspace Template"
		case .rename: "Rename Workspace Template"
		}
	}

	var initialValue: String {
		switch self {
		case .save: "Workspace"
		case .rename(let template): template.name
		}
	}

	var submitLabel: String {
		switch self {
		case .save: "Save"
		case .rename: "Rename"
		}
	}
}
