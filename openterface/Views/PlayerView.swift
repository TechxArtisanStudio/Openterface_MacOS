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
    private let tipLayerManager = DependencyContainer.shared.resolve(TipLayerManagerProtocol.self)
    private var  logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var  hostManager = DependencyContainer.shared.resolve(HostManagerProtocol.self)
    var previewLayer: AVCaptureVideoPreviewLayer?
    let playerBackgorundWarringLayer = CATextLayer()
    let playerBackgroundImage = CALayer()
    
    // Add these variables to track mouse movement
    private var lastMouseEventTimestamp: TimeInterval = 0
    private var lastMousePosition: NSPoint = .zero
    private let minimumTimeBetweenEvents: TimeInterval = 0.016  // About 60fps
    private let minimumMouseDelta: CGFloat = 1.0  // Minimum pixels moved to trigger event
    
    init(captureSession: AVCaptureSession) {
        super.init(frame: .zero)
        self.previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        setupLayer()
        observe()
        
        // Add notification listener to update view when session starts/stops
        NotificationCenter.default.addObserver(
            self, 
            selector: #selector(captureSessionDidStartRunning), 
            name: .AVCaptureSessionDidStartRunning, 
            object: captureSession
        )
        NotificationCenter.default.addObserver(
            self, 
            selector: #selector(captureSessionDidStopRunning), 
            name: .AVCaptureSessionDidStopRunning, 
            object: captureSession
        )
    }

    func setupLayer() {
        logger.log(content: "Setup layer start")
    
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

        logger.log(content: "Setup layer completed")
        
    }
    
    func observe() {
        let playViewNtf = NotificationCenter.default
        
        // observer full Screen Nootification
        playViewNtf.addObserver(self, selector: #selector(handleDidEnterFullScreenNotification(_:)), name: NSWindow.didEnterFullScreenNotification, object: nil)
        playViewNtf.addObserver(self, selector: #selector(promptUserHowToExitRelativeMode(_:)), name: .enableRelativeModeNotification, object: nil)
    }
    
    @objc func promptUserHowToExitRelativeMode(_ notification: Notification) {
        let tips = "Press click「ESC」 multiple times to exit relative mode"
        if let window = self.window {
            tipLayerManager.showTip(
                text: tips,
                yOffset: 1.5,
                window: window
            )
        }
    }
    
    @objc func handleDidEnterFullScreenNotification(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window.styleMask.contains(.fullScreen) {
                var description = ""
                if let shortcut = KeyboardShortcuts.getShortcut(for: .exitFullScreenMode) {
                    description = "\(shortcut)"
                }
                let tips = "「\(description)」exit to full screen"
                tipLayerManager.showTip(
                    text: tips,
                    yOffset: 6.0,
                    window: window
                )
            }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // When the capture session starts running, call this method
    @objc func captureSessionDidStartRunning(_ notification: Notification) {
        logger.log(content: "Capture session started running, updating view")
        DispatchQueue.main.async {
            self.needsLayout = true
            self.needsDisplay = true
        }
    }
    
    // When the capture session stops running, call this method
    @objc func captureSessionDidStopRunning(_ notification: Notification) {
        logger.log(content: "Capture session stopped running, updating view")
        DispatchQueue.main.async {
            self.needsLayout = true
            self.needsDisplay = true
        }
    }
    
    // Override layout method to ensure preview layer covers entire view
    override func layout() {
        super.layout()
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.previewLayer?.frame = self.bounds
        self.playerBackgroundImage.frame = self.bounds
        CATransaction.commit()
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
        if UserSettings.shared.MouseControl == .relativeEvents {
            AppStatus.isFouceWindow = true
            NSCursor.hide()
        }
        // For HID mode, cursor hiding is handled in handleMouseMovement
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
        // Filter duplicate events
        let currentTime = ProcessInfo.processInfo.systemUptime
        let currentPosition = event.locationInWindow
        
        // Check if enough time has passed and mouse has moved enough
        let timeDelta = currentTime - lastMouseEventTimestamp
        let positionDelta = hypot(currentPosition.x - lastMousePosition.x,
                                currentPosition.y - lastMousePosition.y)
        
        if timeDelta >= minimumTimeBetweenEvents && positionDelta >= minimumMouseDelta {
            handleMouseMovement(with: event, mouseEvent: 0x00)
            
            // Update tracking variables
            lastMouseEventTimestamp = currentTime
            lastMousePosition = currentPosition
        }
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

    private func handleMouseMovement(with event: NSEvent, mouseEvent: UInt8 = 0x00, wheelMovement: Int = 0x00) {
        if UserSettings.shared.MouseControl == .relativeHID {
            // In HID mode, events are handled by the HID monitor in MouseManager
            // Only handle cursor hiding/showing for clicks, but not the movement itself
            if mouseEvent != 0x00 { // Only handle button press/release events
                if mouseEvent == 0x01 || mouseEvent == 0x02 || mouseEvent == 0x04 {
                    AppStatus.isFouceWindow = true
                    NSCursor.hide()
                }
            }
            return
        } else if UserSettings.shared.MouseControl == .relativeEvents {
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
            
            let isDragging = event.type == .leftMouseDragged || 
                            event.type == .rightMouseDragged || 
                            event.type == .otherMouseDragged
            
            hostManager.handleRelativeMouseAction(dx: deltaX, dy: deltaY, 
                                                       mouseEvent: mouseEvent, 
                                                       wheelMovement: wheelMovement, 
                                                       dragged: isDragging)
        } else {
            if AppStatus.isMouseInView {
                let mouseLocation = convert(event.locationInWindow, from: nil)
                let mouseX = Float(mouseLocation.x) / Float(self.frame.width) * 4096.0
                let mouseY = 4096.0 - Float(mouseLocation.y) / Float(self.frame.height) * 4096.0
                hostManager.handleAbsoluteMouseAction(x: Int(mouseX), y: Int(mouseY), 
                                                           mouseEvent: mouseEvent, 
                                                           wheelMovement: wheelMovement)
            }
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Logic for when the mouse enters the view
        AppStatus.isMouseInView = true

        if UserSettings.shared.MouseControl == .absolute {
            if UserSettings.shared.isAbsoluteModeMouseHide {
                NSCursor.hide()
                AppStatus.isCursorHidden = true
            } else {
                NSCursor.unhide()
                AppStatus.isCursorHidden = false
            }
        }
        
        if let viewFrame = self.previewLayer {
            AppStatus.currentView = viewFrame.frame
        }
        DispatchQueue.main.async {
            if let window = NSApplication.shared.mainWindow {
                AppStatus.currentWindow = window.frame
            }
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Logic for when the mouse exits the view
        AppStatus.isMouseInView = false
        
        if UserSettings.shared.MouseControl == .absolute {
            NSCursor.unhide()
        }

        if UserSettings.shared.MouseControl == .relativeEvents && AppStatus.isFouceWindow {
            hostManager.moveToAppCenter()
        }
        // For HID mode, mouse positioning is handled by the HID monitor
    }

    // Get window dimensions
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.window?.delegate = self
        
        if let window = self.window {
            let windowSize = window.frame.size
            UserSettings.shared.viewWidth = Float(windowSize.width)
            UserSettings.shared.viewHeight = Float(windowSize.height)
            window.center()
            
            // Update the frame of playerBackgroundImage
            playerBackgroundImage.frame = self.bounds
        } else {
            logger.log(content: "The view is not in a window yet.")
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


