# Security model

- Host rows persist endpoint metadata only. Passwords, passphrases, and private-key bytes are never fields of `Host`; identities carry opaque Keychain references.
- Production Keychain storage is an explicit port. The package fallback returns `unsupported` instead of pretending to protect secrets.
- Host-key challenges include canonical hostname, port, algorithm, and SHA-256 fingerprint. A changed fingerprint is a rejection path; trust is never inferred from authentication success.
- Commands, snippets, macros, multiplexer actions, Herdr templates, and speech text are untrusted. The command policy classifies destructive text and the UI requires a visible approval before sending.
- Speech has no automatic send path. A local transcriber returns editable preview text, and only an explicit Send action may call `SSHConnection.send`.
- Redaction is available for debug output. Do not log credential bytes, transcripts, URLs containing secrets, or terminal snapshots.

The demo transport uses a fixed non-secret fingerprint and must not be used as evidence of production host-key behavior. Before release, implement Security.framework Keychain operations, biometric policy hooks, changed-key UI, microphone lifecycle, and redaction tests on Apple platforms.
