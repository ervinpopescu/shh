# Roadmap and status

This roadmap describes the current `main` branch. Status labels distinguish
code and test evidence from work that requires external infrastructure or
future protocol implementation.

## Verified implementation milestones

The following capabilities are present in the source and have focused tests in
this repository. A passing test demonstrates the named seam, not universal
production interoperability.

1. **Foundation and architecture - implemented.** Package seams, SwiftUI
   application coordination, terminal primitives, command-safety policy, typed
   failures, and unavailable states are present in `Sources/ShhCore/` and
   `App/`. Evidence: `ShhCoreTests`, `ShhAppTests`, and
   `ShhTerminalTests`.
2. **Data, identities, trust, and backup - implemented.** Version-tolerant
   host models, opaque identity descriptors, Keychain abstractions, trust
   records, session restoration, and encrypted vault export/import are present.
   Evidence: `KeychainCredentialStoreTests`, connection failure and restoration
   tests, and `EncryptedVaultBackupTests`.
3. **Direct live SSH - implemented.** `LiveSSHTransport` uses SwiftNIO SSH for
   TOFU host-key validation before credential resolution, password and Ed25519
   authentication, PTY/shell channels, isolated exec channels, keepalives,
   typed errors, reconnect support, and target resolution. Evidence:
   `LiveSSHTransportTests`, `SSHExecIntegrationTests`, and optional saved-host
   tests in `HetznerConnectionIntegrationTests`.
4. **ProxyJump and forwarding - implemented.** Recursive bastion channels,
   local and remote forwarding, and dynamic SOCKS5 forwarding are implemented.
   Evidence: `MultiHopProxyJumpTests` and `PortForwardingTests`.
5. **Tmux and Herdr - implemented.** Tmux probing, robust session parsing,
   creation, attach, remembered targets, approval, and Herdr workspace/pane
   operations are implemented. Zellij, Byobu, and Screen remain explicitly
   deferred adapters. Evidence: `TmuxTests`, `TmuxAppTests`, `HerdrTests`, and
   `HerdrIntegrationTests`.
6. **Terminal behavior - implemented.** SwiftTerm integration, alternate
   screen handling, theme and font preferences, key encoding, accessory
   modifiers, bracketed paste, and resize debouncing are implemented. Evidence:
   `Tests/ShhTerminalTests/` and app typography tests.
7. **Local voice - implemented.** Apple Speech and WhisperKit providers,
   protected temporary recording, model management, resource checks, editable
   transcript preview, and explicit-send policy are implemented. Evidence:
   `Tests/ShhVoiceTests/` and `VoiceTests`.
8. **SFTP and Files app integration - implemented in code.** Citadel is isolated
   to `LiveSFTPRepository`; browsing, transfers, editing, conflict handling,
   File Provider contracts, operation-scoped sessions, App Group snapshots, and
   bounded caches are implemented. Evidence: SFTP and File Provider tests.
9. **Bonjour discovery and lifecycle recovery - implemented.** `_ssh._tcp`
   browsing, advertised hostname resolution, retained discoveries, finite iOS
   background tasks, transport probes, and generation-safe foreground recovery
   are implemented. Evidence: `BonjourSSHDiscoveryTests` and restoration,
   reachability, and lifecycle app tests.
10. **Mosh UDP foundation - implemented, protocol-incomplete.** SSH bootstrap,
    UDP datagrams, session-key redaction/zeroization, state reporting, and
    roaming probes are implemented. Full Mosh SSP encryption, negotiation,
    packet authentication, and speculative echo are not implemented. Evidence:
    `MoshDomainTests`, `MoshBootstrapAndTransportTests`, and `MoshAppTests`.
11. **Cloudflare Access and Tailscale profiles - implemented for target
    resolution.** Connection models, Codable compatibility, Cloudflare header
    construction, Keychain secret lookup, Tailscale hostname resolution, and
    host-key policy mapping are implemented. Evidence:
    `CloudflareTailscaleConnectionTests` and
    `CloudflareTailscaleTransportTests`. External service interoperability is
    not part of CI.
12. **Vault, privacy, and CI validation - implemented.** Encrypted vault
    behavior, privacy manifest, App Group and icon validation scripts, unsigned
    app/extension builds, simulator test jobs, and manual Swift CodeQL workflow
    are present. Evidence: `just ci`, `.github/workflows/ci.yml`, and
    `.github/workflows/codeql.yml`.

## Remaining work and external validation

1. **Physical-device provisioning and smoke tests - not verified.** The source
   contains App Group, Keychain, and File Provider entitlement declarations,
   but physical-device provisioning, Files app execution, Keychain access, and
   microphone/audio behavior require an Apple Developer setup and hardware.
2. **Full Mosh SSP - incomplete.** Implement cryptographic SSP packet
   processing, negotiation, server interoperability, and speculative echo
   before describing Mosh as protocol-complete.
3. **External interoperability and independent review - not verified.** Add
   dedicated environments for Cloudflare Access, Tailscale, varied SSH/SFTP
   servers, network transitions, and device matrices. No third-party
   cryptographic or privacy audit is represented here.
4. **Distribution - not implemented.** There is no TestFlight, App Store
   Connect, signing/distribution, export-compliance submission, or release
   automation workflow. Local `just deploy` is a development install only.

## How to update this roadmap

When a feature changes, update the status and its evidence in the same change.
Do not mark a capability complete solely because a model or UI exists. Link to
focused tests and state whether evidence is unit-level, in-process integration,
simulator-only, optional live-host, physical-device, or external-service
validation. Keep historical milestones only when they are labeled as historical
rather than presenting an old branch state as current.
