# Shh

Shh is a native SwiftUI iPhone/iPad SSH client foundation targeting iOS/iPadOS 17+.

## Offline demo

The app uses an in-memory catalog and demo SSH transport by default. It can review adaptive navigation, host editing, foreground sessions, terminal output, snippets, multiplexer selection, Files unavailable state, monitoring, settings, and explicit command/voice safety workflows without credentials.

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

No live SSH dependency is included until an iOS-compatible backend has passed host-key, PTY, authentication, cancellation, resize, and licensing review. See `docs/PRODUCT.md`, `docs/ARCHITECTURE.md`, `docs/SECURITY.md`, and `docs/ROADMAP.md`.
