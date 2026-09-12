import SwiftUI
import ShhCore
import ShhVoice

public struct VoiceSettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var deletingTier: WhisperModelTier?
    @State private var showingDeleteConfirmation = false

    public init() {}

    public var body: some View {
        Form {
            providerSection
            modelsSection
            defaultModeSection
            privacySection
        }
        .navigationTitle("Voice & Local AI")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete Model?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let tier = deletingTier {
                Button("Delete \(tier.displayName)", role: .destructive) {
                    Task {
                        try? await container.deleteVoiceModel(tier)
                        deletingTier = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                deletingTier = nil
            }
        } message: {
            if let tier = deletingTier {
                Text("Are you sure you want to delete the local weights for \(tier.displayName)? You will need to download them again to use Whisper with this tier.")
            }
        }
        .task {
            await container.refreshVoiceModels()
        }
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        Section {
            Picker("Speech Provider", selection: Binding(
                get: { container.selectedVoiceProviderID },
                set: { container.selectVoiceProvider(id: $0) }
            )) {
                ForEach(container.voiceRegistry.providerDescriptors) { descriptor in
                    Text(descriptor.name).tag(descriptor.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("voice-provider-picker")

            if container.selectedVoiceProviderID == VoiceProviderRegistry.whisperProviderID {
                Text("WhisperKit runs on-device CoreML Whisper models offline with zero cloud telemetry. WhisperKit is the default local provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Apple Speech uses on-device speech recognition. Cloud recognition is strictly forbidden. Apple Speech is an explicit user choice and never activates silently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Provider")
        } footer: {
            Text("Switching providers requires explicit user selection. Shh never silently falls back between speech providers.")
        }
    }

    // MARK: - Downloadable Models Section

    private var modelsSection: some View {
        Section {
            ForEach(WhisperModelTier.allCases, id: \.self) { tier in
                modelRow(for: tier)
            }
        } header: {
            Text("Whisper Models")
        } footer: {
            Text("Local model weights are stored strictly under Application Support/Shh/Models and excluded from iCloud backups. Never stored in Documents.")
        }
    }

    @ViewBuilder
    private func modelRow(for tier: WhisperModelTier) -> some View {
        let descriptor = container.voiceModels.first(where: { $0.id == tier.defaultModelID })
        let modelState = descriptor?.state ?? .notInstalled
        let hasLowRAM = ProcessInfo.processInfo.physicalMemory < tier.minimumRAMBytes

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tier.displayName)
                        .font(.body.weight(.medium))
                    Text("\(tier.estimatedSizeBytes / (1024 * 1024)) MB • Min \(tier.minimumRAMBytes / (1024 * 1024 * 1024)) GB RAM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                switch modelState {
                case .installed:
                    HStack(spacing: 8) {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.green)

                        Button(role: .destructive) {
                            deletingTier = tier
                            showingDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(tier.displayName)")
                        .accessibilityIdentifier("delete-model-\(tier.rawValue)")
                    }

                case .downloading(let fraction):
                    HStack(spacing: 8) {
                        ProgressView(value: fraction, total: 1.0)
                            .frame(width: 80)
                        Button("Cancel") {
                            Task { await container.cancelVoiceModelDownload(tier) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Cancel \(tier.displayName) download")
                        .accessibilityIdentifier("cancel-download-\(tier.rawValue)")
                    }

                case .notInstalled:
                    Button {
                        Task { try? await container.downloadVoiceModel(tier) }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Download \(tier.displayName)")
                    .accessibilityIdentifier("download-model-\(tier.rawValue)")

                case .degraded(let reason):
                    Label("Degraded: \(reason)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)

                case .unavailable(let reason):
                    Text("Unavailable: \(reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if hasLowRAM {
                Label(
                    "Device RAM is below the recommended \(tier.minimumRAMBytes / (1024 * 1024 * 1024)) GB for this model.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("device-ram-warning-\(tier.rawValue)")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Default Input Mode Section

    private var defaultModeSection: some View {
        Section("Default Input Mode") {
            Picker("Default Mode", selection: $container.defaultVoiceMode) {
                ForEach(VoiceInputMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("default-voice-mode-picker")

            Text(container.defaultVoiceMode.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        Section("Privacy & Security") {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("100% On-Device Processing")
                        .font(.subheadline.bold())
                    Text("All audio capture and transcription runs strictly on-device. Audio files are deleted immediately after transcription. Transcripts are never saved to history or transmitted off-device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
            }

            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Zero Cloud Telemetry")
                        .font(.subheadline.bold())
                    Text("Shh never communicates with third-party speech servers, cloud APIs, or analytics frameworks. Model weights are downloaded exclusively from verified sources on user request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "network.slash")
                    .foregroundStyle(.blue)
            }
        }
    }
}
