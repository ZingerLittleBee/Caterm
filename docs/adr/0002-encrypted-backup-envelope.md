# Backup archives use a scrypt + AES-256-GCM JSON envelope

Status: accepted

Manual sync exports all user configuration — including passwords and
private keys — into a single portable `.catermbackup` file, so the file
format is a compatibility contract and a security boundary. We chose a
self-describing JSON envelope: `formatVersion`, explicit KDF parameters
(`scrypt`, N=2^17, r=8, p=1, random 32-byte salt), a small key-validation
block, and one AES-256-GCM ciphertext whose AAD is the canonicalized
header bytes. The plaintext payload carries its own `contentVersion`,
versioned independently of the envelope (Aegis's pattern).

Considered options:

- **Argon2id** is the nominally preferred KDF (Bitwarden/Termius/ente use
  it), but neither CryptoKit nor swift-crypto provides it, and we refuse a
  third-party crypto dependency. scrypt at N=2^17 is equally memory-hard
  in practice and ships in swift-crypto's `_CryptoExtras`, which is
  already in our dependency graph via swift-nio-ssh — zero new deps.
- **Header as AAD** (inspired by age's header MAC): none of the surveyed
  products authenticate their KDF parameters, leaving them open to
  downgrade tampering (SecureCRT's unsalted-SHA256 + zero-IV design is
  the cautionary tale). Binding the header to the ciphertext closes this.
- **Key-validation block** (Bitwarden's `encKeyValidation`): lets import
  distinguish "wrong passphrase" from "corrupted file" — a single GCM
  blob cannot.

Consequence: the envelope fields, KDF parameters, and AAD canonicalization
are frozen once a release ships; any change requires bumping
`formatVersion` and keeping the old decode path forever.
