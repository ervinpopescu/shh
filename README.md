# Shh

Shh is a native SwiftUI iPhone/iPad SSH client targeting iOS/iPadOS 17+.

## Overview

Shh provides an adaptive terminal client, multiplexer integration,
on-device voice transcription, multi-hop port forwarding, Herdr agent
management, Mosh roaming recovery, native iOS Files app integration
via a File Provider extension, and zero-knowledge encrypted vault
backups.

## Documentation

- [`AGENTS.md`](AGENTS.md) - Repository map, architecture seams, setup,
  commands, security contracts, testing, CI, and troubleshooting for coding
  agents.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) - Layer and target boundaries.
- [`docs/PRODUCT.md`](docs/PRODUCT.md) - Implemented behavior and release
  limitations.
- [`docs/SECURITY.md`](docs/SECURITY.md) - Credential, transport, backup,
  privacy, and entitlement guarantees.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) - Completed and future milestones.

## Capabilities

- **Terminal & Transport:** Live SwiftNIO SSH transport with PTY,
  TOFU host-key verification, and SwiftTerm rendering with alternate
  screen buffers and debounced resize handling. Citadel is isolated to
  the SFTP subsystem.
- **Lifecycle & Keepalive:** Finite iOS background grace period
  keepalives for active SSH, Mosh, and forwarding sessions without
  background audio modes, with zero-delay foreground resumption via
  transport probing.
- **Multiplexing:** First-class Tmux integration supporting session
  listing, creation, attach, and command approval.
- **On-Device Voice AI:** WhisperKit and Apple Speech local transcribers
  with push-to-talk recording, editable preview drawers, and strict
  manual send safety policies.
- **Local Network Discovery:** Bonjour discovery (`_ssh._tcp`) detecting
  local SSH servers with advertised mDNS hostname and port resolution.
- **Tunneling & Bastions:** Multi-hop ProxyJump pipeline and port
  forwarding (local, remote, and dynamic SOCKS5).
- **Network Profiles:** Cloudflare Access tunnel resolution with optional
  Keychain-backed client secrets and Tailscale hostname resolution with
  configurable host-key policy. External service interoperability is not part
  of CI.
- **Herdr Supervision:** Workspace and pane management with structured
  agent state monitoring and output inspection.
- **Mosh Roaming:** UDP datagram transport with automatic network
  roaming recovery and session resumption. Full Mosh State
  Synchronization Protocol (SSP) payload encryption and speculative echo
  remain pending.
- **File Provider Extension:** Exposes remote SFTP directories directly
  in the iOS Files app via an `NSFileProviderReplicatedExtension`.
  Atomic synchronization of catalog snapshot and trusted host keys.
  Mosh-only hosts are rejected as unsupported.
- **Encrypted Vault Backup:** Zero-knowledge `.shhbackup` export and
  import encrypted with AES-256-GCM and PBKDF2-HMAC-SHA256 (600,000
  rounds). Includes preview of record counts before restore, explicit
  replace versus merge restore choices, wrong-passphrase and tamper
  detection, and security-scoped staging. Keychain credential bytes and
  private keys are strictly excluded.
- **Privacy & Safety:** Privacy manifest declaring required-reason APIs
  (`UserDefaults`, file timestamps, disk space). Zero tracking, zero
  analytics, and zero collected data.

## Getting Started

On macOS, install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and
`just`, then generate the ignored Xcode project:

```sh
just generate
open Shh.xcodeproj
```

For the repeatable development lifecycle, install `just` and run `just --list`.
The default full-Xcode toolchain is `/Applications/Xcode.app/Contents/Developer`;
override it with `DEVELOPER_DIR=...`. Dedicated simulator presets are selected
without erasing simulator state:

```sh
just check
just build device=iphone
just test device=ipad
just deploy iphone
just deploy-device <simulator-or-device-udid>
just launch ipad
just logs iphone seconds=30
just screenshot ipad
just stop iphone
just ci
```

`IPHONE_UDID`, `IPAD_UDID`, and `DERIVED_DATA_PATH` override the presets and
build location. Simulator builds use ad-hoc signing by default
(`SIGNING_IDENTITY=-`, `SIGNING_REQUIRED=NO`). Physical-device builds use
automatic development signing with team `B7D575CY5M` by default; override it
with `DEVELOPMENT_TEAM=<team-id>` when needed. They never pass the simulator
ad-hoc identity or disable required signing. An unavailable simulator is
reported as such instead of being treated as a physical device. `just clean`
removes only the selected DerivedData directory. Test results, logs, and
screenshots are written to timestamped paths under `tmp/e2e/`.

The Foundation-only core is also a Swift package:

```sh
swift package dump-package
swift test
```

## Platform Status & Limitations

The implementation is covered by package tests, app tests, generated unsigned
builds, and iPhone/iPad simulator tests where applicable. Optional live-host
integration tests require a configured simulator snapshot and remote host;
Cloudflare and Tailscale tests cover target resolution rather than external
service login.

Physical-device App Group/File Provider provisioning, hardware microphone and
Files app validation, full Mosh SSP encryption, independent security review,
broad interoperability testing, and TestFlight/App Store distribution remain
unverified or incomplete. See [`docs/PRODUCT.md`](docs/PRODUCT.md) and
[`docs/ROADMAP.md`](docs/ROADMAP.md) for the evidence boundary.
