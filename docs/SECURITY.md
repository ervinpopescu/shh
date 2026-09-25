# Security model and threat boundaries

Shh treats network peers, remote command output, voice transcripts, backup files,
and File Provider inputs as untrusted. This document describes guarantees in
this repository and identifies boundaries that require external deployment or
review. It is not an independent security audit.

## Credentials and secret isolation

- Host records persist endpoint metadata and opaque identity descriptor IDs.
  Passwords, passphrases, private-key bytes, and Cloudflare client secret
  bytes are not fields of `Host`; Cloudflare stores only an opaque Keychain
  reference in its connection options.
- `KeychainCredentialStore` owns credential bytes. Physical-device queries use
  the shared access group `group.com.ervinpopescu.shh`; unsigned simulator
  environments have a scoped fallback for local tests and previews.
- Host connections resolve an exact identity descriptor by UUID. Credential
  resolution occurs from the authentication delegate after the host-key
  challenge is accepted, rather than loading arbitrary or fallback identities.
- Deleting an identity descriptor retains a shared Keychain secret while other
  descriptors still reference it. Terminal output and scrollback redaction
  protects readable credential values regardless of catalog state.
- Cloudflare Access client IDs are metadata; an optional client secret is
  referenced by Keychain ID and resolved only while constructing the transport
  target. Do not log or serialize the resolved header value.
- Mosh session keys are redacted in descriptions and zeroized on connection
  teardown. Vault passphrase, derived-key, and plaintext serialization buffers
  have explicit cleanup paths, subject to normal platform memory semantics.

Relevant implementation and tests include `Sources/ShhCore/Services.swift`,
`Sources/ShhCore/Mosh.swift`, `Sources/ShhCore/EncryptedSync.swift`,
`Tests/ShhCoreTests/KeychainCredentialStoreTests.swift`, and
`Tests/ShhCoreTests/EncryptedVaultBackupTests.swift`.

## Host-key trust and transport isolation

- `LiveSSHTransport` is the primary direct SwiftNIO SSH implementation.
- Host-key verification uses canonical hostname, port, algorithm, and SHA-256
  fingerprint data. Unknown keys require an explicit trust decision. Changed
  host keys are rejected rather than silently replaced.
- The trust check runs before credential resolution for direct, ProxyJump, and
  exec flows. Temporary trust approvals apply only to the active connection;
  persistent trust records are written through the trust/catalog path.
- ProxyJump validates each hop and the target through the same trust boundary.
- `LiveSFTPRepository` uses Citadel only for the SFTP subsystem. Citadel does
  not own the primary terminal SSH handshake or PTY channel pipeline.
- Tailscale profiles resolve a configured hostname and use the normal prompt
  policy by default; `checkHostKey` selects trusted-only mode. A network
  overlay does not itself establish host identity.
- Cloudflare Access target resolution adds Access headers from configured
  metadata and Keychain state. The repository tests target construction, not
  an external Cloudflare Access deployment.
- Mosh currently bootstraps over SSH and carries the repository's UDP
  datagrams. Full Mosh SSP cryptographic packet processing and speculative echo
  are not implemented, so SSH transport completeness must not be conflated
  with complete Mosh protocol security.

## Remote command and terminal safety

- Commands, snippets, Herdr templates, and voice transcripts are untrusted
  input. `CommandPolicy` uses quote-aware tokenization and classifies syntax.
- Destructive operations are blocked unconditionally. Review-required or
  unsupported syntax requires explicit approval in the UI; approval cannot
  override a hard block.
- Voice transcription always appears in an editable preview and never executes
  automatically. Terminal accessory controls preserve exact escape sequences,
  UTF-8 input, bracketed paste, and Ctrl+Space NUL behavior.
- Remote output is displayed as data. Error mapping avoids exposing unrelated
  credential or filesystem details through user-facing transport failures.

## Encrypted vault backups

The `.shhbackup` envelope currently provides:

- AES-256-GCM authenticated encryption with a random nonce.
- PBKDF2-HMAC-SHA256 key derivation with a default of 600,000 iterations and a
  256-bit random salt. Imports enforce the configured minimum and maximum
  iteration bounds.
- Authenticated associated data binding the format identifier, schema version,
  and creation metadata to the ciphertext.
- Authentication failure before payload decoding for wrong passphrases or
  tampered ciphertext.
- Secret-material scanning before export and after decryption. Keychain secret
  bytes and private-key material are excluded from the payload.
- Security-scoped import staging, explicit replace versus merge restore, and
  prompt cleanup paths.

See `Sources/ShhCore/EncryptedSync.swift` and
`Tests/ShhCoreTests/EncryptedVaultBackupTests.swift`. The cryptographic code
has not received a third-party audit.

## File Provider, filesystem, and lifecycle boundaries

- The File Provider extension runs as a separate sandboxed process.
- App and extension state is shared through the App Group
  `group.com.ervinpopescu.shh`. Catalog and known-host snapshots are written
  atomically by `FileProviderManagerHelper` and consumed by operation-scoped
  extension sessions.
- Remote paths are normalized through `RemotePath.appendingSafely`, which
  rejects traversal outside the selected base path. Materialized files use
  bounded cache metadata and LRU eviction.
- Active terminal, Mosh, and forwarding sessions use finite UIKit background
  execution tasks. Shh does not use silent audio or an audio background mode to
  obtain indefinite network execution. iOS may still suspend the app; on
  foreground return, Shh probes the transport and reconnects/restores state
  when necessary.
- Mosh-only hosts are rejected by File Provider because they do not expose the
  required SFTP subsystem.

The relevant code is under `App/FileProviderManagerHelper.swift`,
`FileProviderExtension/`, `Sources/ShhCore/FileProviderContracts.swift`,
`Sources/ShhCore/Services.swift`, and `App/AppContainer.swift`.

## Privacy and platform declarations

`Resources/PrivacyInfo.xcprivacy` declares required-reason API access for:

- UserDefaults for local session and preference state.
- File timestamps for local cache and displayed modification metadata.
- Disk space checks for file operations and local Whisper model management.

The manifest sets tracking to false and has no collected data types. The app
also declares local-network access for `_ssh._tcp`, microphone and speech
usage descriptions for explicit voice features, and non-exempt encryption in
`project.yml`.

`App/Shh.entitlements` and
`FileProviderExtension/ShhFileProvider.entitlements` declare the shared App
Group and Keychain access group. Run the repository validation scripts after
changing these declarations:

```sh
Tests/verify-app-group.sh Shh.xcodeproj 'generic/platform=iOS'
Tests/verify-local-network-info-plist.sh
Tests/verify-app-icon.sh
```

The first command requires Xcode's developer directory, for example:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Tests/verify-app-group.sh Shh.xcodeproj 'generic/platform=iOS'
```

## Validation limits and release responsibilities

Automated package tests, app tests, generated unsigned builds, simulator tests,
and optional live-host tests provide evidence for implementation behavior. They
do not prove:

- physical-device Keychain, App Group, File Provider, microphone, or audio
  behavior;
- broad SSH server, Cloudflare, Tailscale, network-roaming, or iOS hardware
  interoperability;
- resistance to threats outside the tested model;
- an independent cryptographic or privacy audit; or
- App Store/TestFlight readiness.

There is no distribution pipeline in this repository. Apple provisioning,
App Store Connect submission, export-compliance declarations, and release
sign-off remain responsibilities for a future release process. Do not infer a
legal export classification or store approval from `ITSAppUsesNonExemptEncryption`.
