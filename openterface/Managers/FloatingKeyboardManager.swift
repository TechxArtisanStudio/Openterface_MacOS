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
 
        // Observe main window focus loss notifications
        focusLostObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Check if the window losing focus is the main window
            if let window = notification.object as? NSWindow,
               let identifier = window.identifier?.rawValue,
               identifier.contains("main_openterface") {
                self?.closeFloatingKeysWindow()
            }
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
        if let existingWindow = floatingKeyboardWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let floatingKeysView = FloatingKeysWindow(onClose: { [weak self] in
            self?.closeFloatingKeysWindow()
        })
        let controller = NSHostingController(rootView: floatingKeysView)
        let window = NSWindow(contentViewController: controller)
        window.title = ""
        window.styleMask = [.borderless]
        window.setContentSize(NSSize(width: 800, height: 410))
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        floatingKeyboardWindow = window

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
            self?.floatingKeyboardWindow = nil
        }
    }
    
    public func closeFloatingKeysWindow() {
        floatingKeyboardWindow?.close()
        floatingKeyboardWindow = nil
    }
}
