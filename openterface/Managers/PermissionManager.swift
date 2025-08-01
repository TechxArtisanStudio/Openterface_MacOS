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

import Foundation
import ApplicationServices
import AppKit

class PermissionManager: ObservableObject, PermissionManagerProtocol {
    static let shared = PermissionManager()
    
    private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    
    private init() {}
    
    /// Check if accessibility permissions are granted
    func isAccessibilityPermissionGranted() -> Bool {
        return AXIsProcessTrusted()
    }
    
    /// Request accessibility permissions by automatically adding app to the accessibility list
    func requestAccessibilityPermission() {
        logger.log(content: "Requesting accessibility permissions from user")
        
        // Check if already trusted
        if AXIsProcessTrusted() {
            logger.log(content: "Accessibility permissions already granted")
            return
        }
        
        // Attempt to automatically request accessibility permission
        // This will trigger the system dialog and add the app to the accessibility list
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if accessEnabled {
            logger.log(content: "Accessibility permissions granted")
        } else {
            logger.log(content: "Accessibility permission request initiated - system dialog should appear")
            
            // Show informational alert about what the user needs to do
            showAccessibilityPermissionInfo()
        }
    }
    
    /// Show informational message about accessibility permissions
    private func showAccessibilityPermissionInfo() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = """
            Openterface Mini-KVM has been automatically added to the accessibility list in System Preferences.
            
            To complete the setup:
            1. A system dialog should have appeared asking for permission
            2. If not, you can manually enable it in System Preferences > Privacy & Security > Accessibility
            3. Find "Openterface" in the list and ensure it's checked
            
            This allows the app to:
            • Control mouse movements via HID interface
            • Provide more precise relative mouse control
            
            You may need to restart the app after granting permissions.
            """
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .informational
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self.openAccessibilitySettings()
            }
        }
    }
    
    /// Open System Preferences to the accessibility section
    private func openAccessibilitySettings() {
        let prefPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        
        if NSWorkspace.shared.open(prefPaneURL) {
            logger.log(content: "Opened accessibility settings in System Preferences")
        } else {
            logger.log(content: "Failed to open accessibility settings")
            // Fallback: try to open Security & Privacy preferences
            let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
            NSWorkspace.shared.open(fallbackURL)
        }
    }
    
    /// Show permission status info
    func showPermissionStatus() {
        let isGranted = isAccessibilityPermissionGranted()
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Status"
            
            if isGranted {
                alert.informativeText = "✅ Accessibility permissions are granted.\n\nHID-based relative mouse control is available."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
            } else {
                alert.informativeText = """
                ❌ Accessibility permissions are not granted.
                
                HID-based relative mouse control requires these permissions.
                
                Would you like to automatically request these permissions?
                This will add Openterface to the accessibility list and show the system permission dialog.
                """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Request Permissions")
                alert.addButton(withTitle: "Open Settings Manually")
                alert.addButton(withTitle: "Cancel")
            }
            
            let response = alert.runModal()
            if !isGranted {
                switch response {
                case .alertFirstButtonReturn:
                    // Request permissions automatically
                    self.requestAccessibilityPermission()
                case .alertSecondButtonReturn:
                    // Open settings manually
                    self.openAccessibilitySettings()
                default:
                    // Cancel - do nothing
                    break
                }
            }
        }
    }
}
