# Mobile SFTP Transport Selection

Date: 2026-07-22

## Decision

Caterm implements the read-only iOS and iPadOS file browser with a small SFTP
version 3 client built on the Apple `swift-nio-ssh` transport already used by
the mobile terminal. The first slice supports protocol negotiation, canonical
path resolution, directory open/read/close, and typed SFTP status handling.

This adds no new production dependency and no additional binary payload beyond
the code in Caterm itself. SFTP owns an independent SSH connection, so a file
listing failure cannot terminate an active terminal session.

## Candidate review

| Candidate | Maintenance and license | Compatibility and binary impact | Decision |
| --- | --- | --- | --- |
| In-house SFTP v3 on Apple `swift-nio-ssh` | Maintained with Caterm, same MIT/Apache-compatible dependency graph | Reuses Caterm's pinned Apple NIO stack and auth model; no new package or native library | Selected for the bounded read-only browser |
| [Citadel](https://github.com/orlandos-nl/Citadel) | Active in 2026, MIT | Uses a third-party `swift-nio-ssh` fork plus BigInt, bcrypt C code, and logging; overlaps Caterm's existing SSH stack | Rejected due to dependency duplication and unnecessary binary/API surface |
| [swift-ssh-client](https://github.com/gaetanzanella/swift-ssh-client) | Last repository activity observed in 2023, MIT | Pins older Swift Crypto and `swift-nio-ssh` ranges that conflict with Caterm's current packages | Rejected due to maintenance and compatibility risk |
| [mft](https://github.com/mplpl/mft) | LGPL | Wraps libssh and OpenSSL rather than SwiftNIO, adding native libraries and a separate SSH trust/auth stack | Rejected due to licensing, binary size, and architectural duplication |

## Security and lifecycle seams

- Password and managed Ed25519 key authentication use the same
  `SSHAuthPlan` produced for mobile terminal sessions.
- Terminal and SFTP sessions share one mobile Known Hosts store. File locking,
  reload-before-write, and atomic replacement prevent independent store or
  process instances from overwriting a concurrently accepted key. Unknown keys
  are persisted with trust-on-first-use; changed keys and persistence failures
  are typed errors and stop the connection. Corrupt or unreadable trust data
  fails closed, and a candidate key becomes trusted in memory only after its
  atomic write succeeds.
- Authentication offers are single-use. Re-offering a rejected credential can
  otherwise leave the SSH negotiation spinning indefinitely.
- Task cancellation closes the SFTP child channel, its dedicated SSH
  connection, and the event-loop group, including while connection setup is
  still pending. A cancelled client is discarded before a retry.
- Missing SFTP type, size, or permissions fields remain explicitly unknown;
  protocol data is never replaced with synthetic file metadata.
- Encrypted OpenSSH private keys are intentionally rejected with a typed error
  in this slice. Supporting bcrypt-encrypted OpenSSH key envelopes requires a
  separately reviewed cryptographic implementation.

## Verification contract

- Pure codec tests cover SFTP v3 NAME, STATUS, optional attributes, and
  malformed or truncated data.
- Controller tests cover canonical entries, typed permission/trust states, and
  stale-request suppression during navigation.
- Opt-in integration tests connect to real OpenSSH SFTP with both password and
  managed Ed25519 key authentication and verify host-key mismatch rejection.
- Simulator acceptance covers navigation and refresh on iPhone and iPad.
