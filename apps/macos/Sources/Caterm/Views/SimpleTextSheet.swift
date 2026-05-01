import SwiftUI

/// Minimal modal sheet with a single text field, used to prompt the user
/// for a remote directory path when dispatching an ⌥-drag upload from the
/// terminal surface. Pure SwiftUI — no `NSOpenPanel`, since the target
/// directory lives on the remote host, not the local filesystem.
struct SimpleTextSheet: View {
	let title: String
	let prompt: String
	let submitLabel: String
	@State private var value: String
	let onSubmit: (String) -> Void
	let onCancel: () -> Void

	init(
		title: String,
		prompt: String,
		initialValue: String,
		submitLabel: String = "Upload",
		onSubmit: @escaping (String) -> Void,
		onCancel: @escaping () -> Void
	) {
		self.title = title
		self.prompt = prompt
		self.submitLabel = submitLabel
		_value = State(initialValue: initialValue)
		self.onSubmit = onSubmit
		self.onCancel = onCancel
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(title).font(.headline)
			TextField(prompt, text: $value)
				.textFieldStyle(.roundedBorder)
			HStack {
				Spacer()
				Button("Cancel") { onCancel() }
					.keyboardShortcut(.cancelAction)
				Button(submitLabel) { onSubmit(value) }
					.keyboardShortcut(.defaultAction)
					.disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
			}
		}
		.padding(20)
		.frame(minWidth: 360)
	}
}
