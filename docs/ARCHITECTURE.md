# Architecture

Shh is organized into modular packages and targets enforcing clean
separation of concerns between core domain logic, Apple platform
adapters, network transports, terminal emulation, and background
extensions.

## Layered Modules

### 1. ShhCore (Foundation-Only Core)
- **Domain & Models:** Host metadata, endpoint configurations,
  identities with opaque Keychain references, tags, groups, snippets,
  and metadata-only `IdentityCatalogReconciliation` detecting missing
  references and colliding identities across catalog mutations.
- **Keychain Credential Store:** `KeychainCredentialStore` managing
  isolated private key secrets with serialized access, immediate probe
  cleanup, and simulator-scoped access group fallback while preserving
  strict device entitlement scoping.
- **Safety Policy:** `CommandPolicy` quote-aware tokenizer and allowlist
  blocking destructive commands and flagging review-required syntax.
- **Terminal Primitives:** `ANSIParser`, `TerminalGrid`, and cell models.
- **Sync & Vault:** `EncryptedVaultService`, `EncryptedVaultBackup`,
  PBKDF2-HMAC-SHA256 key derivation, AES-256-GCM encryption, secret
  detection, and replace/merge restore logic.
- **File Provider Contracts:** Stable item identifiers, metadata
  contracts, change anchors, and LRU cache eviction rules.
- **Mosh & Herdr Contracts:** Datagram parsing, command templates, and
  output parsers.

### 2. ShhSSH (Network & Transports)
- **Citadel / SwiftNIO SSH:** Live SSH connection management, PTY
  allocation, remote command execution channels, and host-key callbacks.
- **ProxyJump Pipeline:** Recursive multi-hop bastion SSH channels.
- **Port Forwarding:** Local port forwarding, remote port forwarding,
  and dynamic SOCKS5 server handlers.
- **Mosh Bootstrap & Transport:** Remote `mosh-server` invocation over
  SSH and UDP datagram client with network roaming recovery.
- **Live SFTP:** SFTP channel client for directory navigation, remote
  file CRUD, atomic upload, and streamed download.
- **Bonjour Discovery:** Local network SSH service browsing (`_ssh._tcp`)
  via `NWBrowser` and advertised mDNS hostname and port resolution via
  `NetService`.

### 3. ShhTerminal (Rendering & Input)
- **SwiftTerm Engine:** Native terminal view and rendering.
- **Controller:** Alternate screen buffer coordination, debounced resize
  handling (150ms window), and bracketed paste encoding.
- **Input Coordinator:** Sticky modifier state coordination
  (`TerminalInputCoordinator`) bridging accessory controls with SwiftTerm
  keyboard input, one-shot modifier consumption, exact Ctrl+Space NUL
  encoding, and passthrough safety for escape sequences, UTF-8, and
  bracketed paste.

### 4. ShhVoice (Local Speech Processing)
- **WhisperKit Transcriber:** On-device CoreML Whisper model
  management and transcription.
- **Apple Speech Transcriber:** On-device `SFSpeechRecognizer` fallback.
- **Audio Recorder:** Secure temporary audio file capture with 0600
  permissions, file protection, and immediate post-transcription
  deletion.

### 5. App (SwiftUI & Application Coordination)
- **`AppContainer`:** `@MainActor` state coordinator binding UI scenes
  with transport, catalog, audio, forwarding, and trust stores.
  Reconciles catalog identity references on mutation and persistence
  load, resolving exact identities without silent degradation, and
  managing reference-counted Keychain credential deletion.
  Coordinates finite iOS background execution grace periods via
  standard UIKit background tasks (`BackgroundTaskManaging`),
  preserving active SSH, Mosh, and port forwarding sessions without
  background audio modes, and probes transport responsiveness on
  foreground return before reconnecting.
- **File Provider Manager:** `FileProviderManagerHelper` coordinating
  domain registration, unregistration, and atomic updates to shared App
  Group storage (`snapshot.json` and `known_hosts.json`).
- **Vault Backup UI:** `VaultBackupView` managing encrypted backup
  export, import, preview, replace/merge restore, and security-scoped
  staging.

### 6. ShhFileProvider (App Extension)
- **`NSFileProviderReplicatedExtension`:** Exposes remote SFTP files in
  the iOS Files app.
- **Operation-Scoped Lifecycle:** SSH/SFTP sessions are opened on demand
  per operation and torn down promptly, preventing background connection
  leaks.
- **Shared App Group Storage:** Loads catalog and known-host records
  from `catalogs/snapshot.json` and `catalogs/known_hosts.json`.
- **Cache Eviction:** Bounded LRU cache for materialized files.

## CI Workflow Architecture

GitHub Actions runs on `macos-14` runners with:
- Automated package resolution and test verification (`swift test`).
- Project generation via cached XcodeGen (`xcodegen generate`).
- Generic unsigned iOS builds for `Shh` and `ShhFileProvider`.
- Dynamic simulator discovery selecting available iPhone and iPad
  runtimes without hardcoded identifiers.
- Bounded test execution with log capture and xcresult artifact
  upload on failure.
- Least-privilege permissions (`contents: read`) and concurrency
  cancellation.
