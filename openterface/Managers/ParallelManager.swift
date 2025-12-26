/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation version 3.                                 *
*                                                                            *
*    This program is distributed in the hope that it will be useful, but     *
*    WITHOUT ANY WARRANTY; without even the implied warranty of              *
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU        *
*    General Public License for more details.                                *
*                                                                            *
*    You should have received a copy of the GNU General Public License       *
*    along with this program. If not, see <http://www.gnu.org/licenses/>.    *
*                                                                            *
* ========================================================================== *
*/

import SwiftUI
import AppKit
import CoreGraphics


// Transparent view that blocks all mouse events (prevents clicks passing to system)
private class BlockingView: NSView {
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

// Overlay notifications
extension Notification.Name {
    static let overlayShown = Notification.Name("OverlayShownNotification")
    static let overlayHidden = Notification.Name("OverlayHiddenNotification")
    static let mouseEnteredTarget = Notification.Name("MouseEnteredTargetNotification")
    static let mouseExitedTarget = Notification.Name("MouseExitedTargetNotification")
    static let escapePressed = Notification.Name("EscapePressedNotification")
}

class ParallelManager: ParallelManagerProtocol {
    private var logger: LoggerProtocol { DependencyContainer.shared.resolve(LoggerProtocol.self) }
    
    private(set) var isParallelModeEnabled: Bool = false
    private var isExitingParallelMode: Bool = false
    
    // Overlay window shown when mouse enters target space
    private var overlayWindow: NSWindow?
    var isMouseInTarget: Bool = false
    // Cursor hiding and mouse monitors while overlay is active
    private var mouseLocalMonitor: Any?
    private var mouseGlobalMonitor: Any?
    private var keyboardMonitors: [Any]?

    private var cursorHideCount: Int = 0
    // Store main window original state so we can restore it after parallel mode
    private var mainWindowOriginalFrame: NSRect?
    private var mainWindowOriginalLevel: NSWindow.Level?
    private var mainWindowOriginalIsOpaque: Bool?
    private var mainWindowOriginalBackgroundColor: NSColor?
    private var mainWindowOriginalTitlebarTransparent: Bool?
    private var mainWindowOriginalStyleMask: NSWindow.StyleMask?
    // Display-level cursor hiding bookkeeping
    private var hiddenDisplayIDs: [CGDirectDisplayID] = []
    
    func enterParallelMode() {
        guard !isParallelModeEnabled else { return }
        
        isParallelModeEnabled = true
        logger.log(content: "Entering parallel mode - parallel overlay active")
        
        // Show overlay indicator in main window instead of hiding the app
        AppStatus.showParallelOverlay = true
        // Shrink and move main window to top-center
        shrinkMainWindowToIndicator()
        // Show blocking overlay immediately on the main screen
        if let primary = NSScreen.main ?? NSScreen.screens.first {
            showOverlay(for: primary)
            // Ensure the cursor is visible in the blocking view when entering parallel mode.
            // showOverlay runs async; schedule a short follow-up to unhide the cursor and
            // make the blocker the first responder once the window is available.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self else { return }
                self.showCursorOnAllDisplays()
                // Balance any NSCursor hides performed by showOverlay
                if self.cursorHideCount > 0 {
                    NSCursor.unhide()
                    self.cursorHideCount = max(0, self.cursorHideCount - 1)
                } else {
                    NSCursor.unhide()
                }
                if let overlay = self.overlayWindow {
                    overlay.makeKeyAndOrderFront(nil)
                    if let blocker = overlay.contentView {
                        overlay.makeFirstResponder(blocker)
                    }
                }
            }
        }
    }
    
    func exitParallelMode() {
        guard isParallelModeEnabled else { return }
        
        isParallelModeEnabled = false
        isExitingParallelMode = true
        logger.log(content: "Exiting parallel mode - hiding parallel overlay")
        
        // Reset mouse target state
        isMouseInTarget = false
        
        // Remove overlay indicator
        AppStatus.showParallelOverlay = false
        // Hide any active overlay immediately
        hideOverlay()
        // Restore main window to original state
        restoreMainWindow()
        
        // Reset the exiting flag after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isExitingParallelMode = false
        }
        // If there was an activation observer, remove it
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    
    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        // No automatic hiding when parallel mode is active; keep main window visible.
        return
    }

    @objc private func handleMouseEnteredTarget(_ notification: Notification) {
        isMouseInTarget = true
    }

    @objc private func handleMouseExitedTarget(_ notification: Notification) {
        isMouseInTarget = false
    }

    @objc private func handleEscapePressed(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.exitParallelMode()
        }
    }
    
    func toggleParallelMode() {
        if isParallelModeEnabled {
            exitParallelMode()
        } else {
            enterParallelMode()
        }
    }
    
    func shouldPreventTermination() -> Bool {
        return isParallelModeEnabled || isExitingParallelMode
    }
    
    
    
    // MARK: - Semi-transparent overlay
    
    private func showOverlay(for screen: NSScreen) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // If overlay already exists, just update its frame to target screen
            if let existing = self.overlayWindow {
                existing.setFrame(screen.frame, display: true)
                return
            }

            let frame = screen.frame
            let window = NSWindow(contentRect: frame,
                                  styleMask: .borderless,
                                  backing: .buffered,
                                  defer: false,
                                  screen: screen)

            window.level = .screenSaver
            window.isOpaque = false
            // Make the overlay fully transparent — blocker view will selectively
            // hide the cursor and intercept events when needed.
            window.backgroundColor = NSColor.clear
            window.alphaValue = 1.0
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.hasShadow = false


            let blocker = BlockingView(frame: frame)
            blocker.wantsLayer = true
            blocker.layer?.backgroundColor = NSColor.clear.cgColor
            blocker.autoresizingMask = [.width, .height]

            window.contentView = blocker
            window.acceptsMouseMovedEvents = true

            window.orderFrontRegardless()
            // Try to make it key and front without stealing activation if possible
            window.makeKeyAndOrderFront(nil)
            // ensure blocker receives keyboard and mouse moved events
            window.makeFirstResponder(blocker)
            // extra order to reinforce top-most state
            window.orderFrontRegardless()
            self.overlayWindow = window

            // Observe target enter/exit notifications from the blocker
            NotificationCenter.default.addObserver(self, selector: #selector(self.handleMouseEnteredTarget(_:)), name: .mouseEnteredTarget, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.handleMouseExitedTarget(_:)), name: .mouseExitedTarget, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.handleEscapePressed(_:)), name: .escapePressed, object: nil)

            // Hide cursor at display level and via NSCursor balance
            self.hideCursorOnAllDisplays()
            self.cursorHideCount += 1

            // Post notification that overlay shown
            NotificationCenter.default.post(name: .overlayShown, object: nil)

            // Keep additional event monitors so we can maintain cursor-hidden state
            self.mouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] evt in
                if let s = self, s.isMouseInTarget {
                    CGDisplayHideCursor(CGMainDisplayID())
                }
                return evt
            }
            self.mouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
                if let s = self, s.isMouseInTarget {
                    CGDisplayHideCursor(CGMainDisplayID())
                }
            }
            // Capture keyboard events locally so we can forward to KeyboardManager when mouse is in target
            var monitors: [Any] = []

            let keyDownMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] evt in
                guard let s = self else { return evt }
                // Escape exits parallel mode
                if evt.keyCode == 53 || (evt.charactersIgnoringModifiers == "\u{1b}") {
                    s.exitParallelMode()
                    return nil
                }

                // Forward printable chars or key codes only when in target
                let pm = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)
                if pm.isMouseInTarget {
                    let km = KeyboardManager.shared
                    print("[ParallelManager] Forwarding keyDown: keyCode=\(evt.keyCode), chars=\(String(describing: evt.characters)), charsIgnoringModifiers=\(String(describing: evt.charactersIgnoringModifiers))")
                    km.kbm.pressKey(keys: [evt.keyCode], modifiers: evt.modifierFlags)
                    return nil
                }
                return evt
            }
            if let kd = keyDownMon { monitors.append(kd) }

            let keyUpMon = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] evt in
                let km = KeyboardManager.shared
                let pm = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)
                if pm.isMouseInTarget {
                    print("[ParallelManager] Forwarding keyUp: keyCode=\(evt.keyCode), chars=\(String(describing: evt.characters)), charsIgnoringModifiers=\(String(describing: evt.charactersIgnoringModifiers))")
                    km.kbm.releaseKey(keys: [evt.keyCode])
                    return nil
                }
                return evt
            }
//            if let ku = keyUpMon { monitors.append(ku) }
//
//            let flagsMon = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] evt in
//                guard let s = self else { return evt }
//                let pm = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)
//                if pm.isMouseInTarget {
//                    let newFlags = evt.modifierFlags
//                    let oldFlags = s.overlayWindow == nil ? NSEvent.ModifierFlags() : s.mouseGlobalMonitor == nil ? NSEvent.ModifierFlags() : NSEvent.ModifierFlags()
//                    // Map modifier changes to KeyboardManager (reuse existing behavior from BlockingView.flagsChanged)
//                    func handleModifier(_ special: KeyboardMapper.SpecialKey, flag: NSEvent.ModifierFlags) {
//                        let km = KeyboardManager.shared
//                        if newFlags.contains(flag) && !oldFlags.contains(flag) {
//                            if let keyCode = km.kbm.fromSpecialKeyToKeyCode(code: KeyboardMapper.SpecialKey(rawValue: special.rawValue)!) {
//                                km.kbm.pressKey(keys: [keyCode], modifiers: newFlags)
//                            }
//                        } else if !newFlags.contains(flag) && oldFlags.contains(flag) {
//                            if let keyCode = km.kbm.fromSpecialKeyToKeyCode(code: KeyboardMapper.SpecialKey(rawValue: special.rawValue)!) {
//                                km.kbm.releaseKey(keys: [keyCode])
//                            }
//                        }
//                    }
//
//                    handleModifier(.leftShift, flag: .shift)
//                    handleModifier(.leftCtrl, flag: .control)
//                    handleModifier(.leftAlt, flag: .option)
//                    handleModifier(.win, flag: .command)
//                }
//                return evt
//            }
//            if let ff = flagsMon { monitors.append(ff) }

//            self.keyboardMonitors = monitors
        }
    }
    
    private func hideOverlay() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // remove mouse monitors
            if let local = self.mouseLocalMonitor {
                NSEvent.removeMonitor(local)
                self.mouseLocalMonitor = nil
            }
            if let global = self.mouseGlobalMonitor {
                NSEvent.removeMonitor(global)
                self.mouseGlobalMonitor = nil
            }
            if let kms = self.keyboardMonitors {
                for k in kms { NSEvent.removeMonitor(k) }
                self.keyboardMonitors = nil
            }

            // unhide display-level cursor and balance NSCursor hides
            self.showCursorOnAllDisplays()
            while self.cursorHideCount > 0 {
                NSCursor.unhide()
                self.cursorHideCount -= 1
            }
            NotificationCenter.default.post(name: .overlayHidden, object: nil)

            if let overlay = self.overlayWindow {
                overlay.orderOut(nil)
                self.overlayWindow = nil
            }
            // Remove target enter/exit/escape observers
            NotificationCenter.default.removeObserver(self, name: .mouseEnteredTarget, object: nil)
            NotificationCenter.default.removeObserver(self, name: .mouseExitedTarget, object: nil)
            NotificationCenter.default.removeObserver(self, name: .escapePressed, object: nil)
        }
    }
    
    // MARK: - Main window shrink/restore
    private func findMainWindow() -> NSWindow? {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(UserSettings.shared.mainWindownName) == true }) {
            return window
        }
        return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
    }

    private func shrinkMainWindowToIndicator() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let win = self.findMainWindow(), self.mainWindowOriginalFrame == nil else { return }

                // Save original state
                self.mainWindowOriginalFrame = win.frame
                self.mainWindowOriginalLevel = win.level
                self.mainWindowOriginalIsOpaque = win.isOpaque
                self.mainWindowOriginalBackgroundColor = win.backgroundColor
                self.mainWindowOriginalTitlebarTransparent = win.titlebarAppearsTransparent
                self.mainWindowOriginalStyleMask = win.styleMask

                // Target small size and top-center position on the main screen
                let targetSize = NSSize(width: 160, height: 90)
                let screen = win.screen ?? NSScreen.main
                guard let screenFrame = screen?.frame else { return }
                let targetX = screenFrame.minX + (screenFrame.width - targetSize.width) / 2.0
                let targetY = screenFrame.maxY - targetSize.height - 20.0
                let targetFrame = NSRect(x: targetX, y: targetY, width: targetSize.width, height: targetSize.height)

                // Make window borderless and transparent so only our dot is visible
                win.isOpaque = false
                win.backgroundColor = .clear
                win.titlebarAppearsTransparent = true
                win.titleVisibility = .hidden
                win.standardWindowButton(.closeButton)?.isHidden = true
                win.standardWindowButton(.miniaturizeButton)?.isHidden = true
                win.standardWindowButton(.zoomButton)?.isHidden = true
                win.level = .screenSaver
                // Remove title/titled style and make borderless
                win.styleMask = [.borderless, .fullSizeContentView]
                // Ensure content is clear so only the SwiftUI dot is visible
                win.contentView?.wantsLayer = true
                win.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
                win.setFrame(targetFrame, display: true, animate: true)
            }
    }

    private func restoreMainWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let win = self.findMainWindow(), let original = self.mainWindowOriginalFrame else { return }

            if let origLevel = self.mainWindowOriginalLevel { win.level = origLevel }
            if let origOpaque = self.mainWindowOriginalIsOpaque { win.isOpaque = origOpaque }
            if let origColor = self.mainWindowOriginalBackgroundColor { win.backgroundColor = origColor }
            if let origTitleTransparent = self.mainWindowOriginalTitlebarTransparent { win.titlebarAppearsTransparent = origTitleTransparent }
            if let origStyle = self.mainWindowOriginalStyleMask { win.styleMask = origStyle }
            win.standardWindowButton(.closeButton)?.isHidden = false
            win.standardWindowButton(.miniaturizeButton)?.isHidden = false
            win.standardWindowButton(.zoomButton)?.isHidden = false

            win.setFrame(original, display: true, animate: true)

            // Clear saved state
            self.mainWindowOriginalFrame = nil
            self.mainWindowOriginalLevel = nil
            self.mainWindowOriginalIsOpaque = nil
            self.mainWindowOriginalBackgroundColor = nil
            self.mainWindowOriginalTitlebarTransparent = nil
            self.mainWindowOriginalStyleMask = nil
        }
    }
    
    // MARK: - Display-level cursor hide/show
    private func hideCursorOnAllDisplays() {
        // enumerate active displays
        var activeCount: UInt32 = 0
        var result = CGGetActiveDisplayList(0, nil, &activeCount)
        if result != .success { return }
        let allocated = Int(activeCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: allocated)
        result = CGGetActiveDisplayList(activeCount, &displays, &activeCount)
        if result != .success { return }

        for d in displays {
            CGDisplayHideCursor(d)
            hiddenDisplayIDs.append(d)
        }
    }

    private func showCursorOnAllDisplays() {
        for d in hiddenDisplayIDs {
            CGDisplayShowCursor(d)
        }
        hiddenDisplayIDs.removeAll()
    }
}
