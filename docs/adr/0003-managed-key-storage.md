# Private keys are always copied into managed storage, never referenced by user path

Status: accepted

Historically `.keyFile` hosts stored the absolute path of a user-picked
key (e.g. `~/.ssh/id_ed25519`), and ManagedKeyStore held only keys pulled
in by credential sync. We inverted this: picking a key file (or pasting
key text) now *imports* the bytes into ManagedKeyStore
(`Caterm/keys/<hostId>`), and `keyPath` always points inside managed
storage. Existing hosts are migrated once at launch (read old path → copy
bytes → rewrite via `setCredentialOnly`, which touches neither `updatedAt`
nor `credentialMaterialDirty`; unreadable sources stay put and fall into
the existing `needsCredentialSetup` flow). User path references had no
meaning on another device, so they blocked both credential sync symmetry
and encrypted backup portability — this matches Termius's model, and
makes export/import a pure read/write of the managed directory.

Consequence: key material is *copied*, so rotating a key in `~/.ssh` no
longer propagates to Caterm automatically — the user re-imports the key.
Do not "optimize" this back to path references; portability and the
backup format depend on the managed-storage invariant.
