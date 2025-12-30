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
    private var currentAspectRatioPopup: NSPopUpButton?
    private var gravityDescLabel: NSTextField?
    private var resolutionsLabel: NSTextField?

    private init() {}
    
    @objc private func toggleAspectRatioPopup(_ sender: NSButton) {
        currentAspectRatioPopup?.isEnabled = sender.state == .on
    }
    
    @objc private func updateGravityDescription(_ sender: NSPopUpButton) {
        let selectedIndex = sender.indexOfSelectedItem
        if selectedIndex >= 0 && selectedIndex < GravityOption.allCases.count {
            let selectedOption = GravityOption.allCases[selectedIndex]
            gravityDescLabel?.stringValue = selectedOption.description
        }
    }
    
    @objc private func updateAspectRatioResolutions(_ sender: NSPopUpButton) {
        let selectedIndex = sender.indexOfSelectedItem
        if selectedIndex >= 0 && selectedIndex < AspectRatioOption.allCases.count {
            let selectedOption = AspectRatioOption.allCases[selectedIndex]
            let resolutions = getCommonResolutions(for: selectedOption)
            resolutionsLabel?.stringValue = "Common resolutions: \(resolutions)"
        }
    }
    
    private func getCommonResolutions(for aspectRatio: AspectRatioOption) -> String {
        switch aspectRatio {
        case .ratio16_9:
            return "1920×1080, 2560×1440, 3840×2160"
        case .ratio16_10:
            return "1920×1200, 2560×1600, 1440×900"
        case .ratio21_9:
            return "2560×1080, 3440×1440"
        case .ratio5_3:
            return "2560×1536, 1920×1152"
        case .ratio5_4:
            return "1280×1024, 2560×2048"
        case .ratio4_3:
            return "1600×1200, 1920×1440, 2560×1920"
        case .ratio9_16:
            return "1080×1920, 1440×2560"
        case .ratio9_19_5:
            return "1080×2340"
        case .ratio9_20:
            return "1080×2400"
        case .ratio9_21:
            return "1080×2520"
        case .ratio9_5:
            return "4096×2160"
        }
    }
    
    /// Display the screen ratio selector window
    /// - Parameter completion: The callback after selection, passing in whether to update the window
    func showAspectRatioSelector(completion: @escaping (Bool) -> Void) {
        guard NSApplication.shared.mainWindow != nil else {
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

        let alert = NSAlert()
        alert.messageText = "Aspect Ratio & Video Settings"
        alert.informativeText = "Please select your preferred aspect ratio and video scaling options:"
        
        // Create vertical stack view container
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        
        // Add gravity label
        let gravityLabel = NSTextField(frame: NSRect(x: 0, y: 155, width: 300, height: 20))
        gravityLabel.stringValue = "Scaling:"
        gravityLabel.isEditable = false
        gravityLabel.isBordered = false
        gravityLabel.backgroundColor = .clear
        gravityLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        
        // Add gravity dropdown menu
        let gravityPopup = NSPopUpButton(frame: NSRect(x: 0, y: 130, width: 300, height: 25))
        for option in GravityOption.allCases {
            gravityPopup.addItem(withTitle: option.displayName)
        }
        gravityPopup.selectItem(at: GravityOption.allCases.firstIndex(of: UserSettings.shared.gravity)!)
        gravityPopup.target = self
        gravityPopup.action = #selector(updateGravityDescription(_:))
        
        // Add gravity description
        let gravityDesc = NSTextField(frame: NSRect(x: 0, y: 105, width: 300, height: 20))
        gravityDesc.stringValue = UserSettings.shared.gravity.description
        gravityDesc.isEditable = false
        gravityDesc.isBordered = false
        gravityDesc.backgroundColor = .clear
        gravityDesc.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        gravityDesc.textColor = .blue
        self.gravityDescLabel = gravityDesc
        
        // Add aspect ratio dropdown menu
        let aspectRatioPopup = NSPopUpButton(frame: NSRect(x: 0, y: 50, width: 300, height: 25))
        
        // Get the current resolution value
        var currentResolution = AppStatus.hidReadResolusion.width > 0 ? Float(AppStatus.hidReadResolusion.width) / Float(AppStatus.hidReadResolusion.height) : 0.0
        
        // Special case for 4096x2160 resolution
        if currentResolution == 4096.0 / 2160.0 {
            currentResolution = 1.8 // Set to 9:5 aspect ratio
        }

        // Add all preset ratio options
        for option in AspectRatioOption.allCases {
            var title = option.rawValue
            if Float(CGFloat(option.widthToHeightRatio)) == Float(currentResolution) {
                title += " (Input Resolution)"
            }
            aspectRatioPopup.addItem(withTitle: title)
        }
        
        // Set currently selected ratio
        if let index = AspectRatioOption.allCases.firstIndex(of: UserSettings.shared.customAspectRatio) {
            aspectRatioPopup.selectItem(at: index)
        }
        
        aspectRatioPopup.isEnabled = UserSettings.shared.useCustomAspectRatio
        aspectRatioPopup.target = self
        aspectRatioPopup.action = #selector(updateAspectRatioResolutions(_:))
        self.currentAspectRatioPopup = aspectRatioPopup
        
        // Add resolutions label
        let resolutionsLabel = NSTextField(frame: NSRect(x: 0, y: 15, width: 300, height: 20))
        let initialResolutions = getCommonResolutions(for: UserSettings.shared.customAspectRatio)
        resolutionsLabel.stringValue = "Common resolutions: \(initialResolutions)"
        resolutionsLabel.isEditable = false
        resolutionsLabel.isBordered = false
        resolutionsLabel.backgroundColor = .clear
        resolutionsLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        resolutionsLabel.textColor = .blue
        self.resolutionsLabel = resolutionsLabel
        
        
        // Add checkbox for using custom aspect ratio
        let useCustomAspectRatioCheckbox = NSButton(checkboxWithTitle: "Use custom Aspect Ratio", target: nil, action: nil)
        useCustomAspectRatioCheckbox.state = UserSettings.shared.useCustomAspectRatio ? .on : .off
        useCustomAspectRatioCheckbox.frame = NSRect(x: 0, y: 80, width: 300, height: 20)
        useCustomAspectRatioCheckbox.target = self
        useCustomAspectRatioCheckbox.action = #selector(toggleAspectRatioPopup(_:))
        
        // Add controls to container view
        containerView.addSubview(gravityLabel)
        containerView.addSubview(gravityPopup)
        containerView.addSubview(gravityDesc)
        containerView.addSubview(useCustomAspectRatioCheckbox)
        containerView.addSubview(aspectRatioPopup)
        containerView.addSubview(resolutionsLabel)
//        containerView.addSubview(showHidAlertCheckbox)
        
        alert.accessoryView = containerView
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            // Save user's gravity selection
            let gravityIndex = gravityPopup.indexOfSelectedItem
            if gravityIndex >= 0 && gravityIndex < GravityOption.allCases.count {
                UserSettings.shared.gravity = GravityOption.allCases[gravityIndex]
            }
            
            // Save user's choice for using custom aspect ratio
            UserSettings.shared.useCustomAspectRatio = (useCustomAspectRatioCheckbox.state == .on)
            
            if UserSettings.shared.useCustomAspectRatio {
                let selectedIndex = aspectRatioPopup.indexOfSelectedItem
                if selectedIndex >= 0 && selectedIndex < AspectRatioOption.allCases.count {
                    // Save user's aspect ratio selection
                    UserSettings.shared.customAspectRatio = AspectRatioOption.allCases[selectedIndex]
                } else {
                    logger.log(content: "Invalid aspect ratio selection index: \(selectedIndex)")
                }
            }

            // Notify that gravity settings have changed
            NotificationCenter.default.post(name: .gravitySettingsChanged, object: nil)
            
            // Notify caller to update window size
            completion(true)
        } else {
            completion(false)
        }
        
        self.currentAspectRatioPopup = nil
        self.gravityDescLabel = nil
        self.resolutionsLabel = nil
    }
    
    /// Directly call the system notification to update the window size
    func updateWindowSizeThroughNotification() {
        NotificationCenter.default.post(name: Notification.Name.updateWindowSize, object: nil)
    }

    /// Calculate a window size constrained to an aspect ratio and screen bounds.
    /// - Parameters:
    ///   - window: The window being resized
    ///   - targetSize: The desired target size
    ///   - constraintToScreen: Whether to clamp to the visible screen area
    ///   - initialContentSize: The default content size / aspect ratio to use when none is available
    func calculateConstrainedWindowSize(for window: NSWindow, targetSize: NSSize, constraintToScreen: Bool, initialContentSize: CGSize) -> NSSize {
        // Get the height of the toolbar (if visible)
        let toolbarHeight: CGFloat = (window.toolbar?.isVisible == true) ? window.frame.height - window.contentLayoutRect.height : 0
        
        // Determine the aspect ratio to use
        let aspectRatioToUse: CGFloat

        // Priority: 1. User custom ratio 2. HID ratio 3. Default ratio
        if UserSettings.shared.useCustomAspectRatio {
            aspectRatioToUse = UserSettings.shared.customAspectRatio.widthToHeightRatio
        } else if AppStatus.hidReadResolusion.width > 0 && AppStatus.hidReadResolusion.height > 0 {
            aspectRatioToUse = CGFloat(AppStatus.hidReadResolusion.width) / CGFloat(AppStatus.hidReadResolusion.height)
        } else if let resolution = HIDManager.shared.getResolution(), resolution.width > 0 && resolution.height > 0 {
            aspectRatioToUse = CGFloat(resolution.width) / CGFloat(resolution.height)
        } else {
            aspectRatioToUse = initialContentSize.width / initialContentSize.height
        }

        // Get the screen containing the window
        guard let screen = (window.screen ?? NSScreen.main) else { return targetSize }

        // Calculate new size maintaining content area aspect ratio
        var newSize = targetSize

        // Adjust height calculation to account for the toolbar
        var contentHeight = newSize.width / aspectRatioToUse
        newSize.height = contentHeight + toolbarHeight

        // If requested, constrain the window to the visible screen area
        if constraintToScreen {
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
