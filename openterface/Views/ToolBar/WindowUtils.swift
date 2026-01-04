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

// Window utility class, providing common window functions
final class WindowUtils {
    // Singleton mode
    static let shared = WindowUtils()
    private var  logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var aspectRatioSettingsWindow: NSWindow?

    private init() {}
    
    /// Display the aspect ratio selector window
    /// - Parameter completion: The callback after selection, passing in whether to update the window
    func showAspectRatioSelector(completion: @escaping (Bool) -> Void) {
        guard let mainWindow = NSApplication.shared.mainWindow else {
            logger.log(content: "Failed to show aspect ratio selector: No main window available")
            completion(false)
            return
        }
        
        // Ensure we're on the main thread
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.showAspectRatioSelector(completion: completion)
            }
            return
        }

        // Create the SwiftUI view with closures that capture self properly
        let settingsView = AspectRatioSettingsView(
            onConfirm: { [weak self] gravity, mode, customRatio in
                guard let self = self else { return }
                
                // Save user's selections
                UserSettings.shared.gravity = gravity
                UserSettings.shared.aspectRatioMode = mode
                if mode == .custom {
                    UserSettings.shared.customAspectRatio = customRatio
                }
                
                self.logger.log(content: "Aspect ratio settings updated: mode=\(mode.rawValue), gravity=\(gravity.rawValue)")
                
                // Notify that gravity settings have changed
                NotificationCenter.default.post(name: .gravitySettingsChanged, object: nil)
                
                // Close the dialog
                self.closeAspectRatioSettingsWindow()
                
                // Notify caller to update window size
                completion(true)
            },
            onCancel: { [weak self] in
                guard let self = self else { return }
                
                // Close the dialog
                self.closeAspectRatioSettingsWindow()
                completion(false)
            }
        )
        
        // Create a window to host the SwiftUI view
        let hostingView = NSHostingView(rootView: settingsView)
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        settingsWindow.title = "Aspect Ratio & Video Settings"
        settingsWindow.contentView = hostingView
        settingsWindow.center()
        settingsWindow.isReleasedWhenClosed = true
        
        // Store reference to window for later closure
        self.aspectRatioSettingsWindow = settingsWindow
        
        // Make it modal relative to the main window
        mainWindow.beginSheet(settingsWindow) { [weak self] _ in
            // Clean up reference when sheet ends
            self?.aspectRatioSettingsWindow = nil
        }
    }
    
    private func closeAspectRatioSettingsWindow() {
        guard let window = aspectRatioSettingsWindow else { return }
        
        // End the sheet and close the window
        if let mainWindow = NSApplication.shared.mainWindow {
            mainWindow.endSheet(window)
        } else {
            window.close()
        }
    }
    
    /// Directly call the system notification to update the window size
    func updateWindowSizeThroughNotification() {
        NotificationCenter.default.post(name: Notification.Name.updateWindowSize, object: nil)
    }

    /// Calculate a window size constrained to an aspect ratio and screen bounds.
    /// - Parameters:
    ///   - window: The window being resized
    ///   - targetSize: The desired target size
    ///   - initialContentSize: The default content size / aspect ratio to use when none is available
    func calculateConstrainedWindowSize(for window: NSWindow, targetSize: NSSize, initialContentSize: CGSize) -> NSSize {
        // Get the height of the toolbar (if visible)
        let toolbarHeight: CGFloat = (window.toolbar?.isVisible == true) ? window.frame.height - window.contentLayoutRect.height : 0

        // Determine the aspect ratio to use based on aspectRatioMode
        let aspectRatioToUse: CGFloat

        switch UserSettings.shared.aspectRatioMode {
        case .custom:
            aspectRatioToUse = UserSettings.shared.customAspectRatio.widthToHeightRatio
        case .hidResolution:
            // Try to use HID resolution first
            if AppStatus.hidReadResolusion.width > 0 && AppStatus.hidReadResolusion.height > 0 {
                aspectRatioToUse = CGFloat(AppStatus.hidReadResolusion.width) / CGFloat(AppStatus.hidReadResolusion.height)
            } else if let resolution = HIDManager.shared.getResolution(), resolution.width > 0 && resolution.height > 0 {
                aspectRatioToUse = CGFloat(resolution.width) / CGFloat(resolution.height)
            } else {
                // Fallback to initial content size if HID resolution not available
                aspectRatioToUse = initialContentSize.width / initialContentSize.height
            }
        case .activeResolution:
            // Use active video rect if available
            let activeVideoRect = AppStatus.activeVideoRect
            if activeVideoRect.width > 0 && activeVideoRect.height > 0 {
                aspectRatioToUse = activeVideoRect.width / activeVideoRect.height
            } else if AppStatus.hidReadResolusion.width > 0 && AppStatus.hidReadResolusion.height > 0 {
                // Fallback to HID resolution if active rect not available
                aspectRatioToUse = CGFloat(AppStatus.hidReadResolusion.width) / CGFloat(AppStatus.hidReadResolusion.height)
            } else if let resolution = HIDManager.shared.getResolution(), resolution.width > 0 && resolution.height > 0 {
                aspectRatioToUse = CGFloat(resolution.width) / CGFloat(resolution.height)
            } else {
                // Fallback to initial content size
                aspectRatioToUse = initialContentSize.width / initialContentSize.height
            }
        }

        // Get the screen containing the window
        guard let screen = (window.screen ?? NSScreen.main) else { return targetSize }

        // Calculate new size maintaining content area aspect ratio
        var newSize = targetSize

        // Adjust height calculation to account for the toolbar
        let contentHeight = newSize.width / aspectRatioToUse
        newSize.height = contentHeight + toolbarHeight

        // Limt the window into the visible screen area
        let screenFrame = screen.visibleFrame

        // If the computed height exceeds the screen's visible height, clamp it
        if newSize.height > screenFrame.height {
            // Maximum content height available (excluding toolbar)
            let maxContentHeight = max(screenFrame.height - toolbarHeight, 1)

            // Compute width that preserves aspect ratio for the clamped height
            var adjustedWidth = maxContentHeight * aspectRatioToUse
            var adjustedHeight = maxContentHeight + toolbarHeight

            // If the adjusted width also exceeds screen width, clamp width and recompute height
            if adjustedWidth > screenFrame.width {
                adjustedWidth = screenFrame.width
                let contentHeightFromWidth = adjustedWidth / aspectRatioToUse
                adjustedHeight = contentHeightFromWidth + toolbarHeight
            }

            newSize.width = adjustedWidth
            newSize.height = adjustedHeight
        }

        // Ensure we respect the window's minimum size
        newSize.width = max(newSize.width, window.minSize.width)
        newSize.height = max(newSize.height, window.minSize.height)

        return newSize
    }
    
    /// Toggle always on top window level
    /// - Parameter isEnabled: Whether to enable always on top
    func setAlwaysOnTop(_ isEnabled: Bool) {
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.contains(UserSettings.shared.mainWindownName) ?? false }) {
            if isEnabled {
                window.level = .floating
            } else {
                window.level = .normal
            }
        }
    }
    
    /// Display the HID resolution change alert settings dialog
    /// - Parameter completion: The callback after setting, passing in whether to update the window
    func showHidResolutionAlertSettings(completion: @escaping () -> Void = {}) {
        // Ensure we're on the main thread
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.showHidResolutionAlertSettings(completion: completion)
            }
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "HID Resolution Change Alert Settings"
        alert.informativeText = "Do you want to show alerts when HID resolution changes?"
        
        // Add checkbox
        let showAlertCheckbox = NSButton(checkboxWithTitle: "Show HID resolution change alerts", target: nil, action: nil)
        // Set checkbox state based on current settings
        showAlertCheckbox.state = UserSettings.shared.doNotShowHidResolutionAlert ? .off : .on
        alert.accessoryView = showAlertCheckbox
        
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Save user choice
            UserSettings.shared.doNotShowHidResolutionAlert = (showAlertCheckbox.state == .off)
            
            // Log settings change
            logger.log(content: "User \(UserSettings.shared.doNotShowHidResolutionAlert ? "disabled" : "enabled") HID resolution change alerts")
            
            completion()
        }
    }
}

// Extension notification name
extension Notification.Name {
    static let updateWindowSize = Notification.Name("UpdateWindowSizeNotification")
    static let gravitySettingsChanged = Notification.Name("GravitySettingsChangedNotification")
}
