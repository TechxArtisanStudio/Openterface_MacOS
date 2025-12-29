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
import QuartzCore

class PlayerView: NSView, NSWindowDelegate {
    private let tipLayerManager = DependencyContainer.shared.resolve(TipLayerManagerProtocol.self)
    private var  logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var  hostManager = DependencyContainer.shared.resolve(HostManagerProtocol.self)
    private var  inputMonitorManager = InputMonitorManager.shared
    var previewLayer: AVCaptureVideoPreviewLayer?
    let playerBackgorundWarringLayer = CATextLayer()
    let playerBackgroundImage = CALayer()
    
    // Add these variables to track mouse movement
    private var lastMouseEventTimestamp: TimeInterval = 0
    private var lastMousePosition: NSPoint = .zero
    
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
        // self.previewLayer?.contentsGravity = .resizeAspectFill
        // self.previewLayer?.videoGravity = .resizeAspectFill
        self.previewLayer?.contentsGravity = UserSettings.shared.gravity.contentsGravity
        self.previewLayer?.videoGravity = UserSettings.shared.gravity.videoGravity
        self.previewLayer?.connection?.automaticallyAdjustsVideoMirroring = false
        
        if let image = NSImage(named: "content_dark_eng"), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            playerBackgroundImage.contents = cgImage
            playerBackgroundImage.contentsGravity = UserSettings.shared.gravity.contentsGravity
            self.playerBackgroundImage.zPosition = -2
            // Ensure background color is red when using an image (fallback overlay)
            self.playerBackgroundImage.backgroundColor = NSColor.gray.cgColor
        }
        self.previewLayer?.addSublayer(self.playerBackgroundImage)

        // Set preview layer background to red (replace default black)
        self.previewLayer?.backgroundColor = NSColor.gray.cgColor

        layer = self.previewLayer

        logger.log(content: "Setup layer completed")
        
    }
    
    func observe() {
        let playViewNtf = NotificationCenter.default
        
        // Setup notification observers
        playViewNtf.addObserver(self, selector: #selector(handleDidEnterFullScreenNotification(_:)), name: NSWindow.didEnterFullScreenNotification, object: nil)
        playViewNtf.addObserver(self, selector: #selector(promptUserHowToExitRelativeMode(_:)), name: .enableRelativeModeNotification, object: nil)
        playViewNtf.addObserver(self, selector: #selector(handleHIDMouseEscaped(_:)), name: .hidMouseEscapedNotification, object: nil)
        playViewNtf.addObserver(self, selector: #selector(handleGravitySettingsChanged(_:)), name: .gravitySettingsChanged, object: nil)
    }
    
        @objc func promptUserHowToExitRelativeMode(_ notification: Notification) {
        let tips = "Long press or multiple clikc「ESC」to exit relative mode"
        DispatchQueue.main.async {
            self.tipLayerManager.showTip(text: tips, yOffset: 1.5, window: NSApp.mainWindow)
        }
    }
    
    @objc func handleHIDMouseEscaped(_ notification: Notification) {
        let tips = "Mouse capture released. Click on the video to re-capture."
        DispatchQueue.main.async {
            self.tipLayerManager.showTip(text: tips, yOffset: 1.5, window: NSApp.mainWindow)
        }
    }
    
    @objc func handleGravitySettingsChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            self.setupLayer()
            self.logger.log(content: "Updated gravity settings: \(UserSettings.shared.gravity.rawValue)")
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
        // Check if we need to re-capture HID mouse
        if UserSettings.shared.MouseControl == .relativeHID {
            let mouseManager = MouseManager.shared
            if !mouseManager.isMouseCaptured {
                // Verify the click is actually within this PlayerView
                let locationInView = self.convert(event.locationInWindow, from: nil)
                let isWithinView = self.bounds.contains(locationInView)
                
                logger.log(content: "MouseDown in PlayerView: location=\(locationInView), bounds=\(self.bounds), withinView=\(isWithinView)")
                
                if isWithinView {
                    // Re-capture the mouse when clicking on the player view
                    logger.log(content: "Click within PlayerView bounds - re-capturing mouse")
                    mouseManager.recaptureHIDMouse()
                    return // Don't send the click event when re-capturing
                } else {
                    logger.log(content: "Click outside PlayerView bounds - not re-capturing")
                    return // Don't process clicks outside the view
                }
            }
        }
        
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

        handleMouseMovement(with: event, mouseEvent: 0x00)
        
        // Update tracking variables
        lastMouseEventTimestamp = currentTime
        lastMousePosition = currentPosition
        if UserSettings.shared.MouseControl != .relativeHID {
            inputMonitorManager.recordMouseMove()
        }

        // If parallel overlay indicator is active, post normalized mouse position
        if AppStatus.showParallelOverlay {
            // Compute normalized coordinates relative to the actual video display area
            let videoManager = DependencyContainer.shared.resolve(VideoManagerProtocol.self)
            let videoDimensions = videoManager.dimensions
            let videoWidth = CGFloat(videoDimensions.width)
            let videoHeight = CGFloat(videoDimensions.height)

            let playerSize = self.bounds.size

            var actualVideoDisplaySize: CGSize
            var videoOffsetInPlayer: CGPoint

            if videoWidth <= 0 || videoHeight <= 0 || playerSize.width <= 0 || playerSize.height <= 0 {
                // If missing info, fallback to full view
                actualVideoDisplaySize = playerSize
                videoOffsetInPlayer = CGPoint(x: 0, y: 0)
            } else {
                let videoAspectRatio = videoWidth / videoHeight
                let playerAspectRatio = playerSize.width / playerSize.height

                if abs(videoAspectRatio - playerAspectRatio) < 0.01 {
                    actualVideoDisplaySize = playerSize
                    videoOffsetInPlayer = CGPoint(x: 0, y: 0)
                } else if videoAspectRatio > playerAspectRatio {
                    actualVideoDisplaySize = CGSize(width: playerSize.width, height: playerSize.width / videoAspectRatio)
                    videoOffsetInPlayer = CGPoint(x: 0, y: (playerSize.height - actualVideoDisplaySize.height) / 2)
                } else {
                    actualVideoDisplaySize = CGSize(width: playerSize.height * videoAspectRatio, height: playerSize.height)
                    videoOffsetInPlayer = CGPoint(x: (playerSize.width - actualVideoDisplaySize.width) / 2, y: 0)
                }
            }

            // Convert mouse location into playerView coordinates
            let mouseLocation = convert(event.locationInWindow, from: nil)
            let adjustedX = mouseLocation.x - videoOffsetInPlayer.x
            let adjustedY = mouseLocation.y - videoOffsetInPlayer.y

            // Clamp and normalize
            let clampedX = max(0, min(adjustedX, actualVideoDisplaySize.width))
            let clampedY = max(0, min(adjustedY, actualVideoDisplaySize.height))

            let normX = actualVideoDisplaySize.width > 0 ? Double(clampedX / actualVideoDisplaySize.width) : 0.0
            let normY = actualVideoDisplaySize.height > 0 ? Double(clampedY / actualVideoDisplaySize.height) : 0.0

            // Convert to top-left origin for SwiftUI overlay (y = 0 at top)
            let topOriginY = 1.0 - normY

            NotificationCenter.default.post(name: .remoteMouseMoved, object: nil, userInfo: ["x": normX, "y": topOriginY])
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
        if !AppStatus.isControlChipsetReady {
            return
        }
        
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
                
                // Enqueue the mouse event instead of processing directly
                MouseManager.shared.enqueueAbsoluteMouseEvent(
                    x: Int(mouseX),
                    y: Int(mouseY),
                    mouseEvent: mouseEvent,
                    wheelMovement: wheelMovement
                )
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
    static let hidMouseEscapedNotification = Notification.Name("hidMouseEscapedNotification")
}


