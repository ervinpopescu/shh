<div align="center">

# Shh

### A native, privacy-first SSH workspace for iPhone and iPad

[![CI](https://github.com/ervinpopescu/shh/actions/workflows/ci.yml/badge.svg)](https://github.com/ervinpopescu/shh/actions/workflows/ci.yml)
[![iOS 17+](https://img.shields.io/badge/iOS%2FiPadOS-17%2B-0A7EA4)](https://developer.apple.com/ios/)
[![Swift 5.10](https://img.shields.io/badge/Swift-5.10-F05138)](https://www.swift.org/)

Connect to hosts, work in a real terminal, move files, and keep common
operations within thumb reach. Shh keeps credentials in the platform
Keychain, verifies host keys before authentication, and does not require a
Shh cloud service.

</div>

## What Shh does

- **Terminal-first SSH** - SwiftNIO SSH, PTY sessions, SwiftTerm rendering,
  TOFU host-key verification, reconnect support, and ProxyJump bastions.
- **Files and tunnels** - In-app SFTP, iOS Files integration, local/remote/
  SOCKS5 forwarding, and Bonjour discovery for `_ssh._tcp` services.
- **Focused workflows** - Tmux controls, Herdr workspaces, a one-handed
  Command Dial, terminal image insertion, and Live Activity session status.
- **Local voice input** - WhisperKit and Apple Speech providers with editable
  previews. Transcripts are never sent automatically.
- **Encrypted portability** - `.shhbackup` vault files use AES-256-GCM and
  PBKDF2-HMAC-SHA256. Keychain credential bytes and private keys stay out of
  backups.
- **Privacy by design** - No analytics or tracking service. The privacy
  manifest declares no collected data types; network and microphone access are
  used only by their corresponding features.

## How it works

1. Add a host with endpoint metadata and an opaque identity reference.
2. Approve the host key when Shh encounters an unknown fingerprint. Changed
   host keys are rejected.
3. Shh resolves the selected credential only after trust approval, then opens
   the terminal or an isolated SFTP, exec, or forwarding channel.
4. Use the terminal directly, or open the Command Dial for saved commands,
   multiplexer controls, voice composition, and image transfer.

## Quick start

Shh targets iOS and iPadOS 17 or newer. The repository currently provides the
source and simulator development workflow rather than a TestFlight or App
Store release.

On macOS, install [Xcode](https://developer.apple.com/xcode/),
[XcodeGen](https://github.com/yonaskolb/XcodeGen), and [`just`](https://github.com/casey/just):

```sh
just doctor device=iphone
just generate
open Shh.xcodeproj
```

For a repeatable local check:

```sh
just check
just test iphone
```

Use `DEVELOPER_DIR` to select a different Xcode installation. Simulator
builds use the local ad-hoc defaults; physical-device builds require your own
Apple Developer provisioning and signing team.

## Development commands

```sh
just --list             # Show all recipes
just format-check       # Check Swift formatting
just lint               # Swift and shell checks
just unit               # Host-runnable Swift package tests
just build iphone       # Build the generated app for an iPhone simulator
just test ipad          # Run app tests on an iPad simulator
just ci                 # Run the CI-equivalent local flow
```

The reusable package targets can also be tested directly:

```sh
swift package dump-package
swift test
```

Generated `Shh.xcodeproj` output and build products are local artifacts. The
canonical project description is [`project.yml`](project.yml).

## Product status and boundaries

Shh is an active implementation project with substantial automated coverage:
package tests, app tests, generated unsigned builds, and simulator tests. An
optional live-host simulator path is available when its host snapshot,
credentials, and trust state are configured. Cloudflare Access and Tailscale
coverage validates target resolution, not an external login or network.

The following remain outside the repository's release evidence:

- physical-device provisioning, Keychain/App Group behavior, Files app
  execution, and hardware microphone validation;
- complete Mosh SSP cryptography, packet authentication, server-compatible
  negotiation, and speculative echo;
- broad SSH server, roaming, Cloudflare, Tailscale, and hardware
  interoperability testing;
- an independent cryptographic or privacy audit; and
- TestFlight, App Store distribution, export-compliance submission, and
  release signing.

Demo mode and the Docker OpenSSH fixture are development aids, not proof of
production interoperability. See [`docs/PRODUCT.md`](docs/PRODUCT.md) for the
implementation evidence boundary and [`docs/SECURITY.md`](docs/SECURITY.md)
for the threat model and credential guarantees.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) - module boundaries and
  integration seams.
- [`docs/PRODUCT.md`](docs/PRODUCT.md) - implemented features and validation
  limits.
- [`docs/SECURITY.md`](docs/SECURITY.md) - trust, credential, backup, and
  privacy contracts.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) - completed milestones and future work.
- [`AGENTS.md`](AGENTS.md) - local setup, testing, CI, and contribution
  guidance.
