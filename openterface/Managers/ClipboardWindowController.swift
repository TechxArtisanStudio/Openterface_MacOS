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

import AppKit
import SwiftUI

class ClipboardWindow: NSWindow {
    private var clipboardView: NSHostingView<ClipboardView>?
    
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        setupWindow()
    }
    
    private func setupWindow() {
        // Configure window properties
        self.title = "Clipboard Manager"
        self.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        self.isReleasedWhenClosed = false
        self.level = .floating
        self.backgroundColor = NSColor.windowBackgroundColor
        
        // Set window frame
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let windowSize = CGSize(width: 400, height: 500)
        let windowFrame = NSRect(
            x: screenFrame.maxX - windowSize.width - 20,
            y: screenFrame.maxY - windowSize.height - 20,
            width: windowSize.width,
            height: windowSize.height
        )
        self.setFrame(windowFrame, display: true)
        
        // Create and set content view
        let clipboardView = ClipboardView()
        let hostingView = NSHostingView(rootView: clipboardView)
        self.contentView = hostingView
        self.clipboardView = hostingView
        
        // Configure window behavior
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
    }
    
    override func close() {
        // Hide instead of close to keep the window alive
        self.orderOut(nil)
    }
    
    func toggle() {
        if self.isVisible {
            self.orderOut(nil)
        } else {
            // Check if main window has focus when showing clipboard window
            let mainWindowHasFocus = NSApplication.shared.windows.contains { window in
                if let identifier = window.identifier?.rawValue,
                   identifier.contains("main_openterface") {
                    return window.isMainWindow
                }
                return false
            }
            
            // Set appropriate window level based on main window focus
            self.level = mainWindowHasFocus ? .floating : .normal
            
            self.makeKeyAndOrderFront(nil)
            self.center()
        }
    }
    
    override func keyDown(with event: NSEvent) {
        // Handle Escape key to close window
        if event.keyCode == 53 { // Escape key
            self.orderOut(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

class ClipboardWindowController: NSWindowController {
    static let shared = ClipboardWindowController()
    
    private var mainWindowObserver: NSObjectProtocol?
    private var mainWindowFocusObserver: NSObjectProtocol?
    
    private init() {
        let window = ClipboardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: window)
        setupMainWindowObserver()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        removeMainWindowObserver()
    }
    
    private func setupMainWindowObserver() {
        // Observe main window focus loss notifications
        mainWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Check if the window losing focus is the main window
            if let window = notification.object as? NSWindow,
               self?.isMainOpenterfaceWindow(window) == true {
                self?.handleMainWindowFocusLost()
            }
        }
        
        // Observe main window focus gain notifications
        mainWindowFocusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Check if the window gaining focus is the main window
            if let window = notification.object as? NSWindow,
               self?.isMainOpenterfaceWindow(window) == true {
                self?.handleMainWindowFocusGained()
            }
        }
    }
    
    private func removeMainWindowObserver() {
        if let observer = mainWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            mainWindowObserver = nil
        }
        if let observer = mainWindowFocusObserver {
            NotificationCenter.default.removeObserver(observer)
            mainWindowFocusObserver = nil
        }
    }
    
    private func isMainOpenterfaceWindow(_ window: NSWindow) -> Bool {
        // Check multiple criteria to identify the main Openterface window
        
        // First, check if identifier contains main_openterface
        if let identifier = window.identifier?.rawValue,
           identifier.contains("main_openterface") {
            return true
        }
        
        // Second, check window title
        if window.title.contains("Openterface KVM") {
            return true
        }
        
        // Third, check if this is the main application window (not our clipboard window)
        if window.title == "Openterface KVM" && window != self.window {
            return true
        }
        
        return false
    }
    
    private func handleMainWindowFocusLost() {
        // When main window loses focus, lower the clipboard window level
        guard let clipboardWindow = window as? ClipboardWindow else { return }
        if clipboardWindow.isVisible {
            clipboardWindow.level = .normal
        }
    }
    
    private func handleMainWindowFocusGained() {
        // When main window gains focus, raise the clipboard window level
        guard let clipboardWindow = window as? ClipboardWindow else { return }
        if clipboardWindow.isVisible {
            clipboardWindow.level = .floating
        }
    }

    func toggle() {
        (window as? ClipboardWindow)?.toggle()
    }
}
