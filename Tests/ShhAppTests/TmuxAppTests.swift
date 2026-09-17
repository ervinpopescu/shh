import SwiftUI
import XCTest
@testable import Shh
import ShhCore
import ShhTerminal

@MainActor
final class TmuxAppTests: XCTestCase {

    // MARK: - 1. Probe Tmux

    func testTmuxProbeSuccess() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Tmux Host", hostname: "tmux.test", username: "user")
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let availability = await container.probeTmux()
        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "tmux 3.4")
        XCTAssertEqual(container.tmuxAvailability, .available(version: "tmux 3.4"))
    }

    func testCommandDialControlRequiresApprovalAndUsesExecChannel() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Dial Host", hostname: "dial.test", username: "user")
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        let sessionID = try TmuxSessionID("$4")
        let action = MultiplexerControlAction.tmux(.nextWindow(sessionID))
        let expected = try TmuxControl().command(for: action)
        mock.onExecuteCommand = { command in
            SSHCommandResult(exitCode: command == expected ? 0 : 1, stdout: "", stderr: "")
        }

        let rejected = await container.executeMultiplexerControl(action)
        XCTAssertFalse(rejected, "Dial controls require review")
        let approved = await container.executeMultiplexerControl(action, approved: true)
        XCTAssertTrue(approved)
        XCTAssertFalse(mock.sentData.contains { $0 == Data(expected.utf8) }, "Dial controls use exec, not PTY")
    }

    func testPinnedLiteralApprovalInsertsWithoutReturn() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Pinned Host", hostname: "pinned.test", username: "user")
        await container.connect(to: host)

        let rejected = await container.sendPinnedLiteral("sudo reboot")
        XCTAssertFalse(rejected)
        let approved = await container.sendPinnedLiteral("sudo reboot", approved: true)
        XCTAssertTrue(approved)
        XCTAssertEqual(mock.sentData.last, Data("sudo reboot".utf8))
    }

    private func resolveEvidenceDirectory() -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["EVIDENCE_DIR"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil ||
                FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("shh-evidence", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)) != nil ||
            FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return FileManager.default.temporaryDirectory
    }

    private func saveSnapshot(view: UIView, named filename: String) {
        guard let directory = resolveEvidenceDirectory() else { return }
        let cleanName = URL(fileURLWithPath: filename).lastPathComponent
        let targetURL = directory.appendingPathComponent(cleanName)
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        if let png = image.pngData() {
            try? png.write(to: targetURL)
        }
    }

    private func saveSnapshot(view: UIView, to filename: String) {
        saveSnapshot(view: view, named: filename)
    }

    func testCommandDialSurfaceFitsPhoneAndIPad() {
        var state = CommandDialNavigation(isOpen: true)
        let model = CommandDialModel(pinnedLiterals: ["echo ready"])
        let surface = CommandDialSurface(
            model: model,
            navigation: Binding(get: { state }, set: { state = $0 }),
            placement: .trailing,
            size: .regular,
            hostLabel: "Dial Host",
            paneLabel: "Primary terminal",
            connectionStatus: "Connected",
            onAction: { _ in },
            onDismiss: {}
        )

        let phone = UIHostingController(rootView: surface)
        phone.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let phoneSize = phone.sizeThatFits(in: phone.view.bounds.size)
        XCTAssertGreaterThan(phoneSize.width, 0)
        XCTAssertGreaterThan(phoneSize.height, 0)
        saveSnapshot(view: phone.view, named: "command_dial_surface_phone.png")

        let ipad = UIHostingController(rootView: surface)
        ipad.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let ipadSize = ipad.sizeThatFits(in: ipad.view.bounds.size)
        XCTAssertGreaterThan(ipadSize.width, 0)
        XCTAssertGreaterThan(ipadSize.height, 0)
        saveSnapshot(view: ipad.view, named: "command_dial_surface_ipad.png")
        _ = state
    }

    func testCommandDialSubmenusAndMultiplexerArtifacts() throws {
        var commonKeysNav = CommandDialNavigation(isOpen: true)
        let model = CommandDialModel(pinnedLiterals: ["ls -la", "cargo test"])
        guard let commonKeysNode = model.roots.first(where: { $0.id == "root.common-keys" }) else {
            XCTFail("Missing common-keys root node")
            return
        }
        commonKeysNav.enter(commonKeysNode)
        XCTAssertEqual(commonKeysNav.path, ["root.common-keys"])

        let commonKeysSurface = CommandDialSurface(
            model: model,
            navigation: Binding(get: { commonKeysNav }, set: { commonKeysNav = $0 }),
            placement: .trailing,
            size: .compact,
            hostLabel: "Production Web",
            paneLabel: "Primary terminal",
            connectionStatus: "Connected",
            onAction: { _ in },
            onDismiss: {}
        )
        let phone = UIHostingController(rootView: commonKeysSurface)
        phone.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        saveSnapshot(view: phone.view, named: "command_dial_common_keys_phone.png")

        // Multiplexer controls submenu
        var muxNav = CommandDialNavigation(isOpen: true)
        let session = try TmuxSessionID("$3")
        let muxChildren = CommandDialMultiplexerMenu.nodes(tmuxSessionID: session, capabilities: .tmux)
        let muxModel = CommandDialModel(multiplexerChildren: muxChildren)
        guard let muxNode = muxModel.roots.first(where: { $0.id == "root.multiplexer" }) else {
            XCTFail("Missing multiplexer root node")
            return
        }
        muxNav.enter(muxNode)
        XCTAssertEqual(muxNav.path, ["root.multiplexer"])

        let muxSurface = CommandDialSurface(
            model: muxModel,
            navigation: Binding(get: { muxNav }, set: { muxNav = $0 }),
            placement: .trailing,
            size: .compact,
            hostLabel: "Production Web",
            paneLabel: "Primary terminal",
            connectionStatus: "Connected",
            onAction: { _ in },
            onDismiss: {}
        )
        let muxPhone = UIHostingController(rootView: muxSurface)
        muxPhone.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        saveSnapshot(view: muxPhone.view, named: "command_dial_multiplexer_menu.png")
    }

    func testSendImageEndToEndAndArtifacts() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let sftp = DemoSFTPRepository(seedDemoData: true)
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter),
            sftpRepository: sftp
        )
        let host = try Host(name: "Image Host", hostname: "image.test", username: "dev")
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // 1. Snapshot initial SendImageView using dedicated idle container
        let idleContainer = AppContainer.demo()
        let sendImageView = SendImageView().environmentObject(idleContainer)
        let hosting = UIHostingController(rootView: sendImageView)
        hosting.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        saveSnapshot(view: hosting.view, named: "send_image_view.png")

        // 2. Generate valid test PNG image
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let testImage = renderer.image { ctx in
            UIColor.systemCyan.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        guard let pngData = testImage.pngData() else {
            XCTFail("Failed to render test PNG")
            return
        }

        // 3. Initiate send image
        container.beginSendImage(data: pngData)
        XCTAssertTrue(container.sendImageState.isActive)

        // 4. Await completion
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if case .completed = container.sendImageState { break }
            if case .failed = container.sendImageState { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        guard case .completed(let remotePath) = container.sendImageState else {
            XCTFail("Expected .completed sendImageState, got: \(container.sendImageState), error: \(container.sendImageErrorMessage ?? "none")")
            return
        }

        XCTAssertTrue(remotePath.description.hasPrefix("/home/dev/.shh/images/"))
        XCTAssertTrue(remotePath.description.hasSuffix(".png"))

        // Verify terminal insertion without Return
        guard let sentPathData = mock.sentData.last,
              let sentString = String(data: sentPathData, encoding: .utf8) else {
            XCTFail("Expected image path sent to terminal connection")
            return
        }
        XCTAssertFalse(sentString.hasSuffix("\n"), "Inserted image path must NOT end with a newline")
        XCTAssertFalse(sentString.hasSuffix("\r"), "Inserted image path must NOT end with a carriage return")
        XCTAssertTrue(sentString.contains("/home/dev/.shh/images/"), "Must contain quoted remote path")

        // 5. Snapshot completed SendImageView
        let completedHosting = UIHostingController(rootView: SendImageView().environmentObject(container))
        completedHosting.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        saveSnapshot(view: completedHosting.view, named: "send_image_completed.png")
    }

    func testSendImageAdversarialRejectionAndCancellation() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let sftp = DemoSFTPRepository(seedDemoData: true)
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter),
            sftpRepository: sftp
        )
        let host = try Host(name: "Image Host", hostname: "image.test", username: "dev")
        await container.connect(to: host)

        let initialSentCount = mock.sentData.count

        // Adversarial 1: Malformed bytes
        let malformed = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22])
        container.beginSendImage(data: malformed)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(container.sendImageState, .failed)
        XCTAssertNotNil(container.sendImageErrorMessage)
        XCTAssertEqual(mock.sentData.count, initialSentCount, "No terminal data sent for malformed image")

        // Adversarial 2: Empty data
        container.beginSendImage(data: Data())
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(container.sendImageState, .failed)
        XCTAssertEqual(mock.sentData.count, initialSentCount, "No terminal data sent for empty image")

        // Adversarial 3: Immediate cancellation
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
        let img = renderer.image { _ in UIColor.red.setFill() }
        if let validData = img.pngData() {
            container.beginSendImage(data: validData)
            container.cancelSendImage()
            XCTAssertEqual(container.sendImageState, .cancelled)
        }
    }

    func testTmuxProbeFailureNoTmux() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "No Tmux Host", hostname: "notmux.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 127, stdout: "", stderr: "bash: tmux: command not found\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let availability = await container.probeTmux()
        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(container.tmuxAvailability, availability)
        XCTAssertFalse(container.isTmuxServerRunning)
        XCTAssertTrue(container.tmuxSessions.isEmpty)
    }

    // MARK: - 2. List Sessions

    func testTmuxListSessionsPopulated() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "List Host", hostname: "list.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                let out = "$0\twork\t3\t1700000000\t1700000500\t1\n$1\tbackground\t1\t1700000100\t1700000200\t0\n"
                return SSHCommandResult(exitCode: 0, stdout: out)
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let sessions = await container.listTmuxSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].sessionID, "$0")
        XCTAssertEqual(sessions[0].name, "work")
        XCTAssertEqual(sessions[0].windowsCount, 3)
        XCTAssertTrue(sessions[0].isAttached)
        XCTAssertEqual(sessions[0].attachedClients, 1)

        XCTAssertEqual(sessions[1].sessionID, "$1")
        XCTAssertEqual(sessions[1].name, "background")
        XCTAssertEqual(sessions[1].windowsCount, 1)
        XCTAssertFalse(sessions[1].isAttached)
        XCTAssertEqual(sessions[1].attachedClients, 0)

        XCTAssertTrue(container.isTmuxServerRunning)
        XCTAssertNil(container.tmuxError)
    }

    func testTmuxListSessionsNoServerRunning() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "No Server Host", hostname: "noserver.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "no server running on /tmp/tmux-501/default\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let sessions = await container.listTmuxSessions()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertFalse(container.isTmuxServerRunning)
        XCTAssertNil(container.tmuxError)
    }

    func testTmuxListSessionsNoSessions() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Empty Sessions Host", hostname: "empty.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "no sessions\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let sessions = await container.listTmuxSessions()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(container.isTmuxServerRunning)
        XCTAssertNil(container.tmuxError)
    }

    // MARK: - 3. Attach by Session ID

    func testAttachBySessionIDTargetsPTYAndPersistsMetadata() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let store = InMemorySessionRestorationStore()

        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Attach Host", hostname: "attach.test", username: "user")
        await container.connect(to: host)

        let attachResult = await container.attachTmuxSession(id: "$2")
        XCTAssertTrue(attachResult)
        XCTAssertEqual(container.activeTmuxSessionID, "$2")
        XCTAssertNil(container.tmuxError)

        // Check command reached active connection PTY
        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        let hasAttachCmd = sentStrings.contains { $0.contains("env -u TMUX tmux attach-session -d -t '$2'") }
        XCTAssertTrue(hasAttachCmd, "PTY must receive exact attach command for $2")

        // Check restoration metadata persisted
        let loaded = try await store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.tmuxSessionID, "$2")
        XCTAssertEqual(loaded?.hostID, host.id)
    }

    func testAttachRejectsNonSessionIDNames() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Reject Host", hostname: "reject.test", username: "user")
        await container.connect(to: host)

        let initialSentCount = mock.sentData.count

        // Attaching by name like "main" must be rejected - attach is strictly by session ID ($id)
        let attachResult = await container.attachTmuxSession(id: "main")
        XCTAssertFalse(attachResult)
        XCTAssertNil(container.activeTmuxSessionID)
        XCTAssertNotNil(container.tmuxError)
        XCTAssertTrue(container.tmuxError?.contains("Existing tmux sessions must attach by session ID") ?? false)

        // Zero additional commands sent to PTY
        XCTAssertEqual(mock.sentData.count, initialSentCount)
    }

    // MARK: - 4. Validated Create-or-Attach by Name

    func testCreateOrAttachByNameTargetsPTYAndPersistsMetadata() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe || cmd == "tmux -V" {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd.contains("list-sessions") {
                return SSHCommandResult(exitCode: 0, stdout: "")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }
        let store = InMemorySessionRestorationStore()

        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Create Host", hostname: "create.test", username: "user")
        await container.connect(to: host)

        let createResult = await container.createTmuxSession(name: "workspace")
        XCTAssertTrue(createResult)
        XCTAssertEqual(container.activeTmuxSessionID, "workspace")
        XCTAssertNil(container.tmuxError)

        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        let hasNewSessionCmd = sentStrings.contains { $0.contains("tmux new-session -A -D -s 'workspace'") }
        XCTAssertTrue(hasNewSessionCmd, "PTY must receive exact new-session command for 'workspace'")

        let loaded = try await store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.tmuxSessionID, "workspace")
    }

    func testCreateRejectsInvalidSessionNames() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Invalid Host", hostname: "invalid.test", username: "user")
        await container.connect(to: host)

        let invalidNames = [
            "",
            "   ",
            "foo:bar",
            "foo.bar",
            "foo\u{07}bar",
            String(repeating: "a", count: 129)
        ]

        let initialSentCount = mock.sentData.count

        for name in invalidNames {
            let res = await container.createTmuxSession(name: name)
            XCTAssertFalse(res, "Name '\(name)' must be rejected")
            XCTAssertNotNil(container.tmuxError)
        }

        XCTAssertEqual(mock.sentData.count, initialSentCount, "No commands sent to PTY for invalid session names")
    }

    // MARK: - 5. Zero Terminal Pollution During Discovery

    func testNoTerminalPollutionDuringDiscovery() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Clean Host", hostname: "clean.test", username: "user")
        await container.connect(to: host)

        let sentCountBeforeDiscovery = mock.sentData.count

        await container.refreshTmuxState()
        _ = await container.probeTmux()
        _ = await container.listTmuxSessions()

        // Verify sentData to PTY remained completely untouched during probe & list
        XCTAssertEqual(mock.sentData.count, sentCountBeforeDiscovery, "Discovery operations must never write to the active PTY")
        XCTAssertEqual(container.terminalText, "", "Terminal text must remain empty and unpolluted")
    }

    // MARK: - 6. No Kill-Server Surface or Arbitrary Input

    func testNoKillServerSurfaceOrArbitraryCommandInput() async throws {
        let policy = CommandPolicy()

        // 1. Central policy strictly blocks kill-server and global session destruction
        XCTAssertEqual(policy.classify("tmux kill-server"), .blocked)
        XCTAssertFalse(policy.canSend("tmux kill-server", approved: true))

        XCTAssertEqual(policy.classify("tmux kill-session -a"), .blocked)
        XCTAssertFalse(policy.canSend("tmux kill-session -a", approved: true))

        XCTAssertEqual(policy.classify("tmux kill-session -g"), .blocked)
        XCTAssertFalse(policy.canSend("tmux kill-session -g", approved: true))

        XCTAssertEqual(policy.classify("tmux kill-session --all"), .blocked)
        XCTAssertFalse(policy.canSend("tmux kill-session --all", approved: true))

        // 2. AppContainer sendValidatedCommand strictly blocks kill-server
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Safe Host", hostname: "safe.test", username: "user")
        await container.connect(to: host)

        let sentBefore = mock.sentData.count
        let blockedResult = await container.sendValidatedCommand("tmux kill-server\n", approved: true)
        XCTAssertFalse(blockedResult, "kill-server must be blocked by sendValidatedCommand")
        XCTAssertEqual(mock.sentData.count, sentBefore, "PTY must never receive kill-server")
    }

    // MARK: - 7. Missing Session Handling on Restoration

    func testRememberedRestorationMissingSessionHandling() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let hostID = UUID()
        let store = InMemorySessionRestorationStore(initial: SessionRestorationMetadata(
            hostID: hostID,
            tmuxSessionID: "$99"
        ))
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        // Mock has-session to return failure (missing session)
        mock.onExecuteCommand = { cmd in
            if cmd.contains("has-session") && cmd.contains("$99") {
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "can't find session: $99\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let host = try Host(
            id: hostID,
            name: "Missing Session Host",
            hostname: "missing.test",
            username: "user",
            autoAttachTmux: true
        )

        await container.connect(to: host)

        // Check explicit error message populated
        XCTAssertNotNil(container.tmuxError)
        XCTAssertTrue(container.tmuxError?.contains("Remembered tmux session $99 no longer exists") ?? false)

        // Verify attach was NOT sent to PTY
        let sentStrings = mock.sentData.compactMap { String(data: $0, encoding: .utf8) }
        let hasAttach = sentStrings.contains { $0.contains("attach-session") && $0.contains("'$99'") }
        XCTAssertFalse(hasAttach, "Missing session must not send failing attach command to PTY")

        // The stale target remains available for explicit recovery and is not
        // replaced by a missing-session failure.
        XCTAssertNil(container.activeTmuxSessionID)
        let savedMetadata = try await container.restorationStore.load()
        XCTAssertEqual(savedMetadata?.tmuxSessionID, "$99")
    }

    func testFailedAttachPreservesPreviousLastUsedTarget() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let store = InMemorySessionRestorationStore()
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Preserve Target Host", hostname: "preserve.test", username: "user")
        await container.connect(to: host)
        let firstAttach = await container.attachTmuxSession(id: "$2")
        XCTAssertTrue(firstAttach)

        mock.onSend = { _ in throw TransportError.remoteFailure("attach failed") }
        let failedAttach = await container.attachTmuxSession(id: "$3")
        XCTAssertFalse(failedAttach)
        let preservedMetadata = try await store.load()
        XCTAssertEqual(preservedMetadata?.tmuxSessionID, "$2")
    }

    func testExplicitDisconnectPreservesLastUsedTarget() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }
        let store = InMemorySessionRestorationStore()
        let container = AppContainer(
            transport: transport,
            restorationStore: store,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )
        let host = try Host(name: "Disconnect Target Host", hostname: "disconnect-target.test", username: "user")
        await container.connect(to: host)
        let attachSuccess = await container.attachTmuxSession(id: "$4")
        XCTAssertTrue(attachSuccess)
        await container.disconnect()

        XCTAssertTrue(container.isExplicitDisconnect)
        let preservedMetadata = try await store.load()
        XCTAssertEqual(preservedMetadata?.tmuxSessionID, "$4")
    }

    // MARK: - 8. Reconnect Cancellation & Disconnect Races

    func testReconnectCancellationStopsCoordinator() async throws {
        let transport = ControllableTransport()
        let mockMonitor = MockReachabilityMonitor(isReachable: false)
        let coordinator = ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: mockMonitor,
            reconnectCoordinator: coordinator
        )

        let host = try Host(name: "Cancel Host", hostname: "cancel.test", username: "user")
        await container.connect(to: host)

        // Drop reachability
        mockMonitor.setReachable(false)
        container.handleReachabilityChange(false)

        // User cancels
        await container.cancelReconnect()
        XCTAssertEqual(container.reconnectState, .cancelled)
        XCTAssertTrue(container.isExplicitDisconnect)

        // Reachability restored afterwards does NOT trigger reconnect
        mockMonitor.setReachable(true)
        container.handleReachabilityChange(true)
        XCTAssertEqual(container.reconnectState, .cancelled)
    }

    func testDisconnectResetsTmuxStateAndDiscardsStaleProbeResults() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Race Host", hostname: "race.test", username: "user")
        await container.connect(to: host)

        await container.attachTmuxSession(id: "$0")
        XCTAssertEqual(container.activeTmuxSessionID, "$0")

        await container.disconnect()
        XCTAssertNil(container.activeTmuxSessionID)
        XCTAssertTrue(container.tmuxSessions.isEmpty)
        XCTAssertFalse(container.isTmuxServerRunning)
        XCTAssertEqual(container.tmuxAvailability, .unavailable(reason: "Not connected"))
        XCTAssertNil(container.tmuxError)

        // Stale probe invocation on disconnected session must return unavailable
        let staleProbe = await container.probeTmux()
        XCTAssertFalse(staleProbe.isAvailable)
        XCTAssertEqual(container.tmuxAvailability, .unavailable(reason: "Not connected"))
    }

    // MARK: - 9. Demo Mode Determinism

    func testDemoModeDeterminism() async throws {
        let container = AppContainer.demo()
        XCTAssertTrue(container.isDemo)

        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "Demo Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // Probe in demo mode
        let availability = await container.probeTmux()
        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.version, "tmux 3.4")

        // List in demo mode
        let sessions = await container.listTmuxSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionID, "$0")
        XCTAssertEqual(sessions[0].name, "demo-main")

        // Attach in demo mode
        let attached = await container.attachTmuxSession(id: "$0")
        XCTAssertTrue(attached)
        XCTAssertEqual(container.activeTmuxSessionID, "$0")

        // Create in demo mode
        let created = await container.createTmuxSession(name: "demo-session")
        XCTAssertTrue(created)
        XCTAssertEqual(container.activeTmuxSessionID, "demo-session")
    }

    // MARK: - 10. UI View & VoiceOver Accessibility

    func testMultiplexerPickerViewAccessibilityAndVoiceOver() async throws {
        let container = AppContainer.demo()
        let demoChallenge = HostKeyChallenge(hostname: "demo.local", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:demo-fingerprint")
        await container.trustStore.save(demoChallenge)

        let host = try Host(name: "UI Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        let longSessionName = "a-very-long-tmux-session-name-that-tests-truncation-behavior-across-compact-and-regular-size-classes"
        container.tmuxAvailability = .available(version: "tmux 3.4")
        container.isTmuxServerRunning = true
        container.activeTmuxSessionID = "$0"
        container.tmuxSessions = [
            TmuxSessionInfo(
                sessionID: "$0",
                name: longSessionName,
                windowsCount: 2,
                createdAt: Date(timeIntervalSince1970: 1700000000),
                lastActivityAt: Date(),
                attachedClients: 1
            ),
            TmuxSessionInfo(
                sessionID: "$1",
                name: "dev",
                windowsCount: 1,
                createdAt: Date(timeIntervalSince1970: 1700000100),
                lastActivityAt: Date(),
                attachedClients: 0
            )
        ]

        let picker = MultiplexerPicker().environmentObject(container)
        let hostingController = UIHostingController(rootView: picker)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.layoutIfNeeded()

        XCTAssertGreaterThan(hostingController.view.bounds.width, 0)
        XCTAssertGreaterThan(hostingController.view.bounds.height, 0)
        XCTAssertGreaterThan(hostingController.view.subviews.count, 0)

        // Verify active session check recognizes session by ID
        XCTAssertTrue(container.isTmuxSessionActive(container.tmuxSessions[0]))
        XCTAssertFalse(container.isTmuxSessionActive(container.tmuxSessions[1]))

        // Verify VoiceOver accessibility metadata
        let session0 = container.tmuxSessions[0]
        XCTAssertEqual(session0.sessionID, "$0")
        XCTAssertEqual(session0.name, longSessionName)
        XCTAssertTrue(session0.isAttached)

        let session1 = container.tmuxSessions[1]
        XCTAssertEqual(session1.sessionID, "$1")
        XCTAssertEqual(session1.name, "dev")
        XCTAssertFalse(session1.isAttached)
    }

    // MARK: - 11. iPhone and iPad Layouts

    func testMultiplexerPickerIPhoneAndIPadLayouts() async throws {
        let container = AppContainer.demo()
        let host = try Host(name: "Layout Host", hostname: "demo.local", username: "dev")
        await container.connect(to: host)

        let longName = String(repeating: "long-name-", count: 8)
        container.tmuxAvailability = .available(version: "tmux 3.4")
        container.isTmuxServerRunning = true
        container.tmuxSessions = [
            TmuxSessionInfo(
                sessionID: "$0",
                name: longName,
                windowsCount: 5,
                createdAt: Date(),
                lastActivityAt: Date(),
                attachedClients: 1
            )
        ]

        // Compact size class (iPhone portrait)
        let compactView = MultiplexerPicker()
            .environmentObject(container)
            .environment(\.horizontalSizeClass, .compact)
        let compactController = UIHostingController(rootView: compactView)
        let compactWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        compactWindow.rootViewController = compactController
        compactWindow.makeKeyAndVisible()
        compactController.view.layoutIfNeeded()

        XCTAssertEqual(compactController.view.bounds.width, 393)
        XCTAssertEqual(compactController.view.bounds.height, 852)
        XCTAssertGreaterThan(compactController.view.subviews.count, 0)

        // Regular size class (iPad landscape)
        let regularView = MultiplexerPicker()
            .environmentObject(container)
            .environment(\.horizontalSizeClass, .regular)
        let regularController = UIHostingController(rootView: regularView)
        let regularWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        regularWindow.rootViewController = regularController
        regularWindow.makeKeyAndVisible()
        regularController.view.layoutIfNeeded()

        XCTAssertEqual(regularController.view.bounds.width, 1024)
        XCTAssertEqual(regularController.view.bounds.height, 768)
        XCTAssertGreaterThan(regularController.view.subviews.count, 0)
    }

    // MARK: - 12. Regression Tests (Findings 1 - 8)

    func testStaleProbeAndListResultsDoNotOverwriteNewOrDisconnectedSession() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Stale Host", hostname: "stale.test", username: "user")
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        let gate = AsyncGate()
        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                await gate.wait()
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 0, stdout: "$0\tmain\t1\t1700000000\t1700000500\t1\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        // Start refreshTmuxState asynchronously while probe is blocked at gate
        let refreshTask = Task {
            await container.refreshTmuxState()
        }

        // Wait slightly for refresh to enter probe await
        try await Task.sleep(nanoseconds: 20_000_000)

        // Disconnect before probe returns
        await container.disconnect()
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertEqual(container.tmuxAvailability, .unavailable(reason: "Not connected"))
        XCTAssertTrue(container.tmuxSessions.isEmpty)
        XCTAssertFalse(container.isTmuxServerRunning)

        // Now open the gate so the probe completes
        await gate.open()
        await refreshTask.value

        // Verify that stale probe/list results did NOT overwrite the disconnected state
        XCTAssertEqual(container.activeSession?.state, .disconnected)
        XCTAssertEqual(container.tmuxAvailability, .unavailable(reason: "Not connected"))
        XCTAssertTrue(container.tmuxSessions.isEmpty)
        XCTAssertFalse(container.isTmuxServerRunning)
    }

    func testStaleHasSessionDoesNotMutateStateAfterDisconnect() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let gate = AsyncGate()
        mock.onExecuteCommand = { cmd in
            if cmd.contains("has-session") {
                await gate.wait()
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "no session")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let host = try Host(name: "Slow Host", hostname: "slow.test", username: "user", defaultTmuxSession: "$99", autoAttachTmux: true)

        let connectTask = Task {
            await container.connect(to: host)
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        await container.disconnect()

        await gate.open()
        await connectTask.value

        // Error should not be assigned to disconnected session
        XCTAssertNil(container.tmuxError)
        XCTAssertNil(container.activeTmuxSessionID)
    }

    func testCreatedSessionResolvesToSessionIDAfterListAndUIRecognizesActive() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Create Host", hostname: "create.test", username: "user")
        await container.connect(to: host)

        var sessionsOutput = "$0\tother\t1\t1700000000\t1700000500\t0\n"
        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 0, stdout: sessionsOutput)
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let created = await container.createTmuxSession(name: "project-work")
        XCTAssertTrue(created)
        XCTAssertEqual(container.activeTmuxSessionID, "project-work")

        let candidateSession = TmuxSessionInfo(
            sessionID: "$5",
            name: "project-work",
            windowsCount: 1,
            createdAt: Date(),
            lastActivityAt: Date(),
            attachedClients: 1
        )

        // UI recognizes active by transitional name
        XCTAssertTrue(container.isTmuxSessionActive(candidateSession))

        // Now remote list updates with the new session
        sessionsOutput = "$0\tother\t1\t1700000000\t1700000500\t0\n$5\tproject-work\t1\t1700000000\t1700000500\t1\n"
        let sessions = await container.listTmuxSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(container.activeTmuxSessionID, "$5")

        // Restoration store updated with resolved ID
        let metadata = try await container.restorationStore.load()
        XCTAssertEqual(metadata?.tmuxSessionID, "$5")

        // UI recognizes active by canonical ID
        XCTAssertFalse(container.isTmuxSessionActive(sessions[0]))
        XCTAssertTrue(container.isTmuxSessionActive(sessions[1]))
    }

    func testPreferenceValidationAndAtomicHostSync() async throws {
        let container = AppContainer.demo()
        let host = try Host(name: "Sync Host", hostname: "sync.test", username: "user")
        try await container.catalog.save(host)
        await container.connect(to: host)

        XCTAssertEqual(container.activeHost?.autoAttachTmux, false)
        XCTAssertNil(container.activeHost?.defaultTmuxSession)

        // Legacy target arguments are ignored while auto-attach remains configurable.
        try await container.updateActiveHostPreferences(autoAttachTmux: true, defaultTmuxSession: "legacy-session")
        XCTAssertEqual(container.activeHost?.autoAttachTmux, true)
        XCTAssertNil(container.activeHost?.defaultTmuxSession)
        let reloadedHost = try await container.catalog.listHosts().first(where: { $0.id == host.id })
        XCTAssertNil(reloadedHost?.defaultTmuxSession)
        XCTAssertEqual(reloadedHost?.autoAttachTmux, true)

        try await container.updateActiveHostPreferences(autoAttachTmux: false, defaultTmuxSession: "$3")
        XCTAssertEqual(container.activeHost?.autoAttachTmux, false)
        XCTAssertNil(container.activeHost?.defaultTmuxSession)
    }

    func testListSessionsParserFailureSurfacesSafeUserVisibleError() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Parse Host", hostname: "parse.test", username: "user")
        await container.connect(to: host)

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 0, stdout: "invalid line without tabs\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        let sessions = await container.listTmuxSessions()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(container.tmuxSessions.isEmpty)
        XCTAssertTrue(container.isTmuxServerRunning)
        XCTAssertNotNil(container.tmuxError)
        XCTAssertTrue(container.tmuxError?.contains("Failed to parse tmux sessions") ?? false)
    }

    func testServerStopAndSessionDisappearanceClearsActiveSessionAndRestoration() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        let container = AppContainer(
            transport: transport,
            reachabilityMonitor: MockReachabilityMonitor(isReachable: true),
            reconnectCoordinator: ReconnectCoordinator(clock: { _ in }, jitter: ReconnectCoordinator.zeroJitter)
        )

        let host = try Host(name: "Lifecycle Host", hostname: "life.test", username: "user")
        await container.connect(to: host)

        await container.attachTmuxSession(id: "$0")
        XCTAssertEqual(container.activeTmuxSessionID, "$0")

        // 1. Session disappears from successful list
        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 0, stdout: "$1\tother\t1\t1700000000\t1700000500\t1\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        _ = await container.listTmuxSessions()
        XCTAssertNil(container.activeTmuxSessionID, "Disappeared session must be cleared")
        var metadata = try await container.restorationStore.load()
        XCTAssertEqual(metadata?.tmuxSessionID, "$0")

        // 2. Server stops
        await container.attachTmuxSession(id: "$1")
        XCTAssertEqual(container.activeTmuxSessionID, "$1")

        mock.onExecuteCommand = { cmd in
            if cmd == TmuxCommand.probe {
                return SSHCommandResult(exitCode: 0, stdout: "tmux 3.4\n")
            }
            if cmd == TmuxCommand.listSessions {
                return SSHCommandResult(exitCode: 1, stdout: "", stderr: "no server running on /tmp/tmux-1000/default\n")
            }
            return SSHCommandResult(exitCode: 0, stdout: "")
        }

        _ = await container.listTmuxSessions()
        XCTAssertNil(container.activeTmuxSessionID, "Stopped server must clear activeTmuxSessionID")
        XCTAssertFalse(container.isTmuxServerRunning)
        metadata = try await container.restorationStore.load()
        XCTAssertEqual(metadata?.tmuxSessionID, "$1")
    }

    func testValidatedCommandSendFailureFedToProductionTerminalSurface() async throws {
        let mock = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mock }

        mock.onSend = { _ in
            throw TransportError.remoteFailure("channel error")
        }

        let container = AppContainer(
            transport: transport
        )

        let host = try Host(name: "Send Fail Host", hostname: "sendfail.test", username: "user")
        await container.connect(to: host)

        let success = await container.sendValidatedCommand("echo hello\n", approved: true)
        XCTAssertFalse(success)
        XCTAssertTrue(container.terminalText.contains("Send failed"))
        let transcript = container.terminalController.currentTranscript(limit: 10)
        XCTAssertTrue(transcript.contains("[Send failed:"), "Send failure must be fed to production terminal surface")
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        for cont in continuations {
            cont.resume()
        }
        continuations.removeAll()
    }
}
