import XCTest
import Foundation
import AVFoundation
@testable import ShhCore
@testable import ShhVoice

final class AudioCaptureRecorderTests: XCTestCase {

    // MARK: - Mocks

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    final class MockAudioSessionManager: AudioSessionManaging, @unchecked Sendable {
        var recordPermission: AudioRecordPermission = .granted
        var shouldGrantOnRequest: Bool = true
        var activateCallCount: Int = 0
        var deactivateCallCount: Int = 0
        var activateError: Error?
        var deactivateError: Error?

        func requestRecordPermission() async -> Bool {
            shouldGrantOnRequest
        }

        func activateSession() throws {
            activateCallCount += 1
            if let activateError {
                throw activateError
            }
        }

        func deactivateSession() throws {
            deactivateCallCount += 1
            if let deactivateError {
                throw deactivateError
            }
        }
    }

    final class MockAudioRecordingEngine: AudioRecordingEngine, @unchecked Sendable {
        var isRecording: Bool = false
        var currentTime: TimeInterval = 1.0
        var recordResult: Bool = true
        var recordCallCount: Int = 0
        var stopCallCount: Int = 0

        func record() -> Bool {
            recordCallCount += 1
            if recordResult {
                isRecording = true
                return true
            }
            return false
        }

        func stop() {
            stopCallCount += 1
            isRecording = false
        }
    }

    final class MockAudioRecordingEngineFactory: AudioRecordingEngineFactory, @unchecked Sendable {
        let engine: MockAudioRecordingEngine
        var errorToThrow: Error?

        init(engine: MockAudioRecordingEngine) {
            self.engine = engine
        }

        func makeEngine(url: URL, settings: [String: Any]) throws -> any AudioRecordingEngine {
            if let errorToThrow {
                throw errorToThrow
            }
            return engine
        }
    }

    final class MockAudioLifecycleNotifier: AudioLifecycleNotifier, @unchecked Sendable {
        private let lock = NSLock()
        private var interruptionHandler: (@Sendable (AudioInterruptionEvent) -> Void)?
        private var routeChangeHandler: (@Sendable (AudioRouteChangeEvent) -> Void)?
        private var backgroundHandler: (@Sendable () -> Void)?

        func observe(
            onInterruption: @escaping @Sendable (AudioInterruptionEvent) -> Void,
            onRouteChange: @escaping @Sendable (AudioRouteChangeEvent) -> Void,
            onBackground: @escaping @Sendable () -> Void
        ) -> [Any] {
            lock.lock()
            defer { lock.unlock() }
            self.interruptionHandler = onInterruption
            self.routeChangeHandler = onRouteChange
            self.backgroundHandler = onBackground
            return ["token_1"]
        }

        func removeObservers(_ tokens: [Any]) {
            lock.lock()
            defer { lock.unlock() }
            self.interruptionHandler = nil
            self.routeChangeHandler = nil
            self.backgroundHandler = nil
        }

        func fireInterruption(_ event: AudioInterruptionEvent) {
            lock.lock()
            let handler = interruptionHandler
            lock.unlock()
            handler?(event)
        }

        func fireRouteChange(_ reason: AudioRouteChangeEvent) {
            lock.lock()
            let handler = routeChangeHandler
            lock.unlock()
            handler?(reason)
        }

        func fireBackground() {
            lock.lock()
            let handler = backgroundHandler
            lock.unlock()
            handler?()
        }
    }

    final class ControlledAudioRecorderSleeper: AudioRecorderSleeper, @unchecked Sendable {
        private let lock = NSLock()
        private let startedContinuation: AsyncStream<Void>.Continuation
        private var releaseContinuation: CheckedContinuation<Void, Error>?
        private var releaseRequested = false
        let started: AsyncStream<Void>

        init() {
            let (started, continuation) = AsyncStream<Void>.makeStream()
            self.started = started
            self.startedContinuation = continuation
        }

        func sleep(for _: TimeInterval) async throws {
            startedContinuation.yield(())
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if releaseRequested {
                    lock.unlock()
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                    lock.unlock()
                }
            }
        }

        func waitUntilStarted() async {
            for await _ in started {
                return
            }
        }

        func release() {
            lock.lock()
            let continuation = releaseContinuation
            releaseContinuation = nil
            if continuation == nil {
                releaseRequested = true
            }
            lock.unlock()
            continuation?.resume()
        }
    }

    private func eventually(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await condition()
    }

    // MARK: - Lifecycle & Deletion Tests

    func testHappyPathRecordingLifecycleAndGuaranteedCleanup() async throws {
        let session = MockAudioSessionManager()
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)
        let notifier = MockAudioLifecycleNotifier()

        let createdBox = Box<AudioRecordingHandle?>(nil)
        let recorder = AudioCaptureRecorder(
            maxDuration: 10.0,
            minDuration: 0.05,
            sessionManager: session,
            engineFactory: factory,
            lifecycleNotifier: notifier,
            tempFileFactory: {
                let handle = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
                // Write synthetic wav data so size check passes
                let data = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
                try data.write(to: handle.url)
                createdBox.value = handle
                return handle
            }
        )

        try await recorder.start()
        let isRec = await recorder.isRecording
        XCTAssertTrue(isRec)
        XCTAssertEqual(session.activateCallCount, 1)
        XCTAssertEqual(engine.recordCallCount, 1)
        XCTAssertNotNil(createdBox.value)
        XCTAssertTrue(createdBox.value!.exists)

        try await Task.sleep(nanoseconds: 60_000_000) // 60ms to exceed minDuration

        let stopHandle = try await recorder.stop()
        let isRecAfter = await recorder.isRecording
        XCTAssertFalse(isRecAfter)
        XCTAssertEqual(session.deactivateCallCount, 1)
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertTrue(stopHandle.exists)
        XCTAssertGreaterThan(stopHandle.duration ?? 0, 0)

        // Verify guaranteed deletion when caller cleans up handle
        stopHandle.cleanup()
        XCTAssertFalse(stopHandle.exists)
    }

    func testStopWhenNotRecordingThrows() async {
        let recorder = AudioCaptureRecorder()
        do {
            _ = try await recorder.stop()
            XCTFail("Expected notRecording error")
        } catch let err as AudioRecorderError {
            XCTAssertEqual(err, .notRecording)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartWhenAlreadyRecordingThrows() async throws {
        let session = MockAudioSessionManager()
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)
        let notifier = MockAudioLifecycleNotifier()

        let handleBox = Box<AudioRecordingHandle?>(nil)
        let recorder = AudioCaptureRecorder(
            sessionManager: session,
            engineFactory: factory,
            lifecycleNotifier: notifier,
            tempFileFactory: {
                let h = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
                let data = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
                try data.write(to: h.url)
                handleBox.value = h
                return h
            }
        )

        try await recorder.start()
        defer {
            Task { await recorder.cancel() }
            handleBox.value?.cleanup()
        }

        do {
            try await recorder.start()
            XCTFail("Expected alreadyRecording error")
        } catch let err as AudioRecorderError {
            XCTAssertEqual(err, .alreadyRecording)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPermissionDeniedRejectsRecordingWithoutTempFileLeak() async {
        let session = MockAudioSessionManager()
        session.recordPermission = .denied
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)

        let handleCreatedBox = Box<Bool>(false)
        let recorder = AudioCaptureRecorder(
            sessionManager: session,
            engineFactory: factory,
            tempFileFactory: {
                handleCreatedBox.value = true
                return try AudioRecordingHandle.createTemporary()
            }
        )

        do {
            try await recorder.start()
            XCTFail("Expected permissionDenied error")
        } catch let err as AudioRecorderError {
            XCTAssertEqual(err, .permissionDenied)
            XCTAssertFalse(handleCreatedBox.value, "Temporary file must not be created when permission is denied")
            XCTAssertEqual(engine.recordCallCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUndeterminedPermissionRefusedThrowsPermissionDenied() async {
        let session = MockAudioSessionManager()
        session.recordPermission = .undetermined
        session.shouldGrantOnRequest = false
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)

        let recorder = AudioCaptureRecorder(
            sessionManager: session,
            engineFactory: factory
        )

        do {
            try await recorder.start()
            XCTFail("Expected permissionDenied error")
        } catch let err as AudioRecorderError {
            XCTAssertEqual(err, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAudioSessionActivationFailureCleansUp() async {
        let session = MockAudioSessionManager()
        session.activateError = NSError(domain: "AVAudioSession", code: -50, userInfo: [NSLocalizedDescriptionKey: "Failed"])
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)

        let recorder = AudioCaptureRecorder(
            sessionManager: session,
            engineFactory: factory
        )

        do {
            try await recorder.start()
            XCTFail("Expected deviceUnavailable error")
        } catch let err as AudioRecorderError {
            if case .deviceUnavailable = err {
                // Expected
            } else {
                XCTFail("Expected deviceUnavailable, got \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEngineRecordRefusalCleansUpTemporaryFileAndSession() async throws {
        let session = MockAudioSessionManager()
        let engine = MockAudioRecordingEngine()
        engine.recordResult = false // Fails to start
        let factory = MockAudioRecordingEngineFactory(engine: engine)

        let createdBox = Box<AudioRecordingHandle?>(nil)
        let recorder = AudioCaptureRecorder(
            sessionManager: session,
            engineFactory: factory,
            tempFileFactory: {
                let h = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
                createdBox.value = h
                return h
            }
        )

        do {
            try await recorder.start()
            XCTFail("Expected captureFailed error")
        } catch let err as AudioRecorderError {
            if case .captureFailed = err {
                // Expected
            } else {
                XCTFail("Expected captureFailed, got \(err)")
            }
            XCTAssertEqual(session.deactivateCallCount, 1)
            XCTAssertNotNil(createdBox.value)
            XCTAssertFalse(createdBox.value!.exists, "Temporary file must be deleted on capture failure")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationGuaranteesFileDeletion() async throws {
        let session = MockAudioSessionManager()
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)
        let notifier = MockAudioLifecycleNotifier()

        let createdBox = Box<AudioRecordingHandle?>(nil)
        let recorder = AudioCaptureRecorder(
            sessionManager: session,
            engineFactory: factory,
            lifecycleNotifier: notifier,
            tempFileFactory: {
                let h = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
                let data = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
                try data.write(to: h.url)
                createdBox.value = h
                return h
            }
        )

        try await recorder.start()
        XCTAssertTrue(createdBox.value!.exists)

        await recorder.cancel()
        let isRec = await recorder.isRecording
        XCTAssertFalse(isRec)
        XCTAssertEqual(session.deactivateCallCount, 1)
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertFalse(createdBox.value!.exists, "File must be immediately deleted upon cancellation")
    }

    // MARK: - Interruption, Route Change & Background Tests

    func testAudioInterruptionBeganImmediatelyCancelsAndDeletesFile() async throws {
        let session = MockAudioSessionManager()
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)
        let notifier = MockAudioLifecycleNotifier()

        let createdBox = Box<AudioRecordingHandle?>(nil)
        let recorder = AudioCaptureRecorder(
            sessionManager: session,
            engineFactory: factory,
            lifecycleNotifier: notifier,
            tempFileFactory: {
                let h = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
                let data = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
                try data.write(to: h.url)
                createdBox.value = h
                return h
            }
        )

        try await recorder.start()
        XCTAssertTrue(createdBox.value!.exists)

        // Fire audio interruption began
        notifier.fireInterruption(.began)

        // Allow async cancellation task to complete
        try await Task.sleep(nanoseconds: 50_000_000)

        let isRec = await recorder.isRecording
        XCTAssertFalse(isRec)
        XCTAssertFalse(createdBox.value!.exists, "Interruption must delete temporary file")
        XCTAssertEqual(session.deactivateCallCount, 1)
    }

    func testRouteChangeOldDeviceUnavailableCancelsAndDeletesFile() async throws {
        let session = MockAudioSessionManager()
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)
        let notifier = MockAudioLifecycleNotifier()

        let createdBox = Box<AudioRecordingHandle?>(nil)
        let recorder = AudioCaptureRecorder(
            sessionManager: session,
            engineFactory: factory,
            lifecycleNotifier: notifier,
            tempFileFactory: {
                let h = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
                let data = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
                try data.write(to: h.url)
                createdBox.value = h
                return h
            }
        )

        try await recorder.start()
        XCTAssertTrue(createdBox.value!.exists)

        // Fire route change reason: old device unavailable
        notifier.fireRouteChange(.oldDeviceUnavailable)

        try await Task.sleep(nanoseconds: 50_000_000)

        let isRec = await recorder.isRecording
        XCTAssertFalse(isRec)
        XCTAssertFalse(createdBox.value!.exists, "Route disconnection must delete temporary file")
        XCTAssertEqual(session.deactivateCallCount, 1)
    }

    func testAppBackgroundCancelsAndDeletesFileImmediately() async throws {
        let session = MockAudioSessionManager()
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)
        let notifier = MockAudioLifecycleNotifier()

        let createdBox = Box<AudioRecordingHandle?>(nil)
        let recorder = AudioCaptureRecorder(
            sessionManager: session,
            engineFactory: factory,
            lifecycleNotifier: notifier,
            tempFileFactory: {
                let h = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
                let data = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
                try data.write(to: h.url)
                createdBox.value = h
                return h
            }
        )

        try await recorder.start()
        XCTAssertTrue(createdBox.value!.exists)

        // Fire background notification
        notifier.fireBackground()

        try await Task.sleep(nanoseconds: 50_000_000)

        let isRec = await recorder.isRecording
        XCTAssertFalse(isRec)
        XCTAssertFalse(createdBox.value!.exists, "Backgrounding must immediately delete temporary file")
        XCTAssertEqual(session.deactivateCallCount, 1)
    }

    func testMaxDurationTimeoutCancelsAndCleansUp() async throws {
        let session = MockAudioSessionManager()
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)
        let notifier = MockAudioLifecycleNotifier()
        let sleeper = ControlledAudioRecorderSleeper()

        let createdBox = Box<AudioRecordingHandle?>(nil)
        let recorder = AudioCaptureRecorder(
            maxDuration: 0.05, // 50ms
            sessionManager: session,
            engineFactory: factory,
            lifecycleNotifier: notifier,
            timeoutSleeper: sleeper,
            tempFileFactory: {
                let h = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
                let data = VoiceAudioFormat.createSyntheticWavData(duration: 0.5)
                try data.write(to: h.url)
                createdBox.value = h
                return h
            }
        )

        try await recorder.start()
        XCTAssertTrue(createdBox.value!.exists)

        // Release the injected timer only after the timeout task is known to be waiting.
        await sleeper.waitUntilStarted()
        sleeper.release()

        let cleanupCompleted = await eventually {
            let isRecording = await recorder.isRecording
            let timeoutTaskIsActive = await recorder.hasActiveMaxDurationTask
            return !isRecording && !createdBox.value!.exists && !timeoutTaskIsActive
        }
        XCTAssertTrue(cleanupCompleted, "Timeout cleanup did not complete before the hard deadline")
        let isRecordingAfterTimeout = await recorder.isRecording
        XCTAssertFalse(isRecordingAfterTimeout)
        XCTAssertFalse(createdBox.value!.exists, "Exceeding max duration must clean up file")
        XCTAssertEqual(engine.stopCallCount, 1, "Timeout must stop recording exactly once")
        XCTAssertEqual(session.deactivateCallCount, 1, "Timeout must deactivate audio exactly once")
        let timeoutTaskIsActiveAfterCleanup = await recorder.hasActiveMaxDurationTask
        XCTAssertFalse(timeoutTaskIsActiveAfterCleanup, "Timeout task must be torn down")
    }

    func testRecordingTooShortThrowsAndDeletesFile() async throws {
        let session = MockAudioSessionManager()
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)
        let notifier = MockAudioLifecycleNotifier()

        let createdBox = Box<AudioRecordingHandle?>(nil)
        let recorder = AudioCaptureRecorder(
            minDuration: 5.0, // Set high minDuration so stop() considers it too short
            sessionManager: session,
            engineFactory: factory,
            lifecycleNotifier: notifier,
            tempFileFactory: {
                let h = try AudioRecordingHandle.createTemporary(fileExtension: "wav")
                let data = VoiceAudioFormat.createSyntheticWavData(duration: 0.1)
                try data.write(to: h.url)
                createdBox.value = h
                return h
            }
        )

        try await recorder.start()
        XCTAssertTrue(createdBox.value!.exists)

        do {
            _ = try await recorder.stop()
            XCTFail("Expected recordingTooShort error")
        } catch let err as AudioRecorderError {
            XCTAssertEqual(err, .recordingTooShort)
            XCTAssertFalse(createdBox.value!.exists, "Too short recording must delete temporary file")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInterruptionInvokesOnInterruptionCallback() async throws {
        let session = MockAudioSessionManager()
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)
        let notifier = MockAudioLifecycleNotifier()
        let callbackBox = Box<Bool>(false)

        let recorder = AudioCaptureRecorder(
            sessionManager: session,
            engineFactory: factory,
            lifecycleNotifier: notifier,
            tempFileFactory: {
                try AudioRecordingHandle.createTemporary(fileExtension: "wav")
            },
            onInterruption: {
                callbackBox.value = true
            }
        )

        try await recorder.start()
        notifier.fireInterruption(.began)

        try await Task.sleep(nanoseconds: 50_000_000)

        let isRec = await recorder.isRecording
        XCTAssertFalse(isRec)
        XCTAssertTrue(callbackBox.value, "onInterruption callback must be invoked when audio interruption begins")
    }

    func testRouteChangeInvokesOnInterruptionCallback() async throws {
        let session = MockAudioSessionManager()
        let engine = MockAudioRecordingEngine()
        let factory = MockAudioRecordingEngineFactory(engine: engine)
        let notifier = MockAudioLifecycleNotifier()
        let callbackBox = Box<Bool>(false)

        let recorder = AudioCaptureRecorder(
            sessionManager: session,
            engineFactory: factory,
            lifecycleNotifier: notifier,
            tempFileFactory: {
                try AudioRecordingHandle.createTemporary(fileExtension: "wav")
            },
            onInterruption: {
                callbackBox.value = true
            }
        )

        try await recorder.start()
        notifier.fireRouteChange(.oldDeviceUnavailable)

        try await Task.sleep(nanoseconds: 50_000_000)

        let isRec = await recorder.isRecording
        XCTAssertFalse(isRec)
        XCTAssertTrue(callbackBox.value, "onInterruption callback must be invoked when audio route disconnects")
    }
}
