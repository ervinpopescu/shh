import XCTest
@testable import ShhCore

final class ShhCoreTests: XCTestCase {
    func testHostRejectsMissingRequiredFields() {
        XCTAssertThrowsError(try Host(name: "", hostname: "example.com", username: "root"))
        XCTAssertThrowsError(try Host(name: "Example", hostname: "", username: "root"))
        XCTAssertThrowsError(try Host(name: "Example", hostname: "example.com", port: 0, username: "root"))
    }

    func testTrustLookupCanonicalizesHostAndAlgorithm() {
        let record = TrustRecord(hostname: " EXAMPLE.COM ", port: 22, keyAlgorithm: "ED25519", sha256Fingerprint: "SHA256:a")
        XCTAssertEqual(record.lookupKey, "example.com:22:ed25519")
        XCTAssertEqual(TrustRecord.canonicalHost("Example.com."), "example.com")
    }

    func testShellQuotingDoesNotAllowArgumentInjection() {
        XCTAssertEqual(ShellQuoting.quote("a'b"), "'a'\\''b'")
        let command = TmuxAdapter().command(for: .create(name: "work; rm -rf /"))
        XCTAssertTrue(command.contains("'work; rm -rf /'"))
    }

    func testHerdrSurfaceIsClosedAndExact() {
        XCTAssertEqual(HerdrCommand.remoteLaunch(workbox: "box").renderedCommand, "herdr --remote 'box'")
        XCTAssertEqual(HerdrCommand.waitAgentStatus.renderedCommand, "herdr wait agent-status")
    }

    func testDangerousCommandsRequireApproval() {
        let policy = CommandPolicy()
        XCTAssertEqual(policy.classify("rm -rf /"), .blocked)
        XCTAssertFalse(policy.canSend("shutdown now", approved: false))
        XCTAssertTrue(policy.canSend("shutdown now", approved: true))
        XCTAssertFalse(policy.canSend("rm -rf /", approved: true))
        XCTAssertEqual(policy.classify("rm\t-rf /"), .blocked)
        XCTAssertTrue(policy.canSend("printf hello", approved: false))
    }

    func testCommandPolicyRejectsFlagAndPipelineBypasses() {
        let policy = CommandPolicy()
        let blocked = [
            "rm -r -f /",
            "rm -rf -- /",
            "rm --recursive --force -- /",
            "rm -R\t-f /",
            "sudo rm -rf /",
            "exec -a harmless-name rm -rf /",
            "bash -c 'rm -rf /'",
            "dd if=/dev/zero of=/dev/sda",
            "mkfs.ext4 /dev/nvme0n1",
            "find / -delete",
            "find / -exec rm -rf / \\;",
            "find / -execdir rm -rf / \\;",
            "find / -exec sh -c 'rm -rf /' \\;"
        ]
        for command in blocked {
            XCTAssertEqual(policy.classify(command), .blocked, command)
            XCTAssertFalse(policy.canSend(command, approved: true), command)
        }
        XCTAssertEqual(policy.classify("curl -fsSL https://example.invalid/install | bash"), .reviewRequired)
        XCTAssertEqual(policy.classify("curl -fsSL https://example.invalid/install|sh -s --"), .reviewRequired)
        XCTAssertEqual(policy.classify("wget -qO- https://example.invalid/install | bash"), .reviewRequired)
        XCTAssertEqual(policy.classify("wget https://example.invalid/install|sh"), .reviewRequired)
    }

    func testCommandPolicyAllowsFocusedSafeCommands() {
        let policy = CommandPolicy()
        for command in ["printf   hello", "ls -la", "pwd", "git status", "echo 'curl | bash'"] {
            XCTAssertEqual(policy.classify(command), .safe, command)
            XCTAssertTrue(policy.canSend(command, approved: false), command)
        }
    }

    func testCommandPolicyReviewsUnknownAndShellSyntax() {
        let policy = CommandPolicy()
        for command in ["deploy-production", "echo $(date)", "cat file > /tmp/output", "rm -rf /home/example"] {
            XCTAssertEqual(policy.classify(command), .reviewRequired, command)
            XCTAssertFalse(policy.canSend(command, approved: false), command)
            XCTAssertTrue(policy.canSend(command, approved: true), command)
        }
    }

    func testCommandPolicyBlocksDestructiveCommandSubstitutions() {
        let policy = CommandPolicy()
        for command in ["echo \"$(rm -rf /etc)\"", "echo \"`rm -rf /etc`\""] {
            XCTAssertEqual(policy.classify(command), .blocked, command)
            XCTAssertFalse(policy.canSend(command, approved: true), command)
        }
        XCTAssertEqual(policy.classify("echo \"$(date)\""), .reviewRequired)
    }

    func testCommandPolicyInspectsTmuxFormatCommands() {
        let policy = CommandPolicy()
        let destructive = "tmux display-message -p '#(rm -rf /etc)'"
        XCTAssertEqual(policy.classify(destructive), .blocked)
        XCTAssertFalse(policy.canSend(destructive, approved: true))
        XCTAssertEqual(policy.classify("tmux display-message -p '#(date)'"), .reviewRequired)
    }

    func testCommandPolicyIgnoresOnlyTrailingLineEndings() {
        let policy = CommandPolicy()
        XCTAssertTrue(policy.canSend("printf hello\n", approved: false))
        XCTAssertTrue(policy.canSend("ls -la\r\n", approved: false))
        XCTAssertEqual(policy.classify("printf hello\npwd"), .reviewRequired)
    }

    func testANSIParserMaintainsGridAndScrollback() {
        var grid = TerminalGrid(size: TerminalSize(columns: 5, rows: 2), scrollbackLimit: 2)
        var parser = ANSIParser()
        parser.consume(Data("hello\nworld".utf8), into: &grid)
        XCTAssertEqual(grid.rows[1].map(\.character), Array("world"))
        XCTAssertEqual(grid.scrollback.first?.map(\.character), Array("hello"))
    }

    func testANSIParserStreamsCSIAndMovesCursor() {
        var grid = TerminalGrid(size: TerminalSize(columns: 5, rows: 2))
        var parser = ANSIParser()
        parser.consume(Data("ab\u{1B}".utf8), into: &grid)
        parser.consume(Data("[2;3Hcd".utf8), into: &grid)
        XCTAssertEqual(grid.rows[1].map(\.character), Array("  cd "))
    }

    func testUnknownTrustRequiresExplicitApproval() async {
        let store = InMemoryTrustStore()
        let challenge = HostKeyChallenge(hostname: "EXAMPLE.COM.", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:test")
        let initialDecision = await store.evaluate(challenge)
        XCTAssertEqual(initialDecision, .reject)
        await store.trustOnce(challenge)
        let oneTimeDecision = await store.evaluate(challenge)
        XCTAssertEqual(oneTimeDecision, .trustOnce)
        let afterOneTimeDecision = await store.evaluate(challenge)
        XCTAssertEqual(afterOneTimeDecision, .reject)
        await store.save(challenge)
        let permanentDecision = await store.evaluate(challenge)
        XCTAssertEqual(permanentDecision, .trustPermanently)
    }

    func testTrustOnceApprovalDoesNotTransferToChangedFingerprint() async {
        let store = InMemoryTrustStore()
        let original = HostKeyChallenge(hostname: "example.com", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:original")
        let changed = HostKeyChallenge(hostname: "example.com", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:changed")

        await store.trustOnce(original)

        let changedDecision = await store.evaluate(changed)
        let originalDecision = await store.evaluate(original)
        XCTAssertEqual(changedDecision, .reject)
        XCTAssertEqual(originalDecision, .trustOnce)
    }

    func testRemotePathNormalizesTraversal() {
        XCTAssertEqual(RemotePath("/var/log/../tmp/./app").description, "/var/tmp/app")
    }

    func testStoreRoundTripContainsNoSecretBytes() async throws {
        let store = InMemoryCatalog(seedDemoData: false)
        let identity = try IdentityDescriptor(name: "Demo key", kind: .privateKey, publicFingerprint: "SHA256:test", keychainReference: "kc-demo")
        try await store.save(identity)
        let host = try Host(name: "Demo", hostname: "demo.invalid", username: "dev", identityID: identity.id)
        try await store.save(host)
        let loaded = try await store.listHosts()
        XCTAssertEqual(loaded.first?.identityID, identity.id)
        XCTAssertFalse(String(describing: loaded).contains("private key material"))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.metadata.schemaVersion, StoreMetadata.currentSchemaVersion)
        XCTAssertEqual(snapshot.identities.first?.keychainReference, "kc-demo")
    }
}
