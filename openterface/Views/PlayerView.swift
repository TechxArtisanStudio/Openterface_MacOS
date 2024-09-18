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
        // Prevent division by zero
        guard inMax - inMin != 0 else { return outMin }
      
        // Calculate the input value's ratio within the input range
        let inputScale = (value - inMin) / (inMax - inMin)
      
        // Map the input ratio to the output range
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
        
        // Remove all existing tracking areas
        for trackingArea in self.trackingAreas {
            self.removeTrackingArea(trackingArea)
        }
        
        // Create and add new tracking areas
        self.window?.acceptsMouseMovedEvents = true
        let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .activeAlways]
        let trackingArea = NSTrackingArea(rect: self.bounds, options: options, owner: self, userInfo: nil)
        self.addTrackingArea(trackingArea)
    }
    
    override func mouseDown(with event: NSEvent) {
        handleMouseMovement(with: event, mouseEvent: 0x01)
        if UserSettings.shared.MouseControl == .relative {
            AppStatus.isFouceWindow = true
            NSCursor.hide()
        }
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseMovement(with: event, mouseEvent: 0x00)
    }
    
    override func rightMouseDown(with event: NSEvent) {
        handleMouseMovement(with: event, mouseEvent: 0x02)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleMouseMovement(with: event, mouseEvent: 0x00)
    }

    override func otherMouseDown(with event: NSEvent) {
        handleMouseMovement(with: event, mouseEvent: 0x04)
    }

    override func otherMouseUp(with event: NSEvent) {
        handleMouseMovement(with: event, mouseEvent: 0x00)
    }

    override func mouseMoved(with event: NSEvent) {
        handleMouseMovement(with: event, mouseEvent: 0x00)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseMovement(with: event, mouseEvent: 0x01)
    }
    
    override func rightMouseDragged(with event: NSEvent) {
        handleMouseMovement(with: event, mouseEvent: 0x02)
    }
    
    override func otherMouseDragged(with event: NSEvent) {
        handleMouseMovement(with: event, mouseEvent: 0x04)  // Be AWARE! 0x04 may not match to Middle mouse button correctly! Need to Test Further!
    }

    override func scrollWheel(with event: NSEvent) {
        let wheelMovement = Int(event.scrollingDeltaY)
        handleMouseMovement(with: event, wheelMovement: wheelMovement)
    }


    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        self.window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        handleKeyboardEvent(with: event, isKeyDown: true)
    }

    override func keyUp(with event: NSEvent) {
        handleKeyboardEvent(with: event, isKeyDown: false)
    }

    private func handleKeyboardEvent(with event: NSEvent, isKeyDown: Bool) {
        let keyCode = event.keyCode
        let modifierFlags = event.modifierFlags

        HostManager.shared.handleKeyboardEvent(keyCode: keyCode, modifierFlags: modifierFlags, isKeyDown: isKeyDown)
    }

    private func handleMouseMovement(with event: NSEvent, mouseEvent: UInt8 = 0x00, wheelMovement: Int = 0x00) {
        if UserSettings.shared.MouseControl == .relative {
            let deltaX = Int(event.deltaX)
            let deltaY = Int(event.deltaY)
            let mouseLocation = convert(event.locationInWindow, from: nil)
            let mouseXPtg = Float(mouseLocation.x) / Float(self.frame.width)
            let mouseYPtg = 1 - Float(mouseLocation.y) / Float(self.frame.height)

            // Skip the event if the mouse is at the screen center and the delta is larger than 100
            if (deltaX > 100 || deltaY > 100) 
                && (mouseXPtg > 0.4 && mouseXPtg < 0.6)
                && (mouseYPtg > 0.4 && mouseYPtg < 0.6) {
                return
            }
            
            HostManager.shared.handleRelativeMouseAction(dx: deltaX, dy: deltaY, 
                                                        mouseEvent: mouseEvent, 
                                                        wheelMovement: wheelMovement, 
                                                        dragged: true)
        } else {
            if AppStatus.isMouseInView {
                let mouseLocation = convert(event.locationInWindow, from: nil)
                let mouseX = Float(mouseLocation.x) / Float(self.frame.width) * 4096.0
                let mouseY = 4096.0 - Float(mouseLocation.y) / Float(self.frame.height) * 4096.0
                HostManager.shared.handleAbsoluteMouseAction(x: Int(mouseX), y: Int(mouseY), mouseEvent: mouseEvent, wheelMovement: wheelMovement)
            }
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Logic for when the mouse enters the view
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
        // Logic for when the mouse exits the view
        AppStatus.isMouseInView = false
        
        if UserSettings.shared.MouseControl == .relative && AppStatus.isFouceWindow {
            HostManager.shared.moveToAppCenter()
        }
    }

    // Get window dimensions
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.window?.delegate = self
        
        if let window = self.window {
            let windowSize = window.frame.size
            UserSettings.shared.viewWidth = Float(windowSize.width)
            UserSettings.shared.viewHigh = Float(windowSize.height)
            window.center()
            
            // Update the frame of playerBackgroundImage
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


