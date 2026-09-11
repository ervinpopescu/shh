import XCTest
import ShhCore
@testable import ShhTerminal

final class ResizeDebounceTests: XCTestCase {
    func testTrailingDebounceDeliversOnlyLastSize() {
        let expectation = expectation(description: "Debounced resize delivered")
        var deliveredSizes: [TerminalSize] = []

        let debouncer = ResizeDebouncer(delay: 0.050, queue: .main) { size in
            deliveredSizes.append(size)
            expectation.fulfill()
        }

        // Rapid stream of resizes within 50ms
        debouncer.receive(columns: 80, rows: 24)
        debouncer.receive(columns: 90, rows: 25)
        debouncer.receive(columns: 100, rows: 30)
        debouncer.receive(columns: 120, rows: 40)

        // Only the final size should be delivered
        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(deliveredSizes.count, 1)
        XCTAssertEqual(deliveredSizes.first, TerminalSize(columns: 120, rows: 40))
        XCTAssertEqual(debouncer.latestDeliveredSize, TerminalSize(columns: 120, rows: 40))
        XCTAssertFalse(debouncer.hasPendingResize)
    }

    func testTrailingTimerResetsOnSubsequentCall() {
        let expectation = expectation(description: "Debounced resize delivered after quiet period")
        var deliveredSizes: [TerminalSize] = []

        let debouncer = ResizeDebouncer(delay: 0.060, queue: .main) { size in
            deliveredSizes.append(size)
            expectation.fulfill()
        }

        debouncer.receive(columns: 80, rows: 24)

        // After 30ms (before 60ms fires), send another resize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.030) {
            debouncer.receive(columns: 100, rows: 35)
        }

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(deliveredSizes.count, 1)
        XCTAssertEqual(deliveredSizes.first, TerminalSize(columns: 100, rows: 35))
    }

    func testFlushImmediatelyDeliversPendingSize() {
        var deliveredSizes: [TerminalSize] = []

        let debouncer = ResizeDebouncer(delay: 1.0, queue: .main) { size in
            deliveredSizes.append(size)
        }

        debouncer.receive(columns: 140, rows: 45)
        XCTAssertTrue(debouncer.hasPendingResize)
        XCTAssertEqual(deliveredSizes.count, 0)

        debouncer.flush()
        XCTAssertFalse(debouncer.hasPendingResize)
        XCTAssertEqual(deliveredSizes.count, 1)
        XCTAssertEqual(deliveredSizes.first, TerminalSize(columns: 140, rows: 45))
    }

    func testCancelDiscardsPendingSize() {
        var deliveredSizes: [TerminalSize] = []

        let debouncer = ResizeDebouncer(delay: 0.040, queue: .main) { size in
            deliveredSizes.append(size)
        }

        debouncer.receive(columns: 160, rows: 50)
        XCTAssertTrue(debouncer.hasPendingResize)

        debouncer.cancel()
        XCTAssertFalse(debouncer.hasPendingResize)
        XCTAssertNil(debouncer.latestPendingSize)

        // Wait to verify timer doesn't fire
        let waitExp = expectation(description: "Wait after cancel")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.070) {
            waitExp.fulfill()
        }
        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(deliveredSizes.count, 0)
    }

    func testDefaultDebounceIntervalIs150ms() {
        let debouncer = ResizeDebouncer { _ in }
        XCTAssertEqual(debouncer.delay, 0.150, accuracy: 0.001)
    }
}
