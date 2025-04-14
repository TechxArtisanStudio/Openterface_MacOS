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
    
    // Add a flag to track if the application has just launched
    private var isInitialLaunch = true
    
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
        
        // Register for HID resolution change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHidResolutionChanged(_:)),
            name: .hidResolutionChanged,
            object: nil
        )
        
        // Listen for window size update notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowSizeUpdateRequest(_:)),
            // name: Notification.Name("UpdateWindowSizeNotification"),
            name: Notification.Name.updateWindowSize,
            object: nil
        )
        
        // Initialize window menu items
        setupAspectRatioMenu()
        
        // start audio
        // if audioManager.microphonePermissionGranted {
        //     audioManager.prepareAudio()
        // }
        
        // Set a delay to set the initial launch flag to false after the application has fully started
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isInitialLaunch = false
        }
    }
    
    // Handle HID resolution change notifications
    @objc func handleHidResolutionChanged(_ notification: Notification) {
        // If this is the initial launch, ignore this notification
        if isInitialLaunch {
            // Only update window size silently without showing a prompt
            DispatchQueue.main.async {
                if let window = NSApplication.shared.mainWindow {
                    self.updateWindowSize(window: window)
                }
            }
            return
        }
        
        // Ensure UI operations are performed on the main thread
        DispatchQueue.main.async {
            // Check if the user has selected to not show the prompt again
            if UserSettings.shared.doNotShowHidResolutionAlert {
                // Update window size directly without showing a prompt
                if let window = NSApplication.shared.mainWindow {
                    self.updateWindowSize(window: window)
                }
                return
            }
            
            // Prompt user to choose aspect ratio when HID resolution changes
            if let window = NSApplication.shared.mainWindow {
                let alert = NSAlert()
                alert.messageText = "Display Resolution Changed"
                alert.informativeText = "Display resolution change detected. Would you like to use a custom screen aspect ratio?"
                alert.addButton(withTitle: "Yes")
                alert.addButton(withTitle: "No")
                
                // Add "Don't show again" checkbox
                let doNotShowCheckbox = NSButton(checkboxWithTitle: "Don't show this prompt again", target: nil, action: nil)
                doNotShowCheckbox.state = .off
                alert.accessoryView = doNotShowCheckbox
                
                let response = alert.runModal()
                
                // Save user's "Don't show again" preference
                if doNotShowCheckbox.state == .on {
                    UserSettings.shared.doNotShowHidResolutionAlert = true
                }
                
                if response == .alertFirstButtonReturn {
                    // Show aspect ratio selection menu
                    self.showAspectRatioSelection()
                }
                
                // Update window size based on new aspect ratio
                self.updateWindowSize(window: window)
            }
        }
    }
    
    // Show aspect ratio selection menu
    func showAspectRatioSelection() {
        WindowUtils.shared.showAspectRatioSelector { shouldUpdateWindow in
            if shouldUpdateWindow {
                // Update window size
                if let window = NSApplication.shared.mainWindow {
                    self.updateWindowSize(window: window)
                }
            }
        }
    }
    
    // Setup aspect ratio selection menu
    func setupAspectRatioMenu() {
        // Get the main menu of the application
        guard let mainMenu = NSApp.mainMenu else { return }
        
        // Find the "View" menu or create a new one
        let viewMenuItem = mainMenu.items.first { $0.title == "View" } ?? 
                          mainMenu.items.first { $0.title == "View" }
        
        var viewMenu: NSMenu
        
        if let existingViewMenuItem = viewMenuItem {
            viewMenu = existingViewMenuItem.submenu ?? NSMenu(title: "View")
            existingViewMenuItem.submenu = viewMenu
        } else {
            // If the "View" menu is not found, create a new one
            viewMenu = NSMenu(title: "View")
            let newViewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            newViewMenuItem.submenu = viewMenu
            
            // Find a suitable position to insert the new menu (usually after "File" and "Edit")
            if let editMenuIndex = mainMenu.items.firstIndex(where: { $0.title == "Edit" || $0.title == "Edit" }) {
                mainMenu.insertItem(newViewMenuItem, at: editMenuIndex + 1)
            } else {
                mainMenu.addItem(newViewMenuItem)
            }
        }
        
        // Add a separator
        if viewMenu.items.count > 0 {
            viewMenu.addItem(NSMenuItem.separator())
        }
        
        // Add a "Screen Ratio" submenu
        let aspectRatioMenu = NSMenu(title: "Screen Ratio")
        let aspectRatioMenuItem = NSMenuItem(title: "Screen Ratio", action: nil, keyEquivalent: "")
        aspectRatioMenuItem.submenu = aspectRatioMenu
        viewMenu.addItem(aspectRatioMenuItem)
        
        // Add "Auto Detect" option
        let autoDetectItem = NSMenuItem(title: "Auto Detect", action: #selector(selectAutoDetectAspectRatio(_:)), keyEquivalent: "")
        autoDetectItem.state = UserSettings.shared.useCustomAspectRatio ? .off : .on
        aspectRatioMenu.addItem(autoDetectItem)
        
        aspectRatioMenu.addItem(NSMenuItem.separator())
        
        // Add preset aspect ratio options
        for option in AspectRatioOption.allCases {
            let menuItem = NSMenuItem(title: option.rawValue, action: #selector(selectAspectRatio(_:)), keyEquivalent: "")
            menuItem.representedObject = option
            if UserSettings.shared.useCustomAspectRatio && UserSettings.shared.customAspectRatio == option {
                menuItem.state = .on
            }
            aspectRatioMenu.addItem(menuItem)
        }
        
        // Add a separator
        viewMenu.addItem(NSMenuItem.separator())
        
        // Add a "HID Resolution Change Alert Settings" menu item
        let hidAlertMenuItem = NSMenuItem(title: "HID Resolution Change Alert Settings", action: #selector(showHidResolutionAlertSettings(_:)), keyEquivalent: "")
        viewMenu.addItem(hidAlertMenuItem)
    }
    
    // Select auto detect aspect ratio
    @objc func selectAutoDetectAspectRatio(_ sender: NSMenuItem) {
        // Close user custom aspect ratio
        UserSettings.shared.useCustomAspectRatio = false
        
        // Update menu items status
        updateAspectRatioMenuItems()
        
        // Update window size
        if let window = NSApplication.shared.mainWindow {
            updateWindowSize(window: window)
        }
    }
    
    // Select custom aspect ratio
    @objc func selectAspectRatio(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? AspectRatioOption else { return }
        
        // Save user selection
        UserSettings.shared.customAspectRatio = option
        UserSettings.shared.useCustomAspectRatio = true
        
        // Update menu items status
        updateAspectRatioMenuItems()
        
        // Update window size
        if let window = NSApplication.shared.mainWindow {
            updateWindowSize(window: window)
        }
    }
    
    // Update aspect ratio menu items status
    func updateAspectRatioMenuItems() {
        guard let mainMenu = NSApp.mainMenu,
              let viewMenuItem = mainMenu.items.first(where: { $0.title == "View" || $0.title == "View" }),
              let viewMenu = viewMenuItem.submenu,
              let aspectRatioMenuItem = viewMenu.items.first(where: { $0.title == "Screen Ratio" }),
              let aspectRatioMenu = aspectRatioMenuItem.submenu else { return }
        
        // Update "Auto Detect" option
        if let autoDetectItem = aspectRatioMenu.items.first(where: { $0.title == "Auto Detect" }) {
            autoDetectItem.state = UserSettings.shared.useCustomAspectRatio ? .off : .on
        }
        
        // Update all preset aspect ratio options
        for item in aspectRatioMenu.items {
            if let option = item.representedObject as? AspectRatioOption {
                item.state = (UserSettings.shared.useCustomAspectRatio && UserSettings.shared.customAspectRatio == option) ? .on : .off
            }
        }
    }
    
    // Update window size
    func updateWindowSize(window: NSWindow) {
        // Get screen size
        guard let screen = window.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        
        // Calculate new window size
        let targetSize = NSSize(
            width: screenFrame.width * 0.9,
            height: screenFrame.height * 0.9
        )
        
        // Calculate appropriate size
        let newSize = calculateConstrainedWindowSize(for: window, targetSize: targetSize, constraintToScreen: true)
        
        // Calculate center position
        let newX = screenFrame.origin.x + (screenFrame.width - newSize.width) / 2
        let newY = screenFrame.origin.y + (screenFrame.height - newSize.height) / 2
        
        // Set window size and position
        let newFrame = NSRect(
            x: newX,
            y: newY,
            width: newSize.width,
            height: newSize.height
        )
        
        window.setFrame(newFrame, display: true, animate: true)
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
        
        // Determine the aspect ratio to use
        let aspectRatioToUse: CGFloat
        
        // Priority: 1. User custom ratio 2. HID ratio 3. Default ratio
        if UserSettings.shared.useCustomAspectRatio {
            // Use user custom ratio
            aspectRatioToUse = UserSettings.shared.customAspectRatio.widthToHeightRatio
        } else if AppStatus.hidReadResolusion.width > 0 && AppStatus.hidReadResolusion.height > 0 {
            // Use HID ratio
            let hidAspectRatio = CGFloat(AppStatus.hidReadResolusion.width) / CGFloat(AppStatus.hidReadResolusion.height)
            aspectRatioToUse = hidAspectRatio
        } else {
            // Use default ratio
            let defaultAspectRatio = aspectRatio.width / aspectRatio.height
            aspectRatioToUse = defaultAspectRatio
        }
        
        // Get the screen containing the window
        guard let screen = window.screen ?? NSScreen.main else { return targetSize }
        let screenFrame = screen.visibleFrame
        
        // Calculate new size maintaining content area aspect ratio
        var newSize = targetSize
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
            // Create a target size based on 90% of the screen's maximum size
            let targetSize = NSSize(
                width: screenFrame.width * 0.9,
                height: screenFrame.height * 0.9
            )
            
            // Use calculateConstrainedWindowSize function to calculate new size
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
        // Get current window frame
        let currentFrame = sender.frame
        
        // Get the screen containing the window, if none then return false
        guard let screen = sender.screen ?? NSScreen.main else { return false }
        
        // Get the visible area of the screen
        let screenFrame = screen.visibleFrame
        
        // Get the height of the toolbar (if visible)
        let toolbarHeight: CGFloat = (sender.toolbar?.isVisible == true) ? sender.frame.height - sender.contentLayoutRect.height : 0
        
        // If the window is in normal size, then zoom to max
        if currentFrame.size.width <= aspectRatio.width {
            // Calculate the maximum possible size
            let maxWidth = screenFrame.width
            let maxHeight = screenFrame.height
            
            // Create a target size, representing the maximized state
            let targetSize = NSSize(width: maxWidth, height: maxHeight)
            
            // Use calculateConstrainedWindowSize to maintain the aspect ratio
            let maxSize = calculateConstrainedWindowSize(for: sender, targetSize: targetSize, constraintToScreen: true)
            
            // Calculate center position
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
            // Return to normal size
            let normalSize: NSSize
            if AppStatus.hidReadResolusion.width > 0 && AppStatus.hidReadResolusion.height > 0 {
                // Calculate normal size based on HID resolution
                let baseWidth = CGFloat(AppStatus.hidReadResolusion.width) / 2
                let baseHeight = CGFloat(AppStatus.hidReadResolusion.height) / 2 + toolbarHeight
                normalSize = NSSize(width: baseWidth, height: baseHeight)
            } else {
                // Use default aspect ratio
                normalSize = NSSize(
                    width: aspectRatio.width,
                    height: aspectRatio.height + toolbarHeight
                )
            }
            
            // Calculate center position
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
        
        // Return false to indicate not to use default zoom behavior
        return false
    }
    
    // Handle window size update request
    @objc func handleWindowSizeUpdateRequest(_ notification: Notification) {
        if let window = NSApplication.shared.mainWindow {
            updateWindowSize(window: window)
        }
    }
    
    // Show HID resolution change alert settings
    @objc func showHidResolutionAlertSettings(_ sender: NSMenuItem) {
        WindowUtils.shared.showHidResolutionAlertSettings()
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

