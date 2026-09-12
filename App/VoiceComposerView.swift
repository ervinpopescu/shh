import SwiftUI
import ShhCore
import ShhTerminal
import ShhVoice

public struct VoiceComposer: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedMode: VoiceInputMode = .shellCommand
    @State private var previewText: String = ""
    @State private var isTouchingPTT: Bool = false
    @State private var isSlideToCancel: Bool = false
    @State private var recordingDuration: TimeInterval = 0.0
    @State private var recordingTimer: Timer? = nil
    @State private var showingApproval: Bool = false
    @State private var showingProductionConfirm: Bool = false
    @State private var hasInitialized = false
    @State private var isDownloadingModel: Bool = false
    @State private var downloadProgress: Double = 0.0
    @State private var startRecordingTask: Task<Void, Never>? = nil

    private var hasInstalledWhisper: Bool {
        container.voiceModels.contains { $0.state.isReady }
    }

    private var availableModes: [VoiceInputMode] {
        let allowed = container.activeHost?.voicePolicy.allowedModes ?? Set(VoiceInputMode.allCases)
        let filtered = VoiceInputMode.allCases.filter { allowed.contains($0) }
        return filtered.isEmpty ? VoiceInputMode.allCases : filtered
    }

    public init() {}

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Voice Command")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            cancelAndDismiss()
                        }
                        .accessibilityLabel("Dismiss voice composer")
                        .accessibilityIdentifier("voice-composer-cancel-button")
                    }
                }
                .sheet(isPresented: $showingApproval) {
                    ApprovalSheet(
                        command: (container.activeVoicePreview?.text ?? previewText).trimmingCharacters(in: .whitespacesAndNewlines),
                        onApproved: {
                            container.resetVoiceState()
                            dismiss()
                        }
                    )
                    .environmentObject(container)
                }
                .confirmationDialog(
                    "Confirm Production Agent Message",
                    isPresented: $showingProductionConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Send to Production", role: .destructive) {
                        Task {
                            if let preview = currentPreviewState {
                                let success = await container.sendAgentMessage(preview: preview, confirmedProduction: true)
                                if success { dismiss() }
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    if let host = container.activeHost {
                        Text("Host '\(host.name)' is a production host. Dispatching agent messages sends text directly to the remote shell followed by Enter.")
                    }
                }
                .task {
                    if !hasInitialized {
                        let allowed = container.activeHost?.voicePolicy.allowedModes ?? Set(VoiceInputMode.allCases)
                        if allowed.contains(container.defaultVoiceMode) {
                            selectedMode = container.defaultVoiceMode
                        } else if let firstAllowed = VoiceInputMode.allCases.first(where: { allowed.contains($0) }) {
                            selectedMode = firstAllowed
                        }
                        await container.refreshVoiceModels()
                        hasInitialized = true
                    }
                }
                .onDisappear {
                    cleanupOnExit()
                }
        }
        .editorSheetPresentation(detents: [.medium, .large])
    }

    // MARK: - Main Content Switcher

    @ViewBuilder
    private var content: some View {
        if let host = container.activeHost, !host.isVoiceEnabled {
            hostVoiceDisabledView(host: host)
        } else if container.selectedVoiceProviderID == VoiceProviderRegistry.whisperProviderID && !hasInstalledWhisper {
            downloadRequiredView
        } else if container.isTranscribingVoice {
            transcribingProgressView
        } else if let preview = container.activeVoicePreview {
            editablePreviewView(preview: preview)
        } else {
            pushToTalkView
        }
    }

    // MARK: - 1. Host Voice Disabled View

    @ViewBuilder
    private func hostVoiceDisabledView(host: Host) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "mic.slash.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Voice Input Disabled")
                .font(.title2.bold())

            Text("Voice commands are disabled for host '\(host.name)'. For security, production and sensitive hosts require explicit enablement in host settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("voice-disabled-done-button")
            .padding(.bottom, 24)
        }
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice input is disabled for this host")
    }

    // MARK: - 2. Download Required State (WhisperKit without installed model)

    @ViewBuilder
    private var downloadRequiredView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text("Whisper Model Required")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("WhisperKit runs 100% on-device and requires a local model asset. Download the Tiny model (~75 MB) to start, or switch to Apple Speech.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if isDownloadingModel {
                VStack(spacing: 8) {
                    ProgressView(value: downloadProgress, total: 1.0)
                        .padding(.horizontal, 40)
                    Text("Downloading Whisper Tiny: \(Int(downloadProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button("Cancel Download") {
                        Task {
                            await container.cancelVoiceModelDownload(.tiny)
                            isDownloadingModel = false
                            downloadProgress = 0.0
                        }
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cancel-tiny-download-button")
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    Button {
                        startModelDownload()
                    } label: {
                        Label("Download Whisper Tiny (~75 MB)", systemImage: "arrow.down.circle")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("download-tiny-model-button")

                    Button {
                        container.selectVoiceProvider(id: VoiceProviderRegistry.appleSpeechProviderID)
                    } label: {
                        Text("Use Apple Speech (On-Device)")
                            .font(.body)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("switch-to-apple-speech-button")
                }
                .padding(.horizontal, 30)
            }

            if let err = container.voiceErrorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            Spacer()
        }
        .padding()
        .accessibilityIdentifier("download-required-view")
    }

    private func startModelDownload() {
        isDownloadingModel = true
        downloadProgress = 0.0
        Task {
            do {
                try await container.downloadVoiceModel(.tiny)
                isDownloadingModel = false
            } catch {
                isDownloadingModel = false
                downloadProgress = 0.0
            }
        }
    }

    // MARK: - 3. Transcribing Progress View

    @ViewBuilder
    private var transcribingProgressView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.6)
                .padding(.bottom, 8)

            VStack(spacing: 8) {
                Text("Transcribing on-device...")
                    .font(.headline)

                if container.voiceProgressFraction > 0.0 {
                    ProgressView(value: container.voiceProgressFraction, total: 1.0)
                        .frame(width: 200)
                    Text("\(Int(container.voiceProgressFraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text("Running entirely local on Apple Neural Engine / GPU")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel Transcription", role: .cancel) {
                Task {
                    await container.cancelVoiceRecording()
                    resetRecordingUI()
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("cancel-transcription-button")
            .padding(.bottom, 24)
        }
        .padding()
        .accessibilityIdentifier("transcribing-progress-view")
    }

    // MARK: - 4. Push-to-Talk Recording Area

    @ViewBuilder
    private var pushToTalkView: some View {
        VStack(spacing: 24) {
            // Mode selector
            Picker("Mode", selection: $selectedMode) {
                ForEach(availableModes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .disabled(container.isRecordingVoice)
            .accessibilityIdentifier("voice-mode-picker")

            Spacer()

            // Visual Status and Timer
            VStack(spacing: 8) {
                if container.isRecordingVoice {
                    if isSlideToCancel {
                        Text("Release to Cancel")
                            .font(.headline)
                            .foregroundStyle(.red)
                            .transition(.opacity)
                    } else {
                        Text("Recording...")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(formatDuration(recordingDuration))
                            .font(.system(.title, design: .monospaced).bold())
                            .foregroundStyle(.primary)
                    }
                } else {
                    Text("Hold to Speak")
                        .font(.headline)
                    Text(selectedMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Spacer()

            // Press-and-Hold Button
            ZStack {
                // Pulse ring when recording
                if container.isRecordingVoice {
                    Circle()
                        .stroke(isSlideToCancel ? Color.orange.opacity(0.4) : Color.red.opacity(0.3), lineWidth: 12)
                        .frame(width: 140, height: 140)
                        .scaleEffect(isSlideToCancel ? 1.05 : 1.15)
                        .animation(
                            Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                            value: recordingDuration
                        )
                }

                // Main Circle Button
                Circle()
                    .fill(buttonBackgroundColor)
                    .frame(width: 110, height: 110)
                    .shadow(color: buttonBackgroundColor.opacity(0.4), radius: 12, x: 0, y: 4)

                Image(systemName: isSlideToCancel ? "xmark" : (container.isRecordingVoice ? "waveform" : "mic.fill"))
                    .font(.system(size: 42))
                    .foregroundStyle(.white)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDragChanged(value)
                    }
                    .onEnded { value in
                        handleDragEnded(value)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(container.isRecordingVoice ? "Stop recording voice command" : "Start recording voice command")
            .accessibilityHint("Double-tap to toggle recording, or press and hold. Slide up to cancel.")
            .accessibilityAction(named: container.isRecordingVoice ? "Stop recording" : "Start recording") {
                toggleVoiceOverRecording()
            }
            .accessibilityIdentifier("push-to-talk-button")

            // Slide to cancel hint
            if container.isRecordingVoice {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.up")
                    Text("Slide up to cancel")
                }
                .font(.caption)
                .foregroundStyle(isSlideToCancel ? .red : .secondary)
                .padding(.top, 4)
                .accessibilityHidden(true)
            }

            // VoiceOver alternative toggle button
            Button(action: toggleVoiceOverRecording) {
                Text(container.isRecordingVoice ? "Tap to Stop" : "Tap to Record")
                    .font(.caption.bold())
                    .foregroundStyle(container.isRecordingVoice ? .red : .secondary)
            }
            .accessibilityLabel(container.isRecordingVoice ? "Stop recording voice command" : "Start recording voice command")
            .accessibilityIdentifier(container.isRecordingVoice ? "tap-to-stop-alternative" : "tap-to-record-alternative")

            // Error banner if any
            if let err = container.voiceErrorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(.horizontal)
                .accessibilityIdentifier("voice-error-banner")
            }

            Spacer()

            // Footer note
            Text("Audio recordings are stored in temporary files with 0600 permissions and deleted immediately after transcription.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .padding()
        .accessibilityIdentifier("push-to-talk-view")
    }

    private var buttonBackgroundColor: Color {
        if isSlideToCancel {
            return .red
        }
        if container.isRecordingVoice {
            return .red
        }
        return Color.accentColor
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        if !isTouchingPTT {
            isTouchingPTT = true
            if !container.isRecordingVoice && startRecordingTask == nil {
                startRecordingTask = Task {
                    await startRecording()
                }
            }
        }

        // Detect slide up or horizontal drag for cancellation
        if value.translation.height < -50 || abs(value.translation.width) > 70 {
            if !isSlideToCancel {
                isSlideToCancel = true
                container.isSlideToCancelActive = true
            }
        } else {
            if isSlideToCancel {
                isSlideToCancel = false
                container.isSlideToCancelActive = false
            }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        isTouchingPTT = false
        if let task = startRecordingTask {
            Task {
                await task.value
                if container.isRecordingVoice {
                    if isSlideToCancel {
                        await container.cancelVoiceRecording()
                        resetRecordingUI()
                    } else {
                        await stopAndTranscribe()
                    }
                }
            }
        } else if isSlideToCancel {
            // User cancelled via slide-to-cancel!
            Task {
                await container.cancelVoiceRecording()
                resetRecordingUI()
            }
        } else if container.isRecordingVoice {
            // User released normally: stop and transcribe!
            Task {
                await stopAndTranscribe()
            }
        }
    }

    private func toggleVoiceOverRecording() {
        if container.isRecordingVoice {
            Task { await stopAndTranscribe() }
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        recordingDuration = 0.0
        isSlideToCancel = false
        container.voiceErrorMessage = nil

        do {
            try await container.startVoiceRecording(mode: selectedMode)
            if !isTouchingPTT {
                startRecordingTask = nil
                if isSlideToCancel {
                    await container.cancelVoiceRecording()
                    resetRecordingUI()
                } else {
                    await stopAndTranscribe()
                }
                return
            }
            startDurationTimer()
        } catch {
            resetRecordingUI()
        }
        startRecordingTask = nil
    }

    private func stopAndTranscribe() async {
        stopDurationTimer()
        do {
            let preview = try await container.stopVoiceRecording(mode: selectedMode)
            self.previewText = preview.text
            self.selectedMode = preview.mode
        } catch {
            resetRecordingUI()
        }
    }

    private func startDurationTimer() {
        stopDurationTimer()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            recordingDuration += 0.1
        }
    }

    private func stopDurationTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func resetRecordingUI() {
        stopDurationTimer()
        recordingDuration = 0.0
        isTouchingPTT = false
        isSlideToCancel = false
        container.isSlideToCancelActive = false
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - 5. Editable Preview View

    @ViewBuilder
    private func editablePreviewView(preview: VoicePreviewState) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Mode Selector
                Picker("Mode", selection: Binding(
                    get: { preview.mode },
                    set: { newMode in
                        selectedMode = newMode
                        container.activeVoicePreview?.updateMode(
                            newMode,
                            router: container.voiceRouter,
                            hostPolicy: container.activeHost?.voicePolicy ?? .disabled
                        )
                    }
                )) {
                    ForEach(availableModes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .accessibilityIdentifier("preview-mode-picker")

                // Status / Decision Badge Card
                routingDecisionBadge(preview: preview)

                // Editable Text Editor
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Editable Transcript")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let duration = preview.duration {
                            Text("Recorded \(String(format: "%.1f", duration))s • Audio deleted")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    TextEditor(text: Binding(
                        get: { preview.text },
                        set: { newText in
                            previewText = newText
                            container.activeVoicePreview?.updateText(
                                newText,
                                router: container.voiceRouter,
                                hostPolicy: container.activeHost?.voicePolicy ?? .disabled
                            )
                        }
                    ))
                    .font(preview.mode == .shellCommand ? .system(.body, design: .monospaced) : .body)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(.separator), lineWidth: 0.5)
                    )
                    .accessibilityIdentifier("preview-transcript-editor")
                    .accessibilityLabel("Editable transcribed text")
                }
                .padding(.horizontal)

                Spacer()

                // Primary Action Button based on mode & routing decision
                actionButtons(preview: preview)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
            .padding(.top, 8)
        }
        .accessibilityIdentifier("editable-preview-view")
    }

    @ViewBuilder
    private func routingDecisionBadge(preview: VoicePreviewState) -> some View {
        HStack(spacing: 8) {
            switch preview.mode {
            case .shellCommand:
                switch preview.decision {
                case .manualSendRequired:
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text("Safe Command")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("Manual send required")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .reviewRequired:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Review Required")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("Requires explicit approval")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                case .blocked(let reason):
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text("Command Blocked")
                        .font(.subheadline.bold())
                    Spacer()
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red)
                default:
                    EmptyView()
                }

            case .agentMessage:
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.blue)
                Text("Agent Prompt")
                    .font(.subheadline.bold())

                if let host = container.activeHost, host.isProduction {
                    Spacer()
                    Label("Production Host", systemImage: "shield.lefthalf.filled")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                } else {
                    Spacer()
                    Text("Ordered text + Enter")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            case .insertOnly:
                Image(systemName: "text.cursor")
                    .foregroundStyle(.purple)
                Text("Insert Text")
                    .font(.subheadline.bold())
                Spacer()
                Text("Bracketed paste without Enter")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(badgeAccessibilityText(for: preview))
        .accessibilityIdentifier("routing-decision-badge")
    }

    private func badgeAccessibilityText(for preview: VoicePreviewState) -> String {
        switch preview.mode {
        case .shellCommand:
            switch preview.decision {
            case .manualSendRequired: return "Safe command. Validated by safety policy."
            case .reviewRequired: return "Review required. Command contains sensitive operations."
            case .blocked: return "Command blocked by safety policy."
            default: return "Shell command"
            }
        case .agentMessage:
            if let host = container.activeHost, host.isProduction {
                return "Agent prompt for production host. Extra confirmation required."
            }
            return "Agent prompt. Sends ordered text plus Enter."
        case .insertOnly:
            return "Insert text. Inserts as bracketed paste without Enter."
        }
    }

    @ViewBuilder
    private func actionButtons(preview: VoicePreviewState) -> some View {
        VStack(spacing: 8) {
            switch preview.mode {
            case .shellCommand:
                switch preview.decision {
                case .manualSendRequired:
                    Button {
                        Task {
                            let success = await container.sendVoiceCommand(preview: preview)
                            if success { dismiss() }
                        }
                    } label: {
                        Label("Send Command", systemImage: "paperplane.fill")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("send-safe-command-button")

                case .reviewRequired:
                    Button {
                        showingApproval = true
                    } label: {
                        Label("Review & Approve", systemImage: "checkmark.shield")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .accessibilityIdentifier("review-required-button")

                case .blocked:
                    Button {} label: {
                        Label("Blocked by Safety Policy", systemImage: "slash.circle")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .accessibilityIdentifier("blocked-command-button")

                default:
                    EmptyView()
                }

            case .agentMessage:
                Button {
                    if let host = container.activeHost, host.isProduction {
                        showingProductionConfirm = true
                    } else {
                        Task {
                            let success = await container.sendAgentMessage(preview: preview)
                            if success { dismiss() }
                        }
                    }
                } label: {
                    Label(
                        container.activeHost?.isProduction == true ? "Send to Production Host" : "Send Agent Prompt",
                        systemImage: "paperplane.fill"
                    )
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(container.activeHost?.isProduction == true ? .orange : .blue)
                .accessibilityIdentifier("send-agent-message-button")

            case .insertOnly:
                Button {
                    Task {
                        let success = await container.insertVoiceText(preview: preview)
                        if success { dismiss() }
                    }
                } label: {
                    Label("Insert at Cursor", systemImage: "text.insert")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .accessibilityIdentifier("insert-voice-text-button")
            }

            // Secondary: Re-record
            Button {
                container.resetVoiceState()
                resetRecordingUI()
            } label: {
                Label("Re-record", systemImage: "arrow.counterclockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .accessibilityIdentifier("rerecord-voice-button")
        }
    }

    private var currentPreviewState: VoicePreviewState? {
        container.activeVoicePreview
    }

    private func cancelAndDismiss() {
        Task {
            await container.cancelVoiceRecording()
            cleanupOnExit()
            dismiss()
        }
    }

    private func cleanupOnExit() {
        stopDurationTimer()
        container.resetVoiceState()
        resetRecordingUI()
    }
}
