# Known-host trust is device-local

Status: accepted

An SSH host-key trust decision authorizes only the device on which the user made
it. Hosts and encrypted credential material can synchronize, but Known Hosts do
not silently confer trust on another device. This deliberately differs from
Termius's synced-vault surface because Caterm does not yet have an end-to-end
record design that exposes trust provenance, handles account changes, and lets a
receiving device distinguish observation from authorization.

Consequences: macOS and iOS use the same fingerprint, change, and rejection
semantics while keeping their stores local. Synchronizing Known Hosts requires a
separate threat model and an explicit user-facing provenance design. Device-bound
Secure Enclave private keys remain local under the same principle.
