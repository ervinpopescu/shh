# Roadmap

## Completed Milestones (Feature Branch)

1. **Foundation & Architecture:** Package seams, adaptive SwiftUI shell,
   ANSI terminal primitives, command safety policies, and unavailable
   states.
2. **Data & Security:** Versioned models, Keychain abstraction seams,
   opaque identity records, and session restoration.
3. **Live SSH Transport (SwiftNIO SSH):** Production `LiveSSHTransport`
   implemented directly with SwiftNIO SSH rather than Citadel. Enforces
   strict TOFU host-key verification before credential exchange, native
   password and Ed25519 key authentication (generated and imported
   OpenSSH, PKCS#8, and raw formats), interactive PTY and shell
   allocation, debounced window resize handling, isolated exec channels,
   recursive multi-hop ProxyJump bastions, port forwarding, automatic
   backoff reconnection, and live-host simulator interoperability.
4. **Multiplexer Integration:** First-class Tmux control adapter with
   collision-resistant pipe-delimited format parsing, backward-compatible
   parsing for legacy and tmux 3.7c underscore-sanitized output, session
   listing, creation, attach, and command approval flows.
5. **On-Device Voice AI:** WhisperKit CoreML and Apple Speech
   transcription, push-to-talk recording, preview editing, and zero
   auto-execution policy.
6. **Remote File Management (SFTP Subsystem):** Isolated SFTP subsystem
   repository (`LiveSFTPRepository`) using Citadel with native password
   and Ed25519 authentication, directory navigation, streamed
   upload/download, in-app text editor, structured failure state cards
   with actionable recovery, and conflict resolution.
7. **ProxyJump & Port Forwarding:** Recursive multi-hop bastions, local
   port forwarding, remote port forwarding, and dynamic SOCKS5 proxying.
8. **Herdr Orchestration:** Multi-agent workspace supervisor, pane
   splitting, command execution, and status monitoring.
9. **Mosh Roaming Transport:** UDP datagram transport with automatic
   network roaming recovery across Wi-Fi and Cellular interfaces.
10. **File Provider, Vault Backup & CI:** Native iOS Files app integration
    via `ShhFileProvider` extension with atomic catalog/known-hosts sync,
    zero-knowledge encrypted vault backup (`.shhbackup` AES-GCM +
    PBKDF2), privacy manifest audit, GitHub Actions CI workflow, and
    simulator test suites.
11. **Live Activities (Lock Screen & Dynamic Island):** Privacy-safe
    WidgetKit Live Activity tracking truthful SSH session status
    (connected, reconnecting, failed, disconnected) with reconnection
    progress, sanitized endpoint metadata, and clear background
    execution and credential isolation boundaries.

## Future Milestones (Physical Device & Distribution)

12. **Physical Device & Provisioning:** Apple Developer portal App Group
    and File Provider entitlement provisioning, device Keychain smoke
    testing, and physical microphone validation.
13. **Full Mosh SSP:** Complete State Synchronization Protocol (SSP)
    cryptographic packet encryption and speculative local echo (independent
    of the completed SSH transport).
14. **Independent Audit & Interoperability Expansion:** Third-party
    cryptographic security audit and broad physical-device compatibility
    matrix expansion (current validation covers unit, integration, and
    live-host simulator suites).
15. **TestFlight Beta & App Store:** Build automation, TestFlight
    internal and external beta testing, App Store Connect metadata, and
    EAR Category 5 Part 2 export compliance self-classification filing
    (ECCN 5D992.c).
