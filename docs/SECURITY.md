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

### 2. Trust-On-First-Use (TOFU) Verification
- Host-key verification occurs prior to credential transmission.
- Fingerprints are canonicalized using SHA-256 over canonical hostname,
  port, and algorithm.
- Changed host keys are unconditionally rejected and require explicit
  user review.
- Temporary trust approvals apply only to the active connection and are
  never exported to persistent storage. Permanent trust records are
  synchronized atomically to shared App Group storage.

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
- Passphrase strings and memory buffers are cleared deterministically.

### 5. File Provider & Background Security
- The `ShhFileProvider` extension runs in a dedicated sandboxed process.
- Sessions are strictly operation-scoped: connections are established on
  demand and cleanly torn down after each file operation.
- Remote paths are normalized and bounded using `appendingSafely` to
  prevent path traversal vulnerabilities (`../`).
- Materialized files are cached with bounded counts, disk sizes, and
  LRU eviction policies.

### 6. Privacy Manifest & Required-Reason APIs
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
