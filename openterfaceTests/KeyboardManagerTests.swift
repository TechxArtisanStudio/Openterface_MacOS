import XCTest
import CoreGraphics
@testable import openterface

final class KeyboardManagerTests: XCTestCase {
    func testInitialCapsLockStateMatchesSystem() throws {
        // Arrange - capture system state
        let systemFlags = CGEventSource.flagsState(.combinedSessionState)
        let expectedCapsLock = systemFlags.contains(.maskAlphaShift)

    // Act - ensure shared instance is initialized and returns the same value
    let capsLockState = KeyboardManager.shared.isCapsLockOn
           // AppStatus should also reflect the same initial host state
           let appStatusCapsLockState = AppStatus.isHostCapLockOn

        // Assert
        XCTAssertEqual(capsLockState, expectedCapsLock, "KeyboardManager should reflect the system Caps Lock state at startup")
           XCTAssertEqual(appStatusCapsLockState, expectedCapsLock, "AppStatus.isHostCapLockOn should reflect the system Caps Lock state at startup")
        // AppStatus should also be in sync
           XCTAssertEqual(AppStatus.isHostCapLockOn, expectedCapsLock, "AppStatus should be set to the system Caps Lock state at startup")
    }
}
