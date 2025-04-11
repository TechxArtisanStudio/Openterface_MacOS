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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    @ObservedObject private var audioManager = AudioManager()
    
    var statusBarManager = StatusBarManager()
    var hostmanager = HostManager()
    var keyboardManager = KeyboardManager.shared

    let spm = SerialPortManager.shared

    // var observation: NSKeyValueObservation?
    var log = Logger.shared
    
    let aspectRatio = CGSize(width: 1080, height: 659)
    
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
        // spm.tryOpenSerialPort()
        if #available(macOS 12.0, *) {
            USBDeivcesManager.shared.update()
        } else {
            Logger.shared.log(content: "USB device management requires macOS 12.0 or later. Current functionality is limited.")
        }

        // init HIDManager after USB device manager updated
        _ = HIDManager.shared
        
        NSApplication.shared.windows.forEach { window in
            if let windownName = window.identifier?.rawValue {
                if windownName.contains(UserSettings.shared.mainWindownName) {
                    window.delegate = self
                    window.backgroundColor = NSColor.fromHex("#000000")
                    
                    // Allow window resizing but maintain aspect ratio
                    window.styleMask.insert(.resizable)
                    
                    let initialSize = aspectRatio
                    window.setContentSize(initialSize)
                    
                    // Set minimum size to prevent too small windows
                    window.minSize = NSSize(width: aspectRatio.width / 2, height: aspectRatio.height / 2)
                    // Set maximum size to something reasonable (2x initial size)
                    window.maxSize = NSSize(width: aspectRatio.width * 2, height: aspectRatio.height * 2)
                    window.center()
                }
                    
                   
            }
        }

        // Disable window tabbing feature, which makes the "Show Tab Bar" menu item unavailable
        NSWindow.allowsAutomaticWindowTabbing = false
        
        // start audio
        // if audioManager.microphonePermissionGranted {
        //     audioManager.prepareAudio()
        // }
    }
    
    func windowDidResize(_ notification: Notification) {
        if let window = NSApplication.shared.mainWindow {
            if let toolbar = window.toolbar, toolbar.isVisible {
                let windowHeight = window.frame.height
                let contentLayoutRect = window.contentLayoutRect
                _ = windowHeight - contentLayoutRect.height
                AppStatus.currentView = contentLayoutRect
                AppStatus.currentWindow = window.frame
            }
        }
    }

    func windowWillResize(_ sender: NSWindow, to targetFrameSize: NSSize) -> NSSize {
        let newSize = calculateConstrainedWindowSize(for: sender, targetSize: targetFrameSize, constraintToScreen: true)

        return newSize
    }

    private func calculateConstrainedWindowSize(for window: NSWindow, targetSize: NSSize, constraintToScreen: Bool) -> NSSize {
        // Get the height of the toolbar (if visible)
        let toolbarHeight: CGFloat = (window.toolbar?.isVisible == true) ? window.frame.height - window.contentLayoutRect.height : 0
        
        // Calculate the target aspect ratio
        let hidAspectRatio = CGFloat(AppStatus.hidReadResolusion.width) / CGFloat(AppStatus.hidReadResolusion.height)
        
        let defaultAspectRatio = aspectRatio.width / aspectRatio.height
        
        
        // Get the screen containing the window
        guard let screen = window.screen ?? NSScreen.main else { return targetSize }
        let screenFrame = screen.visibleFrame
        
        // Calculate new size maintaining content area aspect ratio
        var newSize = targetSize
        print("1 - newSize: \(newSize), ratio: \(newSize.width/newSize.height)")
        // Adjust height calculation to account for the toolbar
        let contentHeight = targetSize.height - toolbarHeight
        let contentWidth = targetSize.width
        
        // Calculate content size based on aspect ratio
        let aspectRatioToUse = (AppStatus.hidReadResolusion.width > 0 && AppStatus.hidReadResolusion.height > 0) ? hidAspectRatio : defaultAspectRatio
        
        print("aspectRatioToUse\(aspectRatioToUse)")
        let heightFromWidth = (contentWidth / CGFloat(aspectRatioToUse))
        let widthFromHeight = (contentHeight * CGFloat(aspectRatioToUse))
        
        // Choose the smaller size to ensure the window fits the screen
        if heightFromWidth + toolbarHeight <= screenFrame.height {
            newSize.height = heightFromWidth + toolbarHeight
        } else {
            newSize.width = widthFromHeight
        }

        
        return newSize
    }

    func windowWillStartLiveResize(_ notification: Notification) {

    }

    func windowDidEndLiveResize(_ notification: Notification) {
         
    }

    // Handle window moving between screens
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen else { return }
        
        let screenFrame = screen.visibleFrame
        let currentFrame = window.frame
        
        // Calculate the current aspect ratio of the window
        let currentAspectRatio = currentFrame.width / currentFrame.height
        let targetAspectRatio = aspectRatio.width / aspectRatio.height
        
        // Check if aspect ratio is significantly different (allowing for small floating point differences)
        if abs(currentAspectRatio - targetAspectRatio) > 0.01 {
            // 创建一个目标尺寸，基于屏幕最大尺寸的90%
            let targetSize = NSSize(
                width: screenFrame.width * 0.9,
                height: screenFrame.height * 0.9
            )
            
            // 使用calculateConstrainedWindowSize函数计算新尺寸
            let newSize = calculateConstrainedWindowSize(for: window, targetSize: targetSize, constraintToScreen: true)
            
            // Ensure the new size is not smaller than minimum allowed
            let finalSize = NSSize(
                width: max(newSize.width, window.minSize.width),
                height: max(newSize.height, window.minSize.height)
            )
            
            // Calculate center position on new screen
            let newX = screenFrame.origin.x + (screenFrame.width - finalSize.width) / 2
            let newY = screenFrame.origin.y + (screenFrame.height - finalSize.height) / 2
            
            let newFrame = NSRect(
                x: newX,
                y: newY,
                width: finalSize.width,
                height: finalSize.height
            )
            
            window.setFrame(newFrame, display: true, animate: true)
        }
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
    
    // Add window zoom control
    func windowShouldZoom(_ sender: NSWindow, toFrame newFrame: NSRect) -> Bool {
        // 获取当前窗口框架
        let currentFrame = sender.frame
        
        // 获取包含窗口的屏幕，如果没有则返回false
        guard let screen = sender.screen ?? NSScreen.main else { return false }
        
        // 获取屏幕的可见区域
        let screenFrame = screen.visibleFrame
        
        // 获取工具栏高度（如果可见）
        let toolbarHeight: CGFloat = (sender.toolbar?.isVisible == true) ? sender.frame.height - sender.contentLayoutRect.height : 0
        
        // 如果窗口处于正常大小，则放大到最大
        if currentFrame.size.width <= aspectRatio.width {
            // 计算最大可能的尺寸
            let maxWidth = screenFrame.width
            let maxHeight = screenFrame.height
            
            // 创建一个目标尺寸，代表最大化状态
            let targetSize = NSSize(width: maxWidth, height: maxHeight)
            
            // 使用calculateConstrainedWindowSize来维持宽高比
            let maxSize = calculateConstrainedWindowSize(for: sender, targetSize: targetSize, constraintToScreen: true)
            
            // 计算中心位置
            let newX = screenFrame.origin.x + (screenFrame.width - maxSize.width) / 2
            let newY = screenFrame.origin.y + (screenFrame.height - maxSize.height) / 2
            
            // 设置窗口的最大框架
            let maxFrame = NSRect(
                x: newX,
                y: newY,
                width: maxSize.width,
                height: maxSize.height
            )
            sender.setFrame(maxFrame, display: true, animate: true)
        } else {
            // 返回正常大小
            let normalSize: NSSize
            if AppStatus.hidReadResolusion.width > 0 && AppStatus.hidReadResolusion.height > 0 {
                // 基于HID分辨率计算正常尺寸
                let baseWidth = CGFloat(AppStatus.hidReadResolusion.width) / 2
                let baseHeight = CGFloat(AppStatus.hidReadResolusion.height) / 2 + toolbarHeight
                normalSize = NSSize(width: baseWidth, height: baseHeight)
            } else {
                // 使用默认宽高比
                normalSize = NSSize(
                    width: aspectRatio.width,
                    height: aspectRatio.height + toolbarHeight
                )
            }
            
            // 计算中心位置
            let newX = screenFrame.origin.x + (screenFrame.width - normalSize.width) / 2
            let newY = screenFrame.origin.y + (screenFrame.height - normalSize.height) / 2
            
            // 设置窗口的正常框架
            let normalFrame = NSRect(
                x: newX,
                y: newY,
                width: normalSize.width,
                height: normalSize.height
            )
            sender.setFrame(normalFrame, display: true, animate: true)
        }
        
        // 返回false表示不使用默认缩放行为
        return false
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

