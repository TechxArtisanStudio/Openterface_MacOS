import AppKit
import ORSSerial
import XCTest
@testable import openterface

final class LocalPasteTests: XCTestCase {
    private final class RecordingKeyboardManager: KeyboardManagerProtocol {
        var inputs: [KeyboardInput] = []
        var sentTexts: [String] = []
        var modifierReleaseCount = 0

        func sendKeyboardInput(_ input: KeyboardInput) {
            inputs.append(input)
        }

        func sendSpecialKey(_ key: SpecialKey) {}
        func executeKeyboardMacro(_ macro: KeyboardMacro) {}

        func sendTextToKeyboard(text: String) {
            sentTexts.append(text)
        }

        func releaseAllModifierKeysForPaste() {
            modifierReleaseCount += 1
        }
    }

    private var keyboardManager: RecordingKeyboardManager!
    private var previousKeyboardManager: KeyboardManagerProtocol?
    private var previousPasteBehavior: PasteBehavior!
    private var previousKeyboardLayout: KeyboardLayout!

    override func setUp() {
        super.setUp()

        let container = DependencyContainer.shared
        if container.isRegistered(KeyboardManagerProtocol.self) {
            previousKeyboardManager = container.resolve(KeyboardManagerProtocol.self)
        }

        keyboardManager = RecordingKeyboardManager()
        container.register(KeyboardManagerProtocol.self, instance: keyboardManager as KeyboardManagerProtocol)

        previousPasteBehavior = UserSettings.shared.pasteBehavior
        previousKeyboardLayout = UserSettings.shared.keyboardLayout
    }

    override func tearDown() {
        UserSettings.shared.pasteBehavior = previousPasteBehavior
        UserSettings.shared.keyboardLayout = previousKeyboardLayout

        if let previousKeyboardManager {
            DependencyContainer.shared.register(
                KeyboardManagerProtocol.self,
                instance: previousKeyboardManager
            )
        } else {
            DependencyContainer.shared.unregister(KeyboardManagerProtocol.self)
        }

        keyboardManager = nil
        previousKeyboardManager = nil
        super.tearDown()
    }

    func testAlwaysLocalPasteEmitsCommandVForMacTarget() {
        UserSettings.shared.pasteBehavior = .alwaysPassToTarget
        UserSettings.shared.keyboardLayout = .mac

        ClipboardManager.shared.handlePasteRequest(with: "host clipboard text")

        assertSinglePasteInput(keyCode: 9, modifier: .command)
        XCTAssertEqual(keyboardManager.modifierReleaseCount, 1)
        XCTAssertTrue(keyboardManager.sentTexts.isEmpty)
    }

    func testEmptyHostClipboardDefaultsToLocalPaste() {
        UserSettings.shared.pasteBehavior = .alwaysPasteToTarget
        UserSettings.shared.keyboardLayout = .mac
        let pasteboard = makePasteboard()

        ClipboardManager.shared.handlePasteRequest(from: pasteboard)

        assertSinglePasteInput(keyCode: 9, modifier: .command)
        XCTAssertEqual(keyboardManager.modifierReleaseCount, 1)
        XCTAssertTrue(keyboardManager.sentTexts.isEmpty)
    }

    func testNonTextHostClipboardDefaultsToLocalPaste() {
        UserSettings.shared.pasteBehavior = .askEveryTime
        UserSettings.shared.keyboardLayout = .mac
        let pasteboard = makePasteboard()
        pasteboard.setData(Data([0x00]), forType: .png)

        ClipboardManager.shared.handlePasteRequest(from: pasteboard)

        assertSinglePasteInput(keyCode: 9, modifier: .command)
        XCTAssertEqual(keyboardManager.modifierReleaseCount, 1)
        XCTAssertTrue(keyboardManager.sentTexts.isEmpty)
    }

    func testAskEveryTimeLocalActionEmitsControlVForWindowsTarget() {
        UserSettings.shared.pasteBehavior = .askEveryTime
        UserSettings.shared.keyboardLayout = .windows

        ClipboardManager.shared.handlePasteAction(.passToHost, content: "host clipboard text")

        assertSinglePasteInput(keyCode: 9, modifier: .control)
        XCTAssertEqual(keyboardManager.modifierReleaseCount, 1)
        XCTAssertTrue(keyboardManager.sentTexts.isEmpty)
    }

    func testLocalPasteEmitsControlVForLinuxTarget() {
        UserSettings.shared.keyboardLayout = .linux

        ClipboardManager.shared.handlePasteAction(.passToHost, content: "host clipboard text")

        assertSinglePasteInput(keyCode: 9, modifier: .control)
        XCTAssertEqual(keyboardManager.modifierReleaseCount, 1)
        XCTAssertTrue(keyboardManager.sentTexts.isEmpty)
    }

    func testHostPasteStillTypesHostClipboardContent() {
        UserSettings.shared.pasteBehavior = .alwaysPasteToTarget

        ClipboardManager.shared.handlePasteRequest(with: "Hello")

        XCTAssertEqual(keyboardManager.sentTexts, ["Hello"])
        XCTAssertTrue(keyboardManager.inputs.isEmpty)
        XCTAssertEqual(keyboardManager.modifierReleaseCount, 0)
    }

    func testCancelSendsNoTargetInput() {
        ClipboardManager.shared.handlePasteAction(.cancel, content: "Hello")

        XCTAssertTrue(keyboardManager.inputs.isEmpty)
        XCTAssertTrue(keyboardManager.sentTexts.isEmpty)
        XCTAssertEqual(keyboardManager.modifierReleaseCount, 0)
    }

    private func makePasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("LocalPasteTests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        return pasteboard
    }

    private func assertSinglePasteInput(
        keyCode: UInt16,
        modifier: NSEvent.ModifierFlags,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(keyboardManager.inputs.count, 1, file: file, line: line)
        guard let input = keyboardManager.inputs.first else { return }

        XCTAssertEqual(input.keyCode, keyCode, file: file, line: line)
        XCTAssertEqual(
            input.modifiers.intersection([.command, .control, .option, .shift]),
            modifier,
            file: file,
            line: line
        )
    }
}

final class KeyboardInputReleaseTests: XCTestCase {
    private final class RecordingKeyboardMapper: KeyboardMapper {
        var presses: [(keys: [UInt16], modifiers: NSEvent.ModifierFlags)] = []
        var releases: [[UInt16]] = []

        override func pressKey(keys: [UInt16], modifiers: NSEvent.ModifierFlags) {
            presses.append((keys, modifiers))
        }

        override func releaseKey(keys: [UInt16]) {
            releases.append(keys)
        }
    }

    func testSendKeyboardInputReleasesVAndCommand() {
        let mapper = RecordingKeyboardMapper()
        let manager = KeyboardManager(
            keyboardMapper: mapper,
            monitorEvents: false,
            pollCapsLock: false
        )

        manager.sendKeyboardInput(KeyboardInput(keyCode: 9, modifiers: .command))

        XCTAssertEqual(mapper.presses.count, 1)
        XCTAssertEqual(mapper.presses.first?.keys.filter { $0 != 255 }, [9])
        XCTAssertEqual(mapper.presses.first?.modifiers, .command)
        XCTAssertEqual(mapper.releases.count, 1)
        XCTAssertTrue(mapper.releases[0].allSatisfy { $0 == 255 })
        XCTAssertTrue(manager.pressedKeys.allSatisfy { $0 == 255 })
    }
}

/// End-to-end byte-level tests: ClipboardManager -> real KeyboardManager ->
/// real KeyboardMapper -> captured serial HID reports.
final class LocalPasteHIDReportTests: XCTestCase {
    private final class RecordingSerialPortManager: SerialPortManagerProtocol {
        var commands: [[UInt8]] = []
        var isDeviceReady: Bool = true
        var baudrate: Int = 115200
        var serialPort: ORSSerialPort? { nil }
        var lastSerialDate: Date? { nil }

        func sendAsyncCommand(command: [UInt8], force: Bool) { commands.append(command) }

        func tryOpenSerialPort(priorityBaudrate: Int?) {}
        func tryOpenSerialPortForCH32V208() {}
        func tryOpenSerialPortForCH32V208Sync(timeout: TimeInterval) -> Bool { true }
        func closeSerialPort() {}
        func openSerialPort(baudrate: Int) {}
        func pauseConnectionAttempts() {}
        func resumeConnectionAttempts() {}
        func getChipParameterCfg() {}
        func resetHidChip() {}
        func resetHidChipToFactory(completion: @escaping (Bool) -> Void) { completion(true) }
        func getHidInfo() {}
        func setSdToHost(force: Bool, completion: @escaping (Bool) -> Void) { completion(true) }
        func setSdToTarget(force: Bool, completion: @escaping (Bool) -> Void) { completion(true) }
        func querySdDirection(force: Bool, completion: @escaping (SDCardDirection?) -> Void) { completion(nil) }
        func querySdDirectionSync(timeout: TimeInterval, force: Bool) -> SDCardDirection? { nil }
        func setDTR(_ enabled: Bool) {}
        func lowerDTR() {}
        func raiseDTR() {}
        func setRTS(_ enabled: Bool) -> Bool { true }
        func lowerRTS() -> Bool { true }
        func raiseRTS() -> Bool { true }
    }

    private var serial: RecordingSerialPortManager!
    private var previousSerial: SerialPortManagerProtocol?
    private var previousKeyboardManager: KeyboardManagerProtocol?
    private var previousPasteBehavior: PasteBehavior!
    private var previousKeyboardLayout: KeyboardLayout!

    override func setUp() {
        super.setUp()

        let container = DependencyContainer.shared
        if container.isRegistered(SerialPortManagerProtocol.self) {
            previousSerial = container.resolve(SerialPortManagerProtocol.self)
        }
        serial = RecordingSerialPortManager()
        container.register(SerialPortManagerProtocol.self, instance: serial as SerialPortManagerProtocol)

        if container.isRegistered(KeyboardManagerProtocol.self) {
            previousKeyboardManager = container.resolve(KeyboardManagerProtocol.self)
        }
        let manager = KeyboardManager(monitorEvents: false, pollCapsLock: false)
        container.register(KeyboardManagerProtocol.self, instance: manager as KeyboardManagerProtocol)
        serial.commands.removeAll()

        previousPasteBehavior = UserSettings.shared.pasteBehavior
        previousKeyboardLayout = UserSettings.shared.keyboardLayout
        UserSettings.shared.pasteBehavior = .alwaysPassToTarget
    }

    override func tearDown() {
        UserSettings.shared.pasteBehavior = previousPasteBehavior
        UserSettings.shared.keyboardLayout = previousKeyboardLayout

        let container = DependencyContainer.shared
        if let previousKeyboardManager {
            container.register(KeyboardManagerProtocol.self, instance: previousKeyboardManager)
        } else {
            container.unregister(KeyboardManagerProtocol.self)
        }
        if let previousSerial {
            container.register(SerialPortManagerProtocol.self, instance: previousSerial)
        } else {
            container.unregister(SerialPortManagerProtocol.self)
        }

        serial = nil
        previousSerial = nil
        previousKeyboardManager = nil
        super.tearDown()
    }

    func testMacLocalPasteEmitsGuiPlusVHIDReport() {
        UserSettings.shared.keyboardLayout = .mac

        ClipboardManager.shared.handlePasteRequest(with: "host clipboard text")

        assertPasteReports(modifierByte: 0x08)
    }

    func testWindowsLocalPasteEmitsControlPlusVHIDReport() {
        UserSettings.shared.keyboardLayout = .windows

        ClipboardManager.shared.handlePasteRequest(with: "host clipboard text")

        assertPasteReports(modifierByte: 0x01)
    }

    func testEmptyClipboardTextSkipsDialogAndEmitsLocalPaste() {
        UserSettings.shared.keyboardLayout = .mac
        UserSettings.shared.pasteBehavior = .askEveryTime

        ClipboardManager.shared.handlePasteRequest(with: "")

        assertPasteReports(modifierByte: 0x08)
    }

    private func assertPasteReports(
        modifierByte: UInt8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(serial.commands.count, 3, "expected pre-release, press and release reports", file: file, line: line)
        guard serial.commands.count == 3 else { return }
        let preRelease = serial.commands[0]
        let press = serial.commands[1]
        let release = serial.commands[2]

        for report in [preRelease, press, release] {
            XCTAssertEqual(report.count, 14, file: file, line: line)
            XCTAssertEqual(Array(report.prefix(5)), [0x57, 0xAB, 0x00, 0x02, 0x08], file: file, line: line)
            XCTAssertEqual(report[13], UInt8(report.prefix(13).reduce(0) { $0 + Int($1) } & 0xFF), "checksum mismatch", file: file, line: line)
        }

        XCTAssertEqual(Array(preRelease[5...12]), Array(repeating: 0, count: 8), "pre-release report must clear modifiers and all key slots", file: file, line: line)

        XCTAssertEqual(press[5], modifierByte, "modifier byte", file: file, line: line)
        XCTAssertEqual(press[7], 0x19, "HID scancode for V", file: file, line: line)
        XCTAssertEqual(Array(press[6...6]) + Array(press[8...12]), [0, 0, 0, 0, 0, 0], "no extra keys in press report", file: file, line: line)

        XCTAssertEqual(Array(release[5...12]), Array(repeating: 0, count: 8), "release report must clear modifiers and all key slots", file: file, line: line)
    }
}
