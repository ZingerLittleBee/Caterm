import SSHCommandBuilder
import SwiftUI

enum HostOrganizationEditorMode: Equatable {
	case edit
	case setGroup
	case addTags
	case removeTags
}

struct HostOrganizationEditorRequest: Identifiable {
	let id = UUID()
	let mode: HostOrganizationEditorMode
	let selectedIDs: Set<UUID>
	let initial: HostOrganization?
}

struct HostOrganizationEditorResult {
	let groupPath: [String]?
	let replacementTags: [String]?
	let tagsToAdd: [String]
	let tagsToRemove: [String]

	func apply(to organization: HostOrganization) -> HostOrganization {
		var result = HostOrganization(
			groupPath: groupPath ?? organization.groupPath,
			tags: replacementTags ?? organization.tags
		)
		if !tagsToAdd.isEmpty {
			result = HostOrganizationMutation.apply(.addTags(tagsToAdd), to: result)
		}
		if !tagsToRemove.isEmpty {
			result = HostOrganizationMutation.apply(.removeTags(tagsToRemove), to: result)
		}
		return result
	}
}

struct HostOrganizationEditorSheet: View {
	let request: HostOrganizationEditorRequest
	let existingGroups: [[String]]
	let existingTags: [String]
	let onSave: (HostOrganizationEditorResult) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var groupText: String
	@State private var tagsText: String

	init(
		request: HostOrganizationEditorRequest,
		existingGroups: [[String]],
		existingTags: [String],
		onSave: @escaping (HostOrganizationEditorResult) -> Void
	) {
		self.request = request
		self.existingGroups = existingGroups
		self.existingTags = existingTags
		self.onSave = onSave
		_groupText = State(initialValue: request.initial.map(
			HostOrganizationText.groupText
		) ?? "")
		_tagsText = State(initialValue: request.initial.map(
			HostOrganizationText.tagsText
		) ?? "")
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			VStack(alignment: .leading, spacing: 4) {
				Text(title).font(.title2.weight(.semibold))
				Text("Applies to \(request.selectedIDs.count) \(request.selectedIDs.count == 1 ? "host" : "hosts").")
					.foregroundStyle(.secondary)
			}
			if request.mode == .edit || request.mode == .setGroup {
				VStack(alignment: .leading, spacing: 6) {
					Text("Group").font(.headline)
					TextField("Production / API", text: $groupText)
					if !existingGroups.isEmpty {
						Menu("Choose Existing Group") {
							Button("Ungrouped") { groupText = "" }
							Divider()
							ForEach(existingGroups, id: \.self) { path in
								Button(path.joined(separator: " / ")) {
									groupText = path.joined(separator: " / ")
								}
							}
						}
					}
				}
			}
			if request.mode == .edit || request.mode == .addTags || request.mode == .removeTags {
				VStack(alignment: .leading, spacing: 6) {
					Text(tagsLabel).font(.headline)
					TextField("Linux, Critical, On-call", text: $tagsText)
					Text("Separate tags with commas.")
						.font(.caption)
						.foregroundStyle(.secondary)
					if !existingTags.isEmpty && request.mode != .edit {
						Menu("Choose Existing Tag") {
							ForEach(existingTags, id: \.self) { tag in
								Button(tag) { appendTag(tag) }
							}
						}
					}
				}
			}
			Spacer()
			HStack {
				Button("Cancel") { dismiss() }
					.keyboardShortcut(.cancelAction)
				Spacer()
				Button("Apply") {
					onSave(result)
					dismiss()
				}
				.keyboardShortcut(.defaultAction)
			}
		}
		.textFieldStyle(.roundedBorder)
		.padding(20)
		.frame(width: 460, height: sheetHeight)
	}

	private var title: String {
		switch request.mode {
		case .edit: "Edit Organization"
		case .setGroup: "Set Group"
		case .addTags: "Add Tags"
		case .removeTags: "Remove Tags"
		}
	}

	private var tagsLabel: String {
		request.mode == .removeTags ? "Tags to Remove" : "Tags"
	}

	private var sheetHeight: CGFloat {
		request.mode == .edit ? 360 : 280
	}

	private var parsed: HostOrganization {
		HostOrganizationText.makeOrganization(group: groupText, tags: tagsText)
	}

	private var result: HostOrganizationEditorResult {
		switch request.mode {
		case .edit:
			HostOrganizationEditorResult(
				groupPath: parsed.groupPath,
				replacementTags: parsed.tags,
				tagsToAdd: [], tagsToRemove: []
			)
		case .setGroup:
			HostOrganizationEditorResult(
				groupPath: parsed.groupPath,
				replacementTags: nil,
				tagsToAdd: [], tagsToRemove: []
			)
		case .addTags:
			HostOrganizationEditorResult(
				groupPath: nil, replacementTags: nil,
				tagsToAdd: parsed.tags, tagsToRemove: []
			)
		case .removeTags:
			HostOrganizationEditorResult(
				groupPath: nil, replacementTags: nil,
				tagsToAdd: [], tagsToRemove: parsed.tags
			)
		}
	}

	private func appendTag(_ tag: String) {
		let existing = HostOrganizationText.makeOrganization(
			group: "", tags: tagsText
		).tags
		tagsText = (existing + [tag]).joined(separator: ", ")
	}
}
