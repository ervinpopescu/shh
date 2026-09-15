import XCTest
@testable import ShhSSH
@testable import ShhCore

final class CloudflareTailscaleTransportTests: XCTestCase {

    func testResolveStandardSSHTarget() async throws {
        let host = try Host(
            name: "Standard Host",
            hostname: "standard.example.com",
            port: 2200,
            username: "sshuser",
            connection: .ssh(SSHOptions(strictHostKeyChecking: .trustedOnly))
        )

        let resolved = try await LiveSSHTransport.resolveTransportTarget(for: host)

        XCTAssertEqual(resolved.hostname, "standard.example.com")
        XCTAssertEqual(resolved.port, 2200)
        XCTAssertEqual(resolved.username, "sshuser")
        XCTAssertEqual(resolved.options.strictHostKeyChecking, .trustedOnly)
        XCTAssertNil(resolved.cloudflareHeaders)
        XCTAssertNil(resolved.cloudflareCredentials)
        XCTAssertNil(resolved.tailscaleOptions)
    }

    func testResolveTailscaleEndpointDefaultPortAndRelaxedHostKey() async throws {
        let tsOptions = TailscaleOptions(
            tailscaleHostname: "my-macbook.tailnet-123.ts.net",
            checkHostKey: false
        )
        let host = try Host(
            name: "Tailscale Machine",
            hostname: "placeholder-ip",
            port: 22,
            username: "ervin",
            connection: .tailscale(tsOptions)
        )

        let resolved = try await LiveSSHTransport.resolveTransportTarget(for: host)

        XCTAssertEqual(resolved.hostname, "my-macbook.tailnet-123.ts.net")
        XCTAssertEqual(resolved.port, 22)
        XCTAssertEqual(resolved.username, "ervin")
        XCTAssertEqual(resolved.options.strictHostKeyChecking, .prompt)
        XCTAssertEqual(resolved.tailscaleOptions?.tailscaleHostname, "my-macbook.tailnet-123.ts.net")
        XCTAssertFalse(resolved.tailscaleOptions?.checkHostKey ?? true)
    }

    func testResolveTailscaleEndpointCustomPortAndStrictHostKey() async throws {
        let tsOptions = TailscaleOptions(
            tailscaleHostname: "nas.tailnet.ts.net",
            checkHostKey: true
        )
        let host = try Host(
            name: "Tailscale NAS",
            hostname: "nas.internal",
            port: 8022,
            username: "admin",
            connection: .tailscale(tsOptions)
        )

        let resolved = try await LiveSSHTransport.resolveTransportTarget(for: host)

        XCTAssertEqual(resolved.hostname, "nas.tailnet.ts.net")
        XCTAssertEqual(resolved.port, 8022)
        XCTAssertEqual(resolved.username, "admin")
        XCTAssertEqual(resolved.options.strictHostKeyChecking, .trustedOnly)
        XCTAssertTrue(resolved.tailscaleOptions?.checkHostKey ?? false)
    }

    func testResolveCloudflareAccessWithTunnelDomainAndCredentials() async throws {
        let credStore = InMemoryCredentialStore()
        let secretRef = "cf-token-secret-123"
        let secretValue = "secret-token-abcdef123456"
        try await credStore.save(Data(secretValue.utf8), reference: secretRef)

        let cfOptions = CloudflareAccessOptions(
            clientID: "test-client-id.access",
            clientSecretKeychainRef: secretRef,
            tunnelDomain: "tunnel.mycompany.com"
        )
        let host = try Host(
            name: "Cloudflare Server",
            hostname: "internal-host-name",
            port: 22,
            username: "cfuser",
            connection: .cloudflareAccess(cfOptions)
        )

        let resolved = try await LiveSSHTransport.resolveTransportTarget(
            for: host,
            credentialStore: credStore
        )

        XCTAssertEqual(resolved.hostname, "tunnel.mycompany.com")
        XCTAssertEqual(resolved.port, 22)
        XCTAssertEqual(resolved.username, "cfuser")
        XCTAssertEqual(resolved.cloudflareHeaders?["CF-Access-Client-Id"], "test-client-id.access")
        XCTAssertEqual(resolved.cloudflareHeaders?["CF-Access-Client-Secret"], secretValue)
        XCTAssertEqual(resolved.cloudflareCredentials?.clientID, "test-client-id.access")
        XCTAssertEqual(resolved.cloudflareCredentials?.clientSecret, secretValue)
        XCTAssertEqual(resolved.cloudflareOptions?.tunnelDomain, "tunnel.mycompany.com")
    }

    func testResolveCloudflareAccessFallbackToHostnameWhenTunnelDomainEmpty() async throws {
        let cfOptions = CloudflareAccessOptions(
            clientID: "client-id-only.access",
            clientSecretKeychainRef: "",
            tunnelDomain: ""
        )
        let host = try Host(
            name: "Cloudflare Fallback Server",
            hostname: "direct-tunnel.example.com",
            port: 2222,
            username: "dev",
            connection: .cloudflareAccess(cfOptions)
        )

        let resolved = try await LiveSSHTransport.resolveTransportTarget(for: host)

        XCTAssertEqual(resolved.hostname, "direct-tunnel.example.com")
        XCTAssertEqual(resolved.port, 2222)
        XCTAssertEqual(resolved.username, "dev")
        XCTAssertEqual(resolved.cloudflareHeaders?["CF-Access-Client-Id"], "client-id-only.access")
        XCTAssertNil(resolved.cloudflareHeaders?["CF-Access-Client-Secret"])
        XCTAssertNil(resolved.cloudflareCredentials?.clientSecret)
    }
}
