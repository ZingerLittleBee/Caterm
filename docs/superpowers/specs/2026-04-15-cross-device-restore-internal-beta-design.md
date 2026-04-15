# Cross-Device Restore Internal Beta Design

Date: 2026-04-15
Project: Caterm
Status: Drafted and validated in brainstorming

## Summary

The next internal beta should optimize for one outcome: a user can sign in on a second machine, see the same saved SSH hosts and global terminal settings, and immediately start working.

This phase is not a production-release hardening pass. It is a reliability pass for the cross-device restore flow. SSH and SFTP quality still matter, but only after account, sync, and startup hydration are stable enough to support internal testing.

## Product Goal

Primary goal:

- After logging in on another machine, the user can recover their working environment fast enough to trust Caterm as a synced terminal manager.

In-scope synced data for this beta:

- Account and session
- Saved SSH hosts
- Global terminal settings

Explicitly out of scope for this beta:

- Restoring active tabs or active remote sessions
- Syncing recent paths or recent session history
- Host-specific terminal settings as a user-facing feature
- Production-grade release hardening across all security and QA dimensions

## Recommended Approach

Chosen approach: sync reliability first.

Why:

- It matches the stated beta goal better than terminal and SFTP polish.
- It creates a stable base for later feature work.
- It reduces the risk of a misleading beta where the main promise is cross-device restore but the synced state is incomplete or inconsistent.

Alternatives considered:

1. Connection reliability first
   Better single-machine terminal quality, but weaker support for the core beta promise.

2. Release hardening first
   Better long-term security posture, but slower progress toward an internal beta that users can exercise now.

## Current State

The codebase already has most of the core building blocks:

- Better Auth-based authentication is implemented.
- SSH hosts are stored server-side and sensitive credentials are encrypted at rest.
- Global terminal settings are persisted server-side and cached client-side.
- The desktop app can connect over SSH and SFTP and already supports practical day-to-day flows.
- Type checking passes and production builds pass.

Known gaps relevant to this beta:

- The sync/hydration path is implemented implicitly across providers and routes, but not yet treated as a first-class, tested product flow.
- Biome/Ultracite checks are blocked by a nested config under `.claude/worktrees`, which reduces confidence in routine validation.
- SSH host key verification is still not implemented, which is acceptable only for a limited internal beta with controlled usage and must not be treated as done for release.
- The SFTP transfer queue UI exists, but the backend queue semantics are not fully wired into actual transfer execution and cancellation.

## Priority Model

### P0: Internal Beta Blockers

These items must be stable before calling the cross-device restore flow ready for internal beta.

1. Authentication and session reliability
   Login must consistently succeed, session state must be readable from both app surfaces, and auth failures must degrade predictably.

2. SSH host sync correctness
   Create, edit, and delete operations must converge to the server state and appear correctly after login on another machine.

3. Global terminal settings sync correctness
   Global settings must persist server-side, load on sign-in, and resolve cleanly against local cache behavior.

4. Startup hydration clarity
   The app needs one clear startup sequence for signed-in users: authenticate, fetch synced state, populate providers, then render usable SSH/SFTP flows.

5. End-to-end cross-device verification
   There must be a small but real verification matrix proving that data created on machine A is usable on machine B.

### P1: Internal Beta Stability Enhancers

These should be done immediately after P0 or pulled into P0 if instability is discovered during testing.

1. SSH connection reliability and diagnostics
   Failed connects, reconnecting state, and credential loading errors must be understandable enough for internal testers.

2. SFTP baseline usability
   Connect, browse, edit, and single-file transfer should remain functional, but this phase does not require a full transfer-management system.

3. Validation workflow cleanup
   The repository should be lint-checkable in a normal developer workflow. The current nested Biome config conflict should be removed or isolated.

### P2: Post-Beta or Beta-Plus Work

These are valuable, but they do not directly unlock the chosen beta.

1. True transfer queue orchestration and cancellation semantics
2. Host-specific terminal settings UI
3. Recent-path and recent-session restore
4. Active tab or active session restoration
5. Cleanup of the server-side starter/demo surface

## Design

### Architecture Focus

The design should treat synced account state as a first-class data domain with a predictable lifecycle:

1. User signs in.
2. Session is validated.
3. Synced account data is fetched from the server.
4. Providers initialize from server state, using local cache only as a short-lived fallback.
5. SSH and SFTP user flows consume the hydrated state.

The key design rule is that server state is the source of truth for synced entities, while local cache only improves startup responsiveness and resilience.

### Data Domains

Account/session:

- Determines whether protected routes and providers should initialize.

SSH hosts:

- Persisted server-side.
- Credentials remain encrypted at rest.
- The hydrated host list is the canonical input for connection flows.

Global terminal settings:

- Persisted server-side.
- Cached locally for quick startup and temporary fallback.
- Resolved per host at runtime, even though this beta only commits to syncing the global layer.

### Hydration Rules

On authenticated startup:

- Attempt to load server session first.
- If authenticated, fetch SSH hosts and terminal settings from the server.
- Use cached terminal settings as placeholder state only until server data resolves.
- Never treat cache-only state as authoritative once server state is available.

On failed sync fetch:

- Surface a visible but non-blocking error.
- Continue to expose any safe cached settings already present.
- Avoid pretending that SSH hosts synced successfully if the host fetch failed.

### Error Handling

P0 error handling needs to optimize for diagnosability, not elegance.

Required behavior:

- Login failures should clearly distinguish invalid credentials from server/network problems.
- Host CRUD failures should leave the local UI consistent with actual server state.
- Settings save failures should roll back optimistic state or visibly re-sync.
- Startup hydration failures should state which synced domain failed: session, hosts, or settings.

### Testing Strategy

For this beta, testing should prioritize workflow confidence over broad unit-test coverage.

Required verification:

- Machine A creates an SSH host; machine B logs in and sees it.
- Machine A edits an SSH host; machine B refreshes or signs in and sees the updated value.
- Machine A deletes an SSH host; machine B no longer sees it.
- Machine A changes global terminal settings; machine B receives the same settings after sign-in.
- Cached settings do not override fresher server settings after successful fetch.

Recommended supporting checks:

- Protected-route auth gating
- Provider hydration on cold start
- Error-path behavior for failed host/settings fetches

## Delivery Plan

### Phase 1: Make Sync State Trustworthy

Target outcome:

- Signed-in users consistently receive synced hosts and global settings from the server.

Work in this phase:

- Audit and tighten auth/session initialization
- Normalize SSH host fetch/update/invalidate behavior
- Normalize terminal settings fetch/cache/update behavior
- Define and implement explicit hydration order for the desktop app

Exit criteria:

- Cross-device host and global settings restore works repeatedly in manual verification.

### Phase 2: Make the Restored State Immediately Usable

Target outcome:

- Synced hosts are not just visible; they are usable for real work.

Work in this phase:

- Improve SSH connection failure and reconnect diagnostics
- Verify stored credentials flow cleanly from server to connect actions
- Keep SFTP baseline flows working against synced hosts

Exit criteria:

- A tester can sign in on machine B, pick a synced host, and start a real SSH session without manual re-entry of synced metadata.

### Phase 3: Raise Internal Testing Confidence

Target outcome:

- Developers can validate changes quickly and testers hit fewer avoidable regressions.

Work in this phase:

- Remove the current Biome nested-root failure from normal `bun run check`
- Add targeted workflow verification or automated smoke coverage where practical
- Document beta limitations explicitly

Exit criteria:

- The team has a repeatable validation checklist and a clean developer quality gate.

## Risks

1. Cache/server divergence
   If placeholder cached settings behave like final state, users may see confusing reversions.

2. Auth appears healthy while sync is degraded
   A logged-in shell with missing synced data would fail the beta promise even if the app is technically usable.

3. Real-world SSH usage exposes security assumptions
   Host key verification is still missing, so the beta must stay constrained to trusted internal usage.

4. Stability work gets displaced by feature temptation
   The existing SFTP and terminal surfaces make it easy to keep expanding functionality instead of closing the core sync loop.

## Acceptance Criteria

This design is complete for the internal beta when all of the following are true:

- A user can sign in on another machine and see the same SSH hosts.
- A user can sign in on another machine and receive the same global terminal settings.
- The synced state becomes available through a predictable startup hydration flow.
- Failures in auth, host sync, or settings sync are visible and distinguishable.
- SSH remains usable with synced hosts after restore.
- The team can run type checks and builds successfully, and lint/check workflow is no longer blocked by repository-local config noise.

## Deferred Items

These are intentionally deferred beyond the scope of this design:

- Full transfer queue implementation
- Rich session restoration
- Host-specific settings UI
- Public-release security hardening beyond what is required for a trusted internal beta
