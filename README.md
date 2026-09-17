# Shh

Shh is a native SwiftUI iPhone/iPad SSH client foundation targeting
iOS/iPadOS 17+.

## Overview

Shh provides an adaptive terminal client, multiplexer integration,
on-device voice transcription, multi-hop port forwarding, Herdr agent
management, Mosh roaming recovery, native iOS Files app integration
via a File Provider extension, and zero-knowledge encrypted vault
backups.

## Capabilities

- **Terminal & Transport:** Live Citadel/NIOSSH transport with PTY,
  TOFU host-key verification, and SwiftTerm rendering with alternate
  screen buffers and debounced resize handling.
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

On macOS with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
open Shh.xcodeproj
```

The Foundation-only core is also a Swift package:

```sh
swift package dump-package
swift test
```

## Platform Status & Limitations

All features above are implemented and verified via automated tests on
macOS host runners and iOS/iPadOS 17+ simulators. Physical device
deployment, Apple Developer App Group/File Provider provisioning
profiles, TestFlight distribution, and full Mosh SSP encryption remain
pending future hardware releases.
