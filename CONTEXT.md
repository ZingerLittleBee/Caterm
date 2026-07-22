# Caterm

Native macOS/iOS SSH terminal manager. Users organize hosts, credentials,
snippets, and settings; data moves between devices via iCloud sync or via
manual encrypted backup files.

## Language

### Hosts & identity

**Host**:
A saved SSH destination (name, hostname, port, username, credential
reference, port forwards, jump chain). The central entity of the app.
_Avoid_: Server, session, connection (a session/tab is the *runtime* use of
a host)

**Server ID**:
The cross-device stable identity of a host, assigned by cloud sync. Local
host UUIDs are per-device and regenerated on pull; only the server ID can
say "these two records are the same host" across devices.
_Avoid_: Remote ID, CloudKit ID

**Jump chain**:
The sequence of hosts a connection tunnels through before reaching its
target, expressed host-to-host by reference.

### Credentials

**Credential source**:
*How* a host authenticates — password, key file, or agent. Metadata only;
never contains secret material.

**Credential material**:
The secrets themselves: passwords, key passphrases, private-key bytes.
Stored in Keychain / managed key storage, never in host metadata.
_Avoid_: Credentials (ambiguous between source and material)

**Managed key**:
A private key whose bytes are owned and stored by Caterm, keyed by host.
The only kind of key reference a host may hold — hosts never point at
user filesystem paths. Picking a key file or pasting key text *imports*
the bytes into managed storage.
_Avoid_: Key path, external key, key file reference

### Manual sync (encrypted backup)

**Backup archive**:
A single encrypted `.catermbackup` file containing a full snapshot of user
configuration (hosts, credential material, snippets, settings, bookmarks,
known hosts). The unit of manual sync between devices.
_Avoid_: Export file, config dump, vault

**Envelope**:
The self-describing outer layer of a backup archive: format version, key
derivation parameters, and ciphertext. Decrypting requires only the file
and the passphrase — no app state.

**Backup passphrase**:
The user-chosen (or generated) secret that encrypts one backup archive.
Never stored anywhere; losing it makes the archive unrecoverable.
_Avoid_: Master password (reserved by other products for account-level
secrets)

**Merge plan**:
The dry-run result of matching an archive against local data: per entity,
*add*, *update*, or *skip*, with reasons. Shown for confirmation before an
import writes anything.

**Merge**:
Import semantics — match entities by UUID then server ID, newer side wins
per entity, and local entities absent from the archive are never deleted.
_Avoid_: Restore, replace, overwrite (these imply destructive semantics
the import deliberately does not have)

### Workspaces

**Workspace**:
A durable group of terminal panes used together for one task. One native
window tab presents one workspace; changing its presentation does not change
its pane membership.
_Avoid_: Tab, layout, split view, session group

**Pane**:
A position within a workspace that holds one terminal session or an unresolved
host placeholder.
_Avoid_: Tab, tile, split

**Workspace presentation**:
The Focus or Split projection of a workspace. Presentation changes visibility
and emphasis without creating, closing, or reconnecting terminal sessions.
_Avoid_: Layout mode, session mode

**Workspace template**:
A versioned declaration of workspace hosts, pane topology, and initial focus.
Opening one creates fresh terminal sessions; it never resumes a live process.
_Avoid_: Saved session, snapshot, session restoration

**Command broadcast**:
A reviewed command or snippet delivered once to an explicit snapshot of
eligible panes in one workspace.
_Avoid_: Global broadcast, input mirroring, broadcast mode

### Cross-device continuity

**Resource continuity**:
Hosts, credential material, snippets, and compatible settings becoming
available on another authorized device through sync. It does not include a
live terminal process, socket, scrollback buffer, or host-trust decision.
_Avoid_: Session sync, session handoff

**Known host**:
A device-local SSH host-key observation and trust decision for one endpoint.
It is distinct from a saved Host and is not authorization for another device.
_Avoid_: Synced host trust, trusted Host
