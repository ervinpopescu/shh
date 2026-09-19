# Shh Product Specification

Shh is a native iOS/iPadOS 17+ SSH client designed for engineers who
require security, terminal fidelity, automation, and platform
integration without third-party cloud servers or subscription telemetry.

## Implemented & Validated Features (Simulator & Live Host)

- **Production LiveSSHTransport (Direct SwiftNIO SSH):** Primary SSH
  transport implemented directly with SwiftNIO SSH rather than Citadel.
  Enforces strict Trust-On-First-Use (TOFU) host-key validation before
  any credential transmission, password and Ed25519 key authentication
  (supporting generated and imported OpenSSH, PKCS#8, and raw formats),
  interactive PTY and shell channels, debounced terminal resizing,
  isolated non-interactive exec channels, multi-hop ProxyJump bastions,
  local, remote, and dynamic SOCKS5 forwarding, automatic backoff
  reconnection, and validated live-host simulator interoperability.
- **Remote Files & SFTP Subsystem (Citadel Isolation):** Citadel is
  strictly isolated to SFTP subsystem management (`LiveSFTPRepository`)
  and does not govern the primary SSH handshake. Supports native
  password and Ed25519 authentication, directory navigation, streamed
  upload/download, in-app file editing, structured failure state cards
  with actionable recovery, and automatic approval retries.
- **Adaptive Navigation Shell:** Three-column `NavigationSplitView` on
  iPad and tabbed layout on iPhone, with dark mode and Dynamic Type
  support.
- **Terminal Session & PTY:** SwiftTerm rendering with alternate screen
  buffer support (vim, htop, tmux), ANSI color parser, search drawers,
  and debounced resize handling.
- **Host & Identity Management:** Host configurations, grouping, tags,
  health status, and opaque Keychain references. Private keys are never
  exposed as raw fields of `Host`. Host connections resolve exact
  descriptors by UUID without loading credentials prior to host-key
  acceptance, preventing silent fallback to password authentication or
  arbitrary keys. Missing or colliding identities are detected via
  metadata-only catalog reconciliation, highlighted in host editor
  pickers with fingerprint hints, and surfaced as actionable
  diagnostics. Identity deletion preserves shared Keychain secrets for
  surviving descriptors.
- **Tmux Multiplexer:** First-class tmux integration with session
  listing, creation, attach, and exact-command approval sheets. Includes
  collision-resistant pipe-delimited format parsing, backward
  compatibility for legacy and tmux 3.7c underscore-sanitized output,
  and safe out-of-band window and pane controls (switching, directional
  focus, splits, zoom, copy mode, and pane close) executed over SSH
  exec channels without typing into the interactive PTY.
- **One-Handed Command Dial:** Radial overlay menu optimized for
  single-thumb terminal navigation. Provides rapid access to common
  keys (Esc, Tab, Shift-Tab, directional arrows, Ctrl-C, Ctrl-D, Enter),
  custom snippets, voice recording, software keyboard toggling, pinned
  insert-only literals, and out-of-band multiplexer controls. Supports
  configurable placement (leading or trailing edge for left- or
  right-handed grip), compact or regular sizing, and haptic feedback.
  Integrates strictly with `CommandPolicy`, enforcing modal approval for
  review-required actions and disabling blocked commands.
- **SFTP Image-to-Terminal Insertion:** Direct image staging and upload
  from Photos, Files, or the system clipboard into remote host storage
  (`~/.shh/images/` or a host-configured directory override) over the
  active SFTP session. Enforces strict local pre-upload validation
  (ImageIO type verification for PNG, JPEG, HEIC, GIF, TIFF, and WebP;
  20 MB size and 40 MP dimension bounds). Safely inserts the
  POSIX-quoted remote path into the active terminal PTY without
  appending a newline, allowing the user to inspect or prepend commands
  before execution.
- **On-Device Voice AI:** WhisperKit local CoreML models and Apple
  Speech recognition. Local push-to-talk recording, non-secret
  transcripts, editable preview drawers, and strict prohibition against
  automatic execution.
- **ProxyJump & Forwarding:** Multi-hop bastions, local port forwarding,
  remote port forwarding, and dynamic SOCKS5 proxying.
- **Herdr Agent Orchestration:** Workspace creation, pane splitting,
  command dispatch, agent state monitoring, and output inspection.
- **Mosh Roaming Recovery:** UDP transport foundation with automatic
  reconnection across Wi-Fi and Cellular interface transitions. Note:
  full Mosh SSP remains a separate future protocol task and does not
  affect SSH completeness.
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

- **Physical Device Provisioning:** Apple Developer portal App Group
  and File Provider entitlement provisioning (`group.com.ervinpopescu.shh`
  and `com.apple.developer.fileprovider`) for out-of-process File Provider
  extension execution and physical device Keychain smoke testing.
- **Hardware Microphone & Audio:** Physical device microphone latency
  and background audio interruption validation.
- **Full Mosh SSP:** Complete State Synchronization Protocol (SSP)
  cryptographic packet encryption and speculative local echo (independent
  of the fully implemented SSH transport).
- **Independent Security Audit & Broad Interoperability:** Third-party
  cryptographic audit and broad physical-device hardware matrix testing
  (current testing covers unit, integration, and live-host simulator
  suites).
- **TestFlight Distribution:** TestFlight beta build pipeline and App
  Store Connect release records.
