/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation, either version 3 of the License, or       *
*    (at your option) any later version.                                     *
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    
    var statusBarManager = StatusBarManager()
    var hostmanager = HostManager()
    var keyboardManager = KeyboardManager.shared
    // var observation: NSKeyValueObservation?
    var log = Logger.shared
    
    let aspectRatio = CGSize(width: 1080, height: 630)
    
    var isDarkMode: Bool {
        if #available(macOS 10.14, *) {
            if NSApp.effectiveAppearance.name == .darkAqua {
                return true
            }
        }
        return false
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.mainMenu?.delegate = self
        
        if let window = NSApplication.shared.windows.first {
            window.delegate = self
            window.backgroundColor = NSColor.fromHex("#222222")
            
            let fixedSize = NSSize(width: 1080, height: 630)
            window.setContentSize(fixedSize)
            window.minSize = fixedSize
            window.maxSize = fixedSize
            
            window.center()
        }
    }
    
    func windowWillResize(_ sender: NSWindow, to targetFrameSize: NSSize) -> NSSize {
            // maintain the height / width ratio
            var newSize: NSSize = targetFrameSize
            let newAspectRatio = targetFrameSize.width / targetFrameSize.height
            let desiredAspectRatio = aspectRatio.width / aspectRatio.height
            
            if newAspectRatio > desiredAspectRatio {
                // Window too wide, adjust the width to maintain the height / width ratio
                newSize.width = targetFrameSize.height * desiredAspectRatio
            } else {
                // Window too tall, adjust the height to maintain the height / width ratio
                newSize.height = targetFrameSize.width / desiredAspectRatio
            }
            
            return newSize
        }


    // click on window close button to exit the programme
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        
    }
    
    func applicationWillUpdate(_ notification: Notification) {
        
    }
}

extension NSColor {
    static func fromHex(_ hex: String) -> NSColor {
        let hexFormatted: String = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        
        var int: UInt64 = 0
        Scanner(string: hexFormatted).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hexFormatted.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        
        return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}
