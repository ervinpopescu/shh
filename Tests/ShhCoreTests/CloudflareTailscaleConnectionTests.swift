import XCTest
@testable import ShhCore

final class CloudflareTailscaleConnectionTests: XCTestCase {

    func testCloudflareAccessOptionsInitAndProperties() {
        let options = CloudflareAccessOptions(
            clientID: "abc-123.access",
            clientSecretKeychainRef: "keychain-ref-cf-1",
            tunnelDomain: "ssh.company.internal"
        )

        XCTAssertEqual(options.clientID, "abc-123.access")
        XCTAssertEqual(options.clientSecretKeychainRef, "keychain-ref-cf-1")
        XCTAssertEqual(options.tunnelDomain, "ssh.company.internal")
        XCTAssertEqual(options, CloudflareAccessOptions(
            clientID: "abc-123.access",
            clientSecretKeychainRef: "keychain-ref-cf-1",
            tunnelDomain: "ssh.company.internal"
        ))
    }

    func testTailscaleOptionsInitAndProperties() {
        let defaultOptions = TailscaleOptions(tailscaleHostname: "webserver.tailscale.net")
        XCTAssertEqual(defaultOptions.tailscaleHostname, "webserver.tailscale.net")
        XCTAssertFalse(defaultOptions.checkHostKey)

        let strictOptions = TailscaleOptions(
            tailscaleHostname: "db.magicdns.net",
            checkHostKey: true
        )
        XCTAssertEqual(strictOptions.tailscaleHostname, "db.magicdns.net")
        XCTAssertTrue(strictOptions.checkHostKey)
    }

    func testHostWithCloudflareAccessCodableRoundTrip() throws {
        let cfOpts = CloudflareAccessOptions(
            clientID: "token-client-id.access",
            clientSecretKeychainRef: "ref-secret-cf-99",
            tunnelDomain: "bastion.corp.net"
        )
        let host = try Host(
            name: "Cloudflare Bastion",
            hostname: "bastion.corp.net",
            port: 22,
            username: "accessuser",
            connection: .cloudflareAccess(cfOpts)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(host)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Host.self, from: data)

        XCTAssertEqual(decoded.id, host.id)
        XCTAssertEqual(decoded.name, "Cloudflare Bastion")
        XCTAssertEqual(decoded.hostname, "bastion.corp.net")
        XCTAssertEqual(decoded.username, "accessuser")
        if case .cloudflareAccess(let decodedCFOpts) = decoded.connection {
            XCTAssertEqual(decodedCFOpts.clientID, "token-client-id.access")
            XCTAssertEqual(decodedCFOpts.clientSecretKeychainRef, "ref-secret-cf-99")
            XCTAssertEqual(decodedCFOpts.tunnelDomain, "bastion.corp.net")
        } else {
            XCTFail("Expected .cloudflareAccess connection profile, got \(decoded.connection)")
        }
    }

    func testHostWithTailscaleCodableRoundTrip() throws {
        let tsOpts = TailscaleOptions(
            tailscaleHostname: "my-node.tail0123.ts.net",
            checkHostKey: true
        )
        let host = try Host(
            name: "Tailscale Server",
            hostname: "my-node.tail0123.ts.net",
            port: 2222,
            username: "tsuser",
            connection: .tailscale(tsOpts)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(host)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Host.self, from: data)

        XCTAssertEqual(decoded.id, host.id)
        XCTAssertEqual(decoded.name, "Tailscale Server")
        XCTAssertEqual(decoded.hostname, "my-node.tail0123.ts.net")
        XCTAssertEqual(decoded.port, 2222)
        XCTAssertEqual(decoded.username, "tsuser")
        if case .tailscale(let decodedTSOpts) = decoded.connection {
            XCTAssertEqual(decodedTSOpts.tailscaleHostname, "my-node.tail0123.ts.net")
            XCTAssertTrue(decodedTSOpts.checkHostKey)
        } else {
            XCTFail("Expected .tailscale connection profile, got \(decoded.connection)")
        }
    }

    func testBackwardCompatibilityWithLegacyHostWithoutConnectionField() throws {
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Server",
            "hostname": "192.168.1.50",
            "port": 22,
            "username": "admin",
            "tagIDs": [],
            "health": "healthy",
            "voicePolicy": {"isEnabled": false, "allowedModes": []},
            "forwardingRules": []
        }
        """

        let decoded = try JSONDecoder().decode(Host.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.name, "Legacy Server")
        if case .ssh(let opts) = decoded.connection {
            XCTAssertEqual(opts.strictHostKeyChecking, .prompt)
        } else {
            XCTFail("Expected default .ssh connection profile for legacy payload without connection field")
        }
    }

    func testBackwardCompatibilityWithLegacyStandardStringConnectionField() throws {
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Standard String Host",
            "hostname": "legacy.standard.net",
            "port": 22,
            "username": "root",
            "connection": "standard",
            "tagIDs": [],
            "health": "healthy",
            "voicePolicy": {"isEnabled": false, "allowedModes": []},
            "forwardingRules": []
        }
        """

        let decoded = try JSONDecoder().decode(Host.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.name, "Legacy Standard String Host")
        if case .ssh = decoded.connection {
            // Expected
        } else {
            XCTFail("Expected .ssh profile for legacy 'standard' string connection")
        }
    }

    func testBackwardCompatibilityWithLegacyStandardObjectConnectionField() throws {
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Standard Object Host",
            "hostname": "standard.object.net",
            "port": 22,
            "username": "ubuntu",
            "connection": {
                "standard": {
                    "strictHostKeyChecking": "trustedOnly",
                    "connectTimeoutSeconds": 10
                }
            },
            "tagIDs": [],
            "health": "unknown",
            "voicePolicy": {"isEnabled": false, "allowedModes": []},
            "forwardingRules": []
        }
        """

        let decoded = try JSONDecoder().decode(Host.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.name, "Legacy Standard Object Host")
        if case .ssh(let opts) = decoded.connection {
            XCTAssertEqual(opts.strictHostKeyChecking, .trustedOnly)
            XCTAssertEqual(opts.connectTimeoutSeconds, 10)
        } else {
            XCTFail("Expected .ssh profile with options for legacy standard object connection")
        }
    }

    func testBackwardCompatibilityWithLegacyProxyJumpAndMosh() throws {
        let jumpHostID = UUID()
        let proxyJumpJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Bastion Target",
            "hostname": "internal.lan",
            "port": 22,
            "username": "deploy",
            "connection": {
                "proxyJump": {
                    "hopHostIDs": ["\(jumpHostID.uuidString)"],
                    "sshOptions": {"strictHostKeyChecking": "prompt"}
                }
            },
            "tagIDs": [],
            "health": "unknown",
            "voicePolicy": {"isEnabled": false, "allowedModes": []},
            "forwardingRules": []
        }
        """

        let decodedJump = try JSONDecoder().decode(Host.self, from: Data(proxyJumpJSON.utf8))
        if case .proxyJump(let jumpOpts) = decodedJump.connection {
            XCTAssertEqual(jumpOpts.hopHostIDs, [jumpHostID])
        } else {
            XCTFail("Expected .proxyJump connection")
        }

        let moshJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy Mosh Target",
            "hostname": "mosh.lan",
            "port": 22,
            "username": "dev",
            "connection": {
                "mosh": {
                    "serverCommand": "mosh-server",
                    "predictionMode": "adaptive",
                    "sshOptions": {"strictHostKeyChecking": "prompt"}
                }
            },
            "tagIDs": [],
            "health": "unknown",
            "voicePolicy": {"isEnabled": false, "allowedModes": []},
            "forwardingRules": []
        }
        """

        let decodedMosh = try JSONDecoder().decode(Host.self, from: Data(moshJSON.utf8))
        if case .mosh(let moshOpts) = decodedMosh.connection {
            XCTAssertEqual(moshOpts.serverCommand, "mosh-server")
            XCTAssertEqual(moshOpts.predictionMode, .adaptive)
        } else {
            XCTFail("Expected .mosh connection")
        }
    }

    func testHostConnectionTypeAliasAndStandardFactory() {
        let conn: HostConnectionType = .standard(SSHOptions(strictHostKeyChecking: .trustedOnly))
        if case .ssh(let opts) = conn {
            XCTAssertEqual(opts.strictHostKeyChecking, .trustedOnly)
        } else {
            XCTFail("Expected .standard() to produce .ssh")
        }
    }
}
