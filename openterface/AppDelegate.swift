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
        
        // 注册HID分辨率变化通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHidResolutionChanged(_:)),
            name: .hidResolutionChanged,
            object: nil
        )
        
        // 监听窗口大小更新通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowSizeUpdateRequest(_:)),
            name: Notification.Name("UpdateWindowSizeNotification"),
            object: nil
        )
        
        // 初始化窗口菜单项
        setupAspectRatioMenu()
        
        // start audio
        // if audioManager.microphonePermissionGranted {
        //     audioManager.prepareAudio()
        // }
    }
    
    // 处理HID分辨率变化通知
    @objc func handleHidResolutionChanged(_ notification: Notification) {
        // 确保UI操作在主线程上执行
        DispatchQueue.main.async {
            // 当HID分辨率变化时，提示用户选择比例
            if let window = NSApplication.shared.mainWindow {
                let alert = NSAlert()
                alert.messageText = "显示分辨率已变更"
                alert.informativeText = "检测到显示分辨率变化，您希望使用自定义屏幕比例吗？"
                alert.addButton(withTitle: "是")
                alert.addButton(withTitle: "否")
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // 显示比例选择菜单
                    self.showAspectRatioSelection()
                }
                
                // 根据新的比例更新窗口尺寸
                self.updateWindowSize(window: window)
            }
        }
    }
    
    // 显示比例选择菜单
    func showAspectRatioSelection() {
        guard let window = NSApplication.shared.mainWindow else { return }
        
        let alert = NSAlert()
        alert.messageText = "选择屏幕比例"
        alert.informativeText = "请选择您希望使用的屏幕比例："
        
        let aspectRatioPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
        
        // 添加所有预设比例选项
        for option in AspectRatioOption.allCases {
            aspectRatioPopup.addItem(withTitle: option.rawValue)
        }
        
        // 设置当前选中的比例
        if let index = AspectRatioOption.allCases.firstIndex(of: UserSettings.shared.customAspectRatio) {
            aspectRatioPopup.selectItem(at: index)
        }
        
        alert.accessoryView = aspectRatioPopup
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let selectedIndex = aspectRatioPopup.indexOfSelectedItem
            if selectedIndex >= 0 && selectedIndex < AspectRatioOption.allCases.count {
                // 保存用户选择
                UserSettings.shared.customAspectRatio = AspectRatioOption.allCases[selectedIndex]
                UserSettings.shared.useCustomAspectRatio = true
                
                // 更新窗口尺寸
                updateWindowSize(window: window)
            }
        }
    }
    
    // 设置比例选择菜单
    func setupAspectRatioMenu() {
        // 获取应用程序主菜单
        guard let mainMenu = NSApp.mainMenu else { return }
        
        // 查找"查看"菜单或创建一个新的
        let viewMenuItem = mainMenu.items.first { $0.title == "查看" } ?? 
                          mainMenu.items.first { $0.title == "View" }
        
        var viewMenu: NSMenu
        
        if let existingViewMenuItem = viewMenuItem {
            viewMenu = existingViewMenuItem.submenu ?? NSMenu(title: "查看")
            existingViewMenuItem.submenu = viewMenu
        } else {
            // 如果没有找到"查看"菜单，创建一个新的
            viewMenu = NSMenu(title: "查看")
            let newViewMenuItem = NSMenuItem(title: "查看", action: nil, keyEquivalent: "")
            newViewMenuItem.submenu = viewMenu
            
            // 找到合适的位置插入新菜单（通常在"文件"和"编辑"之后）
            if let editMenuIndex = mainMenu.items.firstIndex(where: { $0.title == "编辑" || $0.title == "Edit" }) {
                mainMenu.insertItem(newViewMenuItem, at: editMenuIndex + 1)
            } else {
                mainMenu.addItem(newViewMenuItem)
            }
        }
        
        // 添加分隔线
        if viewMenu.items.count > 0 {
            viewMenu.addItem(NSMenuItem.separator())
        }
        
        // 添加"屏幕比例"子菜单
        let aspectRatioMenu = NSMenu(title: "屏幕比例")
        let aspectRatioMenuItem = NSMenuItem(title: "屏幕比例", action: nil, keyEquivalent: "")
        aspectRatioMenuItem.submenu = aspectRatioMenu
        viewMenu.addItem(aspectRatioMenuItem)
        
        // 添加"自动检测"选项
        let autoDetectItem = NSMenuItem(title: "自动检测", action: #selector(selectAutoDetectAspectRatio(_:)), keyEquivalent: "")
        autoDetectItem.state = UserSettings.shared.useCustomAspectRatio ? .off : .on
        aspectRatioMenu.addItem(autoDetectItem)
        
        aspectRatioMenu.addItem(NSMenuItem.separator())
        
        // 添加预设比例选项
        for option in AspectRatioOption.allCases {
            let menuItem = NSMenuItem(title: option.rawValue, action: #selector(selectAspectRatio(_:)), keyEquivalent: "")
            menuItem.representedObject = option
            if UserSettings.shared.useCustomAspectRatio && UserSettings.shared.customAspectRatio == option {
                menuItem.state = .on
            }
            aspectRatioMenu.addItem(menuItem)
        }
    }
    
    // 选择自动检测比例
    @objc func selectAutoDetectAspectRatio(_ sender: NSMenuItem) {
        // 关闭用户自定义比例
        UserSettings.shared.useCustomAspectRatio = false
        
        // 更新菜单项状态
        updateAspectRatioMenuItems()
        
        // 更新窗口尺寸
        if let window = NSApplication.shared.mainWindow {
            updateWindowSize(window: window)
        }
    }
    
    // 选择自定义比例
    @objc func selectAspectRatio(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? AspectRatioOption else { return }
        
        // 保存用户选择
        UserSettings.shared.customAspectRatio = option
        UserSettings.shared.useCustomAspectRatio = true
        
        // 更新菜单项状态
        updateAspectRatioMenuItems()
        
        // 更新窗口尺寸
        if let window = NSApplication.shared.mainWindow {
            updateWindowSize(window: window)
        }
    }
    
    // 更新比例菜单项状态
    func updateAspectRatioMenuItems() {
        guard let mainMenu = NSApp.mainMenu,
              let viewMenuItem = mainMenu.items.first(where: { $0.title == "查看" || $0.title == "View" }),
              let viewMenu = viewMenuItem.submenu,
              let aspectRatioMenuItem = viewMenu.items.first(where: { $0.title == "屏幕比例" }),
              let aspectRatioMenu = aspectRatioMenuItem.submenu else { return }
        
        // 更新"自动检测"选项
        if let autoDetectItem = aspectRatioMenu.items.first(where: { $0.title == "自动检测" }) {
            autoDetectItem.state = UserSettings.shared.useCustomAspectRatio ? .off : .on
        }
        
        // 更新所有预设比例选项
        for item in aspectRatioMenu.items {
            if let option = item.representedObject as? AspectRatioOption {
                item.state = (UserSettings.shared.useCustomAspectRatio && UserSettings.shared.customAspectRatio == option) ? .on : .off
            }
        }
    }
    
    // 更新窗口尺寸
    func updateWindowSize(window: NSWindow) {
        // 获取屏幕尺寸
        guard let screen = window.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        
        // 计算新窗口尺寸
        let targetSize = NSSize(
            width: screenFrame.width * 0.9,
            height: screenFrame.height * 0.9
        )
        
        // 计算适当的尺寸
        let newSize = calculateConstrainedWindowSize(for: window, targetSize: targetSize, constraintToScreen: true)
        
        // 计算中心位置
        let newX = screenFrame.origin.x + (screenFrame.width - newSize.width) / 2
        let newY = screenFrame.origin.y + (screenFrame.height - newSize.height) / 2
        
        // 设置窗口尺寸和位置
        let newFrame = NSRect(
            x: newX,
            y: newY,
            width: newSize.width,
            height: newSize.height
        )
        
        window.setFrame(newFrame, display: true, animate: true)
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
        
        // 确定要使用的宽高比
        let aspectRatioToUse: CGFloat
        
        // 优先级：1. 用户自定义比例 2. HID获取的比例 3. 默认比例
        if UserSettings.shared.useCustomAspectRatio {
            // 使用用户自定义比例
            aspectRatioToUse = UserSettings.shared.customAspectRatio.widthToHeightRatio
            Logger.shared.log(content: "使用用户自定义比例: \(UserSettings.shared.customAspectRatio.rawValue), 比例值: \(aspectRatioToUse)")
        } else if AppStatus.hidReadResolusion.width > 0 && AppStatus.hidReadResolusion.height > 0 {
            // 使用HID获取的比例
            let hidAspectRatio = CGFloat(AppStatus.hidReadResolusion.width) / CGFloat(AppStatus.hidReadResolusion.height)
            aspectRatioToUse = hidAspectRatio
            Logger.shared.log(content: "使用HID获取的比例: \(AppStatus.hidReadResolusion.width):\(AppStatus.hidReadResolusion.height), 比例值: \(aspectRatioToUse)")
        } else {
            // 使用默认比例
            let defaultAspectRatio = aspectRatio.width / aspectRatio.height
            aspectRatioToUse = defaultAspectRatio
            Logger.shared.log(content: "使用默认比例: \(aspectRatio.width):\(aspectRatio.height), 比例值: \(aspectRatioToUse)")
        }
        
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
        let heightFromWidth = (contentWidth / aspectRatioToUse)
        let widthFromHeight = (contentHeight * aspectRatioToUse)
        
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
    
    // 处理窗口大小更新请求
    @objc func handleWindowSizeUpdateRequest(_ notification: Notification) {
        if let window = NSApplication.shared.mainWindow {
            updateWindowSize(window: window)
        }
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

