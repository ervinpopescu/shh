import Foundation
import AVFoundation
import ShhCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Permission and Event Types

public enum AudioRecordPermission: Sendable {
    case undetermined
    case denied
    case granted
}

public enum AudioInterruptionEvent: Sendable {
    case began
    case ended(shouldResume: Bool)
}

public enum AudioRouteChangeEvent: Sendable {
    case oldDeviceUnavailable
    case other
}

// MARK: - Dependency Injection Protocols

public protocol AudioSessionManaging: Sendable {
    var recordPermission: AudioRecordPermission { get }
    func requestRecordPermission() async -> Bool
    func activateSession() throws
    func deactivateSession() throws
}

public protocol AudioRecordingEngine: AnyObject, Sendable {
    func record() -> Bool
    func stop()
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
}

public protocol AudioRecordingEngineFactory: Sendable {
    func makeEngine(url: URL, settings: [String: Any]) throws -> any AudioRecordingEngine
}

public protocol AudioLifecycleNotifier: Sendable {
    func observe(
        onInterruption: @escaping @Sendable (AudioInterruptionEvent) -> Void,
        onRouteChange: @escaping @Sendable (AudioRouteChangeEvent) -> Void,
        onBackground: @escaping @Sendable () -> Void
    ) -> [Any]

    func removeObservers(_ tokens: [Any])
}

// MARK: - Live System Implementations

public final class SystemAudioSessionManager: AudioSessionManaging, @unchecked Sendable {
    public static let shared = SystemAudioSessionManager()

    public init() {}

    public var recordPermission: AudioRecordPermission {
        #if os(iOS)
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .undetermined
        @unknown default:
            return .undetermined
        }
        #else
        return .granted
        #endif
    }

    public func requestRecordPermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return true
        #endif
    }

    public func activateSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: [])
        #endif
    }

    public func deactivateSession() throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}

public final class DefaultAudioRecordingEngine: NSObject, AudioRecordingEngine, AVAudioRecorderDelegate, @unchecked Sendable {
    private var recorder: AVAudioRecorder?

    public init(url: URL, settings: [String: Any]) throws {
        super.init()
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.delegate = self
        rec.prepareToRecord()
        self.recorder = rec
    }

    public func record() -> Bool {
        recorder?.record() ?? false
    }

    public func stop() {
        recorder?.stop()
        recorder = nil
    }

    public var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    public var currentTime: TimeInterval {
        recorder?.currentTime ?? 0.0
    }
}

public final class DefaultAudioRecordingEngineFactory: AudioRecordingEngineFactory {
    public init() {}

    public func makeEngine(url: URL, settings: [String: Any]) throws -> any AudioRecordingEngine {
        try DefaultAudioRecordingEngine(url: url, settings: settings)
    }
}

public final class SystemAudioLifecycleNotifier: AudioLifecycleNotifier, @unchecked Sendable {
    public init() {}

    public func observe(
        onInterruption: @escaping @Sendable (AudioInterruptionEvent) -> Void,
        onRouteChange: @escaping @Sendable (AudioRouteChangeEvent) -> Void,
        onBackground: @escaping @Sendable () -> Void
    ) -> [Any] {
        var tokens: [Any] = []
        let center = NotificationCenter.default

        #if os(iOS)
        let interruptionToken = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }
            if type == .began {
                onInterruption(.began)
            } else {
                let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = (optionsValue & AVAudioSession.InterruptionOptions.shouldResume.rawValue) != 0
                onInterruption(.ended(shouldResume: shouldResume))
            }
        }
        tokens.append(interruptionToken)

        let routeToken = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                return
            }
            if reason == .oldDeviceUnavailable {
                onRouteChange(.oldDeviceUnavailable)
            } else {
                onRouteChange(.other)
            }
        }
        tokens.append(routeToken)
        #endif

        #if canImport(UIKit)
        let backgroundToken = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            onBackground()
        }
        tokens.append(backgroundToken)
        #endif

        return tokens
    }

    public func removeObservers(_ tokens: [Any]) {
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
    }
}

// MARK: - AudioCaptureRecorder

/// A Shh-owned AVAudioRecorder adapter for foreground press-and-hold capture.
/// Records 16kHz mono linear PCM to a POSIX 0o600 protected temporary file.
/// Guarantees resource teardown and file deletion upon cancellation, error,
/// audio route disconnection, audio interruption, or app backgrounding.
/// Never declares or enables background audio mode.
public actor AudioCaptureRecorder: AudioRecorder {
    public let maxDuration: TimeInterval
    public let minDuration: TimeInterval

    private let sessionManager: any AudioSessionManaging
    private let engineFactory: any AudioRecordingEngineFactory
    private let lifecycleNotifier: any AudioLifecycleNotifier
    private let tempFileFactory: @Sendable () throws -> AudioRecordingHandle

    private var activeEngine: (any AudioRecordingEngine)?
    private var activeHandle: AudioRecordingHandle?
    private var observerTokens: [Any] = []
    private var maxDurationTask: Task<Void, Never>?
    private var recordingStartTime: Date?

    public init(
        maxDuration: TimeInterval = 60.0,
        minDuration: TimeInterval = 0.1,
        sessionManager: any AudioSessionManaging = SystemAudioSessionManager.shared,
        engineFactory: any AudioRecordingEngineFactory = DefaultAudioRecordingEngineFactory(),
        lifecycleNotifier: any AudioLifecycleNotifier = SystemAudioLifecycleNotifier(),
        tempFileFactory: (@Sendable () throws -> AudioRecordingHandle)? = nil
    ) {
        self.maxDuration = maxDuration
        self.minDuration = minDuration
        self.sessionManager = sessionManager
        self.engineFactory = engineFactory
        self.lifecycleNotifier = lifecycleNotifier
        self.tempFileFactory = tempFileFactory ?? {
            try AudioRecordingHandle.createTemporary(fileExtension: VoiceAudioFormat.fileExtension)
        }
    }

    deinit {
        lifecycleNotifier.removeObservers(observerTokens)
        maxDurationTask?.cancel()
        if let handle = activeHandle {
            handle.cleanup()
        }
    }

    public var isRecording: Bool {
        activeEngine?.isRecording ?? false
    }

    public func start() async throws {
        guard activeEngine == nil && activeHandle == nil else {
            throw AudioRecorderError.alreadyRecording
        }

        // 1. Permission check
        switch sessionManager.recordPermission {
        case .denied:
            throw AudioRecorderError.permissionDenied
        case .undetermined:
            let granted = await sessionManager.requestRecordPermission()
            guard granted else {
                throw AudioRecorderError.permissionDenied
            }
        case .granted:
            break
        }

        // 2. Audio session activation
        do {
            try sessionManager.activateSession()
        } catch {
            throw AudioRecorderError.deviceUnavailable(reason: "Failed to activate audio session: \(error.localizedDescription)")
        }

        // 3. Create protected temporary file
        let handle: AudioRecordingHandle
        do {
            handle = try tempFileFactory()
        } catch {
            try? sessionManager.deactivateSession()
            throw AudioRecorderError.temporaryFileError(reason: "Failed to create secure temporary file: \(error.localizedDescription)")
        }

        // 4. Initialize recording engine
        let engine: any AudioRecordingEngine
        do {
            engine = try engineFactory.makeEngine(url: handle.url, settings: VoiceAudioFormat.pcmRecorderSettings)
        } catch {
            handle.cleanup()
            try? sessionManager.deactivateSession()
            throw AudioRecorderError.captureFailed(reason: "Failed to instantiate audio recorder engine: \(error.localizedDescription)")
        }

        guard engine.record() else {
            handle.cleanup()
            try? sessionManager.deactivateSession()
            throw AudioRecorderError.captureFailed(reason: "AVAudioRecorder refused to start recording")
        }

        self.activeEngine = engine
        self.activeHandle = handle
        self.recordingStartTime = Date()

        // 5. Register lifecycle observers
        self.observerTokens = lifecycleNotifier.observe(
            onInterruption: { [weak self] event in
                if case .began = event {
                    Task { [weak self] in
                        await self?.handleInterruption()
                    }
                }
            },
            onRouteChange: { [weak self] reason in
                if reason == .oldDeviceUnavailable {
                    Task { [weak self] in
                        await self?.handleRouteChange()
                    }
                }
            },
            onBackground: { [weak self] in
                Task { [weak self] in
                    await self?.handleBackground()
                }
            }
        )

        // 6. Max duration timeout enforcement
        let maxSec = self.maxDuration
        self.maxDurationTask = Task { [weak self] in
            let nanos = UInt64(maxSec * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.handleMaxDurationReached()
        }
    }

    public func stop() async throws -> AudioRecordingHandle {
        guard let engine = activeEngine, let handle = activeHandle else {
            throw AudioRecorderError.notRecording
        }

        teardownMonitoring()

        let wallDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0.0
        let engineDuration = engine.currentTime
        let duration = max(wallDuration, engineDuration)

        engine.stop()
        try? sessionManager.deactivateSession()

        self.activeEngine = nil
        self.activeHandle = nil
        self.recordingStartTime = nil

        // Validate duration and minimum data presence
        guard duration >= minDuration else {
            handle.cleanup()
            throw AudioRecorderError.recordingTooShort
        }

        guard handle.exists, let size = handle.sizeBytes, size > 44 else {
            handle.cleanup()
            throw AudioRecorderError.recordingTooShort
        }

        var finalHandle = handle
        finalHandle.duration = duration
        return finalHandle
    }

    public func cancel() async {
        teardownMonitoring()

        if let engine = activeEngine {
            engine.stop()
        }
        if let handle = activeHandle {
            handle.cleanup()
        }

        try? sessionManager.deactivateSession()

        self.activeEngine = nil
        self.activeHandle = nil
        self.recordingStartTime = nil
    }

    // MARK: - Lifecycle Handlers

    private func handleInterruption() async {
        await cancel()
    }

    private func handleRouteChange() async {
        await cancel()
    }

    private func handleBackground() async {
        // App backgrounding must cancel recording and delete temporary files immediately.
        await cancel()
    }

    private func handleMaxDurationReached() async {
        // Max duration reached: cancel and cleanup
        await cancel()
    }

    private func teardownMonitoring() {
        maxDurationTask?.cancel()
        maxDurationTask = nil
        if !observerTokens.isEmpty {
            lifecycleNotifier.removeObservers(observerTokens)
            observerTokens = []
        }
    }
}
