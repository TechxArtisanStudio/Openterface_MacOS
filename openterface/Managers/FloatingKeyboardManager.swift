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

public class FloatingKeyboardManager: FloatingKeyboardManagerProtocol {
    private var floatingKeyboardWindow: NSWindow?
    private var mainWindowObserver: NSObjectProtocol?
    private var focusLostObserver: NSObjectProtocol?
    private var logger: LoggerProtocol { DependencyContainer.shared.resolve(LoggerProtocol.self) }

    public init() {
        setupMainWindowObserver()
    }
    
    private func setupMainWindowObserver() {
        // Observe main window close notifications
        mainWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Check if the closing window is the main window
            if let window = notification.object as? NSWindow,
               let identifier = window.identifier?.rawValue,
               identifier.contains("main_openterface") {
                self?.closeFloatingKeysWindow()
            }
        }
 
        // Observe app losing active focus (e.g., user switches to another app)
        // This is better than observing didResignMain, which fires when clicking the floating keyboard itself
        focusLostObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.closeFloatingKeysWindow()
        }
    }
    
    deinit {
        if let observer = mainWindowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = focusLostObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func showFloatingKeysWindow() {
        logger.log(content: "🎹 FloatingKeyboardManager.showFloatingKeysWindow() called")
        
        if let existingWindow = floatingKeyboardWindow {
            logger.log(content: "Existing floating keyboard window found, bringing to front")
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        logger.log(content: "Creating new floating keyboard window")
        let floatingKeysView = FloatingKeysWindow(onClose: { [weak self] in
            self?.logger.log(content: "Floating keyboard window close callback triggered")
            self?.closeFloatingKeysWindow()
        })
        let controller = NSHostingController(rootView: floatingKeysView)
        let window = NSWindow(contentViewController: controller)
        window.title = ""
        window.styleMask = NSWindow.StyleMask([.borderless])
        window.setContentSize(NSSize(width: 800, height: 410))
        window.isMovableByWindowBackground = true
        // Use a level above the main window so the floating keyboard is never occluded
        // when the main window is set to .floating (always-on-top).
        let mainWindowLevel = NSApplication.shared.windows
            .first(where: { $0.identifier?.rawValue.contains(UserSettings.shared.mainWindownName) ?? false })?
            .level ?? .normal
        let keyboardWindowLevel = NSWindow.Level(rawValue: mainWindowLevel.rawValue + 1)
        window.level = keyboardWindowLevel
        logger.log(content: "Floating keyboard window level set to \(keyboardWindowLevel.rawValue) (main window: \(mainWindowLevel.rawValue))")
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = NSWindow.CollectionBehavior([.canJoinAllSpaces, .fullScreenAuxiliary])
        
        logger.log(content: "Making floating keyboard window key and ordering front")
        window.makeKeyAndOrderFront(nil as Any?)
        NSApp.activate(ignoringOtherApps: true)

        floatingKeyboardWindow = window
        logger.log(content: "Floating keyboard window created and stored")

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.logger.log(content: "Floating keyboard window will close notification received")
            self?.floatingKeyboardWindow = nil
        }
    }
    
    public func closeFloatingKeysWindow() {
        floatingKeyboardWindow?.close()
        floatingKeyboardWindow = nil
    }
    
    public func setFloatingKeyboardHeight(_ height: CGFloat) {
        guard let window = floatingKeyboardWindow else { return }
        let currentFrame = window.frame
        let newFrame = NSRect(x: currentFrame.origin.x,
                             y: currentFrame.origin.y - (height - currentFrame.height),
                             width: currentFrame.width,
                             height: height)
        window.setFrame(newFrame, display: true, animate: true)
    }
}
