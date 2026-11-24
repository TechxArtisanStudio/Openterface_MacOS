import XCTest
@testable import openterface

/// Regression tests for the hot-plug recovery path:
/// a capture session must be torn down when it reports "running" but no
/// longer delivers frames, otherwise the last frame stays frozen forever and
/// re-preparing on replug is skipped.
final class VideoHotplugRecoveryTests: XCTestCase {

    // MARK: - Zombie session predicate

    func testHealthyRunningSessionIsNotRestarted() {
        XCTAssertFalse(
            VideoRecoveryPolicy.sessionNeedsRestart(
                isRunning: true,
                hasInputs: true,
                secondsSinceLastFrame: 0.1
            )
        )
    }

    func testStalledRunningSessionMustRestart() {
        // This is the exact state observed after an unplug: isRunning == true,
        // the stale input is still attached, and no frames arrive.
        XCTAssertTrue(
            VideoRecoveryPolicy.sessionNeedsRestart(
                isRunning: true,
                hasInputs: true,
                secondsSinceLastFrame: VideoRecoveryPolicy.frameStaleTimeout + 5.0
            )
        )
    }

    func testRunningSessionWithoutInputsMustRestart() {
        XCTAssertTrue(
            VideoRecoveryPolicy.sessionNeedsRestart(
                isRunning: true,
                hasInputs: false,
                secondsSinceLastFrame: 0
            )
        )
    }

    func testStoppedSessionIsNeverRestarted() {
        XCTAssertFalse(
            VideoRecoveryPolicy.sessionNeedsRestart(
                isRunning: false,
                hasInputs: true,
                secondsSinceLastFrame: .infinity
            )
        )
    }

    func testStaleThresholdDiscriminates() {
        let timeout = VideoRecoveryPolicy.frameStaleTimeout
        XCTAssertFalse(
            VideoRecoveryPolicy.sessionNeedsRestart(
                isRunning: true,
                hasInputs: true,
                secondsSinceLastFrame: timeout - 0.01
            )
        )
        XCTAssertTrue(
            VideoRecoveryPolicy.sessionNeedsRestart(
                isRunning: true,
                hasInputs: true,
                secondsSinceLastFrame: timeout + 0.01
            )
        )
    }

    // MARK: - Frame staleness

    func testRecentFrameIsNotStale() {
        XCTAssertFalse(
            VideoRecoveryPolicy.isFrameStale(lastUpdate: 100.0, now: 100.5, isLive: true)
        )
    }

    func testFrameOlderThanTimeoutIsStale() {
        XCTAssertTrue(
            VideoRecoveryPolicy.isFrameStale(
                lastUpdate: 100.0,
                now: 100.0 + VideoRecoveryPolicy.frameStaleTimeout + 0.5,
                isLive: true
            )
        )
    }

    func testViewThatNeverWentLiveIsNotCleared() {
        // At launch (no device) the view holds no frame; draw() must not
        // treat that as a stale live frame.
        XCTAssertFalse(
            VideoRecoveryPolicy.isFrameStale(lastUpdate: 0, now: 10_000, isLive: false)
        )
    }

    func testLiveFlagWithoutTimestampIsStale() {
        XCTAssertTrue(
            VideoRecoveryPolicy.isFrameStale(lastUpdate: 0, now: 10_000, isLive: true)
        )
    }
}