# Security Model & Threat Assessment

Shh operates under a strict zero-trust model regarding untrusted network
data, remote execution outputs, voice transcripts, and backup storage.

## Core Security Invariants

### 1. Credentials & Secrets Isolation
- Host records persist endpoint metadata only (hostname, port,
  username).
- Passwords, passphrases, and private key bytes are never stored in
  `Host` records or written to disk.
- Identity records contain only opaque Keychain references.
- In-memory keys are zeroed on teardown.
- On physical devices, Keychain queries strictly enforce the shared
  access group (`group.com.ervinpopescu.shh`) and never broaden query
  scope; unsigned simulator environments use a scoped fallback without
  weakening device protections.
- Host connections resolve identities strictly by exact descriptor
  UUID, deferring credential store queries until after host-key
  acceptance. Missing descriptors or ambiguous collisions trigger
  actionable failures rather than silently degrading into password
  authentication or arbitrary keys.
- Deleting an identity descriptor performs reference-counted cleanup:
  when multiple descriptors share a Keychain reference, the secret is
  retained for surviving descriptors.
- Terminal log and scrollback redaction unconditionally protects all
  readable credential secrets regardless of catalog collision status.

### 2. Trust-On-First-Use (TOFU) Verification & Transport Isolation
- Primary SSH transport (`LiveSSHTransport`) is implemented directly with
  SwiftNIO SSH.
- Host-key verification occurs prior to credential transmission across
  all direct, ProxyJump, and exec channels.
- Fingerprints are canonicalized using SHA-256 over canonical hostname,
  port, and algorithm.
- Changed host keys are unconditionally rejected and require explicit
  user review.
- Temporary trust approvals apply only to the active connection and are
  never exported to persistent storage. Permanent trust records are
  synchronized atomically to shared App Group storage.
- Citadel is isolated strictly to the SFTP subsystem repository
  (`LiveSFTPRepository`) and does not govern the primary SSH terminal
  handshake or channel pipeline.
- Full Mosh State Synchronization Protocol (SSP) remains incomplete as
  a separate future protocol effort and does not affect the complete,
  production-grade status of the SSH transport.
- Evaluation boundary honesty: unit, integration, and live-host simulator
  testing validates implemented protocol behavior, error recovery, and
  interoperability, but does not substitute for an independent third-party
  cryptographic security audit or a broad physical-device compatibility
  matrix.

### 3. Command Execution & Safety Policy
- Commands, snippets, Herdr templates, and voice transcripts are treated
  as untrusted input.
- `CommandPolicy` inspects commands with a quote-aware tokenizer and a
  strict allowlist.
- Destructive operations (root removal, device disk formatting, system
  tampering) are blocked unconditionally.
- High-risk or unrecognized syntax requires explicit modal approval
  before transmission.
- Safety approvals cannot override unconditional blocks.

### 4. Zero-Knowledge Encrypted Vault Backups
- Encrypted backup envelopes (`.shhbackup`) use AES-256-GCM authenticated
  encryption.
- Symmetric encryption keys are derived using PBKDF2-HMAC-SHA256 with
  600,000 iterations and a 256-bit cryptographically secure salt.
- Authenticated Associated Data (AAD) binds the format identifier,
  schema version, and creation timestamp to the ciphertext envelope.
- Tampered payloads or incorrect passphrases trigger immediate
  authentication failure before payload decoding.
- Backups are scanned for prohibited secret material (such as private
  key headers and passwords) before encryption and after decryption.
- Import uses security-scoped file access and stages files securely in
  the application sandbox, deleting staged copies immediately after use.
- Passphrase UI state variables are promptly reset upon task completion
  or modal dismissal. Raw `Data` overloads in `EncryptedVaultService`
  allow caller-controlled memory wiping via `Data.resetBytes(in:)`,
  plaintext payload serialization buffers are zeroed immediately
  following encryption and decryption, and PBKDF2 derived key material
  is wiped deterministically after use.

### 5. File Provider & Background Security
- The `ShhFileProvider` extension runs in a dedicated sandboxed process.
- Sessions are strictly operation-scoped: connections are established on
  demand and cleanly torn down after each file operation.
- Remote paths are normalized and bounded using `appendingSafely` to
  prevent path traversal vulnerabilities (`../`).
- Materialized files are cached with bounded counts, disk sizes, and
  LRU eviction policies.
- Active terminal and tunnel sessions utilize finite UIKit background
  execution tasks (`beginBackgroundTask`) rather than background audio
  modes or silent audio playback, ensuring App Store guideline
  compliance. On task expiration, session restoration metadata is
  securely persisted while avoiding premature socket destruction.
  Transports are probed on foreground return to verify cryptographic
  channel integrity.

### 6. Live Activities & Privacy Invariants
- Live Activity attributes (`ShhSSHSessionActivityAttributes`) and content
  state (`ContentState`) are strictly limited to non-sensitive connection
  metadata: session identifier, sanitized display name, sanitized host label,
  status (`connected`, `reconnecting`, `failed`, `disconnected`), timestamp,
  and reconnection attempt count.
- Terminal text, keystrokes, commands, snippets, private keys, passwords,
  and tokens are strictly excluded and never passed to ActivityKit or
  rendered on the Lock Screen or Dynamic Island.
- Display names and host labels are length-bounded and trimmed of
  leading/trailing whitespace and newlines.
- Live Activities are visual indicators only. They do not request
  background processing time, do not keep network sockets open, and do not
  extend background execution lifetime for SSH or SFTP connections.

### 7. Privacy Manifest & Required-Reason APIs
- `Resources/PrivacyInfo.xcprivacy` declares only accessed APIs:
  - `NSPrivacyAccessedAPICategoryUserDefaults`: Storing local session
    restoration metadata (`CA92.1`).
  - `NSPrivacyAccessedAPICategoryFileTimestamp`: Managing local file
    timestamps, cache eviction, and displaying file modification dates
    to the user (`C617.1`, `0A2A.1`, `3B52.1`).
  - `NSPrivacyAccessedAPICategoryDiskSpace`: Ensuring sufficient disk
    space before writing files or downloading Whisper AI models
    (`85F4.1`, `E174.1`).
- `NSPrivacyTracking` is set to `false`.
- `NSPrivacyCollectedDataTypes` is empty: zero analytics, zero crash
  reporting telemetry, zero user tracking.

### 8. Cryptographic Export Compliance (EAR Category 5, Part 2)
- Shh incorporates cryptographic software for remote communication
  (SSH/SFTP tunnels via SwiftNIO SSH and Citadel) and zero-knowledge
  local vault backup encryption (AES-256-GCM / PBKDF2).
- Non-exempt encryption declaration `ITSAppUsesNonExemptEncryption` is
  set to `YES` in `project.yml` (and rendered into `Info.plist`).
- In accordance with U.S. Export Administration Regulations (EAR, 15
  C.F.R. Part 740, Category 5, Part 2) and Apple App Store distribution
  guidelines, Shh falls under mass-market encryption (ECCN 5D992.c)
  with self-classification / BIS reporting. Distribution complies with
  Apple App Store Connect export compliance screening.

