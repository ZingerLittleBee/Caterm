# CLAUDE.md

Guidance for Claude Code when working in this repository.

Caterm is a **native macOS SSH terminal manager** — a SwiftUI app on
libghostty with iCloud sync and no self-hosted server. Standard Swift
Package Manager layout (`Package.swift` at the repo root).

The authoritative project guide — commands, layout, signing/release,
and Swift code standards — is [`AGENTS.md`](../AGENTS.md) (the root
`CLAUDE.md` is a symlink to it). Read that first.

Quick reference:

- `make ghostty-kit` — build the bundled libghostty xcframework first.
- `make run-app` — default dev loop (build + codesign + launch).
- `make test` — `swift test`; keep it green before committing.
- `make release` / `make publish` — signed+notarized build, then
  tag + GitHub release. Version comes from the top of `CHANGELOG.md`.

Signing pitfalls and the distribution/notarization rationale live in
[`docs/macos-dev-signing.md`](../docs/macos-dev-signing.md).
