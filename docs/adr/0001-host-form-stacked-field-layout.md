# Host form uses stacked labels + bordered fields, not grouped Form

The Add/Edit Host sheet (`HostFormView`) deliberately does **not** use SwiftUI's
`Form` + `.formStyle(.grouped)` + `LabeledContent` idiom. On macOS that combo
renders borderless, right-aligned text fields whose hit target is only the text
glyphs — users reported fields being hard to click, no visible affordance for
what is editable, and input appearing misaligned against the labels.

Three layouts were prototyped in-app (classic two-column with trailing labels;
stacked labels above full-width bordered fields; a 3-step wizard) and compared
live. The user picked the **stacked-label layout**: section cards, a label above
each full-width `.roundedBorder` field, `.large` control size, placeholders on
every field, and one card per port-forward rule with per-field labels. Chosen
for maximum hit area and self-evident affordance; the wizard was rejected as
friction for a high-frequency action, and the two-column layout as weaker on
both counts. Don't "fix" this back to a grouped `Form` for native-look
consistency — that reintroduces the affordance bugs this replaced.
