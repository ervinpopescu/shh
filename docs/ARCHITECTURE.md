# Architecture

`App/` contains SwiftUI scenes and the `@MainActor` app container. `ShhCore` is a Foundation-only Swift package containing domain records, policy, terminal primitives, and ports. The app depends on protocols (`SSHTransport`, `CredentialStore`, `RemoteFileRepository`, `LocalTranscriber`) rather than framework or package-specific types.

`InMemoryCatalog`, `DemoSSHTransport`, `InMemoryTrustStore`, and `Unavailable*` adapters are deterministic implementations for previews, simulator review, and host package tests. They are not claims of production SSH or SFTP support.

Run `xcodegen generate` on macOS to create the iOS project from `project.yml`. Run `swift package dump-package` and `swift test` where Swift is installed. The package declares macOS 13 only as a host-test platform for its Foundation-only core; the generated Xcode project remains iOS-only with no macOS app target. Apple-only Keychain, AVFoundation, and SwiftUI integrations remain at the app boundary.
