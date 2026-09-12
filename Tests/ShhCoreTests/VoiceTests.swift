import XCTest
@testable import ShhCore

final class VoiceTests: XCTestCase {

    // MARK: - Mock Helpers

    actor MockAudioRecorder: AudioRecorder {
        var startCallCount = 0
        var stopCallCount = 0
        var cancelCallCount = 0
        var handleToReturn: AudioRecordingHandle?
        var errorToThrowOnStart: Error?
        var errorToThrowOnStop: Error?

        func setHandleToReturn(_ handle: AudioRecordingHandle?) {
            self.handleToReturn = handle
        }

        func setErrorToThrowOnStart(_ error: Error?) {
            self.errorToThrowOnStart = error
        }

        func setErrorToThrowOnStop(_ error: Error?) {
            self.errorToThrowOnStop = error
        }

        func start() async throws {
            startCallCount += 1
            if let err = errorToThrowOnStart { throw err }
        }

        func stop() async throws -> AudioRecordingHandle {
            stopCallCount += 1
            if let err = errorToThrowOnStop { throw err }
            if let handle = handleToReturn { return handle }
            return try AudioRecordingHandle.createTemporary()
        }

        func cancel() async {
            cancelCallCount += 1
        }
    }

    actor MockTranscriber: LocalTranscriber {
        var textToReturn: String = "echo hello"
        var errorToThrow: Error?
        var delaySeconds: TimeInterval = 0
        var recordedFractions: [Double] = []

        func setTextToReturn(_ text: String) {
            self.textToReturn = text
        }

        func setErrorToThrow(_ error: Error?) {
            self.errorToThrow = error
        }

        func setDelaySeconds(_ delay: TimeInterval) {
            self.delaySeconds = delay
        }

        func transcribe(
            recording: AudioRecordingHandle,
            progress: (@Sendable (Double) -> Void)?
        ) async throws -> String {
            if delaySeconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            if let errorToThrow { throw errorToThrow }
            progress?(0.5)
            recordedFractions.append(0.5)
            progress?(1.0)
            recordedFractions.append(1.0)
            return textToReturn
        }

        func transcribe(audio: Data) async throws -> String {
            if let errorToThrow { throw errorToThrow }
            return textToReturn
        }
    }

    actor ProgressRecorder {
        var values: [Double] = []
        func record(_ value: Double) {
            values.append(value)
        }
    }

    // MARK: - 1. State Transitions

    func testSpeechComposerStateTransitions() {
        var state: SpeechComposerState = .idle
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertNil(state.previewState)
        XCTAssertNil(state.previewText)

        state = .recording
        XCTAssertTrue(state.isRecording)
        XCTAssertFalse(state.isTranscribing)

        state = .recordingWithDuration(3.5)
        XCTAssertTrue(state.isRecording)

        state = .transcribing
        XCTAssertFalse(state.isRecording)
        XCTAssertTrue(state.isTranscribing)

        state = .transcribingWithProgress(fractionCompleted: 0.85)
        XCTAssertTrue(state.isTranscribing)

        let preview = VoicePreviewState(originalTranscript: "ls -la")
        state = .preview(preview)
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isTranscribing)
        XCTAssertEqual(state.previewText, "ls -la")
        XCTAssertEqual(state.previewState?.decision, .manualSendRequired(command: "ls -la"))

        state = .cancelled
        XCTAssertFalse(state.isRecording)

        state = .unavailable
        XCTAssertEqual(state, .unavailable)

        state = .unavailableWithReason("Microphone disabled")
        XCTAssertEqual(state, .unavailableWithReason("Microphone disabled"))

        state = .failed(.cancelled)
        XCTAssertEqual(state, .failed(.cancelled))

        // Backward compatibility factory method
        let compatState = SpeechComposerState.preview(text: "uname -a")
        XCTAssertEqual(compatState.previewText, "uname -a")
    }

    func testVoiceModelStateTransitions() {
        var modelState: VoiceModelState = .notInstalled
        XCTAssertFalse(modelState.isReady)

        modelState = .downloading(fractionCompleted: 0.45)
        XCTAssertFalse(modelState.isReady)

        let date = Date()
        modelState = .installed(installedAt: date)
        XCTAssertTrue(modelState.isReady)

        modelState = .degraded(reason: "Low disk space")
        XCTAssertFalse(modelState.isReady)

        modelState = .unavailable(reason: "Network offline")
        XCTAssertFalse(modelState.isReady)
    }

    func testVoiceProviderStateTransitions() {
        var providerState: VoiceProviderState = .uninitialized
        XCTAssertFalse(providerState.isReady)

        providerState = .ready
        XCTAssertTrue(providerState.isReady)

        providerState = .busy
        XCTAssertFalse(providerState.isReady)

        providerState = .unavailable(reason: "Whisper framework not linked")
        XCTAssertFalse(providerState.isReady)

        providerState = .failed(.modelUnavailable)
        XCTAssertFalse(providerState.isReady)
    }

    func testVoiceSessionCoordinatorHappyPathLifecycle() async throws {
        let recorder = MockAudioRecorder()
        let transcriber = MockTranscriber()
        await transcriber.setTextToReturn("git status")
        let coordinator = VoiceSessionCoordinator(recorder: recorder, transcriber: transcriber)

        let host = try Host(name: "TestBox", hostname: "box.invalid", username: "dev", voicePolicy: .enabled)

        let initialState = await coordinator.state
        XCTAssertEqual(initialState, .idle)

        // 1. Start recording
        try await coordinator.startRecording(host: host, mode: .shellCommand)
        let recordingState = await coordinator.state
        XCTAssertEqual(recordingState, .recording)
        let startCalls = await recorder.startCallCount
        XCTAssertEqual(startCalls, 1)

        // 2. Stop recording and transcribe
        let progressRecorder = ProgressRecorder()
        let preview = try await coordinator.stopRecordingAndTranscribe(host: host, mode: .shellCommand) { fraction in
            Task {
                await progressRecorder.record(fraction)
            }
        }

        let stopCalls = await recorder.stopCallCount
        XCTAssertEqual(stopCalls, 1)
        XCTAssertEqual(preview.originalTranscript, "git status")
        XCTAssertEqual(preview.text, "git status")
        XCTAssertEqual(preview.decision, .manualSendRequired(command: "git status"))
        XCTAssertFalse(preview.isEdited)

        let finalState = await coordinator.state
        XCTAssertEqual(finalState.previewText, "git status")

        // 3. Reset
        await coordinator.reset()
        let resetState = await coordinator.state
        XCTAssertEqual(resetState, .idle)
    }

    // MARK: - 2. Mode Routing & No Auto-Execution Invariant

    func testShellCommandRouting() throws {
        let router = VoiceCommandRouter()
        let policy = HostVoicePolicy.enabled

        // Safe commands require manual send, NEVER auto-execute
        let safe1 = router.route(transcript: "ls -la", mode: .shellCommand, hostPolicy: policy)
        XCTAssertEqual(safe1, .manualSendRequired(command: "ls -la"))
        XCTAssertFalse(safe1.allowsAutomaticExecution)
        XCTAssertTrue(safe1.requiresManualAction)

        let safe2 = router.route(transcript: "git status", mode: .shellCommand, hostPolicy: policy)
        XCTAssertEqual(safe2, .manualSendRequired(command: "git status"))
        XCTAssertFalse(safe2.allowsAutomaticExecution)

        // Review-required commands
        let review1 = router.route(transcript: "reboot", mode: .shellCommand, hostPolicy: policy)
        XCTAssertEqual(review1, .reviewRequired(command: "reboot"))
        XCTAssertFalse(review1.allowsAutomaticExecution)
        XCTAssertTrue(review1.requiresReview)

        let review2 = router.route(transcript: "rm notes.txt", mode: .shellCommand, hostPolicy: policy)
        XCTAssertEqual(review2, .reviewRequired(command: "rm notes.txt"))
        XCTAssertFalse(review2.allowsAutomaticExecution)

        let review3 = router.route(transcript: "cat file | grep pattern", mode: .shellCommand, hostPolicy: policy)
        XCTAssertEqual(review3, .reviewRequired(command: "cat file | grep pattern"))
        XCTAssertFalse(review3.allowsAutomaticExecution)

        // Blocked destructive commands
        let blocked1 = router.route(transcript: "rm -rf /", mode: .shellCommand, hostPolicy: policy)
        XCTAssertEqual(blocked1, .blocked(reason: "Command is blocked by safety policy"))
        XCTAssertFalse(blocked1.allowsAutomaticExecution)
        XCTAssertTrue(blocked1.isBlocked)

        let blocked2 = router.route(transcript: ":(){ :|:& };:", mode: .shellCommand, hostPolicy: policy)
        XCTAssertEqual(blocked2, .blocked(reason: "Command is blocked by safety policy"))
        XCTAssertTrue(blocked2.isBlocked)

        let blocked3 = router.route(transcript: "tmux kill-server", mode: .shellCommand, hostPolicy: policy)
        XCTAssertEqual(blocked3, .blocked(reason: "Command is blocked by safety policy"))
        XCTAssertTrue(blocked3.isBlocked)
    }

    func testInsertOnlyRoutingNeverExecutes() {
        let router = VoiceCommandRouter()
        let policy = HostVoicePolicy.enabled

        // Normal text
        let insert1 = router.route(transcript: "def calculate_total():", mode: .insertOnly, hostPolicy: policy)
        XCTAssertEqual(insert1, .insertPendingConfirmation(text: "def calculate_total():"))
        XCTAssertFalse(insert1.allowsAutomaticExecution)
        XCTAssertTrue(insert1.requiresManualAction)

        // Text that would be dangerous shell commands is preserved as raw text insertion, NOT blocked or run
        let dangerousText = "rm -rf / && reboot"
        let insert2 = router.route(transcript: dangerousText, mode: .insertOnly, hostPolicy: policy)
        XCTAssertEqual(insert2, .insertPendingConfirmation(text: dangerousText))
        XCTAssertFalse(insert2.allowsAutomaticExecution)
        XCTAssertFalse(insert2.isBlocked)
    }

    func testAgentMessageRoutingNeverExecutesShell() {
        let router = VoiceCommandRouter()
        let policy = HostVoicePolicy.enabled

        // Normal prompt
        let prompt = "Explain the failing test in ReconnectCoordinator"
        let decision1 = router.route(transcript: prompt, mode: .agentMessage, hostPolicy: policy)
        XCTAssertEqual(decision1, .agentDispatchPendingConfirmation(message: prompt))
        XCTAssertFalse(decision1.allowsAutomaticExecution)
        XCTAssertTrue(decision1.requiresManualAction)

        // Shell-like text in agentMessage mode is staged for agent dispatch, NOT executed in shell
        let shellPrompt = "run tests for me"
        let decision2 = router.route(transcript: shellPrompt, mode: .agentMessage, hostPolicy: policy)
        XCTAssertEqual(decision2, .agentDispatchPendingConfirmation(message: shellPrompt))
        XCTAssertFalse(decision2.allowsAutomaticExecution)
    }

    func testEmptyTranscriptRoutingIsRejected() {
        let router = VoiceCommandRouter()
        let policy = HostVoicePolicy.enabled

        let emptyDecision = router.route(transcript: "", mode: .shellCommand, hostPolicy: policy)
        XCTAssertEqual(emptyDecision, .rejected(reason: "Voice transcript is empty"))
        XCTAssertFalse(emptyDecision.allowsAutomaticExecution)
        XCTAssertTrue(emptyDecision.isRejected)

        let whitespaceDecision = router.route(transcript: "   \n\t  ", mode: .insertOnly, hostPolicy: policy)
        XCTAssertEqual(whitespaceDecision, .rejected(reason: "Voice transcript is empty"))
    }

    func testAllRoutingDecisionsForbidAutoExecution() {
        // Exhaustive assertion: No case of VoiceRoutingDecision ever allows automatic execution
        let decisions: [VoiceRoutingDecision] = [
            .blocked(reason: "Safety"),
            .reviewRequired(command: "reboot"),
            .manualSendRequired(command: "ls"),
            .insertPendingConfirmation(text: "hello"),
            .agentDispatchPendingConfirmation(message: "help"),
            .rejected(reason: "Disabled")
        ]

        for decision in decisions {
            XCTAssertFalse(
                decision.allowsAutomaticExecution,
                "Invariant violated: Decision \(decision) must not allow automatic execution"
            )
        }
    }

    // MARK: - 3. Production Policy & Host Enforcement

    func testDisabledHostVoicePolicyRejectsRoutingAndStart() async throws {
        let router = VoiceCommandRouter()
        let disabledPolicy = HostVoicePolicy.disabled

        let decision = router.route(transcript: "ls -la", mode: .shellCommand, hostPolicy: disabledPolicy)
        XCTAssertEqual(decision, .rejected(reason: "Voice input is disabled for this host"))
        XCTAssertFalse(decision.allowsAutomaticExecution)
        XCTAssertTrue(decision.isRejected)

        // Test coordinator rejects startRecording immediately before touching microphone
        let recorder = MockAudioRecorder()
        let transcriber = MockTranscriber()
        let coordinator = VoiceSessionCoordinator(recorder: recorder, transcriber: transcriber)

        let host = try Host(name: "Prod Host", hostname: "prod.invalid", username: "root", voicePolicy: .disabled)
        XCTAssertFalse(host.isVoiceEnabled)

        do {
            try await coordinator.startRecording(host: host, mode: .shellCommand)
            XCTFail("startRecording should have thrown on disabled host")
        } catch let err as TranscriptionError {
            XCTAssertEqual(err, .hostPolicyDisabled(hostID: host.id))
        }

        let startCalls = await recorder.startCallCount
        XCTAssertEqual(startCalls, 0, "Microphone must never be engaged when host voice policy is disabled")
        let state = await coordinator.state
        XCTAssertEqual(state, .failed(.hostPolicyDisabled(hostID: host.id)))
    }

    func testHostPolicyRestrictedModes() async throws {
        let router = VoiceCommandRouter()
        // Allow insertOnly ONLY
        let restrictedPolicy = HostVoicePolicy(isEnabled: true, allowedModes: [.insertOnly])

        // insertOnly is permitted
        let insertDecision = router.route(transcript: "echo hello", mode: .insertOnly, hostPolicy: restrictedPolicy)
        XCTAssertEqual(insertDecision, .insertPendingConfirmation(text: "echo hello"))

        // shellCommand is rejected
        let shellDecision = router.route(transcript: "echo hello", mode: .shellCommand, hostPolicy: restrictedPolicy)
        XCTAssertEqual(shellDecision, .rejected(reason: "Voice mode 'shellCommand' is not permitted by host policy"))

        // agentMessage is rejected
        let agentDecision = router.route(transcript: "help", mode: .agentMessage, hostPolicy: restrictedPolicy)
        XCTAssertEqual(agentDecision, .rejected(reason: "Voice mode 'agentMessage' is not permitted by host policy"))

        // Coordinator rejects starting in forbidden mode
        let recorder = MockAudioRecorder()
        let coordinator = VoiceSessionCoordinator(recorder: recorder)
        let host = try Host(name: "Restricted", hostname: "res.invalid", username: "dev", voicePolicy: restrictedPolicy)

        do {
            try await coordinator.startRecording(host: host, mode: .shellCommand)
            XCTFail("Should reject start in shellCommand mode")
        } catch let err as TranscriptionError {
            if case .transcriptionFailed(let reason) = err {
                XCTAssertTrue(reason.contains("shellCommand"))
            } else {
                XCTFail("Unexpected error: \(err)")
            }
        }
        let startCalls = await recorder.startCallCount
        XCTAssertEqual(startCalls, 0)
    }

    // MARK: - 4. Cancellation & File Cleanup

    func testCancelDuringRecordingCleansUp() async throws {
        let recorder = MockAudioRecorder()
        let coordinator = VoiceSessionCoordinator(recorder: recorder)
        let host = try Host(name: "Box", hostname: "b.invalid", username: "dev", voicePolicy: .enabled)

        try await coordinator.startRecording(host: host, mode: .shellCommand)
        let recState = await coordinator.state
        XCTAssertEqual(recState, .recording)

        await coordinator.cancel()
        let cancelCalls = await recorder.cancelCallCount
        XCTAssertEqual(cancelCalls, 1)
        let cancelState = await coordinator.state
        XCTAssertEqual(cancelState, .cancelled)
    }

    func testCancelDuringTranscribingCleansUpTemporaryFile() async throws {
        let recorder = MockAudioRecorder()
        let tempHandle = try AudioRecordingHandle.createTemporary()
        await recorder.setHandleToReturn(tempHandle)
        try Data("dummy audio".utf8).write(to: tempHandle.fileURL)
        XCTAssertTrue(tempHandle.exists)

        let transcriber = MockTranscriber()
        await transcriber.setDelaySeconds(0.5) // Long enough to cancel mid-flight

        let coordinator = VoiceSessionCoordinator(recorder: recorder, transcriber: transcriber)
        let host = try Host(name: "Box", hostname: "b.invalid", username: "dev", voicePolicy: .enabled)

        try await coordinator.startRecording(host: host, mode: .shellCommand)

        let task = Task {
            try await coordinator.stopRecordingAndTranscribe(host: host, mode: .shellCommand)
        }

        // Give it a moment to enter transcribing
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await coordinator.cancel()

        do {
            _ = try await task.value
            XCTFail("Task should throw cancelled error")
        } catch {
            // Expected cancellation error
        }

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .cancelled)
        XCTAssertFalse(tempHandle.exists, "Temporary audio recording file must be cleaned up on cancellation")
    }

    func testWithTemporaryHandleGuaranteesCleanupOnThrow() async {
        var recordedURL: URL?
        do {
            try await AudioRecordingHandle.withTemporaryHandle { handle in
                recordedURL = handle.url
                XCTAssertTrue(handle.exists)
                throw AudioRecorderError.captureFailed(reason: "intentional error")
            }
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        if let recordedURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: recordedURL.path), "File must be cleaned up even if body throws")
        }
    }

    // MARK: - 5. Audio Recording Handle Security & Operations

    func testAudioRecordingHandleSecurePermissionsAndOperations() throws {
        let handle = try AudioRecordingHandle.createTemporary(fileExtension: "m4a")
        XCTAssertTrue(handle.exists)
        XCTAssertEqual(handle.url, handle.fileURL)

        // Verify POSIX permissions 0600 (owner read/write only)
        let attrs = try FileManager.default.attributesOfItem(atPath: handle.url.path)
        let posixPerms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(posixPerms?.intValue, 0o600, "Secure temporary recording handle must have 0600 permissions")

        // Write test data
        let testBytes = Data("test-audio-content".utf8)
        try testBytes.write(to: handle.fileURL)

        XCTAssertEqual(handle.sizeBytes, Int64(testBytes.count))
        let readBack = try handle.readData()
        XCTAssertEqual(readBack, testBytes)

        // Deletion
        try handle.delete()
        XCTAssertFalse(handle.exists)
        XCTAssertNil(handle.sizeBytes)

        // Multiple delete calls should not throw
        XCTAssertNoThrow(try handle.delete())
        XCTAssertNoThrow(handle.cleanup())
    }

    // MARK: - 6. Codable Backward Compatibility

    func testLegacyHostJSONDecodingDefaultsVoiceToDisabled() throws {
        // 1. Raw JSON without voicePolicy key
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Production Database",
            "hostname": "db.internal.corp",
            "port": 22,
            "username": "postgres"
        }
        """

        let decoder = JSONDecoder()
        let host = try decoder.decode(Host.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(host.name, "Production Database")
        XCTAssertEqual(host.hostname, "db.internal.corp")
        XCTAssertEqual(host.voicePolicy, .disabled, "No host silently enables voice after decoding old data")
        XCTAssertFalse(host.isVoiceEnabled)
        XCTAssertTrue(host.voicePolicy.allowedModes.isEmpty)

        // 2. Encoded full Host with voicePolicy explicitly stripped from JSON payload
        let original = try Host(
            name: "Stripped Host",
            hostname: "legacy.internal",
            username: "admin",
            voicePolicy: .enabled
        )
        let encoded = try JSONEncoder().encode(original)
        var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        jsonObject.removeValue(forKey: "voicePolicy")

        let strippedData = try JSONSerialization.data(withJSONObject: jsonObject)
        let decodedStripped = try decoder.decode(Host.self, from: strippedData)
        XCTAssertEqual(decodedStripped.name, "Stripped Host")
        XCTAssertEqual(decodedStripped.voicePolicy, .disabled, "Stripped payload must decode to disabled voice policy")
        XCTAssertFalse(decodedStripped.isVoiceEnabled)
    }

    func testHostDecodingWithBooleanVoicePolicy() throws {
        let jsonEnabled = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Enabled Host",
            "hostname": "box.invalid",
            "port": 22,
            "username": "user",
            "voicePolicy": true
        }
        """
        let hostEnabled = try JSONDecoder().decode(Host.self, from: Data(jsonEnabled.utf8))
        XCTAssertTrue(hostEnabled.isVoiceEnabled)
        XCTAssertEqual(hostEnabled.voicePolicy.allowedModes, Set(VoiceInputMode.allCases))

        let jsonDisabled = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Disabled Host",
            "hostname": "box.invalid",
            "port": 22,
            "username": "user",
            "voicePolicy": false
        }
        """
        let hostDisabled = try JSONDecoder().decode(Host.self, from: Data(jsonDisabled.utf8))
        XCTAssertFalse(hostDisabled.isVoiceEnabled)
        XCTAssertTrue(hostDisabled.voicePolicy.allowedModes.isEmpty)
    }

    func testHostDecodingWithStringVoicePolicy() throws {
        let jsonEnabled = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Enabled Host",
            "hostname": "box.invalid",
            "port": 22,
            "username": "user",
            "voicePolicy": "enabled"
        }
        """
        let hostEnabled = try JSONDecoder().decode(Host.self, from: Data(jsonEnabled.utf8))
        XCTAssertTrue(hostEnabled.isVoiceEnabled)

        let jsonDisabled = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Disabled Host",
            "hostname": "box.invalid",
            "port": 22,
            "username": "user",
            "voicePolicy": "disabled"
        }
        """
        let hostDisabled = try JSONDecoder().decode(Host.self, from: Data(jsonDisabled.utf8))
        XCTAssertFalse(hostDisabled.isVoiceEnabled)
    }

    func testHostDecodingWithStructuredVoicePolicy() throws {
        let jsonStructured = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Structured Host",
            "hostname": "box.invalid",
            "port": 22,
            "username": "user",
            "voicePolicy": {
                "isEnabled": true,
                "allowedModes": ["shellCommand", "insertOnly"]
            }
        }
        """
        let host = try JSONDecoder().decode(Host.self, from: Data(jsonStructured.utf8))
        XCTAssertTrue(host.isVoiceEnabled)
        XCTAssertEqual(host.voicePolicy.allowedModes, [.shellCommand, .insertOnly])
        XCTAssertTrue(host.voicePolicy.allows(mode: .shellCommand))
        XCTAssertTrue(host.voicePolicy.allows(mode: .insertOnly))
        XCTAssertFalse(host.voicePolicy.allows(mode: .agentMessage))
    }

    func testHostVoicePolicyRoundTrip() throws {
        let host = try Host(
            name: "RoundTrip",
            hostname: "rt.invalid",
            username: "admin",
            voicePolicy: HostVoicePolicy(isEnabled: true, allowedModes: [.shellCommand])
        )

        let encoded = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(Host.self, from: encoded)

        XCTAssertEqual(decoded.name, "RoundTrip")
        XCTAssertEqual(decoded.voicePolicy, host.voicePolicy)
        XCTAssertTrue(decoded.isVoiceEnabled)
        XCTAssertEqual(decoded.voicePolicy.allowedModes, [.shellCommand])
    }

    func testVoiceDescriptorsAndStatesCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // 1. VoicePreviewState
        let preview = VoicePreviewState(
            originalTranscript: "echo test",
            text: "echo test modified",
            mode: .shellCommand,
            decision: .manualSendRequired(command: "echo test modified"),
            duration: 2.4
        )
        let previewData = try encoder.encode(preview)
        let decodedPreview = try decoder.decode(VoicePreviewState.self, from: previewData)
        XCTAssertEqual(decodedPreview.originalTranscript, preview.originalTranscript)
        XCTAssertEqual(decodedPreview.text, preview.text)
        XCTAssertEqual(decodedPreview.mode, preview.mode)
        XCTAssertEqual(decodedPreview.decision, preview.decision)
        XCTAssertEqual(decodedPreview.duration, preview.duration)
        XCTAssertTrue(decodedPreview.isEdited)

        // 2. VoiceModelDescriptor
        let model = VoiceModelDescriptor(
            id: "whisper.base.en",
            providerID: "local.whisper",
            name: "Whisper Base English",
            sizeBytes: 142_000_000,
            state: .installed(installedAt: Date(timeIntervalSince1970: 1700000000)),
            supportedLanguages: ["en"]
        )
        let modelData = try encoder.encode(model)
        let decodedModel = try decoder.decode(VoiceModelDescriptor.self, from: modelData)
        XCTAssertEqual(decodedModel.id, model.id)
        XCTAssertEqual(decodedModel.sizeBytes, model.sizeBytes)
        XCTAssertEqual(decodedModel.state, model.state)

        // 3. VoiceProviderDescriptor
        let provider = VoiceProviderDescriptor(
            id: "local.whisper",
            name: "Whisper On-Device",
            kind: .localWhisper,
            supportedModes: [.shellCommand, .insertOnly, .agentMessage],
            isAvailable: true,
            isLocalOnly: true,
            providerDescription: "Local quantized whisper model"
        )
        let providerData = try encoder.encode(provider)
        let decodedProvider = try decoder.decode(VoiceProviderDescriptor.self, from: providerData)
        XCTAssertEqual(decodedProvider.id, provider.id)
        XCTAssertEqual(decodedProvider.kind, provider.kind)
        XCTAssertEqual(decodedProvider.supportedModes, provider.supportedModes)

        // 4. VoiceProgress
        let progress = VoiceProgress(phase: .transcribing, fractionCompleted: 0.65, message: "Processing audio")
        let progressData = try encoder.encode(progress)
        let decodedProgress = try decoder.decode(VoiceProgress.self, from: progressData)
        XCTAssertEqual(decodedProgress, progress)
    }

    // MARK: - 7. Preview Editing & Recalculation

    func testVoicePreviewStateEditingRecalculatesDecision() {
        var preview = VoicePreviewState(originalTranscript: "ls -la", mode: .shellCommand)
        XCTAssertEqual(preview.decision, .manualSendRequired(command: "ls -la"))
        XCTAssertFalse(preview.isEdited)

        // Edit from safe command to dangerous command
        preview.updateText("rm -rf /")
        XCTAssertTrue(preview.isEdited)
        XCTAssertEqual(preview.decision, .blocked(reason: "Command is blocked by safety policy"))

        // Edit to risky command
        preview.updateText("reboot")
        XCTAssertEqual(preview.decision, .reviewRequired(command: "reboot"))

        // Switch mode to insertOnly
        preview.updateMode(.insertOnly)
        XCTAssertEqual(preview.decision, .insertPendingConfirmation(text: "reboot"))

        // Switch mode to agentMessage
        preview.updateMode(.agentMessage)
        XCTAssertEqual(preview.decision, .agentDispatchPendingConfirmation(message: "reboot"))
    }

    // MARK: - 8. Transcriber Protocol Default Bridging

    struct LegacyDataOnlyTranscriber: LocalTranscriber {
        func transcribe(audio: Data) async throws -> String {
            return "legacy-data: \(String(decoding: audio, as: UTF8.self))"
        }
    }

    struct HandleOnlyTranscriber: LocalTranscriber {
        func transcribe(
            recording: AudioRecordingHandle,
            progress: (@Sendable (Double) -> Void)?
        ) async throws -> String {
            let data = try recording.readData()
            return "handle-based: \(String(decoding: data, as: UTF8.self))"
        }
    }

    func testLegacyDataTranscriberBridgesFromHandle() async throws {
        let legacy = LegacyDataOnlyTranscriber()
        try await AudioRecordingHandle.withTemporaryHandle { handle in
            try Data("hello world".utf8).write(to: handle.fileURL)
            let result = try await legacy.transcribe(recording: handle)
            XCTAssertEqual(result, "legacy-data: hello world")
        }
    }

    func testHandleTranscriberBridgesFromData() async throws {
        let handleBased = HandleOnlyTranscriber()
        let result = try await handleBased.transcribe(audio: Data("from data buffer".utf8))
        XCTAssertEqual(result, "handle-based: from data buffer")
    }

    func testUnavailableImplementationsThrowModelUnavailable() async {
        let recorder = UnavailableAudioRecorder()
        do {
            try await recorder.start()
            XCTFail("Should throw modelUnavailable")
        } catch let err as TranscriptionError {
            XCTAssertEqual(err, .modelUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await recorder.stop()
            XCTFail("Should throw modelUnavailable")
        } catch let err as TranscriptionError {
            XCTAssertEqual(err, .modelUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let transcriber = UnavailableTranscriber()
        do {
            _ = try await transcriber.transcribe(audio: Data())
            XCTFail("Should throw modelUnavailable")
        } catch let err as TranscriptionError {
            XCTAssertEqual(err, .modelUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - 9. Rich Errors Coverage

    func testRichErrorCasesAndDescriptions() {
        let recorderErrors: [AudioRecorderError] = [
            .permissionDenied,
            .deviceUnavailable(reason: "No input found"),
            .alreadyRecording,
            .notRecording,
            .temporaryFileError(reason: "Disk full"),
            .captureFailed(reason: "Buffer overflow"),
            .recordingTooShort,
            .cancelled
        ]
        XCTAssertEqual(recorderErrors.count, 8)

        let hostID = UUID()
        let transcriptionErrors: [TranscriptionError] = [
            .modelUnavailable,
            .cancelled,
            .modelNotInstalled(modelID: "whisper.large"),
            .recorderError(.permissionDenied),
            .audioFileUnreadable(reason: "Missing file"),
            .unsupportedAudioFormat(reason: "Invalid sample rate"),
            .transcriptionFailed(reason: "Model crashed"),
            .hostPolicyDisabled(hostID: hostID),
            .timeout,
            .unsupported
        ]
        XCTAssertEqual(transcriptionErrors.count, 10)
    }
}
