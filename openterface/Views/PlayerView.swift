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
import AVFoundation
import KeyboardShortcuts

class PlayerView: NSView, NSWindowDelegate {
    var previewLayer: AVCaptureVideoPreviewLayer?
    let playerBackgorundWarringLayer = CATextLayer()
    let playerBackgroundImage = CALayer()
    
    init(captureSession: AVCaptureSession) {
        super.init(frame: .zero)
        self.previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        setupLayer()
        observe()
    }

    func setupLayer() {
        Logger.shared.log(content: "Setup layer start")
    
        self.previewLayer?.frame = self.frame
        self.previewLayer?.contentsGravity = .resizeAspectFill
        self.previewLayer?.videoGravity = .resizeAspectFill
        self.previewLayer?.connection?.automaticallyAdjustsVideoMirroring = false
        
        if let image = NSImage(named: "content_dark_eng"), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            playerBackgroundImage.contents = cgImage
            playerBackgroundImage.contentsGravity = .resizeAspect
            self.playerBackgroundImage.zPosition = -2
        }
        self.previewLayer?.addSublayer(self.playerBackgroundImage)

        layer = self.previewLayer

        Logger.shared.log(content: "Setup layer completed")
    }
    
    func observe() {
        let playViewNtf = NotificationCenter.default
        
        // observer full Screen Nootification
        playViewNtf.addObserver(self, selector: #selector(handleDidEnterFullScreenNotification(_:)), name: NSWindow.didEnterFullScreenNotification, object: nil)
        playViewNtf.addObserver(self, selector: #selector(handleCustomNotification(_:)), name: .enableRelativeModeNotification, object: nil)
    }
    
    func map(value: Double, inMin: Double, inMax: Double, outMin: Double, outMax: Double) -> Double {
        // 防止除零
        guard inMax - inMin != 0 else { return outMin }
      
        // 计算输入数值在输入范围内的比例
        let inputScale = (value - inMin) / (inMax - inMin)
      
        // 将输入比例映射到输出范围
        let outputValue = outMin + (outMax - outMin) * inputScale
        return outputValue
    }
    
    @objc func handleCustomNotification(_ notification: Notification) {
        if let screen = NSScreen.main {
            let screenSize = screen.frame.size
            Logger.shared.log(content: "Screen resolution is \(screenSize.width) x \(screenSize.height)")

            if let layer = self.layer {
                let screenSize = self.bounds.size
                let textLayer = CATextLayer()
                let tips = "Press click「ESC」 multiple times to exit relative mode"
                textLayer.string = tips
                textLayer.fontSize = map(value: screenSize.width, inMin: 100, inMax: 2000, outMin: 10, outMax: 30)
                textLayer.frame = CGRect(x: screenSize.width - CGFloat(CGFloat(tips.count) * textLayer.fontSize * 0.5), y: screenSize.height - textLayer.fontSize * 1.5 , width: CGFloat(CGFloat(tips.count) * textLayer.fontSize * 0.5), height: textLayer.fontSize * 1.5)
                textLayer.foregroundColor = NSColor.white.cgColor
                textLayer.backgroundColor = NSColor.black.cgColor
                textLayer.alignmentMode = .center
                textLayer.contentsScale = self.window?.backingScaleFactor ?? 1

                layer.addSublayer(textLayer)

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    let fadeAnimation = CABasicAnimation(keyPath: "opacity")
                    fadeAnimation.fromValue = 1.0
                    fadeAnimation.toValue = 0.0
                    fadeAnimation.duration = 5.0
                    fadeAnimation.isRemovedOnCompletion = false
                    fadeAnimation.fillMode = .forwards

                    textLayer.add(fadeAnimation, forKey: nil)
                }
            }
        }
    }
    
    @objc func handleDidEnterFullScreenNotification(_ notification: Notification) {
        
        if let screen = NSScreen.main {
            let screenSize = screen.frame.size
            Logger.shared.log(content: "Screen resolution is \(screenSize.width) x \(screenSize.height)")
            
            if let window = notification.object as? NSWindow  , let _ =  self.window?.contentView?.frame.size{
                // NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask.keyDown, handler: myKeyDownEvent)
                if window.styleMask.contains(.fullScreen) {
                    let textLayer = CATextLayer()
                    var description:String = ""
                    if let shortcut = KeyboardShortcuts.getShortcut(for: .exitFullScreenMode) {
                        description = "\(shortcut)"
                    }
                    let tips = "「\(String(describing: description))」exit to full screen"
                    textLayer.string = tips
                    textLayer.fontSize = map(value: screenSize.width, inMin: 100, inMax: 2000, outMin: 10, outMax: 30)
                    
                    let _x = screenSize.width - CGFloat(CGFloat(tips.count) * textLayer.fontSize * 0.6)
                    let _y = screenSize.height - textLayer.fontSize * 6
                    let _w = CGFloat(CGFloat(tips.count) * textLayer.fontSize * 0.5)
                    let _h = textLayer.fontSize * 1.5
                    
                    textLayer.frame = CGRect(
                        x: _x,
                        y: _y ,
                        width: _w,
                        height: _h
                    )
                    
                    textLayer.backgroundColor = NSColor.black.cgColor
            
                    self.previewLayer?.addSublayer(textLayer)
            
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        let fadeAnimation = CABasicAnimation(keyPath: "opacity")
                        fadeAnimation.fromValue = 1.0
                        fadeAnimation.toValue = 0.0
                        fadeAnimation.duration = 2.0
                        fadeAnimation.isRemovedOnCompletion = false
                        fadeAnimation.fillMode = .forwards
                        
                        textLayer.add(fadeAnimation, forKey: "opacityAnimation")
                    }
                }
            }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        // 移除所有现有的跟踪区域
        for trackingArea in self.trackingAreas {
            self.removeTrackingArea(trackingArea)
        }
        
        // 创建并添加新的跟踪区域
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        let trackingArea = NSTrackingArea(rect: self.bounds, options: options, owner: self, userInfo: nil)
        self.addTrackingArea(trackingArea)
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // 鼠标进入视图时的处理逻辑
        AppStatus.isMouseInView = true
        
        if let viewFrame = self.previewLayer {
            AppStatus.currentView = viewFrame.frame
        }
        if let window = NSApplication.shared.mainWindow {
            AppStatus.currentWindow = window.frame
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // 鼠标退出视图时的处理逻辑
        AppStatus.isMouseInView = false
    }
    
    // 获取窗口长宽
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.window?.delegate = self
        
        if let window = self.window {
            let windowSize = window.frame.size
            UserSettings.shared.viewWidth = Float(windowSize.width)
            UserSettings.shared.viewHigh = Float(windowSize.height)
            window.center()
            
            // 更新 playerBackgroundImage 的 frame
             playerBackgroundImage.frame = self.bounds
        } else {
            Logger.shared.log(content: "The view is not in a window yet.")
        }
    }
    
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)

        playerBackgroundImage.frame = self.bounds
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()

        playerBackgroundImage.frame = self.bounds
    }
    
    func windowDidResize(_ notification: Notification) {
        if let window = self.window {
            playerBackgroundImage.frame = NSRect(origin: .zero, size: window.frame.size)
        }
    }
}


extension Notification.Name {
    static let enableRelativeModeNotification = Notification.Name("enableRelativeModeNotification")
}

