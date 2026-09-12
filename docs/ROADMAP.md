# Roadmap

## Completed Milestones (Feature Branch)

1. **Foundation & Architecture:** Package seams, adaptive SwiftUI shell,
   ANSI terminal primitives, command safety policies, and unavailable
   states.
2. **Data & Security:** Versioned models, Keychain abstraction seams,
   opaque identity records, and session restoration.
3. **Live SSH Transport:** Citadel and SwiftNIO SSH integration, PTY
   allocation, TOFU host-key verification, cancellation, and resize
   handling.
4. **Multiplexer Integration:** First-class Tmux control adapter,
   session listing, creation, attach, and command approval flows.
5. **On-Device Voice AI:** WhisperKit CoreML and Apple Speech
   transcription, push-to-talk recording, preview editing, and zero
   auto-execution policy.
6. **Remote File Management:** SFTP subsystem repository, directory
   navigation, streamed upload/download, in-app text editor, and conflict
   resolution.
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

## Future Milestones (Physical Device & Distribution)

11. **Physical Device & Provisioning:** Apple Developer portal App Group
    and File Provider entitlement provisioning, device Keychain smoke
    testing, and physical microphone validation.
12. **Mosh SSP Hardening:** Full State Synchronization Protocol (SSP)
    cryptographic packet encryption and speculative local echo.
13. **TestFlight Beta & App Store:** Build automation, TestFlight
    internal and external beta testing, and App Store Connect metadata.
