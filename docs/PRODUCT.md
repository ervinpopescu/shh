# Shh Product Specification

Shh is a native iOS/iPadOS 17+ SSH client designed for engineers who
require security, terminal fidelity, automation, and platform
integration without third-party cloud servers or subscription telemetry.

## Implemented & Validated Features (Simulator)

- **Adaptive Navigation Shell:** Three-column `NavigationSplitView` on
  iPad and tabbed layout on iPhone, with dark mode and Dynamic Type
  support.
- **Terminal Session & PTY:** SwiftTerm rendering with alternate screen
  buffer support (vim, htop, tmux), ANSI color parser, search drawers,
  and debounced resize handling.
- **Host & Identity Management:** Host configurations, grouping, tags,
  health status, and opaque Keychain references. Private keys are never
  exposed as raw fields of `Host`.
- **Tmux Multiplexer:** First-class tmux integration with session
  listing, creation, attach, and exact-command approval sheets.
- **On-Device Voice AI:** WhisperKit local CoreML models and Apple
  Speech recognition. Local push-to-talk recording, non-secret
  transcripts, editable preview drawers, and strict prohibition against
  automatic execution.
- **ProxyJump & Forwarding:** Multi-hop bastions, local port forwarding,
  remote port forwarding, and dynamic SOCKS5 proxying.
- **Herdr Agent Orchestration:** Workspace creation, pane splitting,
  command dispatch, agent state monitoring, and output inspection.
- **Mosh Roaming Recovery:** UDP transport foundation with automatic
  reconnection across Wi-Fi and Cellular interface transitions.
- **Files App Integration:** File Provider extension exposing remote
  SFTP files directly in Apple's Files app. Domain registration and
  removal from Settings. Mosh-only hosts are explicitly rejected with
  clear guidance.
- **Encrypted Vault Backup & Sync:** Zero-knowledge `.shhbackup` export
  and import with passphrase confirmation, schema and count preview,
  explicit merge versus replace restore choices, wrong-passphrase and
  tamper detection, security-scoped file staging, and deterministic
  passphrase clearing. No Keychain secret bytes are included in backups.
- **Privacy Manifest:** Audited `PrivacyInfo.xcprivacy` declaring
  `UserDefaults`, file timestamps, and disk space checks. Zero tracking
  and zero user data collection.

## Pending Hardware & Release Requirements

The following capabilities require physical device access, paid Apple
Developer account provisioning, or future protocol engineering:

- **App Group & Extension Provisioning:** Production code signing with
  `com.apple.developer.fileprovider` entitlements and App Group
  sharing (`group.com.ervinpopescu.shh`) for out-of-process File Provider
  execution on physical devices.
- **Hardware Microphone & Audio:** Physical device microphone latency
  and background audio interruption validation.
- **Full Mosh SSP:** Complete State Synchronization Protocol (SSP)
  cryptographic packet encryption and speculative local echo.
- **TestFlight Distribution:** TestFlight beta build pipeline and App
  Store Connect release records.
