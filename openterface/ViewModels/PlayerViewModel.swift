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
import Combine
import CoreAudio

/// ViewModel for handling UI-related functionality and coordinating with managers
class PlayerViewModel: NSObject, ObservableObject {
    private var  logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    
    // MARK: - Published Properties
    
    /// Indicates if microphone permission is granted
    @Published var isAudioGranted: Bool = false
    
    /// Proxy for video manager's isVideoGranted
    @Published var isVideoGranted: Bool = false
    
    /// Proxy for video manager's dimensions
    @Published var dimensions = CMVideoDimensions()
    
    /// Proxy for video manager's isVideoConnected
    @Published var isVideoConnected: Bool = false
    
    /// Zoom level for the preview layer (1.0 = normal, 2.0 = 2x zoom, etc.)
    @Published var zoomLevel: CGFloat = 1.0
    
    /// The rect of the active video area
    @Published var activeVideoRect: CGRect = .zero
    
    // MARK: - Properties
    
    /// Video manager for handling video capture
    private let videoManager: any VideoManagerProtocol
    
    /// Set of cancellables for managing publishers
    private var cancellables = Set<AnyCancellable>()
    
    /// Flag to prevent adding observers multiple times
    var hasObserverBeenAdded = false
    
    /// Minimum zoom level allowed
    private let minZoomLevel: CGFloat = 1.0
    
    /// Maximum zoom level allowed
    private let maxZoomLevel: CGFloat = 4.0
    
    /// Zoom step increment/decrement
    private let zoomStep: CGFloat = 0.1
    
    // MARK: - Initialization
    
    init(videoManager: any VideoManagerProtocol = DependencyContainer.shared.resolve(VideoManagerProtocol.self)) {
        self.videoManager = videoManager
        super.init()
        
        self.setupBindings()
        
        // Always setup observers, regardless of AppStatus.isFristRun
        self.setupZoomObservers()
        
        if AppStatus.isFristRun == false {
            // Add window event observers
            self.observeWindowNotifications()
            AppStatus.isFristRun = true
        }
    }
    
    deinit {
        cleanupObservers()
    }
    
    // MARK: - Computed Properties
    
    /// Provides access to the video manager's capture session
    var captureSession: AVCaptureSession {
        return videoManager.captureSession
    }
    
    // MARK: - Setup Methods
    
    /// Configures data bindings between published properties and actions
    func setupBindings() {
        // Cast to concrete type to access published properties
        guard let concreteVideoManager = videoManager as? VideoManager else {
            logger.log(content: "Warning: VideoManager is not the expected concrete type")
            return
        }
        
        // Observe video manager's published properties
        concreteVideoManager.$isVideoGranted
            .assign(to: \.isVideoGranted, on: self)
            .store(in: &cancellables)
        
        concreteVideoManager.$dimensions
            .assign(to: \.dimensions, on: self)
            .store(in: &cancellables)
        
        concreteVideoManager.$isVideoConnected
            .assign(to: \.isVideoConnected, on: self)
            .store(in: &cancellables)
    }
    
    /// Sets up notification observers for window events
    func observeWindowNotifications() {
        let notificationCenter = NotificationCenter.default
        
        guard !hasObserverBeenAdded else { return }
        
        // Window focus events
        notificationCenter.addObserver(self, selector: #selector(windowDidBecomeMain(_:)), 
                                     name: NSWindow.didBecomeMainNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(windowdidResignMain(_:)), 
                                     name: NSWindow.didResignMainNotification, object: nil)
        
        self.hasObserverBeenAdded = true
    }
    
    /// Sets up zoom menu observers
    private func setupZoomObservers() {
        let notificationCenter = NotificationCenter.default
        
        // Zoom menu events
        notificationCenter.addObserver(self, selector: #selector(handleMenuZoomIn(_:)), 
                                     name: Notification.Name("MenuZoomInTriggered"), object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleMenuZoomOut(_:)), 
                                     name: Notification.Name("MenuZoomOutTriggered"), object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleMenuZoomReset(_:)), 
                                     name: Notification.Name("MenuZoomResetTriggered"), object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleMenuZoomToHeight(_:)), 
                                     name: Notification.Name("MenuZoomToHeightTriggered"), object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleMenuZoomToWidth(_:)), 
                                     name: Notification.Name("MenuZoomToWidthTriggered"), object: nil)
    }
    
    /// Removes all observers and listeners
    private func cleanupObservers() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: nil)
        notificationCenter.removeObserver(self, name: NSWindow.didResignMainNotification, object: nil)
        notificationCenter.removeObserver(self, name: Notification.Name("MenuZoomInTriggered"), object: nil)
        notificationCenter.removeObserver(self, name: Notification.Name("MenuZoomOutTriggered"), object: nil)
        notificationCenter.removeObserver(self, name: Notification.Name("MenuZoomResetTriggered"), object: nil)
        notificationCenter.removeObserver(self, name: Notification.Name("MenuZoomToHeightTriggered"), object: nil)
        notificationCenter.removeObserver(self, name: Notification.Name("MenuZoomToWidthTriggered"), object: nil)
    }
    
    // MARK: - Authorization
    
    /// Checks and requests camera and microphone permissions
    func checkAuthorization() {
        videoManager.checkAuthorization()
    }
    
    // MARK: - Video Handling (Delegated to VideoManager)
    
    /// Prepares and starts video capture
    func prepareVideo() {
        videoManager.prepareVideo()
    }

    /// Stops video capture session
    func stopVideoSession() {
        videoManager.stopVideoSession()
    }
    
    /// Starts video capture session
    func startVideoSession() {
        videoManager.startVideoSession()
    }
    
    /// Adds an input to the capture session if possible
    func addInput(_ input: AVCaptureInput) {
        videoManager.addInput(input)
    }
    
    /// Checks if a device unique ID matches a location ID
    func matchesLocalID(_ uniqueID: String, _ locationID: String) -> Bool {
        return videoManager.matchesLocalID(uniqueID, locationID)
    }
    
    // MARK: - Zoom Handling
    
    /// Zoom source enumeration to track origin of zoom change
    enum ZoomSource {
        case manual      // User initiated zoom (in/out/reset)
        case menu        // Zoom to width/height from menu
        case autoResize  // Auto-zoom triggered by window resize
    }
    
    /// Zooms in the video preview
    func zoomIn() {
        let newZoomLevel = min(zoomLevel + zoomStep, maxZoomLevel)
        setZoomLevel(newZoomLevel, source: .manual)
        logger.log(content: "Zoom In: \(String(format: "%.2f", newZoomLevel))x")
    }
    
    /// Zooms out the video preview
    func zoomOut() {
        let newZoomLevel = max(zoomLevel - zoomStep, minZoomLevel)
        setZoomLevel(newZoomLevel, source: .manual)
        logger.log(content: "Zoom Out: \(String(format: "%.2f", newZoomLevel))x")
    }
    
    /// Resets zoom to default (1.0x)
    func resetZoom() {
        setZoomLevel(1.0, source: .manual)
        logger.log(content: "Zoom Reset: 1.00x")
    }
    
    /// Internal zoom to height with source parameter
    func zoomToHeight(source: ZoomSource = .menu) {
        let activeRect = AppStatus.activeVideoRect
        guard activeRect.height > 0 else {
            return
        }
        
        let videoSize = AppStatus.videoDimensions

        guard videoSize.height > 0 else {
            return
        }

        // Calculate zoom based on height
        let zoomHeight = videoSize.height / activeRect.height
        let constrainedZoomLevel = min(max(zoomHeight, minZoomLevel), maxZoomLevel)
        
        setZoomLevel(constrainedZoomLevel, source: source)
    }
    
    /// Internal zoom to width with source parameter
    func zoomToWidth(source: ZoomSource = .menu) {
        let activeRect = AppStatus.activeVideoRect

        guard activeRect.width > 0 else {
            return
        }
        
        let videoSize = AppStatus.videoDimensions

        guard videoSize.width > 0 else {
            return
        }

        // Calculate zoom based on width
        let zoomWidth = videoSize.width / activeRect.width
        let constrainedZoomLevel = min(max(zoomWidth, minZoomLevel), maxZoomLevel)

        setZoomLevel(constrainedZoomLevel, source: source)
    }
    
    /// Sets the zoom level to a specific value
    private func setZoomLevel(_ newLevel: CGFloat, source: ZoomSource = .manual) {
        if self.zoomLevel == newLevel && source != ZoomSource.autoResize{
            return
        }
        
        DispatchQueue.main.async {
            self.zoomLevel = newLevel
            
            // Log based on source
            let sourceLabel: String
            switch source {
            case .manual:
                sourceLabel = "Manual"
            case .menu:
                sourceLabel = "Menu"
            case .autoResize:
                sourceLabel = "Auto-Resize"
            }
            self.logger.log(content: "Zoom Level Set To: \(String(format: "%.2f", newLevel))x (\(sourceLabel))") 
            
            // Post notification with zoom source information
            let userInfo: [String: Any] = [
                "zoomLevel": newLevel,
                "source": source
            ]
            NotificationCenter.default.post(name: Notification.Name("PlayerZoomLevelChanged"), object: self, userInfo: userInfo)
        }
    }
    
    // MARK: - Audio Handling (Legacy, kept for compatibility)
    
    /// Finds audio devices that match the default video device
    private func findMatchingAudioDevices() -> [AVCaptureDevice] {
        let audioDeviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInMicrophone,
            .externalUnknown
        ]
        
        let audioDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: audioDeviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        
        var matchingAudioDevices = [AVCaptureDevice]()
        
        for device in audioDiscoverySession.devices {
            if device.uniqueID.contains(AppStatus.DefaultVideoDevice?.locationID ?? "nil"), 
               !matchingAudioDevices.contains(where: { $0.localizedName == device.localizedName }) {
                matchingAudioDevices.append(device)
            }
        }
        
        return matchingAudioDevices
    }
    
    /// Sets up audio capture with the specified device
    private func setupAudioCapture(with device: AVCaptureDevice) {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            self.addInput(input)
        } catch {
            logger.log(content: "Failed to set up audio capture: \(error.localizedDescription)")
        }
    }
    
    /// Creates an audio format compatible with both input and output
    private func createCompatibleAudioFormat(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) -> AVAudioFormat {
        var format = inputFormat
        
        if inputFormat.sampleRate != outputFormat.sampleRate {
            // Create a new format with matching sample rate
            format = AVAudioFormat(
                commonFormat: inputFormat.commonFormat,
                sampleRate: outputFormat.sampleRate,
                channels: inputFormat.channelCount,
                interleaved: inputFormat.isInterleaved) ?? outputFormat
            
            logger.log(content: "Adjusting sample rate from \(inputFormat.sampleRate) to \(outputFormat.sampleRate)")
        }
        
        return format
    }
    
    // MARK: - Window Event Handlers
    
    /// Handles when window becomes main
    @objc func windowDidBecomeMain(_ notification: Notification) {
        if (UserSettings.shared.MouseControl == MouseControlMode.relativeHID || UserSettings.shared.MouseControl == MouseControlMode.relativeEvents) && AppStatus.isExit == false {
            NSCursor.hide()
            AppStatus.isCursorHidden = true
        }
        AppStatus.isFouceWindow = true
    }
    
    /// Handles when window resigns main
    @objc func windowdidResignMain(_ notification: Notification) {
        AppStatus.isFouceWindow = false
        AppStatus.isMouseInView = false
        if let handler = AppStatus.eventHandler {
            logger.log(content: "Removing monitor handler")
            NSEvent.removeMonitor(handler)
            AppStatus.eventHandler = nil
        }
    }
    
    /// Handles fullscreen mode changes
    @objc func handleDidEnterFullScreenNotification(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window.styleMask.contains(.fullScreen) {
                logger.log(content: "The window just entered full screen mode.")
            } else {
                logger.log(content: "The window just exited full screen mode.")
            }
        }
    }
    
    // MARK: - Menu Zoom Handlers
    
    /// Handles zoom in from menu
    @objc func handleMenuZoomIn(_ notification: Notification) {
        zoomIn()
    }
    
    /// Handles zoom out from menu
    @objc func handleMenuZoomOut(_ notification: Notification) {
        zoomOut()
    }
    
    /// Handles zoom reset from menu
    @objc func handleMenuZoomReset(_ notification: Notification) {
        resetZoom()
    }
    
    /// Handles zoom to height from menu or auto-resize
    @objc func handleMenuZoomToHeight(_ notification: Notification) {
        // Check if this is from auto-resize
        let isAutoResize = notification.userInfo?["isAutoResize"] as? Bool ?? false
        let source: ZoomSource = isAutoResize ? .autoResize : .menu
        zoomToHeight(source: source)
    }
    
    /// Handles zoom to width from menu or auto-resize
    @objc func handleMenuZoomToWidth(_ notification: Notification) {
        // Check if this is from auto-resize
        let isAutoResize = notification.userInfo?["isAutoResize"] as? Bool ?? false
        let source: ZoomSource = isAutoResize ? .autoResize : .menu
        zoomToWidth(source: source)
    }
}
