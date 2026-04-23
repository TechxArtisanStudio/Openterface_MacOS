import SwiftUI
import AppKit

// MARK: - AIInputRouter
// Routes mouse and keyboard input to the correct low-level transport (HID or VNC).

enum AIInputRouter {
    private static var trackedMouseX: Int = 2048
    private static var trackedMouseY: Int = 2048
    private static let animatedClickDurationSeconds: Double = 2.0
    private static let animatedClickSteps: Int = 24

    private static func clampedAbsolute(_ value: Int) -> Int {
        min(max(value, 0), 4096)
    }

    private static func mapToVNCFramebuffer(absX: Int, absY: Int) -> (x: Int, y: Int) {
        let x = clampedAbsolute(absX)
        let y = clampedAbsolute(absY)
        let framebuffer = VNCClientManager.shared.framebufferSize
        let width = max(Int(framebuffer.width.rounded()), 1)
        let height = max(Int(framebuffer.height.rounded()), 1)

        let mappedX = width <= 1 ? 0 : Int((Double(x) / 4096.0) * Double(width - 1))
        let mappedY = height <= 1 ? 0 : Int((Double(y) / 4096.0) * Double(height - 1))
        return (mappedX, mappedY)
    }

    private static func keySym(for keyCode: UInt16) -> UInt32? {
        let named: [UInt16: UInt32] = [
            53: 0xFF1B,  // esc
            36: 0xFF0D,  // enter
            48: 0xFF09,  // tab
            49: 0x0020,  // space
            51: 0xFF08,  // backspace
            115: 0xFF50, // home
            119: 0xFF57, // end
            116: 0xFF55, // page up
            121: 0xFF56, // page down
            126: 0xFF52, // up
            125: 0xFF54, // down
            123: 0xFF51, // left
            124: 0xFF53, // right
            122: 0xFFBE, // f1
            120: 0xFFBF, // f2
            99:  0xFFC0, // f3
            118: 0xFFC1, // f4
            96:  0xFFC2, // f5
            97:  0xFFC3, // f6
            98:  0xFFC4, // f7
            100: 0xFFC5, // f8
            101: 0xFFC6, // f9
            109: 0xFFC7, // f10
            103: 0xFFC8, // f11
            111: 0xFFC9  // f12
        ]
        if let symbol = named[keyCode] {
            return symbol
        }

        let alphaNumeric: [UInt16: UInt32] = [
            0: 0x0061, 11: 0x0062, 8: 0x0063, 2: 0x0064, 14: 0x0065,
            3: 0x0066, 5: 0x0067, 4: 0x0068, 34: 0x0069, 38: 0x006A,
            40: 0x006B, 37: 0x006C, 46: 0x006D, 45: 0x006E, 31: 0x006F,
            35: 0x0070, 12: 0x0071, 15: 0x0072, 1: 0x0073, 17: 0x0074,
            32: 0x0075, 9: 0x0076, 13: 0x0077, 7: 0x0078, 16: 0x0079,
            6: 0x007A,
            29: 0x0030, 18: 0x0031, 19: 0x0032, 20: 0x0033, 21: 0x0034,
            23: 0x0035, 22: 0x0036, 26: 0x0037, 28: 0x0038, 25: 0x0039
        ]
        return alphaNumeric[keyCode]
    }

    private static func keySym(for scalar: UnicodeScalar) -> UInt32 {
        switch scalar {
        case "\n", "\r":
            return 0xFF0D
        case "\t":
            return 0xFF09
        default:
            return scalar.value
        }
    }

    private static func modifierKeySyms(from modifiers: NSEvent.ModifierFlags) -> [UInt32] {
        let filtered = modifiers.intersection(.deviceIndependentFlagsMask)
        var symbols: [UInt32] = []
        if filtered.contains(.control) { symbols.append(0xFFE3) }
        if filtered.contains(.option)  { symbols.append(0xFFE9) }
        if filtered.contains(.shift)   { symbols.append(0xFFE1) }
        if filtered.contains(.command) { symbols.append(0xFFEB) }
        return symbols
    }

    static func sendMouseMove(absX: Int, absY: Int) {
        let clampedX = clampedAbsolute(absX)
        let clampedY = clampedAbsolute(absY)
        trackedMouseX = clampedX
        trackedMouseY = clampedY

        if AppStatus.activeConnectionProtocol == .vnc {
            let point = mapToVNCFramebuffer(absX: clampedX, absY: clampedY)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: 0x00)
            return
        }

        HostManager.shared.handleAbsoluteMouseAction(x: clampedX, y: clampedY, mouseEvent: 0x00, wheelMovement: 0x00)
    }

    static func animatedClick(button: UInt8, absX: Int, absY: Int, isDoubleClick: Bool = false) {
        let targetX = clampedAbsolute(absX)
        let targetY = clampedAbsolute(absY)
        let startX = trackedMouseX
        let startY = trackedMouseY

        if startX != targetX || startY != targetY {
            let stepDelay = animatedClickDurationSeconds / Double(max(animatedClickSteps, 1))
            for step in 1...animatedClickSteps {
                let progress = Double(step) / Double(animatedClickSteps)
                let interpolatedX = Int((Double(startX) + Double(targetX - startX) * progress).rounded())
                let interpolatedY = Int((Double(startY) + Double(targetY - startY) * progress).rounded())
                sendMouseMove(absX: interpolatedX, absY: interpolatedY)
                Thread.sleep(forTimeInterval: stepDelay)
            }
        } else {
            sendMouseMove(absX: targetX, absY: targetY)
        }

        showClickOverlay(absX: targetX, absY: targetY)
        click(button: button, absX: targetX, absY: targetY, isDoubleClick: isDoubleClick)
    }

    static func animatedDrag(button: UInt8 = 0x01, startAbsX: Int? = nil, startAbsY: Int? = nil, endAbsX: Int, endAbsY: Int) {
        let startX = clampedAbsolute(startAbsX ?? trackedMouseX)
        let startY = clampedAbsolute(startAbsY ?? trackedMouseY)
        let targetX = clampedAbsolute(endAbsX)
        let targetY = clampedAbsolute(endAbsY)

        sendMouseMove(absX: startX, absY: startY)
        Thread.sleep(forTimeInterval: 0.05)

        if AppStatus.activeConnectionProtocol == .vnc {
            let startPoint = mapToVNCFramebuffer(absX: startX, absY: startY)
            VNCClientManager.shared.sendPointerEvent(x: startPoint.x, y: startPoint.y, buttonMask: button)

            let stepDelay = animatedClickDurationSeconds / Double(max(animatedClickSteps, 1))
            for step in 1...animatedClickSteps {
                let progress = Double(step) / Double(animatedClickSteps)
                let interpolatedX = Int((Double(startX) + Double(targetX - startX) * progress).rounded())
                let interpolatedY = Int((Double(startY) + Double(targetY - startY) * progress).rounded())
                let point = mapToVNCFramebuffer(absX: interpolatedX, absY: interpolatedY)
                VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: button)
                Thread.sleep(forTimeInterval: stepDelay)
            }

            let targetPoint = mapToVNCFramebuffer(absX: targetX, absY: targetY)
            VNCClientManager.shared.sendPointerEvent(x: targetPoint.x, y: targetPoint.y, buttonMask: 0x00)
        } else {
            HostManager.shared.handleAbsoluteMouseAction(x: startX, y: startY, mouseEvent: button, wheelMovement: 0x00)

            let stepDelay = animatedClickDurationSeconds / Double(max(animatedClickSteps, 1))
            for step in 1...animatedClickSteps {
                let progress = Double(step) / Double(animatedClickSteps)
                let interpolatedX = Int((Double(startX) + Double(targetX - startX) * progress).rounded())
                let interpolatedY = Int((Double(startY) + Double(targetY - startY) * progress).rounded())
                HostManager.shared.handleAbsoluteMouseAction(x: interpolatedX, y: interpolatedY, mouseEvent: button, wheelMovement: 0x00)
                Thread.sleep(forTimeInterval: stepDelay)
            }

            HostManager.shared.handleAbsoluteMouseAction(x: targetX, y: targetY, mouseEvent: 0x00, wheelMovement: 0x00)
        }

        trackedMouseX = targetX
        trackedMouseY = targetY
    }

    private static func showClickOverlay(absX: Int, absY: Int) {
        let normalizedX = min(max(CGFloat(absX) / 4096.0, 0.0), 1.0)
        let normalizedY = min(max(CGFloat(absY) / 4096.0, 0.0), 1.0)
        let token = UUID()

        DispatchQueue.main.async {
            AppStatus.aiClickPointNormalized = CGPoint(x: normalizedX, y: normalizedY)
            AppStatus.aiClickOverlayToken = token
            AppStatus.showAIClickOverlay = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard AppStatus.aiClickOverlayToken == token else { return }
            AppStatus.showAIClickOverlay = false
        }
    }

    static func click(button: UInt8, absX: Int, absY: Int, isDoubleClick: Bool = false) {
        if AppStatus.activeConnectionProtocol == .vnc {
            let point = mapToVNCFramebuffer(absX: absX, absY: absY)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: 0x00)
            Thread.sleep(forTimeInterval: 0.04)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: button)
            Thread.sleep(forTimeInterval: 0.04)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: 0x00)

            guard isDoubleClick else { return }
            Thread.sleep(forTimeInterval: 0.12)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: button)
            Thread.sleep(forTimeInterval: 0.04)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: 0x00)
            return
        }

        let x = clampedAbsolute(absX)
        let y = clampedAbsolute(absY)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: 0x00, wheelMovement: 0x00)
        Thread.sleep(forTimeInterval: 0.04)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: button, wheelMovement: 0x00)
        Thread.sleep(forTimeInterval: 0.04)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: 0x00, wheelMovement: 0x00)

        guard isDoubleClick else { return }
        Thread.sleep(forTimeInterval: 0.12)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: button, wheelMovement: 0x00)
        Thread.sleep(forTimeInterval: 0.04)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: 0x00, wheelMovement: 0x00)
    }

    static func sendText(_ text: String) {
        guard !text.isEmpty else { return }

        if AppStatus.activeConnectionProtocol == .vnc {
            for scalar in text.unicodeScalars {
                let sym = keySym(for: scalar)
                VNCClientManager.shared.sendKeyEvent(keySym: sym, isDown: true)
                Thread.sleep(forTimeInterval: 0.015)
                VNCClientManager.shared.sendKeyEvent(keySym: sym, isDown: false)
                Thread.sleep(forTimeInterval: 0.015)
            }
            return
        }

        KeyboardManager.shared.sendTextToKeyboard(text: text)
    }

    static func sendShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if AppStatus.activeConnectionProtocol == .vnc {
            guard let mainKeySym = keySym(for: keyCode) else { return false }
            let modifierSymbols = modifierKeySyms(from: modifiers)

            for symbol in modifierSymbols {
                VNCClientManager.shared.sendKeyEvent(keySym: symbol, isDown: true)
            }
            VNCClientManager.shared.sendKeyEvent(keySym: mainKeySym, isDown: true)
            Thread.sleep(forTimeInterval: 0.05)
            VNCClientManager.shared.sendKeyEvent(keySym: mainKeySym, isDown: false)
            for symbol in modifierSymbols.reversed() {
                VNCClientManager.shared.sendKeyEvent(keySym: symbol, isDown: false)
            }
            return true
        }

        HostManager.shared.handleKeyboardEvent(keyCode: keyCode, modifierFlags: modifiers, isKeyDown: true)
        Thread.sleep(forTimeInterval: 0.05)
        HostManager.shared.handleKeyboardEvent(keyCode: keyCode, modifierFlags: modifiers, isKeyDown: false)
        return true
    }
}
