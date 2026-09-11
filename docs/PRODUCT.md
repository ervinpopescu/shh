# Shh product slice

Shh is a native iOS/iPadOS 17 SSH client foundation. This checkout ships an offline/demo vertical slice so navigation and safety workflows can be reviewed without credentials or a server.

## Implemented

- Adaptive `NavigationSplitView` host/session/files/snippets/monitoring/settings shell.
- Host create/edit/delete metadata; group/tag/identity/trust models; identity records contain only opaque Keychain references.
- Demo SSH transport, foreground session lifecycle, ANSI-oriented terminal text, command composer, and explicit disconnect.
- Snippet display and exact-command approval workflow.
- Multiplexer picker with tmux command model and honest unavailable states.
- Files/SFTP and local Whisper boundaries with unavailable UI.

## Planned behind the same seams

Vetted iOS SSH/PTY implementation, real Keychain implementation, SFTP, health service, tmux execution, local Whisper model management, forwarding, Mosh, ProxyJump, and UI test/device validation. Background sessions, sync, transfers, and rich Herdr orchestration are post-release work.
