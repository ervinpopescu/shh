import XCTest
@testable import ShhCore

final class ReconnectAndRestorationTests: XCTestCase {

    // MARK: - Host Backward Decoding & Preferences

    func testHostBackwardDecodingWithoutTmuxPreferences() throws {
        let original = try Host(
            name: "Legacy Host",
            hostname: "legacy.invalid",
            username: "admin"
        )
        let encoder = JSONEncoder()
        let fullData = try encoder.encode(original)
        var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: fullData) as? [String: Any])

        // Strip modern fields to simulate legacy payload
        jsonObject.removeValue(forKey: "tmuxPreferences")
        jsonObject.removeValue(forKey: "defaultTmuxSession")
        jsonObject.removeValue(forKey: "autoAttachTmux")

        let legacyData = try JSONSerialization.data(withJSONObject: jsonObject)
        let decoder = JSONDecoder()
        let host = try decoder.decode(Host.self, from: legacyData)

        XCTAssertEqual(host.name, "Legacy Host")
        XCTAssertEqual(host.hostname, "legacy.invalid")
        XCTAssertEqual(host.username, "admin")
        XCTAssertNil(host.defaultTmuxSession)
        XCTAssertFalse(host.autoAttachTmux)
        XCTAssertNil(host.tmuxPreferences.defaultSession)
        XCTAssertFalse(host.tmuxPreferences.autoAttach)
    }

    func testHostDecodingWithTmuxPreferencesObject() throws {
        let original = try Host(
            name: "Tmux Host",
            hostname: "tmux.invalid",
            username: "dev"
        )
        let encoder = JSONEncoder()
        let fullData = try encoder.encode(original)
        var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: fullData) as? [String: Any])

        // Inject structured tmuxPreferences object
        jsonObject.removeValue(forKey: "defaultTmuxSession")
        jsonObject.removeValue(forKey: "autoAttachTmux")
        jsonObject["tmuxPreferences"] = [
            "defaultSession": "$2",
            "autoAttach": true
        ]

        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        let decoder = JSONDecoder()
        let host = try decoder.decode(Host.self, from: data)

        XCTAssertEqual(host.defaultTmuxSession, "$2")
        XCTAssertTrue(host.autoAttachTmux)
        XCTAssertEqual(host.tmuxPreferences.defaultSession, "$2")
        XCTAssertTrue(host.tmuxPreferences.autoAttach)
    }

    func testHostDecodingWithFlattenedTmuxKeys() throws {
        let original = try Host(
            name: "Flat Tmux Host",
            hostname: "flat.invalid",
            username: "user"
        )
        let encoder = JSONEncoder()
        let fullData = try encoder.encode(original)
        var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: fullData) as? [String: Any])

        // Inject flat tmux keys
        jsonObject.removeValue(forKey: "tmuxPreferences")
        jsonObject["defaultTmuxSession"] = "workbox"
        jsonObject["autoAttachTmux"] = true

        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        let decoder = JSONDecoder()
        let host = try decoder.decode(Host.self, from: data)

        XCTAssertEqual(host.defaultTmuxSession, "workbox")
        XCTAssertTrue(host.autoAttachTmux)
        XCTAssertEqual(host.tmuxPreferences.defaultSession, "workbox")
        XCTAssertTrue(host.tmuxPreferences.autoAttach)
    }

    func testHostEncodingAndRoundTripWithTmuxPreferences() throws {
        let host = try Host(
            name: "RoundTrip Host",
            hostname: "rt.invalid",
            port: 22,
            username: "tester",
            defaultTmuxSession: "main",
            autoAttachTmux: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(host)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Host.self, from: data)

        XCTAssertEqual(decoded.id, host.id)
        XCTAssertEqual(decoded.name, "RoundTrip Host")
        XCTAssertEqual(decoded.defaultTmuxSession, "main")
        XCTAssertTrue(decoded.autoAttachTmux)
    }

    // MARK: - Reconnect Coordinator: Backoff & Jitter Bounds

    func testReconnectCoordinatorBaseBackoffProgression() {
        XCTAssertEqual(ReconnectCoordinator.baseDelay(for: 1), 1.0)
        XCTAssertEqual(ReconnectCoordinator.baseDelay(for: 2), 2.0)
        XCTAssertEqual(ReconnectCoordinator.baseDelay(for: 3), 4.0)
        XCTAssertEqual(ReconnectCoordinator.baseDelay(for: 4), 8.0)
        XCTAssertEqual(ReconnectCoordinator.baseDelay(for: 5), 16.0)
        // Capped at 32 seconds
        XCTAssertEqual(ReconnectCoordinator.baseDelay(for: 6), 32.0)
        XCTAssertEqual(ReconnectCoordinator.baseDelay(for: 7), 32.0)
    }

    func testReconnectCoordinatorJitterBounds() {
        let expectedBases: [TimeInterval] = [1.0, 2.0, 4.0, 8.0, 16.0]

        for (index, base) in expectedBases.enumerated() {
            let attempt = index + 1
            for _ in 0..<200 {
                let jitterOffset = ReconnectCoordinator.defaultJitter(base)
                XCTAssertGreaterThanOrEqual(jitterOffset, 0.0, "Jitter must never be negative")
                let maxAllowedJitter = min(1.0, base * 0.25)
                XCTAssertLessThanOrEqual(jitterOffset, maxAllowedJitter, "Jitter must be bounded by min(1.0, base * 0.25)")

                let totalDelay = ReconnectCoordinator.delay(for: attempt, jitter: ReconnectCoordinator.defaultJitter)
                XCTAssertGreaterThanOrEqual(totalDelay, base, "Total delay must be at least base delay")
                XCTAssertLessThanOrEqual(totalDelay, 32.0, "Total delay must never exceed 32s cap")
            }
        }
    }

    // MARK: - Reconnect Coordinator: Max Attempts & Retries

    func testReconnectCoordinatorMaxAttemptsExhaustion() async {
        let coordinator = ReconnectCoordinator(
            clock: { _ in },
            jitter: ReconnectCoordinator.zeroJitter
        )

        let attemptsRecorded = ManagedAtomicIntArray()

        let expectation = expectation(description: "Coordinator reaches exhausted")
        await coordinator.setStateChangeHandler { state in
            if case .exhausted(let attempts) = state {
                XCTAssertEqual(attempts, 5)
                expectation.fulfill()
            }
        }

        await coordinator.start { attempt in
            await attemptsRecorded.append(attempt)
            throw TransportError.networkUnavailable
        }

        await fulfillment(of: [expectation], timeout: 2.0)

        let history = await attemptsRecorded.get()
        XCTAssertEqual(history, [1, 2, 3, 4, 5], "Coordinator must execute exactly 5 attempts in sequence before exhausting")
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .exhausted(attempts: 5))
    }

    func testReconnectCoordinatorSuccessHaltsRetries() async {
        let coordinator = ReconnectCoordinator(
            clock: { _ in },
            jitter: ReconnectCoordinator.zeroJitter
        )

        let attemptsRecorded = ManagedAtomicIntArray()

        let expectation = expectation(description: "Coordinator succeeds on attempt 3")
        await coordinator.setStateChangeHandler { state in
            if state == .connected {
                expectation.fulfill()
            }
        }

        await coordinator.start { attempt in
            await attemptsRecorded.append(attempt)
            if attempt < 3 {
                throw TransportError.timeout
            }
            // Attempt 3 succeeds!
        }

        await fulfillment(of: [expectation], timeout: 2.0)

        let history = await attemptsRecorded.get()
        XCTAssertEqual(history, [1, 2, 3], "Retries must stop once connection succeeds")
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .connected)
    }

    // MARK: - Reconnect Coordinator: Cancellation

    func testReconnectCoordinatorCancellation() async throws {
        let resumeGate = TestGate()
        let coordinator = ReconnectCoordinator(
            clock: { _ in
                await resumeGate.wait()
            },
            jitter: ReconnectCoordinator.zeroJitter
        )

        let cancelledExpectation = expectation(description: "Coordinator enters cancelled state")
        await coordinator.setStateChangeHandler { state in
            if state == .cancelled {
                cancelledExpectation.fulfill()
            }
        }

        await coordinator.start { _ in }

        // Allow start loop to transition into waiting
        try await Task.sleep(nanoseconds: 20_000_000)

        await coordinator.cancel()

        await fulfillment(of: [cancelledExpectation], timeout: 2.0)
        let state = await coordinator.state
        XCTAssertEqual(state, .cancelled)

        // Opening gate after cancellation must not resume retries
        await resumeGate.open()
        try await Task.sleep(nanoseconds: 20_000_000)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .cancelled)
    }

    // MARK: - Reconnect Coordinator: Stale Generation Guards

    func testReconnectCoordinatorStaleGenerationGuards() async throws {
        let connectGate = TestGate()
        let startedGate = TestGate()
        let coordinator = ReconnectCoordinator(
            clock: { _ in },
            jitter: ReconnectCoordinator.zeroJitter
        )

        await coordinator.start { attempt in
            await startedGate.open()
            await connectGate.wait()
            // Delayed completion after generation change
        }

        // Wait until connect action has started
        await startedGate.wait()

        // Cancel while connect action is suspended inside connectGate
        await coordinator.cancel()
        let cancelledState = await coordinator.state
        XCTAssertEqual(cancelledState, .cancelled)

        // Now resume the suspended connect action from generation 1
        await connectGate.open()
        try await Task.sleep(nanoseconds: 30_000_000)

        // State must NOT be mutated to .connected by the stale attempt
        let stateAfterStaleCompletion = await coordinator.state
        XCTAssertEqual(stateAfterStaleCompletion, .cancelled, "Stale attempt completion must be ignored by generation guard")
    }

    func testReconnectCoordinatorNonRetryableErrorHaltsImmediately() async {
        let coordinator = ReconnectCoordinator(
            clock: { _ in },
            jitter: ReconnectCoordinator.zeroJitter
        )

        let attemptsRecorded = ManagedAtomicIntArray()
        let failedExpectation = expectation(description: "Coordinator fails immediately on non-retryable error")

        await coordinator.setStateChangeHandler { state in
            if case .failed = state {
                failedExpectation.fulfill()
            }
        }

        await coordinator.start { attempt in
            await attemptsRecorded.append(attempt)
            throw TransportError.hostKeyChanged(old: "SHA256:old", new: "SHA256:new")
        }

        await fulfillment(of: [failedExpectation], timeout: 2.0)

        let history = await attemptsRecorded.get()
        XCTAssertEqual(history, [1], "Non-retryable error must halt retries immediately after attempt 1")
    }

    // MARK: - Restoration Metadata & In-Memory Store

    func testSessionRestorationMetadataAndInMemoryStore() async throws {
        let hostID = UUID()
        let sessionID = UUID()
        let now = Date()

        let metadata = SessionRestorationMetadata(
            hostID: hostID,
            sessionID: sessionID,
            tmuxSessionID: "$0",
            timestamp: now
        )

        let store = InMemorySessionRestorationStore()
        let initialLoad = try await store.load()
        XCTAssertNil(initialLoad)

        try await store.save(metadata)
        let loaded = try await store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.hostID, hostID)
        XCTAssertEqual(loaded?.sessionID, sessionID)
        XCTAssertEqual(loaded?.tmuxSessionID, "$0")
        XCTAssertEqual(loaded?.timestamp, now)

        try await store.clear()
        let clearedLoad = try await store.load()
        XCTAssertNil(clearedLoad)
    }
}

// MARK: - Test Helpers

private actor ManagedAtomicIntArray {
    private var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }

    func get() -> [Int] {
        values
    }
}

private actor TestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { cont in
            continuations.append(cont)
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
