# Architecture

Shh is a native SwiftUI iOS/iPadOS 17+ SSH client. The repository is split
between reusable Swift package targets and an XcodeGen-defined iOS application
with a File Provider extension. The package seams make network, terminal,
voice, storage, and policy behavior testable without requiring a running app.

## Build and target topology

```text
Package.swift
  ShhCore       domain models, policies, contracts, persistence, crypto
  ShhSSH        SwiftNIO SSH, SFTP adapter, discovery, forwarding, Mosh
  ShhTerminal   SwiftTerm bridge, input, resize, terminal preferences
  ShhVoice      Apple Speech, WhisperKit, audio capture, model management
       \             |            |             /
        project.yml (XcodeGen specification)
                 |
       Shh iOS application + ShhFileProvider extension
                 |
       ShhAppTests and package test targets
```

`project.yml` is the source of truth for the generated `Shh.xcodeproj`.
`Shh.xcodeproj`, build products, DerivedData, SwiftPM checkouts, and resolved
package metadata are generated or ignored. Use `just generate` after changing
the XcodeGen specification; do not hand-edit generated project files.

The iOS app target is `Shh`, with bundle identifier
`com.ervinpopescu.shh`. The extension target is `ShhFileProvider`, with bundle
identifier `com.ervinpopescu.shh.FileProvider`. Both use the shared App Group
`group.com.ervinpopescu.shh`; the app and extension also declare the shared
Keychain access group. The app declares Bonjour service `_ssh._tcp` and the
local-network usage description in `App/Info.plist` and `project.yml`.

## Runtime data flow

```text
SwiftUI views
    -> AppContainer (@MainActor)
       -> injected Core protocols and state
          -> LiveSSHTransport / LiveMoshTransport
          -> LiveSFTPRepository
          -> PortForwardingManager / BonjourSSHDiscovery
          -> VoiceProviderRegistry / WhisperModelManager
          -> KeychainCredentialStore / trust and catalog stores

AppContainer and FileProviderManagerHelper
    -> App Group catalog and known-host snapshots
       -> ShhFileProvider operation-scoped sessions
          -> LiveSFTPRepository -> remote SFTP server
```

The app coordinator owns user-facing session state and injects concrete or demo
implementations. The extension runs in its own process and consumes only the
shared contracts and atomically synchronized snapshots it needs.

## Modules

### ShhCore

`Sources/ShhCore/` is the platform-neutral model and policy layer. Its major
seams are:

- `Domain.swift`: hosts, connection profiles, groups, tags, identity
  descriptors, trust records, terminal preferences, forwarding rules, and
  session models.
- `Services.swift`: transport, trust, credential, command execution, catalog,
  and persistence protocols, typed errors, Keychain implementations, command
  policy, remote path safety, and demo services.
- `EncryptedSync.swift`: versioned `.shhbackup` envelopes, AES-GCM and PBKDF2
  implementation, secret scanning, sync records, and replace/merge restore
  modes.
- `SFTP.swift`, `Tmux.swift`, `Herdr.swift`, and `Mosh.swift`: feature
  contracts, command builders, parsers, state models, and demo adapters.
- `ReconnectCoordinator.swift`: actor-isolated reconnect state and backoff
  coordination.
- `FileProviderContracts.swift`: stable item identifiers, change anchors,
  cache metadata, eviction policies, and offline-operation records.

The package target does not own SwiftUI screens or live iOS lifecycle wiring.
Use protocols and injected implementations when adding behavior so the core
and its tests remain independent of app UI and device services.

### ShhSSH

`Sources/ShhSSH/` contains live network implementations:

- `LiveSSHTransport` is the primary direct SwiftNIO SSH transport. It performs
  host-key validation, password or Ed25519 authentication, PTY and shell
  setup, isolated exec channels, keepalives, reconnect support, and ProxyJump
  channel construction.
- `HostKeyValidatorDelegate` and the trust protocols enforce the TOFU decision
  flow before credentials are resolved and sent.
- `LiveSFTPRepository` is deliberately isolated to the SFTP subsystem and uses
  Citadel for SFTP channel management. Citadel is not the primary terminal SSH
  handshake.
- `PortForwardingManager`, `PortForwardingTraffic`, and
  `SOCKS5ServerHandler` implement local, remote, and dynamic SOCKS forwarding.
- `BonjourSSHDiscovery` browses `_ssh._tcp`, resolves advertised hostnames and
  ports, and preserves discovered services across interface updates.
- `LiveMoshTransport`, `MoshBootstrapper`, `MoshConnection`, and
  `LiveMoshDatagramChannel` bootstrap `mosh-server` over SSH and carry the
  current UDP datagram model with roaming probes. Full Mosh SSP encryption and
  speculative echo are not implemented.
- `ServerTelemetryPoller` provides the remote telemetry probe used by the app.

The connection profile model also supports Cloudflare Access and Tailscale
endpoint resolution. Cloudflare Access resolves a tunnel domain and optional
Keychain-backed headers; Tailscale resolves the configured hostname and maps
its `checkHostKey` option to prompt or trusted-only host-key policy. These
profiles have serialization and target-resolution tests, but the repository's
CI does not authenticate against an external Cloudflare or Tailscale service.

### ShhTerminal

`Sources/ShhTerminal/` adapts SwiftTerm to UIKit and SwiftUI:

- `ShhTerminalController` owns terminal engine state, alternate-screen
  behavior, theme and font preferences, and terminal actions.
- `ShhTerminalView` hosts the SwiftTerm view.
- `TerminalInputCoordinator` handles accessory modifier state, one-shot
  consumption, passthrough escape sequences, UTF-8 input, and bracketed paste.
- `TerminalKeyEncoder` defines terminal key bytes, including Ctrl+Space NUL
  encoding.
- `ResizeDebouncer` coalesces terminal size changes before sending them to the
  connection.

### ShhVoice

`Sources/ShhVoice/` keeps speech processing local:

- `WhisperKitTranscriber` and `WhisperModelManager` manage on-device CoreML
  models, resource checks, downloads, validation, and deletion.
- `AppleSpeechTranscriber` is the explicit on-device Apple Speech provider.
- `AudioCaptureRecorder` owns microphone permission, recording lifecycle,
  interruptions, and temporary audio files.
- `VoiceProviderRegistry` exposes provider and model state to the app.

The app presents a transcript for editing and approval. Voice input is not an
implicit remote command execution path.

### App

`App/` contains SwiftUI screens and application coordination:

- `ShhApp.swift` defines the adaptive navigation shell, host editor, terminal
  screen, multiplexer views, voice composer, settings, and feature sheets.
- `AppContainer.swift` is the `@MainActor` coordinator. It wires transports,
  catalog and trust stores, Keychain, session restoration, background tasks,
  SFTP, forwarding, Mosh, Bonjour, voice, tmux, Herdr, and File Provider
  state.
- `SessionRestoration.swift`, `Reachability.swift`, and the background-task
  manager implement finite iOS lifecycle recovery. They do not guarantee
  indefinite background socket execution.
- `FileProviderManagerHelper.swift` registers domains and atomically writes
  catalog and known-host snapshots for the extension.
- `VaultBackupView.swift` and related settings views expose encrypted backup,
  Keychain identity, voice, and File Provider controls.

### ShhFileProvider

`FileProviderExtension/` implements `NSFileProviderReplicatedExtension`:

- `FileProviderExtension.swift` owns the extension entry point and operation
  lifecycle.
- `FileProviderEnumerator.swift` translates remote directory state into File
  Provider enumeration and change callbacks.
- `FileProviderItem.swift` maps remote metadata to File Provider items.
- `FileProviderSessionManager.swift` loads App Group snapshots, creates
  operation-scoped live SFTP sessions, and manages bounded local materialized
  file storage.

Mosh-only hosts are rejected because the extension requires SFTP. The extension
must not retain long-lived SSH sessions between independent File Provider
operations.

## Security-sensitive boundaries

The implementation and tests rely on these boundaries:

1. Host records persist endpoint metadata and opaque identity IDs, not secret
   bytes. Exact identity descriptors are resolved by UUID.
2. Host-key trust is evaluated before credential loading for direct, ProxyJump,
   and exec flows. Unknown keys require an explicit decision; changed keys are
   rejected.
3. `CommandPolicy` blocks destructive syntax and sends review-required or
   unsupported syntax through an explicit approval UI.
4. Vault backups use authenticated encryption and never include Keychain secret
   bytes. Import preserves tamper, schema, secret-scan, and replace/merge
   checks.
5. Remote paths are bounded with `RemotePath.appendingSafely`. File Provider
   caches are bounded and evicted by the core policy.
6. iOS background work uses finite UIKit background tasks. Foreground recovery
   probes the transport and restores the selected tmux or Herdr target when
   possible.

See [`SECURITY.md`](SECURITY.md) for threat-model detail and
[`PRODUCT.md`](PRODUCT.md) for user-visible behavior and validation limits.

## Tests and evidence

The package test targets cover core policy, models, vault behavior, transport
parsers, in-process SSH behavior, terminal input, and voice components. The
`ShhAppTests` target covers app coordination and SwiftUI-facing behavior. The
SSH integration tests use the in-process `SSHTestServer` in
`Tests/ShhSSHTests/`; the Docker OpenSSH image in `fixtures/docker-sshd/` is an
optional manual interoperability fixture.

`Tests/verify-app-group.sh`, `Tests/verify-app-icon.sh`, and
`Tests/verify-local-network-info-plist.sh` validate generated entitlements,
asset metadata, and local-network declarations. `just check` is the fast host
quality gate. `just ci` adds generated unsigned app and extension builds and
both simulator test passes. The optional Hetzner tests in
`Tests/ShhAppTests/HetznerConnectionIntegrationTests.swift` skip unless a
suitable shared simulator host and credential snapshot are present.

GitHub Actions runs on `macos-14`; `ci.yml` also has a docs-only fast path for
root/docs Markdown changes. `codeql.yml` performs a manual Swift build for
CodeQL analysis. Neither workflow is a TestFlight or App Store release
pipeline.
