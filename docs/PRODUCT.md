# Shh product and implementation status

Shh is a native SwiftUI iPhone/iPad SSH client targeting iOS/iPadOS 17+. It
provides terminal access, remote file operations, automation and multiplexer
controls, local voice input, network tunneling, discovery, and encrypted local
backup without a Shh cloud service, analytics, or tracking.

This document separates implementation present in the repository from
validation that requires a configured remote host, simulator state, physical
hardware, or a future protocol task. Test names below are evidence of the
corresponding seams, not a claim that every external deployment has been
validated.

## Implemented feature surface

### SSH, authentication, and connection profiles

- **Direct SSH:** `LiveSSHTransport` uses SwiftNIO SSH for host-key
  verification, password and Ed25519 authentication, PTY and interactive shell
  channels, isolated command channels, keepalives, typed error mapping, and
  reconnect support.
- **TOFU and identities:** host records keep opaque identity references;
  unknown keys require a trust decision and changed keys are rejected. Exact
  identity resolution and metadata-only catalog reconciliation prevent silent
  credential fallback.
- **ProxyJump:** recursive bastion channels support host-ID and endpoint-based
  hop configuration.
- **Cloudflare Access profile:** resolves a tunnel domain and prepares the
  configured Access client ID and optional Keychain-backed client secret as
  transport-target metadata. Serialization and target-resolution behavior are
  covered; the repository does not implement or validate an external
  cloudflared login flow.
- **Tailscale profile:** resolves the configured Tailscale hostname and port.
  `checkHostKey` selects trusted-only versus the normal prompt policy.
  Serialization and target-resolution behavior are covered; no CI job requires
  a Tailscale network.

Evidence includes `LiveSSHTransportTests.swift`,
`SSHExecIntegrationTests.swift`, `MultiHopProxyJumpTests.swift`,
`CloudflareTailscaleTransportTests.swift`, and
`CloudflareTailscaleConnectionTests.swift`. The optional
`HetznerConnectionIntegrationTests.swift` exercises a saved live host only when
its simulator App Group snapshot and credentials are available.

### Terminal and multiplexer workflows

- **Terminal:** SwiftTerm rendering, alternate screen buffers, ANSI themes,
  search, terminal zoom, debounced resize, bracketed paste, accessory
  modifiers, and exact terminal key encoding.
- **Tmux:** availability probing, session listing and parsing, creation,
  attach, auto-attach, remembered targets, and explicit command approval.
  Parsing supports the current pipe-delimited output and documented legacy
  forms.
- **Herdr:** workspace creation, pane splitting, command dispatch, polling,
  state parsing, output inspection, and remembered workspace targets.
- **Deferred multiplexers:** Zellij, Byobu, and Screen are represented as
  unavailable UI choices and do not have live adapters in this repository.

Evidence is in `Tests/ShhTerminalTests/`, `Tests/ShhAppTests/TmuxAppTests.swift`,
`Tests/ShhCoreTests/TmuxTests.swift`, `Tests/ShhCoreTests/HerdrTests.swift`,
and `Tests/ShhSSHTests/HerdrIntegrationTests.swift`.

### SFTP and Files app integration

- **In-app SFTP:** `LiveSFTPRepository` uses Citadel for the SFTP subsystem,
  isolated from the primary terminal handshake. It supports navigation,
  metadata, streamed upload/download, editing, directory and file operations,
  transfer progress, and conflict handling.
- **File Provider:** `ShhFileProvider` exposes configured SSH/SFTP hosts to the
  iOS Files app through an `NSFileProviderReplicatedExtension`. Catalog and
  trusted-host records are synchronized through the shared App Group, sessions
  are operation-scoped, and materialized files use bounded cache policy.
  Mosh-only hosts are rejected because Mosh does not provide SFTP.

Evidence is in `Tests/ShhSSHTests/LiveSFTPRepositoryTests.swift`,
`Tests/ShhCoreTests/SFTPModelTests.swift`,
`Tests/ShhCoreTests/FileProviderContractsTests.swift`,
`Tests/ShhCoreTests/FileProviderInfoPlistTests.swift`, and
`Tests/ShhAppTests/FileProviderAppTests.swift`. The Files app extension still
requires Apple provisioning and physical-device validation for release use.

### Forwarding, discovery, and lifecycle

- **Forwarding:** local, remote, and dynamic SOCKS5 forwarding with rule
  validation, traffic counters, status state, non-loopback approval, and
  ProxyJump support.
- **Bonjour:** `_ssh._tcp` browsing with advertised hostname and port
  resolution, trailing-dot normalization, retained discoveries, and actionable
  network failure states.
- **Session lifecycle:** finite UIKit background-task grace periods preserve
  active SSH, Mosh, and forwarding work when iOS permits it. Foreground return
  probes the existing transport and reconnects/restores the last tmux or Herdr
  target if the socket did not survive. Indefinite background TCP execution is
  not promised.

Evidence is in `Tests/ShhSSHTests/PortForwardingTests.swift`,
`Tests/ShhCoreTests/PortForwardingModelTests.swift`,
`Tests/ShhSSHTests/BonjourSSHDiscoveryTests.swift`,
`Tests/ShhAppTests/RestorationAndReachabilityTests.swift`, and
`Tests/ShhAppTests/ConnectionFailureAppTests.swift`.

### Mosh roaming

`LiveMoshTransport` bootstraps `mosh-server` over SSH, obtains a session key and
UDP port, uses a datagram channel, and reports connected, roaming, and
reconnect-related state. `MoshConnection` implements the repository's current
datagram model, teardown, key zeroization, and roaming probe behavior.

Full Mosh State Synchronization Protocol encryption, packet authentication,
server-compatible SSP negotiation, and speculative echo are not implemented.
The current implementation must not be described as a complete Mosh client.
Evidence is limited to repository model, bootstrap, transport, and app tests in
`Tests/ShhCoreTests/MoshDomainTests.swift`,
`Tests/ShhSSHTests/MoshBootstrapAndTransportTests.swift`, and
`Tests/ShhAppTests/MoshAppTests.swift`.

### Local voice input

- **Providers:** WhisperKit CoreML models and Apple Speech are explicit local
  providers. Cloud speech recognition is not used by the implementation.
- **Recording:** push-to-talk audio capture handles permissions, interruptions,
  route changes, temporary protected files, and cleanup.
- **Safety:** transcripts appear in an editable preview and require explicit
  approval before they can be sent as remote input. They are never auto-run.
- **Model management:** model tiers are selected using device resource checks;
  model files live under Application Support and can be downloaded or removed.

Evidence is in `Tests/ShhVoiceTests/` and `Tests/ShhAppTests/VoiceTests.swift`.
Microphone latency and interruptions on physical devices remain unvalidated.

### Encrypted vault backup and privacy

`.shhbackup` export/import uses AES-256-GCM with PBKDF2-HMAC-SHA256 at 600,000
iterations, authenticated envelope metadata, secret-material scanning, schema
validation, wrong-passphrase and tamper detection, security-scoped staging,
and explicit replace or merge restore. Keychain secret bytes and private keys
are excluded from the backup payload. Passphrase and intermediate buffers have
explicit cleanup paths.

`Resources/PrivacyInfo.xcprivacy` declares the required-reason APIs used by the
app for local preferences, file timestamps, and disk-space checks. It declares
no tracking and no collected data types. Evidence is in
`Tests/ShhCoreTests/EncryptedVaultBackupTests.swift` and
`Tests/ShhCoreTests/FileProviderInfoPlistTests.swift`.

### Development and demo mode

The app has an injected demo mode selected by `--demo` or
`SHH_DEMO_MODE=1`. Demo transports, SFTP, voice, and Mosh adapters allow UI
and simulator flows without real credentials. Demo mode is not a production
transport and must not be used as evidence of live-host interoperability.

## Validation boundary

The standard automated coverage is:

- `swift test` or `just unit` for package models, policies, live transport
  components, in-process SSH integration, terminal behavior, and voice logic.
- `just test iphone` and `just test ipad` for the generated app test scheme on
  available simulators.
- `just ci` for package tests, generated unsigned app and extension builds,
  icon and entitlement checks, and both simulator test passes.
- GitHub CodeQL for the manually built Swift targets.

The optional live-host simulator tests require an existing App Group snapshot,
Keychain credentials, trusted host state, and a remote environment. They are
skipped when those prerequisites are absent. The Docker OpenSSH fixture in
`fixtures/docker-sshd/` is available for manual checks but is not a required
package-test dependency.

## Remaining product and release work

These items are intentionally not marked complete by repository tests:

1. **Physical-device validation and provisioning:** App Group and File Provider
   provisioning, device Keychain behavior, microphone/audio behavior, and
   Files app execution require an Apple Developer setup and hardware.
2. **Complete Mosh SSP:** cryptographic SSP packet processing, negotiation,
   server interoperability, and speculative local echo require additional
   protocol implementation.
3. **Independent security review:** no third-party cryptographic audit is
   represented by this repository.
4. **Broad interoperability matrix:** external Cloudflare, Tailscale, SSH
   server, network-roaming, and physical-device combinations need dedicated
   validation beyond the current test doubles and optional host tests.
5. **Distribution:** no TestFlight, App Store Connect, signing, export
   compliance submission, or App Store release pipeline is present.
