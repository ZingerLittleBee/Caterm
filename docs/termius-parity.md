# Termius Individual-User Parity Matrix

Last verified: 2026-07-24

This matrix compares Caterm with the current Termius surface that materially
affects an individual SSH user on macOS, iPhone, or iPad. It is not a
feature-count target. Native platform behavior, security boundaries, and
verifiable workflows take precedence over copying another product's UI.

## Verification basis

- Current first-party Termius documentation for
  [Hosts](https://docs.termius.com/),
  [Groups and tags](https://docs.termius.com/organize-and-connect-to-hosts/groups-and-tags),
  [Workspaces](https://docs.termius.com/terminal/workspaces),
  [Snippets](https://docs.termius.com/terminal/snippets),
  [SFTP](https://docs.termius.com/organize-and-connect-to-hosts/managing-files-with-sftp),
  [Identities](https://docs.termius.com/keychain/identities),
  [keys and certificates](https://docs.termius.com/keychain/ssh-keys-and-certificates),
  [autocomplete and shell integration](https://docs.termius.com/terminal/autocomplete-and-shell-integration),
  [session logs](https://docs.termius.com/organize-and-connect-to-hosts/session-logs),
  and [vaults](https://docs.termius.com/getting-started/learn-about-vaults).
- The live [Termius pricing comparison](https://termius.com/pricing), checked
  again on 2026-07-23. Starter still includes SSH, SFTP, autocomplete, and
  port forwarding. Pro adds a Personal cloud vault, desktop/mobile sync,
  snippets automation, and log bookmarks. Team and Business capabilities
  remain separate below.
- Read-only inspection of the installed Termius 9.41.1 application. The
  navigation surface and dual-endpoint SFTP structure matched the first-party
  documentation. No screenshot, Host value, account identity, credential,
  terminal content, or application log from that inspection is committed.
- Caterm source, public tests, targeted runtime checks, real local SSH/SFTP
  fixtures, and the open verification tickets linked below.

The status vocabulary is intentionally strict:

- **Implemented**: executable source and automated or runtime evidence exist.
- **Deliberately excluded**: Caterm has chosen a different product or security
  boundary; the rationale is part of the disposition.
- **Deferred**: the capability has a concrete open ticket and is not claimed
  as shipped parity yet.
- **Unverified**: the implementation may provide the behavior, but the named
  acceptance evidence is missing. Caterm does not advertise the claim.

## Individual-user matrix

| Termius capability | Caterm status | Caterm disposition and evidence |
| --- | --- | --- |
| Saved Hosts, labels, nested Groups, tags, search, and bulk organization | **Implemented** | The synchronized Host model carries nested organization and tags in [`Host.swift`](../Sources/SSHCommandBuilder/Host.swift) and [`HostOrganization.swift`](../Sources/SSHCommandBuilder/HostOrganization.swift). Native management lives in [`HostManagerView.swift`](../Sources/Caterm/Views/HostManagerView.swift), with behavior covered by [`HostOrganizationTests`](../Tests/CatermTests/HostOrganizationTests.swift). |
| Group-level inherited credentials, proxies, startup behavior, and Group Quick Connect | **Deliberately excluded** | Caterm keeps connection-critical behavior explicit on each Host. Groups organize Hosts but do not silently change authentication or routing for every descendant. Workspace templates are the explicit reusable multi-Host task boundary. |
| One Host containing several protocol configurations | **Deliberately excluded** | Caterm models one SSH connection declaration per Host. This keeps authentication, Known Hosts, Jump chains, automation, and failure state unambiguous. |
| Import from OpenSSH config, CSV, PuTTY, MobaXterm, and SecureCRT | **Deliberately excluded** | Caterm imports keys, OpenSSH `known_hosts`, and its encrypted cross-platform backup archive, but does not promise broad third-party migration parsing. Those formats do not strengthen the recurring SSH workflow and carry high ambiguity around inherited config. Evidence: [`KnownHostsManagerView.swift`](../Sources/Caterm/Views/KnownHostsManagerView.swift) and [`BackupImporter.swift`](../Sources/BackupService/BackupImporter.swift). |
| Reusable Identities linked to several Hosts | **Implemented** | Passwords, private keys, SSH certificates, and device-bound identity references use the dedicated [`CredentialIdentityStore`](../Sources/CredentialIdentityStore), encrypted sync in [`CredentialIdentitySync`](../Sources/CredentialIdentitySync), runtime resolution in [`CredentialIdentityRuntime`](../Sources/CredentialIdentityRuntime), and native macOS/iOS management views. Transaction, sync, backup, resolution, and connection tests mirror those modules. |
| Import and use private keys and SSH certificates | **Implemented** | Caterm preserves the certificate/private-key pairing and writes scoped runtime material for OpenSSH. Evidence: [`CredentialIdentityEditorService.swift`](../Sources/CredentialIdentitySecurity/CredentialIdentityEditorService.swift), [`CredentialIdentityConnectionPreparer.swift`](../Sources/CredentialIdentityRuntime/CredentialIdentityConnectionPreparer.swift), and [`CredentialIdentityAuthenticationTests`](../Tests/CatermMobileTests/MobileCredentialIdentityAuthenticationTests.swift). Caterm does not currently provide an in-app general-purpose key generator. |
| Biometric, non-exportable Secure Enclave SSH keys | **Implemented** | A signed physical-device run created a device-bound P-256 identity, displayed its ready state, terminated and relaunched Caterm, restored the Keychain reference, and authenticated to a disposable OpenSSH fixture through a confirmed identity with no password fallback. The private key never left the Secure Enclave, and the temporary identity, Host, and server authorization were removed after acceptance. Evidence: [`SecureEnclaveIdentityKeyProvider.swift`](../Sources/CredentialIdentitySecurity/SecureEnclaveIdentityKeyProvider.swift), [`SecureEnclaveSSHAgentSession.swift`](../Sources/CredentialIdentityRuntime/SecureEnclaveSSHAgentSession.swift), and [`CredentialIdentityIntegrationTests.swift`](../Tests/CredentialIdentitySecurityTests/CredentialIdentityIntegrationTests.swift). |
| FIDO2 SSH keys and Termius SSH ID | **Deliberately excluded** | Caterm has no account service and does not publish a device key set under a hosted handle. FIDO2 needs a separate hardware-token transport and UX; neither is implied by Secure Enclave support. |
| Password and private-key authentication | **Implemented** | macOS uses OpenSSH with scoped askpass and prepared identity material; iOS uses NIO SSH authentication plans. Evidence: [`SSHConnectionPolicy.swift`](../Sources/SSHCommandBuilder/SSHConnectionPolicy.swift), [`MobileAuthenticationPlanProvider.swift`](../Sources/CatermMobile/MobileAuthenticationPlanProvider.swift), and the corresponding SSH command, SessionStore, and mobile authentication tests. |
| Built-in agent forwarding | **Deliberately excluded** | Caterm intentionally removed its non-functional Agent credential source and does not pretend that a Finder-launched app can depend on an ambient `SSH_AUTH_SOCK`. Device-bound signing uses a narrowly scoped Caterm runtime instead of exposing a general forwarded agent. |
| Multi-hop Jump Hosts and SOCKS forwarding | **Implemented** | Recursive `ProxyJump`, cycle detection, generated per-session config, and dynamic forwarding are implemented in [`SSHCommandBuilder.swift`](../Sources/SSHCommandBuilder/SSHCommandBuilder.swift), [`Chain.swift`](../Sources/SSHCommandBuilder/Chain.swift), and [`PortForward.swift`](../Sources/SSHCommandBuilder/PortForward.swift), with focused builder tests. |
| HTTP proxy configuration | **Deliberately excluded** | Caterm supports explicit SSH Jump Hosts and dynamic SOCKS forwarding, not a separate HTTP CONNECT proxy layer. Adding one would expand proxy credential, trust, and failure semantics without improving the core SSH path. |
| Local, remote, and dynamic port forwarding | **Implemented** | macOS exposes all three OpenSSH forwarding kinds and records skipped-rule diagnostics through [`PortForward.swift`](../Sources/SSHCommandBuilder/PortForward.swift) and [`PortForwardWorkspaceView.swift`](../Sources/Caterm/Views/PortForwardWorkspaceView.swift). Builder, preflight, persistence, and UI behavior are covered by [`PortForwardValidationTests.swift`](../Tests/SSHCommandBuilderTests/PortForwardValidationTests.swift), [`PortForwardPreflightTests.swift`](../Tests/SessionStoreTests/PortForwardPreflightTests.swift), and [`PortForwardWorkspaceTests.swift`](../Tests/CatermTests/PortForwardWorkspaceTests.swift). iOS synchronizes the declarations but does not advertise an always-on mobile tunnel because background suspension makes that promise false. |
| Desktop Workspaces with split/focus presentation, reusable layout, and broadcast | **Implemented** | A native window tab owns a Workspace tree while `SessionStore` continues to own each connection. Evidence: [`WorkspaceCore`](../Sources/WorkspaceCore), [`WorkspaceCoordinator.swift`](../Sources/Caterm/WorkspaceCoordinator.swift), [`NativeWorkspaceSplitView.swift`](../Sources/Caterm/Views/NativeWorkspaceSplitView.swift), [`WorkspaceTemplateStore`](../Sources/WorkspaceTemplateStore), and [`WorkspaceBroadcast`](../Sources/WorkspaceBroadcast), plus their mirrored tests. Templates create fresh sessions; broadcast reviews one complete command against a frozen recipient snapshot and reports per-Pane outcomes. |
| Exact restoration and an advertised 16-terminal Workspace limit | **Unverified** | Caterm deliberately advertises no numeric Pane limit. An ad-hoc signed real-SSH run exposed and fixed the embedded-terminal wakeup path and the asynchronous saved-Host restoration race; a restarted three-Pane Workspace then restored three independent connected sessions while a genuinely missing Host retained its safe recovery surface. Apple Development-signed restoration, accessibility, and multi-surface resource evidence remain open in [#55](https://github.com/ZingerLittleBee/Caterm/issues/55). |
| IDE-style autocomplete and shell integration | **Deliberately excluded** | Caterm does not open extra exec channels to collect remote history, working directory, or active-command state. This avoids a hidden compatibility and privacy expansion. Ghostty remains the terminal engine, not a shell telemetry service. |
| Saved Snippets and explicit terminal paste/run | **Implemented** | Snippets persist and synchronize on macOS and iOS through [`SnippetStore`](../Sources/SnippetStore), [`SnippetSyncClient`](../Sources/SnippetSyncClient), and [`MobileSnippetSyncRuntime.swift`](../Sources/CatermMobile/MobileSnippetSyncRuntime.swift). Store, reconciliation, transport-model, and mobile lifecycle behavior are covered by the mirrored Snippet test targets. |
| Startup Snippets and per-Host environment variables | **Implemented** | [`HostAutomation.swift`](../Sources/SSHCommandBuilder/HostAutomation.swift) provides stable Snippet references, validated non-secret environment metadata, explicit review/suppression, and reconnect policy across macOS and iOS. Signed disposable SSH fixtures verified the full command review, one exact startup execution, an accepted environment value, a rejected value remaining absent, the macOS OpenSSH acceptance-limit warning, and a suppression connection with no automation. |
| Reviewed multi-Host and multi-Pane Snippet execution | **Implemented** | [`WorkspaceBroadcast`](../Sources/WorkspaceBroadcast) freezes the selected recipients, requires one complete-command review, and reports per-Pane outcomes. The native review surface lives in [`WorkspaceBroadcastViews.swift`](../Sources/Caterm/Views/WorkspaceBroadcastViews.swift), with execution and policy coverage in [`WorkspaceBroadcastTests.swift`](../Tests/WorkspaceBroadcastTests/WorkspaceBroadcastTests.swift). |
| Synchronized shell command history | **Deliberately excluded** | Caterm records local connection metadata, not terminal commands or output. This is a privacy boundary, not a missing sync lane. [`SessionHistory`](../Sources/SessionHistory) stores Host, timing, state, and outcome only. |
| Recorded session logs and log bookmarks | **Deliberately excluded** | Caterm does not persist or synchronize terminal output by default. Connection history exists for operational diagnostics, but it is not a replayable terminal log. |
| Desktop dual-pane SFTP, cross-Host copy, drag and drop, transfer tracking, and external-editor upload-back | **Deferred** | The native implementation and focused/real-OpenSSH tests exist in [`SFTPTaskWindowView.swift`](../Sources/Caterm/Views/SFTPTaskWindowView.swift), [`RemoteExternalEditorCoordinator.swift`](../Sources/Caterm/Views/RemoteExternalEditorCoordinator.swift), and [`RealOpenSSHTransferTests.swift`](../Tests/FileTransferStoreTests/RealOpenSSHTransferTests.swift). Ad-hoc signed real-SSH GUI runs covered local-to-remote and remote-to-remote copy, relaying disclosure, Keep Both conflicts, exact byte integrity, private external-editor staging, automatic in-place-save detection, remote-change conflict choices, atomic upload-back, cancellation, unrelated terminal-Pane independence, editor exit, task-window close, application quit, and clean and modified-draft cleanup. Automated watcher tests separately cover atomic replacement followed by later in-place writes. Caterm deliberately remains outside App Sandbox because the current libghostty PTY child cannot execute OpenSSH in a sandbox-signed prototype; [ADR 0007](adr/0007-keep-macos-transport-outside-app-sandbox.md) records that shipping boundary. Apple Development-signed shipping-configuration acceptance remains open in [#59](https://github.com/ZingerLittleBee/Caterm/issues/59) because the current signing attempt fails with `errSecInternalComponent`. |
| iPhone and iPad SFTP with Files integration, mutations, transfer state, and drag and drop | **Implemented** | NIO SFTP browsing/mutations and the shared transfer coordinator are composed in [`MobileAppComposition.swift`](../Sources/CatermMobile/MobileAppComposition.swift), [`MobileFileBrowserView.swift`](../Sources/CatermMobile/MobileFileBrowserView.swift), and [`MobileFileTransfer.swift`](../Sources/CatermMobile/MobileFileTransfer.swift). Mobile transport, real-fixture, Files, lifecycle, conflict, cancellation, and accessibility tests live under [`CatermMobileTests`](../Tests/CatermMobileTests). |
| Mobile cross-Host SFTP copy | **Deliberately excluded** | The mobile product keeps transfer ownership inside one active Host session and provides explicit download, Files export, and upload workflows. It does not expose a multi-session remote-copy API or imply that the deferred desktop dual-pane workflow ships on iPhone or iPad. |
| Mobile-native terminal input and hardware keyboard support | **Implemented** | The iOS terminal provides a programmable key strip, native-keyboard choice, hardware-keyboard routing, snippets, resize handling, and reconnect through [`CatermMobileTerminal`](../Sources/CatermMobileTerminal) and [`MobileTerminalSessionView.swift`](../Sources/CatermMobileTerminal/MobileTerminalSessionView.swift), with focused mobile terminal tests. Caterm does not claim Termius voice input or AI command generation. |
| Local Terminal, Mosh, Telnet, and Serial | **Deliberately excluded** | Caterm is an SSH and SFTP product. Telnet is unencrypted, Serial is a separate hardware product, Local Terminal adds sandbox and shell-lifecycle scope, and Mosh needs UDP transport, server bootstrap, roaming, and mobile lifecycle design. |
| Cross-device Hosts, credentials, settings, and snippets | **Implemented** | The live iOS root owns durable stores and a serialized lifecycle coordinator in [`MobileCatermShell.swift`](../Sources/CatermMobile/MobileCatermShell.swift), [`MobileAppComposition.swift`](../Sources/CatermMobile/MobileAppComposition.swift), and [`MobileSyncCoordinator.swift`](../Sources/CatermMobile/MobileSyncCoordinator.swift). Shared Host reconciliation, encrypted credential envelopes, settings compatibility, and snippet sync are covered by their module tests and mobile composition tests. Cached Hosts and snippets remain available while offline or signed out. |
| Encrypted cloud vault and recoverable cross-device credential policy | **Implemented** | Caterm uses the user's private CloudKit database plus synchronizable iCloud Keychain rather than a Caterm account or server. Credential fields are sealed with AES-256-GCM and associated data before CloudKit upload. Evidence: [`CredentialSync`](../Sources/CredentialSync), [`CredentialSyncStore`](../Sources/CredentialSyncStore), [`CredentialIdentitySecurity`](../Sources/CredentialIdentitySecurity), and their crypto/sync tests. |
| Known Hosts synchronization | **Deliberately excluded** | Caterm synchronizes Host metadata but keeps authorization device-local by design. Every device performs its own host-key verification. The threat-model decision is recorded in [ADR 0006](adr/0006-known-host-trust-is-device-local.md). |
| App PIN or biometric application lock | **Deliberately excluded** | Caterm relies on the signed-in macOS or iOS session, device passcode, FileVault, Keychain access controls, and Apple device-management or remote-erase controls. A second app-local PIN would not replace those boundaries. Secure Enclave SSH signing is a separate SSH authentication capability, not an application lock. |
| Termius-account two-factor authentication | **Deliberately excluded** | Caterm has no Caterm account, hosted control plane, or password login to protect with a second factor. Device access is governed by the user's Apple platform security and iCloud account controls; SSH server authentication remains independent. |
| Post-quantum SSH algorithm guarantee | **Unverified** | Caterm delegates macOS negotiation to the installed OpenSSH and iOS negotiation to its NIO SSH stack. No pinned ML-KEM/ML-DSA interoperability matrix exists, so Caterm makes no post-quantum compatibility claim. |

## Team and Business boundary

The following current Termius features are intentionally excluded from the
individual parity count:

| Termius capability | Boundary in Termius | Caterm disposition |
| --- | --- | --- |
| Shared Team vault, secure team sharing, real-time collaboration, and Terminal Multiplayer | Team and above | **Deliberately excluded.** Caterm is account-free and has no collaboration backend. |
| Team-visible session logs | Team and above | **Deliberately excluded.** Caterm does not capture terminal content by default. |
| Multiple Team vaults and granular vault access control | Business and above | **Deliberately excluded.** There is no Caterm organization or role model. |
| AWS, DigitalOcean, and Azure inventory discovery | Team and above in the current pricing comparison | **Deliberately excluded.** Provider inventory and credentials are a separate product surface, not SSH-client parity. |
| SAML SSO, compliance reports, approved domains, administration, billing, and enterprise support | Business or Enterprise | **Deliberately excluded.** These do not belong to the individual-user product. |

Team and Business rows are not counted as individual gaps and do not inflate
the roadmap.

## Verification limits at completion

- Focused #59 verification passed 77 XCTest cases, with two environment-gated
  real-fixture tests skipped, plus 14 Swift Testing cases. The two real
  OpenSSH tests also passed separately against disposable single-Host and
  dual-Host fixtures.
- The relative ControlMaster-path regression selection passed 78 XCTest cases
  plus one Swift Testing case. An ad-hoc signed GUI run then connected to a
  disposable OpenSSH fixture, authorized a local folder, listed the remote
  location, uploaded an exact 43-byte file, and refreshed the remote pane.
- Further ad-hoc signed #59 GUI coverage passed remote-to-remote relay and
  conflict flows plus external-editor save detection, remote-conflict choices,
  atomic upload-back, cancellation, editor-exit handling, and explicit draft
  discard. That run exposed an in-place-save detection defect; the production
  watcher was fixed test-first, and 12 external-editor Swift Testing cases now
  cover both in-place writes and atomic replacement followed by later in-place
  writes. A later run verified that closing an unrelated terminal Pane leaves
  the draft intact; both task-window close and application quit require
  explicit confirmation, preserve the draft when cancelled, and clean staging
  without uploading when confirmed.
- Ad-hoc signed #55 GUI coverage found and fixed a terminal-lifecycle defect:
  embedded libghostty wakeups now drain on the main actor so child exit state
  reaches the Pane. A separate Workspace restoration defect was also fixed:
  saved Workspaces now retry after the asynchronous Host repository loads. A
  restarted three-Pane fixture restored three independent connected SSH
  surfaces; an actually missing Host remained on the safe recovery surface.
- The final mobile regression selection passed 87 XCTest cases plus 11 Swift
  Testing cases. A fresh `make ios-build` product installed and launched on an
  iPhone 17 Pro Simulator and an iPad Pro 13-inch Simulator; Computer Use
  confirmed the compact tab layout and regular-width sidebar/detail layout.
- `swift build --target Caterm` and focused affected suites pass.
- The full unfiltered `make test` run remains non-green because suite-composed
  execution stalls in an XCTest asynchronous wait; focused affected suites
  pass and isolated suites around the last buffered output also pass.
- A prior `make run-app` acceptance produced and launched a development-signed
  application whose disposable SSH fixture completed startup automation.
  The current rerun reaches the signing step but fails with
  `errSecInternalComponent`; desktop SFTP Apple Development-signed
  shipping-configuration proof remains a separate gate.
- Signed physical-device acceptance created a Secure Enclave identity,
  restarted Caterm before connecting, and authenticated to a disposable
  OpenSSH fixture with no password fallback. Cleanup then confirmed that the
  identity metadata, device-bound Keychain accounts, temporary Host, and
  server authorization were absent.
- Signed macOS Workspace restoration/accessibility/load proof and Apple
  Development-signed desktop SFTP shipping-configuration acceptance remain
  scoped by #55 and #59.
- No private Host address, account identity, credential, terminal content,
  screenshot, application log, or local fixture is included in this document
  or committed elsewhere by the parity audit.
