import ShhCore
import XCTest

@testable import Shh

private actor CommandRecorder {
    private var commands: [String] = []

    func append(_ command: String) {
        commands.append(command)
    }

    func contains(_ command: String) -> Bool {
        commands.contains(command)
    }
}

@MainActor
final class HerdrDefaultAppTests: XCTestCase {
    func testFirstRuntimeRestoresPersistedHerdrContextOnlyOnce() async throws {
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { host in
            host.hostname == "alpha-herdr.test" ? connectionA : connectionB
        }
        let hostA = try Host(
            name: "Restored Herdr Host", hostname: "alpha-herdr.test", username: "user")
        let hostB = try Host(
            name: "Independent Herdr Host", hostname: "beta-herdr.test", username: "user")
        let store = InMemorySessionRestorationStore(
            initial: SessionRestorationMetadata(
                hostID: hostA.id, herdrSessionName: "restored-context"))
        let catalog = InMemoryCatalog(
            snapshot: CatalogSnapshot(hosts: [hostA, hostB], identities: []))
        let container = AppContainer(
            catalog: catalog,
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter))

        await container.connect(to: hostA)
        let sessionAID = try XCTUnwrap(container.selectedSessionID)
        XCTAssertEqual(container.runtime(for: sessionAID)?.herdr.sessionName, "restored-context")

        await container.connect(to: hostB)
        let sessionBID = try XCTUnwrap(container.selectedSessionID)
        XCTAssertNil(
            container.runtime(for: sessionBID)?.herdr.sessionName,
            "A new runtime must begin in Herdr's implicit default context")
    }

    func testSecondRuntimeForSameHostStartsInImplicitHerdrContext() async throws {
        let connectionA = MockSSHConnection()
        let connectionB = MockSSHConnection()
        let connections = ConnectionSequence([connectionA, connectionB])
        let transport = ControllableTransport()
        transport.onConnect = { _ in await connections.next() }
        let host = try Host(
            name: "Shared Herdr Host", hostname: "shared-herdr.test", username: "user")
        let store = InMemorySessionRestorationStore(
            initial: SessionRestorationMetadata(hostID: host.id, herdrSessionName: "alpha"))
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter))

        await container.connect(to: host)
        let firstSessionID = try XCTUnwrap(container.selectedSessionID)
        XCTAssertEqual(container.runtime(for: firstSessionID)?.herdr.sessionName, "alpha")

        await container.connect(to: host)
        let secondSessionID = try XCTUnwrap(container.selectedSessionID)
        XCTAssertNotEqual(firstSessionID, secondSessionID)
        XCTAssertNil(
            container.runtime(for: secondSessionID)?.herdr.sessionName,
            "A second runtime for the same host must use Herdr's implicit context")
    }

    func testDefaultHerdrDescriptorUsesImplicitContext() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(
                clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(
            name: "Default Herdr Host", hostname: "default-herdr.test", username: "user")
        await container.connect(to: host)
        let commands = CommandRecorder()
        mock.onExecuteCommand = { command in
            await commands.append(command)
            if command == HerdrCommand.sessionList.renderedCommand {
                return SSHCommandResult(
                    exitCode: 0,
                    stdout:
                        #"{"id":"cli:session:list","result":{"sessions":[{"name":"default","default":true,"running":true},{"name":"review","default":false,"running":true}]}}"#
                )
            }
            if command == "herdr --version" {
                return SSHCommandResult(exitCode: 0, stdout: "herdr 0.9.5\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        _ = await container.listHerdrSessions()
        let selected = await container.selectHerdrSession(name: "default")
        let sawImplicitCommand = await commands.contains("herdr --version")
        let sawNamedDefaultCommand = await commands.contains("herdr --session 'default' --version")
        XCTAssertTrue(selected)
        XCTAssertNil(container.activeHerdrSessionName)
        XCTAssertTrue(sawImplicitCommand)
        XCTAssertFalse(sawNamedDefaultCommand)
    }
}
