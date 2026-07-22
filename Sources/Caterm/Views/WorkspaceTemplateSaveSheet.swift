import SwiftUI
import WorkspaceCore
import WorkspaceTemplateStore

struct WorkspaceTemplateSaveSheet: View {
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject private var templateStore: WorkspaceTemplateStore
	let workspace: Workspace

	@State private var name = "Workspace"
	@State private var errorMessage: String?
	@StateObject private var submission = SingleFlightSubmission()

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Save Workspace Template")
				.font(.headline)
			TextField("Name", text: $name)
				.textFieldStyle(.roundedBorder)
				.disabled(submission.isSubmitting)
			HStack {
				Spacer()
				if submission.isSubmitting {
					ProgressView()
						.controlSize(.small)
				}
				Button("Cancel") { dismiss() }
					.keyboardShortcut(.cancelAction)
					.disabled(submission.isSubmitting)
				Button("Save") { save() }
					.keyboardShortcut(.defaultAction)
					.disabled(
						name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
							|| submission.isSubmitting
					)
			}
		}
		.padding(20)
		.frame(minWidth: 360)
		.interactiveDismissDisabled(submission.isSubmitting)
		.onDisappear { submission.cancel() }
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

	private func save() {
		submission.submit {
			do {
				_ = try await templateStore.save(workspace: workspace, name: name)
				dismiss()
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}
}
