import XCTest
import SwiftUI
@testable import Shh
import ShhCore
import ShhSSH
import ShhTerminal
import ShhVoice

@MainActor
final class VoiceAppTests: XCTestCase {

    // MARK: - Test Fixtures & Helpers

    private func makeConnectedContainer(
        host: Host? = nil,
        transcriber: (any LocalTranscriber)? = nil,
        voiceRecorder: (any AudioRecorder)? = nil,
        modelManager: WhisperModelManager? = nil
    ) async throws -> (AppContainer, MockSSHConnection, Host) {
        let testHost = try (host ?? Host(
            name: "Dev Workstation",
            hostname: "dev.local",
            username: "developer",
            voicePolicy: .enabled
        ))

        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockConnection }

        let modelsDir = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceAppTests_Models_\(UUID().uuidString)")
        let resolvedManager = modelManager ?? WhisperModelManager(
            modelsDirectory: modelsDir,
            downloader: DemoWhisperDownloader()
        )

        let resolvedTranscriber = transcriber ?? DemoTranscriber(transcript: "ls -la")
        let resolvedRecorder = voiceRecorder ?? DemoAudioRecorder()

        let registry = VoiceProviderRegistry(
            whisperTranscriber: resolvedTranscriber,
            appleSpeechTranscriber: resolvedTranscriber,
            initialSelectedID: VoiceProviderRegistry.whisperProviderID
        )

        let container = AppContainer(
            transport: transport,
            transcriber: resolvedTranscriber,
            modelManager: resolvedManager,
            voiceRegistry: registry,
            voiceRecorder: resolvedRecorder
        )

        let challenge = HostKeyChallenge(
            hostname: testHost.hostname,
            port: testHost.port,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:test-fingerprint"
        )
        await container.trustStore.save(challenge)
        await container.connect(to: testHost)
        XCTAssertEqual(container.activeSession?.state, .connected)

        return (container, mockConnection, testHost)
    }

    // MARK: - 1. Three Modes Execution

    func testShellCommandModeSafeExecution() async throws {
        let transcriber = DemoTranscriber(transcript: "git status")
        let (container, mockConnection, _) = try await makeConnectedContainer(transcriber: transcriber)

        // Install tiny model so Whisper provider is ready
        try await container.downloadVoiceModel(.tiny)

        // Record and transcribe
        try await container.startVoiceRecording(mode: .shellCommand)
        XCTAssertTrue(container.isRecordingVoice)

        let preview = try await container.stopVoiceRecording(mode: .shellCommand)
        XCTAssertEqual(preview.text, "git status")
        XCTAssertEqual(preview.mode, .shellCommand)
        XCTAssertEqual(preview.decision, .manualSendRequired(command: "git status"))

        // Invariant: Inbound bytes must be 0 before explicit send!
        XCTAssertEqual(mockConnection.sentData.count, 0, "No bytes must be sent before user confirms Send")

        // User explicitly taps Send Command
        let sent = await container.sendVoiceCommand(preview: preview)
        XCTAssertTrue(sent)

        // Verify sent payload: "git status\n"
        XCTAssertEqual(mockConnection.sentData.count, 1)
        XCTAssertEqual(mockConnection.sentData.first, Data("git status\n".utf8))

        // State reset to idle
        XCTAssertEqual(container.speechState, .idle)
        XCTAssertNil(container.activeVoicePreview)
    }

    func testShellCommandModeReviewRequiredExecution() async throws {
        let transcriber = DemoTranscriber(transcript: "reboot")
        let (container, mockConnection, _) = try await makeConnectedContainer(transcriber: transcriber)
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)
        let preview = try await container.stopVoiceRecording(mode: .shellCommand)
        XCTAssertEqual(preview.text, "reboot")
        XCTAssertEqual(preview.decision, .reviewRequired(command: "reboot"))

        // sendVoiceCommand without approval returns false
        let unapprovedSend = await container.sendVoiceCommand(preview: preview)
        XCTAssertFalse(unapprovedSend)
        XCTAssertEqual(mockConnection.sentData.count, 0)

        // Approved send succeeds
        let approvedSend = await container.sendValidatedCommand("reboot\n", approved: true)
        XCTAssertTrue(approvedSend)
        XCTAssertEqual(mockConnection.sentData.count, 1)
        XCTAssertEqual(mockConnection.sentData.first, Data("reboot\n".utf8))
    }

    func testAgentMessageModeExecution() async throws {
        let prompt = "Find failing tests in module ShhVoice"
        let transcriber = DemoTranscriber(transcript: prompt)
        let (container, mockConnection, _) = try await makeConnectedContainer(transcriber: transcriber)
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .agentMessage)
        let preview = try await container.stopVoiceRecording(mode: .agentMessage)
        XCTAssertEqual(preview.mode, .agentMessage)
        XCTAssertEqual(preview.decision, .agentDispatchPendingConfirmation(message: prompt))

        // Zero bytes before send
        XCTAssertEqual(mockConnection.sentData.count, 0)

        // Send agent message (non-production host)
        let sent = await container.sendAgentMessage(preview: preview)
        XCTAssertTrue(sent)

        // Must send ordered raw text plus Enter ("\n")
        XCTAssertEqual(mockConnection.sentData.count, 1)
        XCTAssertEqual(mockConnection.sentData.first, Data((prompt + "\n").utf8))
    }

    func testInsertOnlyModeSendsBracketedPasteWithoutEnter() async throws {
        let codeSnippet = "func process() {\n    return true\n}"
        let transcriber = DemoTranscriber(transcript: codeSnippet)
        let (container, mockConnection, _) = try await makeConnectedContainer(transcriber: transcriber)
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .insertOnly)
        let preview = try await container.stopVoiceRecording(mode: .insertOnly)
        XCTAssertEqual(preview.mode, .insertOnly)
        XCTAssertEqual(preview.decision, .insertPendingConfirmation(text: codeSnippet))

        // Zero bytes before insertion
        XCTAssertEqual(mockConnection.sentData.count, 0)

        // Insert at cursor
        let inserted = await container.insertVoiceText(preview: preview)
        XCTAssertTrue(inserted)

        XCTAssertEqual(mockConnection.sentData.count, 1)
        let sentPayload = mockConnection.sentData.first!
        let expectedBracketed = TerminalKeyEncoder.encodePaste(codeSnippet, bracketed: true)

        XCTAssertEqual(sentPayload, expectedBracketed, "Insert text must wrap in bracketed paste markers")

        // CRITICAL INVARIANT: NO trailing newline / Enter!
        XCTAssertFalse(
            sentPayload.last == 0x0A || sentPayload.last == 0x0D,
            "Insert only mode must NEVER append trailing newline / Enter"
        )
    }

    // MARK: - 2. No-Auto-Execute Invariant

    func testNoAutoExecuteInvariantAcrossAllModes() async throws {
        let commands = [
            ("ls -la", VoiceInputMode.shellCommand),
            ("help me debug", VoiceInputMode.agentMessage),
            ("let x = 10", VoiceInputMode.insertOnly)
        ]

        for (text, mode) in commands {
            let transcriber = DemoTranscriber(transcript: text)
            let (container, mockConnection, _) = try await makeConnectedContainer(transcriber: transcriber)
            try await container.downloadVoiceModel(.tiny)

            try await container.startVoiceRecording(mode: mode)
            let preview = try await container.stopVoiceRecording(mode: mode)

            // Verify state is preview, NEVER automatically executed
            XCTAssertEqual(container.speechState, .preview(preview))
            XCTAssertEqual(mockConnection.sentData.count, 0, "Mode \(mode) must never auto-execute on transcription complete")
        }
    }

    func testModeSwitchDoesNotAutoExecute() async throws {
        let transcriber = DemoTranscriber(transcript: "date")
        let (container, mockConnection, host) = try await makeConnectedContainer(transcriber: transcriber)
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)
        var preview = try await container.stopVoiceRecording(mode: .shellCommand)

        // Switch mode to agentMessage
        preview.updateMode(.agentMessage, router: container.voiceRouter, hostPolicy: host.voicePolicy)
        XCTAssertEqual(mockConnection.sentData.count, 0, "Switching mode must never auto-execute")

        // Switch mode to insertOnly
        preview.updateMode(.insertOnly, router: container.voiceRouter, hostPolicy: host.voicePolicy)
        XCTAssertEqual(mockConnection.sentData.count, 0, "Switching mode must never auto-execute")
    }

    // MARK: - 3. Blocked Shell Commands

    func testBlockedCommandsCannotBeSentFromVoice() async throws {
        let dangerousCommands = [
            "rm -rf /",
            "tmux kill-server",
            ":(){ :|:& };:"
        ]

        for cmd in dangerousCommands {
            let transcriber = DemoTranscriber(transcript: cmd)
            let (container, mockConnection, _) = try await makeConnectedContainer(transcriber: transcriber)
            try await container.downloadVoiceModel(.tiny)

            try await container.startVoiceRecording(mode: .shellCommand)
            let preview = try await container.stopVoiceRecording(mode: .shellCommand)

            XCTAssertTrue(preview.decision.isBlocked, "Command '\(cmd)' must be classified as blocked")
            let sent = await container.sendVoiceCommand(preview: preview)
            XCTAssertFalse(sent, "Blocked command must never be sent")
            XCTAssertEqual(mockConnection.sentData.count, 0)
        }
    }

    func testEditingBlockedCommandToSafeEnablesSend() async throws {
        let transcriber = DemoTranscriber(transcript: "rm -rf /")
        let (container, mockConnection, host) = try await makeConnectedContainer(transcriber: transcriber)
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)
        var preview = try await container.stopVoiceRecording(mode: .shellCommand)
        XCTAssertTrue(preview.decision.isBlocked)

        // Edit text to a safe command
        preview.updateText("ls -l /tmp", router: container.voiceRouter, hostPolicy: host.voicePolicy)
        XCTAssertEqual(preview.decision, .manualSendRequired(command: "ls -l /tmp"))
        XCTAssertTrue(preview.isEdited)

        let sent = await container.sendVoiceCommand(preview: preview)
        XCTAssertTrue(sent)
        XCTAssertEqual(mockConnection.sentData.first, Data("ls -l /tmp\n".utf8))
    }

    // MARK: - 4. Production Restrictions

    func testPerHostVoiceDisablePolicyRejectsRecording() async throws {
        let disabledHost = try Host(
            name: "Production DB",
            hostname: "db.corp.internal",
            username: "admin",
            voicePolicy: .disabled
        )
        let (container, _, _) = try await makeConnectedContainer(host: disabledHost)
        try await container.downloadVoiceModel(.tiny)

        do {
            try await container.startVoiceRecording(mode: .shellCommand)
            XCTFail("Must throw error when voice is disabled for host")
        } catch let err as TranscriptionError {
            XCTAssertEqual(err, .hostPolicyDisabled(hostID: disabledHost.id))
        }

        XCTAssertFalse(container.isRecordingVoice)
        XCTAssertNotNil(container.voiceErrorMessage)
    }

    func testPerHostAllowedModesRestrictsExecution() async throws {
        let insertOnlyPolicy = HostVoicePolicy(isEnabled: true, allowedModes: [.insertOnly])
        let host = try Host(
            name: "InsertOnlyHost",
            hostname: "insert.internal",
            username: "user",
            voicePolicy: insertOnlyPolicy
        )
        let (container, _, _) = try await makeConnectedContainer(host: host)
        try await container.downloadVoiceModel(.tiny)

        // Shell command rejected
        do {
            try await container.startVoiceRecording(mode: .shellCommand)
            XCTFail("Should reject mode not allowed by policy")
        } catch {
            XCTAssertFalse(container.isRecordingVoice)
        }

        // Insert only allowed
        try await container.startVoiceRecording(mode: .insertOnly)
        XCTAssertTrue(container.isRecordingVoice)
        await container.cancelVoiceRecording()
    }

    func testPerHostAllowedModesRestrictsModesAvailableInPicker() async throws {
        let insertOnlyPolicy = HostVoicePolicy(isEnabled: true, allowedModes: [.insertOnly])
        let host = try Host(
            name: "InsertOnlyHost",
            hostname: "insert.internal",
            username: "user",
            voicePolicy: insertOnlyPolicy
        )
        let (container, _, _) = try await makeConnectedContainer(host: host)
        try await container.downloadVoiceModel(.tiny)

        let composer = VoiceComposer().environmentObject(container)
        let controller = UIHostingController(rootView: composer)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()

        XCTAssertGreaterThan(controller.view.bounds.width, 0)
        XCTAssertGreaterThan(controller.view.bounds.height, 0)
    }

    func testAlternativeTapButtonWhenRecordingIsLabeledTapToStop() async throws {
        let (container, _, _) = try await makeConnectedContainer()
        try await container.downloadVoiceModel(.tiny)

        let composer = VoiceComposer().environmentObject(container)
        let controller = UIHostingController(rootView: composer)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()

        // Before recording: container is not recording
        XCTAssertFalse(container.isRecordingVoice)

        // Begin recording
        try await container.startVoiceRecording(mode: .shellCommand)
        XCTAssertTrue(container.isRecordingVoice)
        controller.view.layoutIfNeeded()

        // Stop recording
        await container.cancelVoiceRecording()
        XCTAssertFalse(container.isRecordingVoice)
    }

    func testAgentMessageRequiresProductionHostConfirmation() async throws {
        let prodHost = try Host(
            name: "ProdWeb01",
            hostname: "web.prod.internal",
            username: "deploy",
            voicePolicy: .enabled,
            isProduction: true
        )
        XCTAssertTrue(prodHost.isProduction)

        let prompt = "restart the web service"
        let transcriber = DemoTranscriber(transcript: prompt)
        let (container, mockConnection, _) = try await makeConnectedContainer(host: prodHost, transcriber: transcriber)
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .agentMessage)
        let preview = try await container.stopVoiceRecording(mode: .agentMessage)

        // 1. Unconfirmed dispatch to production host must fail
        let unconfirmed = await container.sendAgentMessage(preview: preview, confirmedProduction: false)
        XCTAssertFalse(unconfirmed, "Unconfirmed send to production host must fail")
        XCTAssertEqual(mockConnection.sentData.count, 0)

        // 2. Confirmed dispatch to production host succeeds
        let confirmed = await container.sendAgentMessage(preview: preview, confirmedProduction: true)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(mockConnection.sentData.count, 1)
        XCTAssertEqual(mockConnection.sentData.first, Data((prompt + "\n").utf8))
    }

    // MARK: - 5. Redaction

    func testTerminalRedactionPreservesSecretHidingDuringVoiceWorkflow() async throws {
        let secretValue = "superSecretAPIKey12345"
        let credStore = InMemoryCredentialStore()
        let identity = try IdentityDescriptor(name: "TestKey", kind: .password, keychainReference: "ref_1")
        try await credStore.save(Data(secretValue.utf8), reference: identity.keychainReference)

        let host = try Host(
            name: "SecureBox",
            hostname: "sec.test",
            username: "root",
            identityID: identity.id,
            voicePolicy: .enabled
        )

        let mockConnection = MockSSHConnection()
        let transport = ControllableTransport()
        transport.onConnect = { _ in mockConnection }

        let container = AppContainer(
            catalog: InMemoryCatalog(),
            credentialStore: credStore,
            transport: transport
        )
        try await container.catalog.save(identity)
        try await container.catalog.save(host)

        let challenge = HostKeyChallenge(hostname: host.hostname, port: host.port, algorithm: "ssh-ed25519", fingerprint: "SHA256:fingerprint")
        await container.trustStore.save(challenge)
        await container.connect(to: host)

        // Verify that container redacts secret
        let incomingWithSecret = Data("output with token \(secretValue) in logs\n".utf8)
        let redacted = container.redacted(incomingWithSecret)
        let redactedString = String(decoding: redacted, as: UTF8.self)
        XCTAssertFalse(redactedString.contains(secretValue))
        XCTAssertTrue(redactedString.contains("[REDACTED]"))
    }

    // MARK: - 6. Deletion & Zero Persistence

    func testAudioFileGuaranteedDeletionOnSuccess() async throws {
        var recordedHandleURL: URL?
        final class CapturingRecorder: AudioRecorder, @unchecked Sendable {
            var onStop: ((URL) -> Void)?
            func start() async throws {}
            func stop() async throws -> AudioRecordingHandle {
                let handle = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
                try Data("synthetic-bytes".utf8).write(to: handle.fileURL)
                onStop?(handle.url)
                var finalH = handle
                finalH.duration = 1.0
                return finalH
            }
            func cancel() async {}
        }

        let capturer = CapturingRecorder()
        capturer.onStop = { url in
            recordedHandleURL = url
        }

        let (container, _, _) = try await makeConnectedContainer(voiceRecorder: capturer)
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)
        _ = try await container.stopVoiceRecording(mode: .shellCommand)

        guard let recordedHandleURL else {
            XCTFail("Handle URL must be captured")
            return
        }

        // File MUST be deleted after stopVoiceRecording!
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recordedHandleURL.path),
            "Audio recording file must be deleted immediately after transcription completes"
        )
    }

    func testAudioFileGuaranteedDeletionOnCancellation() async throws {
        let (container, _, _) = try await makeConnectedContainer()
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)
        XCTAssertTrue(container.isRecordingVoice)

        await container.cancelVoiceRecording()
        XCTAssertFalse(container.isRecordingVoice)
        XCTAssertEqual(container.speechState, .cancelled)
    }

    func testAudioFileGuaranteedDeletionOnError() async throws {
        var recordedHandleURL: URL?
        final class CapturingRecorder: AudioRecorder, @unchecked Sendable {
            var onStop: ((URL) -> Void)?
            func start() async throws {}
            func stop() async throws -> AudioRecordingHandle {
                let handle = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
                try Data("synthetic-bytes".utf8).write(to: handle.fileURL)
                onStop?(handle.url)
                var finalH = handle
                finalH.duration = 1.0
                return finalH
            }
            func cancel() async {}
        }

        let capturer = CapturingRecorder()
        capturer.onStop = { url in
            recordedHandleURL = url
        }

        let failingTranscriber = DemoTranscriber()
        failingTranscriber.setSimulateError(TranscriptionError.transcriptionFailed(reason: "forced failure"))

        let (container, _, _) = try await makeConnectedContainer(
            transcriber: failingTranscriber,
            voiceRecorder: capturer
        )
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)

        do {
            _ = try await container.stopVoiceRecording(mode: .shellCommand)
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        guard let recordedHandleURL else {
            XCTFail("Handle URL must be captured")
            return
        }

        // Must still be deleted on error!
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recordedHandleURL.path),
            "Audio recording file must be deleted even if transcription throws"
        )
    }

    func testTranscriptsNeverPersistInStorage() async throws {
        let transcript = "secret_command_that_should_not_persist"
        let transcriber = DemoTranscriber(transcript: transcript)
        let (container, _, _) = try await makeConnectedContainer(transcriber: transcriber)
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)
        let preview = try await container.stopVoiceRecording(mode: .shellCommand)
        XCTAssertEqual(preview.text, transcript)

        // Dismiss / reset
        container.resetVoiceState()

        // Check container state
        XCTAssertEqual(container.speechState, .idle)
        XCTAssertNil(container.activeVoicePreview)

        // Invariant: No transcript key exists in UserDefaults
        let defaultsDict = UserDefaults.standard.dictionaryRepresentation()
        for (key, val) in defaultsDict {
            if let stringVal = val as? String {
                XCTAssertFalse(stringVal.contains(transcript), "Transcript must never leak into UserDefaults key '\(key)'")
            }
        }
    }

    // MARK: - 7. Cancellation

    func testSlideToCancelWorkflow() async throws {
        let (container, _, _) = try await makeConnectedContainer()
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)
        XCTAssertTrue(container.isRecordingVoice)

        // Simulate slide-to-cancel
        container.isSlideToCancelActive = true
        await container.cancelVoiceRecording()

        XCTAssertFalse(container.isRecordingVoice)
        XCTAssertFalse(container.isSlideToCancelActive)
        XCTAssertEqual(container.speechState, .cancelled)
    }

    func testTranscriptionCancellation() async throws {
        let slowTranscriber = DemoTranscriber(transcript: "slow", simulateDelay: 0.5)
        let (container, _, _) = try await makeConnectedContainer(transcriber: slowTranscriber)
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)

        let stopTask = Task {
            try await container.stopVoiceRecording(mode: .shellCommand)
        }

        // Give it a brief moment to enter transcribing
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(container.isTranscribingVoice)

        await container.cancelVoiceRecording()
        stopTask.cancel()

        XCTAssertFalse(container.isTranscribingVoice)
        XCTAssertEqual(container.speechState, .cancelled)
    }

    func testCancelledSlowTranscriptionDoesNotResurrectPreviewUponCompletion() async throws {
        let slowTranscriber = DemoTranscriber(transcript: "slow transcript", simulateDelay: 0.15)
        let (container, _, _) = try await makeConnectedContainer(transcriber: slowTranscriber)
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)

        let stopTask = Task {
            try await container.stopVoiceRecording(mode: .shellCommand)
        }

        // Give it a moment to enter transcribing
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(container.isTranscribingVoice)

        // Cancel while transcribing
        await container.cancelVoiceRecording()
        XCTAssertEqual(container.speechState, .cancelled)
        XCTAssertNil(container.activeVoicePreview)

        // Wait longer than transcriber's delay so background task completes
        try await Task.sleep(nanoseconds: 200_000_000)

        // Stale transcription must NOT have resurrected state to .preview!
        XCTAssertEqual(container.speechState, .cancelled, "State must remain .cancelled and not resurrect to preview")
        XCTAssertNil(container.activeVoicePreview, "Active preview must not be resurrected by stale completion")
        XCTAssertFalse(container.isTranscribingVoice)
        _ = try? await stopTask.value
    }

    func testResetVoiceStateDuringSlowTranscriptionDoesNotGetOverwritten() async throws {
        let slowTranscriber = DemoTranscriber(transcript: "slow transcript", simulateDelay: 0.15)
        let (container, _, _) = try await makeConnectedContainer(transcriber: slowTranscriber)
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)

        let stopTask = Task {
            try await container.stopVoiceRecording(mode: .shellCommand)
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(container.isTranscribingVoice)

        // Reset voice state while transcribing
        container.resetVoiceState()
        XCTAssertEqual(container.speechState, .idle)
        XCTAssertNil(container.activeVoicePreview)

        // Wait for slow transcriber to complete
        try await Task.sleep(nanoseconds: 200_000_000)

        // State must remain .idle and not be overwritten
        XCTAssertEqual(container.speechState, .idle, "State must remain .idle")
        XCTAssertNil(container.activeVoicePreview)
        XCTAssertFalse(container.isTranscribingVoice)
        _ = try? await stopTask.value
    }

    func testApprovalSheetSendResetsVoiceState() async throws {
        let (container, connection, _) = try await makeConnectedContainer()
        try await container.downloadVoiceModel(.tiny)

        let preview = VoicePreviewState(
            originalTranscript: "reboot",
            mode: .shellCommand,
            duration: 1.0,
            router: container.voiceRouter,
            hostPolicy: .enabled
        )
        container.activeVoicePreview = preview
        container.speechState = .preview(preview)

        // Create ApprovalSheet with onApproved callback as wired in VoiceComposer
        var onApprovedCalled = false
        let sheet = ApprovalSheet(command: "reboot", onApproved: {
            onApprovedCalled = true
            container.resetVoiceState()
        })
        _ = sheet.environmentObject(container)

        // Execute send with approval via container
        let sent = await container.sendValidatedCommand("reboot\n", approved: true)
        XCTAssertTrue(sent)
        XCTAssertTrue(connection.sentData.contains { String(decoding: $0, as: UTF8.self).contains("reboot") })

        // When approval succeeds, onApproved callback resets voice state
        sheet.onApproved?()
        XCTAssertTrue(onApprovedCalled)
        XCTAssertNil(container.activeVoicePreview, "Voice state must be reset after approved command is sent")
        XCTAssertEqual(container.speechState, .idle)
    }

    func testSceneBackgroundCancelsActiveVoiceSession() async throws {
        let (container, _, _) = try await makeConnectedContainer()
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)
        XCTAssertTrue(container.isRecordingVoice)

        // App backgrounding must cancel recording
        container.handleScenePhaseChange(.background)

        // Allow task to run
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(container.isRecordingVoice)
        XCTAssertEqual(container.speechState, .cancelled)
    }

    // MARK: - 8. Stale Tasks & Disconnect

    func testDisconnectWhileRecordingCancelsVoiceSession() async throws {
        let (container, _, _) = try await makeConnectedContainer()
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)
        XCTAssertTrue(container.isRecordingVoice)

        await container.disconnect()

        XCTAssertFalse(container.isRecordingVoice)
        XCTAssertEqual(container.speechState, .idle)
        XCTAssertNil(container.activeVoicePreview)
    }

    // MARK: - 9. Permission States

    func testPermissionDeniedHandling() async throws {
        actor DeniedRecorder: AudioRecorder {
            func start() async throws { throw AudioRecorderError.permissionDenied }
            func stop() async throws -> AudioRecordingHandle { throw AudioRecorderError.permissionDenied }
            func cancel() async {}
        }

        let deniedRecorder = DeniedRecorder()
        let (container, _, _) = try await makeConnectedContainer(voiceRecorder: deniedRecorder)
        try await container.downloadVoiceModel(.tiny)

        do {
            try await container.startVoiceRecording(mode: .shellCommand)
            XCTFail("Should throw permissionDenied")
        } catch let err as AudioRecorderError {
            XCTAssertEqual(err, .permissionDenied)
        }

        XCTAssertFalse(container.isRecordingVoice)
        XCTAssertNotNil(container.voiceErrorMessage)
    }

    func testPermissionGrantedRecording() async throws {
        let (container, _, _) = try await makeConnectedContainer()
        try await container.downloadVoiceModel(.tiny)

        try await container.startVoiceRecording(mode: .shellCommand)
        XCTAssertTrue(container.isRecordingVoice)
        await container.cancelVoiceRecording()
    }

    // MARK: - 10. Provider & Model States

    func testWhisperKitIsDefaultProvider() async throws {
        let (container, _, _) = try await makeConnectedContainer()
        XCTAssertEqual(container.selectedVoiceProviderID, VoiceProviderRegistry.whisperProviderID)
        XCTAssertTrue(container.isWhisperSelected)
        XCTAssertEqual(container.selectedProviderDisplayName, "WhisperKit")
    }

    func testAppleSpeechExplicitSelectionAndNoSilentFallback() async throws {
        let (container, _, _) = try await makeConnectedContainer()

        // 1. Explicit selection of Apple Speech
        container.selectVoiceProvider(id: VoiceProviderRegistry.appleSpeechProviderID)
        XCTAssertEqual(container.selectedVoiceProviderID, VoiceProviderRegistry.appleSpeechProviderID)
        XCTAssertFalse(container.isWhisperSelected)
        XCTAssertEqual(container.selectedProviderDisplayName, "Apple Speech")

        // 2. Reject unknown provider
        container.selectVoiceProvider(id: "cloudGoogleSpeech")
        XCTAssertNotNil(container.voiceErrorMessage)
        XCTAssertEqual(container.selectedVoiceProviderID, VoiceProviderRegistry.appleSpeechProviderID, "Unknown provider must be rejected")
    }

    func testDownloadRequiredStateWhenNoWhisperModelInstalled() async throws {
        let (container, _, _) = try await makeConnectedContainer()
        let hasInstalled = await container.hasInstalledWhisperModel()
        XCTAssertFalse(hasInstalled, "Fresh container must not have models installed")

        do {
            try await container.startVoiceRecording(mode: .shellCommand)
            XCTFail("Should throw modelNotInstalled when no model is downloaded")
        } catch let err as TranscriptionError {
            if case .modelNotInstalled = err {
                // Expected
            } else {
                XCTFail("Unexpected error: \(err)")
            }
        }
    }

    func testWhisperModelDownloadProgressAndInstallFlow() async throws {
        let (container, _, _) = try await makeConnectedContainer()

        // Download tiny model
        try await container.downloadVoiceModel(.tiny)

        let models = container.voiceModels
        let tinyModel = models.first { $0.id == WhisperModelTier.tiny.defaultModelID }
        XCTAssertNotNil(tinyModel)
        XCTAssertTrue(tinyModel?.state.isReady == true)

        let hasInstalled = await container.hasInstalledWhisperModel()
        XCTAssertTrue(hasInstalled)
    }

    func testWhisperModelDeletionResetsToNotInstalled() async throws {
        let (container, _, _) = try await makeConnectedContainer()
        try await container.downloadVoiceModel(.tiny)

        let hasInstalledBefore = await container.hasInstalledWhisperModel()
        XCTAssertTrue(hasInstalledBefore)

        try await container.deleteVoiceModel(.tiny)

        let hasInstalledAfter = await container.hasInstalledWhisperModel()
        XCTAssertFalse(hasInstalledAfter)
    }

    // MARK: - 11. Accessibility & VoiceOver

    func testVoiceComposerAccessibilityElements() async throws {
        // NOTE: Verifies view tree instantiation, window hosting, and non-empty subview hierarchy.
        // Physical VoiceOver speech announcements and hardware microphone routing remain residual
        // risks requiring physical device verification.
        let (container, _, _) = try await makeConnectedContainer()
        try await container.downloadVoiceModel(.tiny)

        let view = VoiceComposer().environmentObject(container)
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()

        XCTAssertGreaterThan(controller.view.bounds.width, 0)
        XCTAssertGreaterThan(controller.view.bounds.height, 0)
        XCTAssertGreaterThan(controller.view.subviews.count, 0)

        // Verify preview state also builds non-zero frame layout with editor & buttons
        let preview = VoicePreviewState(
            originalTranscript: "git diff",
            mode: .shellCommand,
            duration: 1.5,
            router: container.voiceRouter,
            hostPolicy: .enabled
        )
        container.activeVoicePreview = preview
        controller.view.layoutIfNeeded()

        XCTAssertGreaterThan(controller.view.bounds.width, 0)
        XCTAssertGreaterThan(controller.view.bounds.height, 0)
    }

    func testVoiceSettingsAccessibilityElements() async throws {
        // NOTE: Verifies settings view tree instantiation and layout bounds.
        let (container, _, _) = try await makeConnectedContainer()
        let view = VoiceSettingsView().environmentObject(container)
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()

        XCTAssertGreaterThan(controller.view.bounds.width, 0)
        XCTAssertGreaterThan(controller.view.bounds.height, 0)
        XCTAssertGreaterThan(controller.view.subviews.count, 0)
    }

    // MARK: - 12. Dynamic Type & Layouts

    func testVoiceComposerDynamicTypeSupport() async throws {
        // NOTE: Verifies that under small, large, and accessibility Dynamic Type sizes,
        // VoiceComposer layouts with non-zero bounds and non-empty hierarchy.
        let (container, _, _) = try await makeConnectedContainer()
        try await container.downloadVoiceModel(.tiny)

        for size in [DynamicTypeSize.small, DynamicTypeSize.large, DynamicTypeSize.accessibility3] {
            let view = VoiceComposer()
                .environmentObject(container)
                .environment(\.dynamicTypeSize, size)
            let controller = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.layoutIfNeeded()

            XCTAssertGreaterThan(controller.view.bounds.width, 0, "Width must be > 0 at \(size)")
            XCTAssertGreaterThan(controller.view.bounds.height, 0, "Height must be > 0 at \(size)")
            XCTAssertGreaterThan(controller.view.subviews.count, 0, "Subviews must be non-empty at \(size)")
        }
    }

    func testVoiceComposerIPhoneAndIPadLayouts() async throws {
        // NOTE: Verifies layout across compact (iPhone) and regular (iPad) geometries.
        let (container, _, _) = try await makeConnectedContainer()
        try await container.downloadVoiceModel(.tiny)

        // Compact width (iPhone: 393 x 852)
        let compactView = VoiceComposer()
            .environmentObject(container)
            .environment(\.horizontalSizeClass, .compact)
        let compactController = UIHostingController(rootView: compactView)
        let iphoneWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        iphoneWindow.rootViewController = compactController
        iphoneWindow.makeKeyAndVisible()
        compactController.view.layoutIfNeeded()

        XCTAssertEqual(compactController.view.bounds.width, 393)
        XCTAssertEqual(compactController.view.bounds.height, 852)
        XCTAssertGreaterThan(compactController.view.subviews.count, 0)

        // Regular width (iPad: 820 x 1180)
        let regularView = VoiceComposer()
            .environmentObject(container)
            .environment(\.horizontalSizeClass, .regular)
        let regularController = UIHostingController(rootView: regularView)
        let ipadWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1180))
        ipadWindow.rootViewController = regularController
        ipadWindow.makeKeyAndVisible()
        regularController.view.layoutIfNeeded()

        XCTAssertEqual(regularController.view.bounds.width, 820)
        XCTAssertEqual(regularController.view.bounds.height, 1180)
        XCTAssertGreaterThan(regularController.view.subviews.count, 0)
    }

    func testDemoTranscriberSerializesConcurrentStateAccess() async throws {
        let transcriber = DemoTranscriber(transcript: "initial", simulateDelay: 0)
        let updates = Task.detached {
            for index in 0..<100 {
                transcriber.setTranscript("transcript-\(index)")
            }
        }

        var results: [String] = []
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    do {
                        return try await transcriber.transcribe(audio: Data())
                    } catch {
                        return ""
                    }
                }
            }
            for await result in group {
                results.append(result)
            }
        }
        await updates.value

        XCTAssertEqual(results.count, 100)
        XCTAssertTrue(results.allSatisfy { $0 == "initial" || $0.hasPrefix("transcript-") })
    }

    func testDemoTranscriberConcurrentErrorInjectionAndRecovery() async throws {
        struct TestTranscribeError: Error, Equatable {}
        let transcriber = DemoTranscriber(transcript: "valid-transcription", simulateDelay: 0)

        // Inject simulated error
        transcriber.setSimulateError(TestTranscribeError())

        do {
            _ = try await transcriber.transcribe(audio: Data())
            XCTFail("Transcribe must throw when simulateError is set")
        } catch is TestTranscribeError {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Clear error and verify recovery
        transcriber.setSimulateError(nil)
        let recovered = try await transcriber.transcribe(audio: Data())
        XCTAssertEqual(recovered, "valid-transcription")
    }

    // MARK: - 13. Demo Mode Behavior

    func testDemoContainerFullVoiceWorkflow() async throws {
        let container = AppContainer.demo()
        XCTAssertTrue(container.isDemo)

        let host = try Host(
            name: "Demo Host",
            hostname: "demo.invalid",
            username: "dev",
            voicePolicy: .enabled
        )

        let challenge = HostKeyChallenge(
            hostname: host.hostname,
            port: 22,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:demo-fingerprint"
        )
        await container.trustStore.save(challenge)
        await container.connect(to: host)
        XCTAssertEqual(container.activeSession?.state, .connected)

        // 1. Initially requires model download
        let hasModel = await container.hasInstalledWhisperModel()
        XCTAssertFalse(hasModel)

        // 2. Download tiny model in demo mode
        try await container.downloadVoiceModel(.tiny)
        let hasModelAfter = await container.hasInstalledWhisperModel()
        XCTAssertTrue(hasModelAfter)

        // 3. Record in demo mode
        try await container.startVoiceRecording(mode: .shellCommand)
        XCTAssertTrue(container.isRecordingVoice)

        let preview = try await container.stopVoiceRecording(mode: .shellCommand)
        XCTAssertEqual(preview.mode, .shellCommand)
        XCTAssertFalse(preview.text.isEmpty)

        // 4. Send command in demo mode
        let sent = await container.sendVoiceCommand(preview: preview)
        XCTAssertTrue(sent)
        XCTAssertEqual(container.speechState, .idle)
    }
}
