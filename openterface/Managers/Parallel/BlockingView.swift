import AppKit
import CoreGraphics

// Transparent view that blocks all mouse events (prevents clicks passing to system)
final class BlockingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only block mouse events when the mouse is considered inside the target region.
        // When not in target, return nil so events pass through to underlying windows.
        return isMouseInTargetState ? self : nil
    }

    override var acceptsFirstResponder: Bool { return true }

    // Edge-wrapping state
    private var lastWarpTime: Date?
    private let warpCooldown: TimeInterval = 0.5
    private let edgeThreshold: CGFloat = 5.0
    private var isMouseInTargetState: Bool = false
    // Track last modifier flags to detect presses/releases
    private var lastModifierFlags: NSEvent.ModifierFlags = []

    private func enqueueMouseEvent(_ event: NSEvent, mouseEventCode: UInt8) {
        // Use global mouse location similar to HIDMonitor for consistency
        let globalPoint = NSEvent.mouseLocation
        checkAndWrapMouseAtEdges(globalPoint)
        // If we're not currently in the target state, do not forward mouse events to the target
        if !isMouseInTargetState {
            let logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
            logger.log(content: "[BlockingView] Mouse event ignored because mouse not in target")

            showCursorOnAllDisplays()
            return
        }

        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(globalPoint, $0.frame, false) }) else { return }
        let screenFrame = targetScreen.frame

        let absX = Int((globalPoint.x - screenFrame.minX) / screenFrame.width * 4096.0)
        let absY = Int((screenFrame.maxY - globalPoint.y) / screenFrame.height * 4096.0)
        let clampedX = max(0, min(4096, absX))
        let clampedY = max(0, min(4096, absY))

        let logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
        logger.log(content: "[BlockingView][MouseInTarget:\(isMouseInTargetState)] Overlay mouse event -> code:\(mouseEventCode) x:\(clampedX) y:\(clampedY)")
        MouseManager.shared.enqueueAbsoluteMouseEvent(x: clampedX, y: clampedY, mouseEvent: mouseEventCode, wheelMovement: 0)

    }

    private func checkAndWrapMouseAtEdges(_ mouseLocation: NSPoint) {
        print("Checking mouse at location: \(mouseLocation)")
        // Prevent rapid repeated warps
        if let last = lastWarpTime, Date().timeIntervalSince(last) < warpCooldown { return }

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) else { return }
        let screenFrame = screen.frame
        var newLocation = mouseLocation
        let placement = UserSettings.shared.targetComputerPlacement

        if !isMouseInTargetState {
            switch placement {
            case .right:
                if mouseLocation.x >= screenFrame.maxX - edgeThreshold {
                    newLocation.x = screenFrame.minX + edgeThreshold
                    newLocation.y = screenFrame.maxY - mouseLocation.y
                }
            case .left:
                if mouseLocation.x <= screenFrame.minX + edgeThreshold {
                    newLocation.x = screenFrame.maxX - edgeThreshold
                    newLocation.y = screenFrame.maxY - mouseLocation.y
                }
            case .top:
                if mouseLocation.y >= screenFrame.maxY - edgeThreshold {
                    newLocation.y = screenFrame.minY + edgeThreshold
                }
            case .bottom:
                if mouseLocation.y <= screenFrame.minY + edgeThreshold {
                    newLocation.y = screenFrame.maxY - edgeThreshold
                }
            }

            if newLocation != mouseLocation {
                lastWarpTime = Date()
                CGWarpMouseCursorPosition(newLocation)
                isMouseInTargetState = true
                // Hide cursor immediately (display-level + NSCursor) when entering target
                hideCursorOnAllDisplays()
                NSCursor.hide()
                // Ensure the overlay window captures events when inside target
                if let w = self.window {
                    w.ignoresMouseEvents = false
                }
                NotificationCenter.default.post(name: .mouseEnteredTarget, object: nil)
            }
        } else {
            switch placement {
            case .right:
                if mouseLocation.x <= screenFrame.minX + edgeThreshold {
                    newLocation.x = screenFrame.maxX - edgeThreshold
                    newLocation.y = screenFrame.maxY - mouseLocation.y
                    isMouseInTargetState = false
                }
            case .left:
                if mouseLocation.x >= screenFrame.maxX - edgeThreshold {
                    newLocation.x = screenFrame.minX + edgeThreshold
                    newLocation.y = screenFrame.maxY - mouseLocation.y
                    isMouseInTargetState = false
                }
            case .top:
                if mouseLocation.y <= screenFrame.minY + edgeThreshold {
                    newLocation.y = screenFrame.maxY - edgeThreshold
                    isMouseInTargetState = false
                }
            case .bottom:
                if mouseLocation.y >= screenFrame.maxY - edgeThreshold {
                    newLocation.y = screenFrame.minY + edgeThreshold
                    isMouseInTargetState = false
                }
            }

            if newLocation != mouseLocation {
                lastWarpTime = Date()
                CGWarpMouseCursorPosition(newLocation)
                // Show cursor immediately when exiting target
                showCursorOnAllDisplays()
                NSCursor.unhide()
                // Allow events to pass through to the system when not in target
                if let w = self.window {
                    w.ignoresMouseEvents = true
                }
                NotificationCenter.default.post(name: .mouseExitedTarget, object: nil)
            }
        }
    }

    // local helpers to hide/show cursor on all displays
    private func hideCursorOnAllDisplays() {
        let logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
        logger.log(content: "[BlockingView] Hiding cursor on all displays")
        var activeCount: UInt32 = 0
        var result = CGGetActiveDisplayList(0, nil, &activeCount)
        if result != .success { return }
        let allocated = Int(activeCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: allocated)
        result = CGGetActiveDisplayList(activeCount, &displays, &activeCount)
        if result != .success { return }
        for d in displays { CGDisplayHideCursor(d) }
        NSCursor.hide()
    }

    private func showCursorOnAllDisplays() {
        let logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
        logger.log(content: "[BlockingView] Showing cursor on all displays")
        var activeCount: UInt32 = 0
        var result = CGGetActiveDisplayList(0, nil, &activeCount)
        if result != .success { return }
        let allocated = Int(activeCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: allocated)
        result = CGGetActiveDisplayList(activeCount, &displays, &activeCount)
        if result != .success { return }
        for d in displays { CGDisplayShowCursor(d) }
        NSCursor.unhide()
    }

    override func mouseMoved(with event: NSEvent) {
        enqueueMouseEvent(event, mouseEventCode: 0x00)
    }

    override func mouseDragged(with event: NSEvent) {
        // Treat drag as button-held movement: map to left button while dragging
        enqueueMouseEvent(event, mouseEventCode: 0x01)
    }

    override func rightMouseDragged(with event: NSEvent) {
        enqueueMouseEvent(event, mouseEventCode: 0x02)
    }

    override func otherMouseDragged(with event: NSEvent) {
        enqueueMouseEvent(event, mouseEventCode: 0x04)
    }

    override func mouseDown(with event: NSEvent) {
        enqueueMouseEvent(event, mouseEventCode: 0x01)
    }

    override func mouseUp(with event: NSEvent) {
        enqueueMouseEvent(event, mouseEventCode: 0x00)
    }

    override func rightMouseDown(with event: NSEvent) {
        enqueueMouseEvent(event, mouseEventCode: 0x02)
    }

    override func rightMouseUp(with event: NSEvent) {
        enqueueMouseEvent(event, mouseEventCode: 0x00)
    }

    override func otherMouseDown(with event: NSEvent) {
        enqueueMouseEvent(event, mouseEventCode: 0x04)
    }

    override func otherMouseUp(with event: NSEvent) {
        enqueueMouseEvent(event, mouseEventCode: 0x00)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let win = self.window, let screen = win.screen else { return }
        let mouseLocation = event.locationInWindow
        let pointOnScreen = win.convertToScreen(NSRect(origin: mouseLocation, size: .zero)).origin
        let screenFrame = screen.frame
        let screenWidth = screenFrame.width
        let screenHeight = screenFrame.height

        let absX = Int((pointOnScreen.x - screenFrame.minX) / screenWidth * 4096.0)
        let absY = Int((screenFrame.maxY - pointOnScreen.y) / screenHeight * 4096.0)
        let clampedX = max(0, min(4096, absX))
        let clampedY = max(0, min(4096, absY))

        let wheel = Int(event.scrollingDeltaY * 10)
        MouseManager.shared.enqueueAbsoluteMouseEvent(x: clampedX, y: clampedY, mouseEvent: 0x00, wheelMovement: wheel)
    }

    // MARK: - Keyboard handling: forward to target KeyboardManager
    override func flagsChanged(with event: NSEvent) {
        let newFlags = event.modifierFlags
        let oldFlags = lastModifierFlags

        // Helper to press/release a special key
        func handleModifier(_ special: KeyboardMapper.SpecialKey, flag: NSEvent.ModifierFlags) {
            let km = KeyboardManager.shared
            if newFlags.contains(flag) && !oldFlags.contains(flag) {
                if let keyCode = km.kbm.fromSpecialKeyToKeyCode(code: KeyboardMapper.SpecialKey(rawValue: special.rawValue)!) {
                    km.kbm.pressKey(keys: [keyCode], modifiers: newFlags)
                }
            } else if !newFlags.contains(flag) && oldFlags.contains(flag) {
                if let keyCode = km.kbm.fromSpecialKeyToKeyCode(code: KeyboardMapper.SpecialKey(rawValue: special.rawValue)!) {
                    km.kbm.releaseKey(keys: [keyCode])
                }
            }
        }

        // Note: we map generic modifier flags to left variants when necessary
        if newFlags != oldFlags {
            handleModifier(.leftShift, flag: .shift)
            handleModifier(.leftCtrl, flag: .control)
            handleModifier(.leftAlt, flag: .option)
            handleModifier(.win, flag: .command)
            // Caps Lock handling
            if newFlags.contains(.capsLock) && !oldFlags.contains(.capsLock) {
                if let keyCode = KeyboardManager.shared.kbm.fromSpecialKeyToKeyCode(code: .capsLock) {
                    KeyboardManager.shared.kbm.pressKey(keys: [keyCode], modifiers: newFlags)
                }
            } else if !newFlags.contains(.capsLock) && oldFlags.contains(.capsLock) {
                if let keyCode = KeyboardManager.shared.kbm.fromSpecialKeyToKeyCode(code: .capsLock) {
                    KeyboardManager.shared.kbm.releaseKey(keys: [keyCode])
                }
            }
        }

        lastModifierFlags = newFlags
    }

    override func keyDown(with event: NSEvent) {
        print("[BlockingView] keyDown received: keyCode=\(event.keyCode), chars=\(String(describing: event.characters)), charsIgnoringModifiers=\(String(describing: event.charactersIgnoringModifiers))")
        // If Escape pressed, notify manager to exit parallel mode
        if event.keyCode == 53 || (event.charactersIgnoringModifiers == "\u{1b}") {
            NotificationCenter.default.post(name: .escapePressed, object: nil)
            return
        }

        // Only forward keyboard input when mouse is in target
        let pm = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)
        if !pm.isMouseInTarget { return }

        let km = KeyboardManager.shared
        // If characters (printable), send as text
        if let chars = event.characters, !chars.isEmpty {
            km.sendTextToKeyboard(text: chars)
            return
        }

        // Otherwise, send raw key press to target
        let keyCode = event.keyCode
        km.kbm.pressKey(keys: [keyCode], modifiers: event.modifierFlags)
    }

    override func keyUp(with event: NSEvent) {
        // Only forward keyUp to KeyboardManager when mouse is in target
        let pm = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)
        if !pm.isMouseInTarget { return }

        let km = KeyboardManager.shared
        let keyCode = event.keyCode
        km.kbm.releaseKey(keys: [keyCode])
    }

}
