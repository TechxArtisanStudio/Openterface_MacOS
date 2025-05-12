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
    
    private init() {}
    
    /// Display the screen ratio selector window
    /// - Parameter completion: The callback after selection, passing in whether to update the window
    func showAspectRatioSelector(completion: @escaping (Bool) -> Void) {
        guard let window = NSApplication.shared.mainWindow else {
            Logger.shared.log(content: "Failed to show aspect ratio selector: No main window available")
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
        
        do {
            let alert = NSAlert()
            alert.messageText = "Select Aspect Ratio"
            alert.informativeText = "Please select your preferred aspect ratio:"
            
            // Create vertical stack view container
            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 65))
            
            // Add aspect ratio dropdown menu
            let aspectRatioPopup = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 200, height: 25))
            
            // Add all preset ratio options
            for option in AspectRatioOption.allCases {
                aspectRatioPopup.addItem(withTitle: option.rawValue)
            }
            
            // Set currently selected ratio
            if let index = AspectRatioOption.allCases.firstIndex(of: UserSettings.shared.customAspectRatio) {
                aspectRatioPopup.selectItem(at: index)
            }
            
            // Add checkbox for HID resolution change alerts
            let showHidAlertCheckbox = NSButton(checkboxWithTitle: "Show HID resolution change alerts", target: nil, action: nil)
            showHidAlertCheckbox.state = UserSettings.shared.doNotShowHidResolutionAlert ? .off : .on
            showHidAlertCheckbox.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
            
            // Add controls to container view
            containerView.addSubview(aspectRatioPopup)
            containerView.addSubview(showHidAlertCheckbox)
            
            alert.accessoryView = containerView
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            
            if response == .alertFirstButtonReturn {
                let selectedIndex = aspectRatioPopup.indexOfSelectedItem
                if selectedIndex >= 0 && selectedIndex < AspectRatioOption.allCases.count {
                    // Save user's aspect ratio selection
                    UserSettings.shared.customAspectRatio = AspectRatioOption.allCases[selectedIndex]
                    UserSettings.shared.useCustomAspectRatio = true
                    
                    // Save user's choice for HID resolution change alerts
                    UserSettings.shared.doNotShowHidResolutionAlert = (showHidAlertCheckbox.state == .off)
                    
                    // Log settings changes
                    Logger.shared.log(content: "User selected aspect ratio: \(UserSettings.shared.customAspectRatio.rawValue)")
                    Logger.shared.log(content: "User \(UserSettings.shared.doNotShowHidResolutionAlert ? "disabled" : "enabled") HID resolution change alerts")
                    
                    // Notify caller to update window size
                    completion(true)
                } else {
                    Logger.shared.log(content: "Invalid aspect ratio selection index: \(selectedIndex)")
                    completion(false)
                }
            } else {
                completion(false)
            }
        } catch {
            Logger.shared.log(content: "Error showing aspect ratio selector: \(error.localizedDescription)")
            completion(false)
        }
    }
    
    /// Directly call the system notification to update the window size
    func updateWindowSizeThroughNotification() {
        NotificationCenter.default.post(name: Notification.Name.updateWindowSize, object: nil)
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
        
        do {
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
                Logger.shared.log(content: "User \(UserSettings.shared.doNotShowHidResolutionAlert ? "disabled" : "enabled") HID resolution change alerts")
                
                completion()
            }
        } catch {
            Logger.shared.log(content: "Error showing HID resolution alert settings: \(error.localizedDescription)")
        }
    }
}

// Extension notification name
extension Notification.Name {
    static let updateWindowSize = Notification.Name("UpdateWindowSizeNotification")
} 
