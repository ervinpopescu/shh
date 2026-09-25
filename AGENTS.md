# Coding agent guide

This file is the repository-specific guide for coding agents working on Shh. It
is intentionally kept at the repository root so agent tooling can discover it.
Applicable parent, user, and organization-level instructions still apply. If a
nested instruction file is added later, its narrower path scope takes
precedence.

## Project at a glance

Shh is a native SwiftUI SSH client for iOS and iPadOS 17 or newer. It provides
interactive SSH terminals, tmux and Herdr integration, SFTP and Files app
integration, local voice transcription, port forwarding, Bonjour discovery,
Cloudflare Access and Tailscale connection profiles, Mosh roaming recovery,
and encrypted vault backups. There is no server-side
application in this repository and no analytics or tracking service.

The repository has two build surfaces:

- The Swift package in `Package.swift` builds the reusable `ShhCore`, `ShhSSH`,
  `ShhTerminal`, and `ShhVoice` targets plus their host-runnable tests.
- The XcodeGen specification in `project.yml` generates the iOS app,
  File Provider extension, and app-test targets. `Shh.xcodeproj` is generated
  and ignored by Git; do not edit it by hand.

The normal development host is macOS with Xcode, because the app and extension
are iOS targets. CI runs on `macos-14`, selects an installed Xcode 16, and
builds unsigned generic iOS targets plus iPhone and iPad simulator tests.
`project.yml` records an Xcode 15.4 project-generation preference, so use the
installed Xcode selected by `DEVELOPER_DIR` for the actual build.

## Before editing

1. Confirm the repository and worktree. The default checkout should remain on
   `main` or `master`; feature branches must use dedicated git worktrees. Do
   not switch branches or overwrite existing unrelated changes unexpectedly.

   ```sh
   git status --short --branch
   git branch --show-current
   git worktree list
   ```

2. Start from a clean tracked working tree, or record and preserve any
   pre-existing changes. Never overwrite unrelated edits. Build products and
   local evidence normally live in ignored `build/`, `.build/`, or `tmp/`
   paths, but still do not add them to a change.
3. Read the relevant design and security documentation before changing a
   behavior:
   - [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
   - [`docs/PRODUCT.md`](docs/PRODUCT.md)
   - [`docs/SECURITY.md`](docs/SECURITY.md)
   - [`docs/ROADMAP.md`](docs/ROADMAP.md)
4. Keep changes narrow. Do not commit unless the task explicitly asks for a
   commit. Never put secrets, private keys, passwords, host credentials, or
   device-specific evidence in the repository.

## Setup and command reference

Install the required macOS tools before using the project recipes:

- Xcode with an iOS 17+ simulator runtime and its command-line tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- `just` (`brew install just`)
- `swift-format` for Swift formatting (`brew install swift-format`)
- `shellcheck` for shell-script linting (`brew install shellcheck`)
- Python 3, which the recipes and validation scripts use
- Docker is optional and only needed for the OpenSSH fixture in
  `fixtures/docker-sshd/`

The recipes fail early when a required tool is missing. List the current
recipes before relying on memory:

```sh
just --list
just doctor device=iphone
```

`just doctor` checks Xcode, XcodeGen, Swift, Python, and the selected simulator.
The default developer directory is
`/Applications/Xcode.app/Contents/Developer`; set `DEVELOPER_DIR` to another
Xcode installation when necessary. CI sets it to the selected Xcode 16
installation.

### Generate, format, lint, and test

| Goal | Command | Notes |
| --- | --- | --- |
| Generate the project | `just generate` | Runs `xcodegen generate --spec project.yml`. |
| Format Swift | `just format` | Modifies Swift files under `App`, `FileProviderExtension`, `Sources`, and `Tests`. |
| Check Swift format | `just format-check` | Non-mutating `swift-format lint`. |
| Lint | `just lint` | Swift format lint plus `shellcheck Tests/*.sh`. |
| Host package tests | `just unit` | Runs `swift test --enable-code-coverage` for the package targets. |
| Fast local gate | `just check` | Format check, lint, and host package tests. |
| Full CI-equivalent flow | `just ci` | Host tests, project generation, unsigned generic builds, icon validation, and iPhone/iPad simulator tests. |
| Run all app tests on iPhone | `just test iphone` | Uses the selected available iPhone simulator and writes an `.xcresult` under `tmp/e2e/`. |
| Run all app tests on iPad | `just test ipad` | Same flow for the selected iPad simulator. |
| Run focused app tests | `just test-focused test=ShhAppTests/AppContainerTests device=iphone` | The `test` value can name a test class or method. |
| Build the app | `just build iphone` | Generates the project and builds for a simulator or explicit device UDID. |
| Inspect simulator/device readiness | `just doctor device=ipad` | Pass `udid=<id>` to inspect a specific target. |

The package tests use the in-process server and test doubles in
`Tests/ShhSSHTests/`; they do not require the Docker fixture. The optional
fixture can be used for manual OpenSSH interoperability checks:

```sh
docker build -t shh-test-sshd fixtures/docker-sshd
docker run -d --rm -p 2222:2222 --name shh-sshd shh-test-sshd
```

The fixture credentials are documented in
[`fixtures/docker-sshd/README.md`](fixtures/docker-sshd/README.md) and are test
credentials only. Do not use them in production or commit real credentials.

### Simulator and device lifecycle

Dedicated simulator presets are named `Shh Review iPhone` and `Shh Review
iPad`. The recipes discover their UDIDs instead of hardcoding them. Override
these values when needed:

- `IPHONE_UDID`: default iPhone preset UDID
- `IPAD_UDID`: default iPad preset UDID
- `DERIVED_DATA_PATH`: default `build/DerivedData`
- `DEVELOPER_DIR`: Xcode developer directory
- `SIGNING_IDENTITY`: simulator identity, default `-`
- `SIGNING_REQUIRED`: simulator signing requirement, default `NO`
- `DEVELOPMENT_TEAM`: physical-device team, default `B7D575CY5M`

Useful lifecycle commands are:

```sh
just boot iphone
just deploy iphone
just deploy-device <simulator-or-device-udid>
just launch iphone
just logs iphone seconds=30
just screenshot iphone name=launch
just stop iphone
just clean
```

`just deploy` installs the generated debug app. Simulator builds use ad-hoc
signing overrides; physical-device builds use automatic development signing
and require a provisioned device and team. `just launch`, `logs`, `screenshot`,
and `stop` operate on an already selected target. `just clean` removes only
the configured `build/` or `tmp/e2e/` DerivedData path. E2E logs, screenshots,
and result bundles are timestamped under `tmp/e2e/` and should not be committed.

## Repository map

| Path | Responsibility |
| --- | --- |
| `Package.swift` | Swift package products, targets, iOS/macOS platform declarations, and pinned dependency versions. |
| `Package.resolved` | Local dependency resolution output; ignored/generated, so do not hand-edit it. |
| `project.yml` | Canonical XcodeGen specification for the app, extension, package products, and test targets. |
| `justfile` | Canonical local lifecycle, validation, simulator, signing, and artifact commands. |
| `App/` | SwiftUI app entry point, `AppContainer`, host and identity UI, terminal/session coordination, SFTP UI, voice UI, forwarding UI, backup UI, and app entitlements. |
| `Sources/ShhCore/` | Foundation-only domain models, service protocols, safety policy, persistence contracts, vault encryption, SFTP/tmux/Herdr/Mosh models, and testable coordination primitives. |
| `Sources/ShhSSH/` | SwiftNIO SSH transport, TOFU host-key validation, ProxyJump, exec and PTY channels, Cloudflare Access and Tailscale target resolution, port forwarding, Bonjour discovery, Mosh transport, telemetry, and Citadel-backed SFTP. |
| `Sources/ShhTerminal/` | SwiftTerm bridge, terminal controller/view, input coordination, key encoding, resize debouncing, and terminal preferences. |
| `Sources/ShhVoice/` | Local Apple Speech and WhisperKit providers, audio capture, voice provider registry, model management, and resource checks. |
| `FileProviderExtension/` | `NSFileProviderReplicatedExtension`, enumeration/item adapters, operation-scoped sessions, and shared catalog storage. |
| `Resources/` | Privacy manifest and AppIcon asset catalog. |
| `Tests/ShhCoreTests/` | Core domain, persistence, vault, command, SFTP, tmux, Mosh, and voice model tests. |
| `Tests/ShhSSHTests/` | Transport, SSH server, SFTP, ProxyJump, forwarding, Bonjour, Herdr, Mosh, and telemetry tests. |
| `Tests/ShhTerminalTests/` | Headless terminal, key encoding, resize, and input coordinator tests. |
| `Tests/ShhVoiceTests/` | Audio format/recording, transcriber, provider, and Whisper model tests. |
| `Tests/ShhAppTests/` | App-container, SwiftUI behavior, lifecycle, File Provider, restoration, and feature integration tests. |
| `Tests/verify-*.sh` | CI checks for App Group entitlements, compiled/source icons, and Bonjour Info.plist declarations. |
| `fixtures/docker-sshd/` | Optional Alpine OpenSSH server for manual interoperability checks. |
| `.github/workflows/ci.yml` | Documentation-only classification, package tests, generated-project builds, icon/App Group checks, and simulator matrix. |
| `.github/workflows/codeql.yml` | Manual-build Swift CodeQL analysis on macOS runners. |
| `docs/` | Architecture, product behavior, security model, and roadmap references. |

## Architecture and dependency seams

Keep dependencies flowing through the existing seams rather than moving UI or
platform code into the core package.

### ShhCore

`ShhCore` is the platform-neutral model and policy layer. Important seams are:

- `Domain.swift` for hosts, endpoints, groups, tags, identity descriptors,
  trust settings, and terminal preferences.
- `Services.swift` for transport, trust, command execution, and credential
  store protocols plus typed transport errors.
- `EncryptedSync.swift` for `.shhbackup` envelopes, vault payloads, restore
  modes, and sync records.
- `SFTP.swift`, `Tmux.swift`, `Herdr.swift`, and `Mosh.swift` for feature
  contracts and parsers.
- `ReconnectCoordinator.swift` for deterministic reconnect/backoff behavior.
- `FileProviderContracts.swift` for stable item IDs, change anchors, cache
  metadata, and eviction rules.

Use protocols and injected implementations when adding behavior. The demo
implementations in the core/app seams are intended for previews and tests, not
as a substitute for live transport behavior.

### ShhSSH

`LiveSSHTransport` is the primary direct SSH transport implemented with
SwiftNIO SSH. It owns host-key validation, authentication, PTY/shell channels,
exec channels, reconnect support, ProxyJump, and forwarding. It also resolves
Cloudflare Access tunnel targets and optional Keychain-backed headers, plus
Tailscale hostnames and host-key policy. The repository tests those resolution
seams but does not authenticate against external services in CI.

`LiveSFTPRepository` is a deliberately isolated Citadel-backed SFTP
implementation; do not make Citadel the primary terminal SSH handshake without
updating the architecture and security documentation.

Bonjour discovery uses the `_ssh._tcp` service type. Mosh bootstraps through
SSH and then uses UDP roaming recovery. Full Mosh State Synchronization
Protocol encryption and speculative echo are still future work, so do not
describe the current Mosh implementation as complete SSP.

### ShhTerminal and ShhVoice

`ShhTerminalController` and `ShhTerminalView` adapt SwiftTerm to UIKit and
SwiftUI. Preserve the existing input guarantees, including bracketed paste,
sticky modifier consumption, Ctrl+Space NUL encoding, and debounced resize.
`ShhVoice` keeps transcription local through Apple Speech or WhisperKit. Audio
recordings are temporary and are deleted after transcription; voice UI must
continue to show an editable preview and must never auto-execute a transcript.

### App and File Provider

`AppContainer` is the `@MainActor` application coordinator. It wires the live
transport, credential/trust stores, terminal, SFTP, forwarding, Mosh, Herdr,
voice, session restoration, background-task, and File Provider helpers into
SwiftUI. Keep long-running or network work behind the existing async
protocols, and keep view-specific state in views rather than duplicating
connection state.

`FileProviderExtension` runs out of process and reads atomically synchronized
catalog and trusted-host snapshots from the App Group. File operations open
sessions on demand and tear them down per operation. Mosh-only hosts are not
supported by the File Provider path.

## Behavioral and security contracts

These are implementation constraints, not optional UI details. Consult
[`docs/SECURITY.md`](docs/SECURITY.md) for the complete threat model.

- **Credential isolation:** host records contain endpoint metadata and opaque
  identity references, not password or private-key bytes. Resolve an exact
  identity descriptor by UUID. Do not query credentials before host-key
  approval, silently fall back to another identity, or log secrets.
- **Keychain behavior:** physical-device queries are scoped to
  `group.com.ervinpopescu.shh`. Simulator fallback exists for unsigned local
  runs and must not weaken device entitlements. Preserve reference-counted
  cleanup when identity descriptors share a secret.
- **TOFU ordering:** direct, ProxyJump, and exec connections validate the host
  key before sending credentials. Unknown keys require an explicit decision;
  changed keys are rejected unless the documented trust flow is followed.
  Temporary approvals must not become persistent trust records.
- **Command safety:** remote commands, snippets, Herdr commands, and voice
  transcripts are untrusted. `CommandPolicy` tokenizes quoted input, blocks
  unconditional destructive commands, and requires approval for review-needed
  syntax. Approval cannot override a hard block.
- **Vault backups:** `.shhbackup` uses AES-256-GCM with PBKDF2-HMAC-SHA256 and
  600,000 rounds. Preserve authenticated envelope metadata, secret scanning,
  wrong-passphrase/tamper failures, explicit replace versus merge behavior,
  security-scoped staging, and deterministic passphrase/buffer cleanup. Never
  put Keychain secret bytes in a backup.
- **Filesystem safety:** normalize remote paths and retain traversal defenses;
  preserve bounded File Provider cache and LRU eviction behavior. Temporary
  audio and staged backup files must be protected and removed promptly.
- **Lifecycle:** use finite UIKit background tasks rather than silent audio or
  background-audio tricks. Foreground return probes the existing transport and
  restores or reconnects deterministically when the socket did not survive.
- **Privacy and entitlements:** keep `Resources/PrivacyInfo.xcprivacy`, local
  network declarations, microphone/speech descriptions, and App Group/keychain
  entitlements synchronized with behavior. Run the relevant `Tests/verify-*.sh`
  script when changing these surfaces.

## Configuration and generated artifacts

The source of truth is `project.yml`, not `Shh.xcodeproj`. After changing the
specification or source membership, run `just generate` and inspect the
resulting build locally, but do not add the generated project to Git. The
package dependency versions are exact in `Package.swift`; update dependencies
through the package manifest and normal SwiftPM resolution rather than editing
build products or generated metadata.

Important identifiers and declarations include:

- App bundle: `com.ervinpopescu.shh`
- File Provider bundle: `com.ervinpopescu.shh.FileProvider`
- Shared App Group: `group.com.ervinpopescu.shh`
- Bonjour service: `_ssh._tcp`
- iOS deployment target: 17.0
- App privacy manifest: `Resources/PrivacyInfo.xcprivacy`
- App entitlements: `App/Shh.entitlements`
- Extension entitlements: `FileProviderExtension/ShhFileProvider.entitlements`

The app's local settings use `UserDefaults`; credential and private-key data
use Keychain abstractions. Environment variables documented in the lifecycle
section affect local recipes only. Do not add environment-specific hostnames,
UDIDs, signing material, or secrets to source.

## Development workflow and conventions

1. Identify the layer and existing protocol seam before editing.
2. Add or update the nearest focused unit/integration test in the matching
   `Tests/<Target>Tests` directory. Name tests after the behavior or source
   seam they protect.
3. For UI behavior, prefer existing accessibility identifiers and app tests;
   use `just test-focused` before the full simulator matrix when iterating.
4. Run `just format-check`, `just lint`, and the narrowest relevant tests. Run
   `just check` before handoff when dependencies and host tooling are available.
5. Run `just generate` and a build after changing `project.yml`, entitlements,
   Info.plist values, package membership, or extension wiring.
6. Review `git diff --check`, `git diff`, and `git status --short` before
   reporting. Do not include `build/`, `.build/`, `DerivedData/`, `tmp/e2e/`,
   screenshots, logs, xcresult bundles, or secrets.

Follow the existing Swift formatting and concurrency style. `@MainActor`, actor
isolation, `Sendable`, and injected async protocols are intentional. Avoid
force-unwrapping untrusted network or user input. Preserve typed errors and
privacy-preserving error messages. Do not make broad dependency, architecture,
or product changes as part of a focused bug fix.

For shell scripts, use Bash with `set -euo pipefail` as appropriate, quote
paths, avoid developer-specific absolute paths, and run ShellCheck. Test
scripts must not write evidence into `Tests/`; the repository's review config
explicitly forbids that.

## CI, deployment, and release boundaries

`ci.yml` runs on pushes and pull requests targeting `main`. It can classify
root/docs Markdown-only changes for lightweight UTF-8, conflict-marker, and
whitespace checks. Other changes run package tests, XcodeGen generation,
unsigned generic app and extension builds, icon/App Group validation, and
separate iPhone/iPad simulator test jobs. CodeQL runs a manual Swift build on
pushes, pull requests, and a weekly schedule.

There is no TestFlight or App Store release pipeline in this repository. Local
`just deploy` is installation for a simulator or provisioned physical device,
not a distribution release. Physical device App Group/File Provider
provisioning, hardware microphone validation, full Mosh SSP, an independent
security audit, and TestFlight/App Store work remain roadmap items. Do not
claim a release is validated from simulator-only or unsigned builds.

## Troubleshooting

- **`xcodegen` or `just` missing:** install the tool listed in the setup
  section, then rerun `just doctor`.
- **Wrong Xcode selected:** set `DEVELOPER_DIR` to the desired
  `Contents/Developer` directory and confirm with `xcodebuild -version`.
- **No simulator found:** install an iOS 17+ runtime, create or boot an
  available iPhone/iPad simulator, or pass an explicit available `udid`.
  `just doctor` reports whether a target is a simulator or a physical device.
- **Signing failures:** simulator builds use the recipe defaults. Physical
  devices require automatic development signing, a matching
  `DEVELOPMENT_TEAM`, provisioning, and the correct device UDID. Do not work
  around this by weakening entitlements in source.
- **Stale generated project/build:** run `just generate` and, if safe, `just
  clean`; avoid deleting unrelated user data or all simulator state.
- **App Group/File Provider failures:** inspect both entitlement files and run
  `Tests/verify-app-group.sh` against the generated project. The extension and
  app must use `group.com.ervinpopescu.shh`; test bundles must not carry that
  entitlement.
- **Bonjour permission failures:** verify `App/Info.plist` and the generated
  app contain exactly `_ssh._tcp` and the local-network usage description, then
  run `Tests/verify-local-network-info-plist.sh`.
- **Icon validation failures:** run `Tests/verify-app-icon.sh` without an
  argument for the source catalog, or pass the built `.app` for source plus
  compiled metadata validation.
- **Host tests pass but live behavior fails:** distinguish in-process
  `SSHTestServer` coverage from simulator/device interoperability, then inspect
  the typed transport error and host-key decision path. Do not bypass TOFU or
  credential isolation to make a test pass.
- **Voice/model tests fail on constrained hardware:** inspect the model tier
  and `WhisperModelManager` resource checks. Keep transcription local and avoid
  adding network-backed fallback behavior without an explicit product decision.

## Documentation maintenance

Keep this guide focused on agent workflows and repository contracts. Put
end-user behavior and detailed design in the linked docs rather than copying
those documents here. When a command, target, path, entitlement, security
invariant, or roadmap status changes, update this guide and the relevant
canonical document in the same change. Keep links relative and verify changed
Markdown with UTF-8, conflict-marker, and whitespace checks.
