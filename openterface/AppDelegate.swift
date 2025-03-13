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
    // MARK: - 属性
    
    @ObservedObject private var audioManager = AudioManager()
    
    private let statusBarManager = StatusBarManager()
    private let hostManager = HostManager()
    private let keyboardManager = KeyboardManager.shared
    private let serialPortManager = SerialPortManager.shared
    private let logger = Logger.shared
    
    private let defaultAspectRatio = CGSize(width: 1080, height: 659)
    
    // MARK: - 计算属性
    
    var isDarkMode: Bool {
        if #available(macOS 10.14, *) {
            return NSApp.effectiveAppearance.name == .darkAqua
        }
        return false
    }
    
    // MARK: - NSApplicationDelegate 方法
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuDelegate()
        initializeDeviceManagers()
        configureMainWindow()
        disableWindowTabbing()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 未来可能需要实现的功能
    }
    
    func applicationWillUpdate(_ notification: Notification) {
        // 未来可能需要实现的功能
    }
    
    // MARK: - NSWindowDelegate 方法
    
    func windowDidResize(_ notification: Notification) {
        guard let window = NSApplication.shared.mainWindow,
              let toolbar = window.toolbar, toolbar.isVisible else { return }
        
        let contentLayoutRect = window.contentLayoutRect
        AppStatus.currentView = contentLayoutRect
        AppStatus.currentWindow = window.frame
    }

    func windowWillResize(_ sender: NSWindow, to targetFrameSize: NSSize) -> NSSize {
        let toolbarHeight = getToolbarHeight(for: sender)
        let aspectRatioToUse = getAspectRatioToUse()
        
        guard let screen = sender.screen ?? NSScreen.main else { return targetFrameSize }
        let screenFrame = screen.visibleFrame
        
        // 计算保持宽高比的新尺寸
        var newSize = targetFrameSize
        let contentHeight = targetFrameSize.height - toolbarHeight
        let contentWidth = targetFrameSize.width
        
        let heightFromWidth = contentWidth / aspectRatioToUse
        let widthFromHeight = contentHeight * aspectRatioToUse
        
        // 选择较小的尺寸以确保窗口适合屏幕
        if heightFromWidth + toolbarHeight <= screenFrame.height {
            newSize.height = heightFromWidth + toolbarHeight
        } else {
            newSize.width = widthFromHeight
        }

        // 确保尺寸不超过屏幕边界
        newSize.width = min(newSize.width, screenFrame.width)
        newSize.height = min(newSize.height, screenFrame.height)
        
        // 确保尺寸不低于最小值
        let minContentHeight = sender.minSize.height - toolbarHeight
        let minContentWidth = sender.minSize.width
        newSize.width = max(newSize.width, minContentWidth)
        newSize.height = max(newSize.height, minContentHeight + toolbarHeight)
        
        return newSize
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        // 未来可能需要实现的功能
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // 未来可能需要实现的功能
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen else { return }
        
        // 检查是否处于全屏模式
        let isFullScreen = window.styleMask.contains(.fullScreen)
        
        // 如果是全屏模式，让PlayerView处理
        if isFullScreen {
            Logger.shared.log(content: "🔄 窗口切换屏幕（全屏模式）- 交由PlayerView处理")
            return
        }
        
        let screenFrame = screen.visibleFrame
        let currentFrame = window.frame
        
        // 计算窗口当前宽高比
        let currentAspectRatio = currentFrame.width / currentFrame.height
        let targetAspectRatio = defaultAspectRatio.width / defaultAspectRatio.height
        
        Logger.shared.log(content: "🖥️ 窗口切换到新屏幕 - 屏幕尺寸: \(screenFrame.size), 当前宽高比: \(currentAspectRatio), 目标宽高比: \(targetAspectRatio)")
        
        // 检查宽高比是否明显不同（允许小的浮点差异）
        if abs(currentAspectRatio - targetAspectRatio) > 0.01 {
            let maxPossibleWidth = screenFrame.width * 0.9
            let maxPossibleHeight = screenFrame.height * 0.9
            
            let newSize = calculateSizeWithAspectRatio(
                maxWidth: maxPossibleWidth,
                maxHeight: maxPossibleHeight,
                aspectRatio: targetAspectRatio
            )
            
            // 确保新尺寸不小于允许的最小值
            let finalSize = NSSize(
                width: max(newSize.width, window.minSize.width),
                height: max(newSize.height, window.minSize.height)
            )
            
            // 计算新屏幕上的中心位置
            let newFrame = calculateCenteredFrame(
                in: screenFrame,
                size: finalSize
            )
            
            Logger.shared.log(content: "📏 调整窗口大小以保持宽高比 - 新尺寸: \(finalSize)")
            
            window.setFrame(newFrame, display: true, animate: true)
            
            // 更新AppStatus中的视图和窗口信息
            if let contentView = window.contentView {
                AppStatus.currentView = contentView.bounds
            }
            AppStatus.currentWindow = window.frame
        } else {
            Logger.shared.log(content: "✅ 窗口宽高比正确，无需调整")
        }
    }
    
    func windowShouldZoom(_ sender: NSWindow, toFrame newFrame: NSRect) -> Bool {
        let currentFrame = sender.frame
        guard let screen = sender.screen ?? NSScreen.main else { return false }
        
        let screenFrame = screen.visibleFrame
        let toolbarHeight = getToolbarHeight(for: sender)
        let aspectRatioToUse = getAspectRatioToUse()
        
        if currentFrame.size.width <= defaultAspectRatio.width {
            // 放大到最大尺寸
            let maxPossibleWidth = screenFrame.width
            let maxPossibleHeight = screenFrame.height - toolbarHeight
            
            let maxSize = calculateSizeWithAspectRatio(
                maxWidth: maxPossibleWidth,
                maxHeight: maxPossibleHeight,
                aspectRatio: aspectRatioToUse,
                toolbarHeight: toolbarHeight
            )
            
            let maxFrame = calculateCenteredFrame(
                in: screenFrame,
                size: maxSize
            )
            
            sender.setFrame(maxFrame, display: true, animate: true)
        } else {
            // 恢复到正常尺寸
            let normalSize = calculateNormalSize(toolbarHeight: toolbarHeight)
            
            let normalFrame = calculateCenteredFrame(
                in: screenFrame,
                size: normalSize
            )
            
            sender.setFrame(normalFrame, display: true, animate: true)
        }
        
        // 返回false表示不使用默认缩放行为
        return false
    }
    
    // MARK: - 私有辅助方法
    
    private func setupMenuDelegate() {
        NSApp.mainMenu?.delegate = self
    }
    
    private func initializeDeviceManagers() {
        if #available(macOS 12.0, *) {
            USBDeivcesManager.shared.update()
        } else {
            logger.log(content: "USB设备管理需要macOS 12.0或更高版本。当前功能受限。")
        }
        
        // 在USB设备管理器更新后初始化HIDManager
        _ = HIDManager.shared
    }
    
    private func configureMainWindow() {
        NSApplication.shared.windows.forEach { window in
            guard let windowName = window.identifier?.rawValue,
                  windowName.contains(UserSettings.shared.mainWindownName) else { return }
            
            window.delegate = self
            window.backgroundColor = NSColor.fromHex("#000000")
            
            // 允许窗口调整大小但保持宽高比
            window.styleMask.insert(.resizable)
            
            window.setContentSize(defaultAspectRatio)
            
            // 设置最小尺寸以防止窗口过小
            window.minSize = NSSize(width: defaultAspectRatio.width / 2, height: defaultAspectRatio.height / 2)
            // 设置最大尺寸为合理值（初始尺寸的2倍）
            window.maxSize = NSSize(width: defaultAspectRatio.width * 2, height: defaultAspectRatio.height * 2)
            window.center()
        }
    }
    
    private func disableWindowTabbing() {
        // 禁用窗口标签功能，使"显示标签栏"菜单项不可用
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    private func getToolbarHeight(for window: NSWindow) -> CGFloat {
        return (window.toolbar?.isVisible == true) ? window.frame.height - window.contentLayoutRect.height : 0
    }
    
    private func getAspectRatioToUse() -> CGFloat {
        let hidAspectRatio = CGFloat(AppStatus.hidReadResolusion.width) / CGFloat(AppStatus.hidReadResolusion.height)
        let defaultAspectRatio = self.defaultAspectRatio.width / self.defaultAspectRatio.height
        
        return (AppStatus.hidReadResolusion.width > 0 && AppStatus.hidReadResolusion.height > 0) ? 
               hidAspectRatio : defaultAspectRatio
    }
    
    private func calculateSizeWithAspectRatio(
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        aspectRatio: CGFloat,
        toolbarHeight: CGFloat = 0
    ) -> NSSize {
        if maxWidth / aspectRatio <= maxHeight {
            // 宽度是限制因素
            return NSSize(
                width: maxWidth,
                height: (maxWidth / aspectRatio) + toolbarHeight
            )
        } else {
            // 高度是限制因素
            return NSSize(
                width: maxHeight * aspectRatio,
                height: maxHeight + toolbarHeight
            )
        }
    }
    
    private func calculateCenteredFrame(in screenFrame: NSRect, size: NSSize) -> NSRect {
        let newX = screenFrame.origin.x + (screenFrame.width - size.width) / 2
        let newY = screenFrame.origin.y + (screenFrame.height - size.height) / 2
        
        return NSRect(
            x: newX,
            y: newY,
            width: size.width,
            height: size.height
        )
    }
    
    private func calculateNormalSize(toolbarHeight: CGFloat) -> NSSize {
        if AppStatus.hidReadResolusion.width > 0 && AppStatus.hidReadResolusion.height > 0 {
            return NSSize(
                width: CGFloat(AppStatus.hidReadResolusion.width) / 2,
                height: CGFloat(AppStatus.hidReadResolusion.height) / 2 + toolbarHeight
            )
        } else {
            return NSSize(
                width: defaultAspectRatio.width,
                height: defaultAspectRatio.height + toolbarHeight
            )
        }
    }
}

// MARK: - NSColor 扩展

extension NSColor {
    static func fromHex(_ hex: String) -> NSColor {
        let hexFormatted = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        
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
        
        return NSColor(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

