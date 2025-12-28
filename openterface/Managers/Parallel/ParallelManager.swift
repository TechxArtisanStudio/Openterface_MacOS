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

// BlockingView extracted to `openterface/Managers/Parallel/BlockingView.swift`

// Overlay notifications
extension Notification.Name {
    static let overlayShown = Notification.Name("OverlayShownNotification")
    static let overlayHidden = Notification.Name("OverlayHiddenNotification")
    static let parallelModeChanged = Notification.Name("ParallelModeChanged")
    static let targetPlacementChanged = Notification.Name("TargetPlacementChanged")
    static let mouseEnteredTarget = Notification.Name("MouseEnteredTargetNotification")
    static let mouseExitedTarget = Notification.Name("MouseExitedTargetNotification")
    static let escapePressed = Notification.Name("EscapePressedNotification")
    static let remoteMouseMoved = Notification.Name("RemoteMouseMovedNotification")
}

class ParallelManager: ParallelManagerProtocol {
    private var logger: LoggerProtocol { DependencyContainer.shared.resolve(LoggerProtocol.self) }
    
    private(set) var isParallelModeEnabled: Bool = false
    private var isExitingParallelMode: Bool = false
    
    // Overlay manager handles overlay window, monitors and cursor hiding
    private let overlayManager = OverlayManager()
    var isMouseInTarget: Bool = false
    // Store main window original state so we can restore it after parallel mode
    private var mainWindowOriginalFrame: NSRect?
    private var mainWindowOriginalLevel: NSWindow.Level?
    private var mainWindowOriginalIsOpaque: Bool?
    private var mainWindowOriginalBackgroundColor: NSColor?
    private var mainWindowOriginalTitlebarTransparent: Bool?
    private var mainWindowOriginalTitleVisibility: NSWindow.TitleVisibility?
    private var mainWindowOriginalStyleMask: NSWindow.StyleMask?
    private var mainWindowOriginalToolbarVisible: Bool?
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
            // Register for blocker notifications
            NotificationCenter.default.addObserver(self, selector: #selector(self.handleMouseEnteredTarget(_:)), name: .mouseEnteredTarget, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.handleMouseExitedTarget(_:)), name: .mouseExitedTarget, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.handleEscapePressed(_:)), name: .escapePressed, object: nil)

            overlayManager.show(for: primary)
            // Ensure the cursor is visible in the blocking view when entering parallel mode.
            // showOverlay runs async; schedule a short follow-up to unhide the cursor and
            // make the blocker the first responder once the window is available.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self else { return }
                self.overlayManager.showCursorOnAllDisplays()
                NSCursor.unhide()
                self.overlayManager.bringOverlayToFront()
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
        overlayManager.hide()
        // Restore main window to original state
        restoreMainWindow()
        
        // Reset the exiting flag after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isExitingParallelMode = false
        }
        // Remove notification observers registered for overlay/blocker events
        NotificationCenter.default.removeObserver(self, name: .mouseEnteredTarget, object: nil)
        NotificationCenter.default.removeObserver(self, name: .mouseExitedTarget, object: nil)
        NotificationCenter.default.removeObserver(self, name: .escapePressed, object: nil)
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
    // Overlay is now handled by `OverlayManager` in `Managers/Parallel/OverlayManager.swift`
    
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
                self.mainWindowOriginalTitleVisibility = win.titleVisibility
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
                // Save toolbar visibility (if any) and hide toolbar while in parallel indicator mode
                self.mainWindowOriginalToolbarVisible = win.toolbar?.isVisible
                win.toolbar?.isVisible = false
                win.level = .screenSaver
                // // Remove title/titled style and make borderless
                // win.styleMask = [.borderless, .fullSizeContentView]
                // // Ensure content is clear so only the SwiftUI dot is visible
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
            if let origTitleVisibility = self.mainWindowOriginalTitleVisibility { win.titleVisibility = origTitleVisibility }
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
            self.mainWindowOriginalTitleVisibility = nil
            self.mainWindowOriginalStyleMask = nil
            // Restore toolbar visibility if we changed it
            if let origToolbarVisible = self.mainWindowOriginalToolbarVisible {
                win.toolbar?.isVisible = origToolbarVisible
            }
            self.mainWindowOriginalToolbarVisible = nil
        }
    }
    
    
}
