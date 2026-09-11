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
        XCTAssertTrue(policy.canSend("printf hello", approved: false))
    }

    func testANSIParserMaintainsGridAndScrollback() {
        var grid = TerminalGrid(size: TerminalSize(columns: 5, rows: 2), scrollbackLimit: 2)
        var parser = ANSIParser()
        parser.consume(Data("hello\nworld".utf8), into: &grid)
        XCTAssertEqual(grid.rows[1].map(\.character), Array("world"))
        XCTAssertEqual(grid.scrollback.first?.map(\.character), Array("hello"))
    }

    func testRemotePathNormalizesTraversal() {
        XCTAssertEqual(RemotePath("/var/log/../tmp/./app").description, "/var/tmp/app")
    }

    func testStoreRoundTripContainsNoSecretBytes() async throws {
        let store = InMemoryCatalog(seedDemoData: false)
        let identity = try IdentityDescriptor(name: "Demo key", kind: .privateKey, publicFingerprint: "SHA256:test", keychainReference: "kc-demo")
        await store.save(identity)
        let host = try Host(name: "Demo", hostname: "demo.invalid", username: "dev", identityID: identity.id)
        await store.save(host)
        let loaded = try await store.listHosts()
        XCTAssertEqual(loaded.first?.identityID, identity.id)
        XCTAssertFalse(String(describing: loaded).contains("private key material"))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.metadata.schemaVersion, StoreMetadata.currentSchemaVersion)
        XCTAssertEqual(snapshot.identities.first?.keychainReference, "kc-demo")
    }
}
