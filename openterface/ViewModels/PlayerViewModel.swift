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
    
    // MARK: - Properties
    
    /// Video manager for handling video capture
    private let videoManager: any VideoManagerProtocol
    
    /// Set of cancellables for managing publishers
    private var cancellables = Set<AnyCancellable>()
    
    /// Flag to prevent adding observers multiple times
    var hasObserverBeenAdded = false
    
    // MARK: - Initialization
    
    init(videoManager: any VideoManagerProtocol = DependencyContainer.shared.resolve(VideoManagerProtocol.self)) {
        self.videoManager = videoManager
        super.init()
        
        self.setupBindings()
        
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
    
    /// Removes all observers and listeners
    private func cleanupObservers() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: nil)
        notificationCenter.removeObserver(self, name: NSWindow.didResignMainNotification, object: nil)
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
}
