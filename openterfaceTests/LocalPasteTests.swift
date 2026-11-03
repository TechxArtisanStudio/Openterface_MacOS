import AppKit
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
