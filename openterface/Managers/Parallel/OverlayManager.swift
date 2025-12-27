import AppKit
import CoreGraphics

/// Manages the semi-transparent overlay window, event monitors, and display-level cursor hiding.
final class OverlayManager {
    private(set) var overlayWindow: NSWindow?
    private var mouseLocalMonitor: Any?
    private var mouseGlobalMonitor: Any?
    private var keyboardMonitors: [Any]?
    private var cursorHideCount: Int = 0
    private var hiddenDisplayIDs: [CGDirectDisplayID] = []

    func show(for screen: NSScreen) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

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
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(blocker)
            window.orderFrontRegardless()
            self.overlayWindow = window

            // Hide cursor at display level and via NSCursor balance
            self.hideCursorOnAllDisplays()
            self.cursorHideCount += 1

            // Post notification that overlay shown
            NotificationCenter.default.post(name: Notification.Name.overlayShown, object: nil)

            // Keep additional event monitors so we can maintain cursor-hidden state
            self.mouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { evt in
                let pm: ParallelManagerProtocol = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)
                if pm.isMouseInTarget {
                    CGDisplayHideCursor(CGMainDisplayID())
                }
                return evt
            }
            self.mouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { evt in
                let pm: ParallelManagerProtocol = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)
                if pm.isMouseInTarget {
                    CGDisplayHideCursor(CGMainDisplayID())
                }
            }

            // Capture keyboard events locally so we can forward to KeyboardManager when mouse is in target
            var monitors: [Any] = []

            let keyDownMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { evt in
                // Escape exits parallel mode via notification; ParallelManager listens for this
                if evt.keyCode == 53 || (evt.charactersIgnoringModifiers == "\u{1b}") {
                    NotificationCenter.default.post(name: .escapePressed, object: nil)
                    return nil
                }

                // Forward printable chars or key codes only when in target
                let pm: ParallelManagerProtocol = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)
                if pm.isMouseInTarget {
                    let km = KeyboardManager.shared
                    km.kbm.pressKey(keys: [evt.keyCode], modifiers: evt.modifierFlags)
                    return nil
                }
                return evt
            }
            if let kd = keyDownMon { monitors.append(kd) }

            let keyUpMon = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { evt in
                let km = KeyboardManager.shared
                let pm: ParallelManagerProtocol = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)
                if pm.isMouseInTarget {
                    km.kbm.releaseKey(keys: [evt.keyCode])
                    return nil
                }
                return evt
            }
            if let ku = keyUpMon { monitors.append(ku) }

            if !monitors.isEmpty { self.keyboardMonitors = monitors }
        }
    }

    func bringOverlayToFront() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let overlay = self.overlayWindow else { return }
            overlay.makeKeyAndOrderFront(nil)
            if let blocker = overlay.contentView { overlay.makeFirstResponder(blocker) }
        }
    }

    func showCursorOnAllDisplays() {
        for d in hiddenDisplayIDs {
            CGDisplayShowCursor(d)
        }
        hiddenDisplayIDs.removeAll()
    }

    func hideCursorOnAllDisplays() {
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

    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
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
            NotificationCenter.default.post(name: Notification.Name.overlayHidden, object: nil)

            if let overlay = self.overlayWindow {
                overlay.orderOut(nil)
                self.overlayWindow = nil
            }
        }
    }
}
