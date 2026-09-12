import XCTest
import SwiftUI
@testable import Shh
import ShhCore

@MainActor
final class EditorSheetPresentationTests: XCTestCase {
    func testEditorSheetPresentationModifierDefaults() {
        let modifier = EditorSheetPresentationModifier()
        XCTAssertEqual(modifier.detents, [.large])
        XCTAssertEqual(modifier.dragIndicator, .visible)
    }

    func testEditorSheetPresentationModifierCustomDetents() {
        let customDetents: Set<PresentationDetent> = [.medium, .large]
        let modifier = EditorSheetPresentationModifier(detents: customDetents, dragIndicator: .hidden)
        XCTAssertEqual(modifier.detents, customDetents)
        XCTAssertEqual(modifier.dragIndicator, .hidden)
    }

    func testViewExtensionAppliesModifier() {
        let sampleView = Text("Editor Sheet Content")
            .editorSheetPresentation()
        let hostingController = UIHostingController(rootView: sampleView)
        hostingController.loadViewIfNeeded()
        XCTAssertNotNil(hostingController.view)
    }

    func testHostEditorViewConstructionAndHosting() async throws {
        let container = AppContainer.demo()

        // Test new host editor view
        let newHostView = HostEditorView().environmentObject(container)
        let newHostHosting = UIHostingController(rootView: newHostView)
        newHostHosting.loadViewIfNeeded()
        XCTAssertNotNil(newHostHosting.view)

        // Test existing host editor view
        let existingHost = try Host(
            id: UUID(),
            name: "Test Host",
            hostname: "test.example.com",
            port: 22,
            username: "admin"
        )
        let existingHostView = HostEditorView(existing: existingHost).environmentObject(container)
        let existingHostHosting = UIHostingController(rootView: existingHostView)
        existingHostHosting.loadViewIfNeeded()
        XCTAssertNotNil(existingHostHosting.view)
    }

    func testIdentityEditorViewConstructionAndHosting() async throws {
        let container = AppContainer.demo()

        var created: IdentityDescriptor?
        let identityEditor = IdentityEditorView { ident in
            created = ident
        }.environmentObject(container)

        let hostingController = UIHostingController(rootView: identityEditor)
        hostingController.loadViewIfNeeded()
        XCTAssertNotNil(hostingController.view)
        XCTAssertNil(created)
    }

    func testPortForwardingRuleEditorSheetConstructionAndHosting() throws {
        // Test new rule sheet
        var savedRule: PortForwardingRule?
        let newRuleView = PortForwardingRuleEditorSheet { rule in
            savedRule = rule
        }
        let newRuleHosting = UIHostingController(rootView: newRuleView)
        newRuleHosting.loadViewIfNeeded()
        XCTAssertNotNil(newRuleHosting.view)
        XCTAssertNil(savedRule)

        // Test edit existing rule sheet
        let existingRule = try PortForwardingRule(
            id: UUID(),
            name: "Local Tunnel",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 8080,
            remoteHost: "internal.host",
            remotePort: 80
        )
        let editRuleView = PortForwardingRuleEditorSheet(existingRule: existingRule) { rule in
            savedRule = rule
        }
        let editRuleHosting = UIHostingController(rootView: editRuleView)
        editRuleHosting.loadViewIfNeeded()
        XCTAssertNotNil(editRuleHosting.view)
    }

    func testFileEditorSheetConstructionAndHosting() throws {
        let container = AppContainer.demo()
        container.editingFileContent = "print('Hello iPadOS')\n"
        let editorView = FileEditorSheet().environmentObject(container)
        let hosting = UIHostingController(rootView: editorView)
        hosting.loadViewIfNeeded()
        XCTAssertNotNil(hosting.view)
    }

    func testHerdrSheetsConstructionAndHosting() throws {
        let container = AppContainer.demo()

        let createWorkspaceView = HerdrCreateWorkspaceSheet().environmentObject(container)
        let createHosting = UIHostingController(rootView: createWorkspaceView)
        createHosting.loadViewIfNeeded()
        XCTAssertNotNil(createHosting.view)

        let pane = HerdrPane(id: "%1", label: "web-server", agentState: .idle, currentCommand: "node server.js", lastActivity: Date())
        let sendCommandView = HerdrSendCommandSheet(pane: pane).environmentObject(container)
        let sendHosting = UIHostingController(rootView: sendCommandView)
        sendHosting.loadViewIfNeeded()
        XCTAssertNotNil(sendHosting.view)

        let outputView = HerdrOutputSheet(pane: pane).environmentObject(container)
        let outputHosting = UIHostingController(rootView: outputView)
        outputHosting.loadViewIfNeeded()
        XCTAssertNotNil(outputHosting.view)
    }

    func testApprovalSheetAndMultiplexerPickerConstruction() throws {
        let container = AppContainer.demo()

        let approvalView = ApprovalSheet(command: "ls -la /tmp").environmentObject(container)
        let approvalHosting = UIHostingController(rootView: approvalView)
        approvalHosting.loadViewIfNeeded()
        XCTAssertNotNil(approvalHosting.view)

        let muxView = MultiplexerPicker().environmentObject(container)
        let muxHosting = UIHostingController(rootView: muxView)
        muxHosting.loadViewIfNeeded()
        XCTAssertNotNil(muxHosting.view)
    }

    func testTechnicalInputsPreserveIntentionalCasing() async throws {
        let container = AppContainer.demo()

        // Verify mixed casing is preserved on Host creation and inspection
        let host = try Host(
            id: UUID(),
            name: "Staging-US-East-1",
            hostname: "SSH.Internal.Domain.Net",
            port: 2222,
            username: "DevAdmin"
        )
        XCTAssertEqual(host.name, "Staging-US-East-1")
        XCTAssertEqual(host.hostname, "SSH.Internal.Domain.Net")
        XCTAssertEqual(host.username, "DevAdmin")

        // Verify mixed casing is preserved for key identity
        let identity = try await container.createEd25519Identity(name: "ProdOps-Key", comment: "Admin@Cloud-Bastion")
        XCTAssertEqual(identity.name, "ProdOps-Key")
        let pubKey = try await container.openSSHPublicKey(for: identity, comment: "Admin@Cloud-Bastion")
        XCTAssertTrue(pubKey?.contains("Admin@Cloud-Bastion") == true)

        // Verify mixed casing is preserved for port forwarding rule
        let rule = try PortForwardingRule(
            id: UUID(),
            name: "GraphQL-API-Tunnel",
            type: .local,
            localHost: "127.0.0.1",
            localPort: 4000,
            remoteHost: "API-Gateway.Internal",
            remotePort: 4000
        )
        XCTAssertEqual(rule.name, "GraphQL-API-Tunnel")
        XCTAssertEqual(rule.remoteHost, "API-Gateway.Internal")
    }
}
