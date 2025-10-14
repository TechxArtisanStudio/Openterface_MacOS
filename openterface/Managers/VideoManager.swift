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

/// Manager for handling video capture and device management
class VideoManager: NSObject, ObservableObject, VideoManagerProtocol {
    private lazy var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private lazy var hidManager: HIDManagerProtocol = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
    private lazy var audioManager: AudioManagerProtocol = DependencyContainer.shared.resolve(AudioManagerProtocol.self)
    private var usbDevicesManager: USBDevicesManagerProtocol? {
        if #available(macOS 12.0, *) {
            return DependencyContainer.shared.resolve(USBDevicesManagerProtocol.self)
        }
        return nil
    }
    
    // MARK: - Published Properties
    
    
    /// Indicates if camera permission is granted
    @Published var isVideoGranted: Bool = false
    
    /// Current video dimensions
    @Published var dimensions = CMVideoDimensions()
    
    /// Indicates if video is currently connected
    @Published var isVideoConnected: Bool = false
    
    // MARK: - Properties
    
    /// Singleton instance
    static let shared = VideoManager()
    
    /// Session for capturing video
    var captureSession: AVCaptureSession!
    
    /// Set of cancellables for managing publishers
    private var cancellables = Set<AnyCancellable>()
    
    /// Audio property listener ID for observing audio device changes
    private var audioPropertyListenerID: AudioObjectPropertyListenerBlock?
    
    /// Flag to prevent adding observers multiple times
    var hasObserverBeenAdded = false
    
    /// Flag to prevent multiple simultaneous starts of video session
    private var isVideoSessionStarting = false
    
    /// Last video session start time
    private var lastVideoSessionStartTime = Date(timeIntervalSince1970: 0)
    
    /// Minimum interval for video session start (1 second)
    private let videoSessionStartMinInterval: TimeInterval = 1.0
    
    /// Delegate for handling video output
    private var videoOutputDelegate: VideoOutputDelegate?
    
    /// Public access to video output delegate for OCR processing
    var outputDelegate: VideoOutputDelegate? {
        return videoOutputDelegate
    }
    
    // MARK: - Initialization
    
    override init() {
        captureSession = AVCaptureSession()
        super.init()
        
        self.setupBindings()
        setupSession()
        
        if AppStatus.isFristRun == false {
            // Add device notification observers
            self.observeDeviceNotifications()
            AppStatus.isFristRun = true
        }
    }
    
    deinit {
        cleanupObservers()
    }
    
    // MARK: - Setup Methods
    
    /// Sets up the capture session with outputs
    func setupSession() {
        let videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true

        self.videoOutputDelegate = VideoOutputDelegate()
        videoDataOutput.setSampleBufferDelegate(videoOutputDelegate, queue: DispatchQueue(label: "VideoOutputQueue"))

        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
        }
    }
    
    /// Configures data bindings between published properties and actions
    func setupBindings() {
        // When video permission changes, update video session
        $isVideoGranted
            .sink { [weak self] isVideoGranted in
                if isVideoGranted {
                    self?.prepareVideoWithHAL()
                } else {
                    self?.stopVideoSession()
                }
            }
            .store(in: &cancellables)
    }
    
    /// Sets up notification observers for device connections
    func observeDeviceNotifications() {
        let notificationCenter = NotificationCenter.default
        
        guard !hasObserverBeenAdded else { return }
        
        // Video device connection events
        notificationCenter.addObserver(self, selector: #selector(videoWasConnected), 
                                     name: .AVCaptureDeviceWasConnected, object: nil)
        notificationCenter.addObserver(self, selector: #selector(videoWasDisconnected), 
                                     name: .AVCaptureDeviceWasDisconnected, object: nil)
        
        // Firmware update video session control events
        notificationCenter.addObserver(self, selector: #selector(handleStopVideoSession(_:)), 
                                     name: NSNotification.Name("StopVideoSession"), object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleStartVideoSession(_:)), 
                                     name: NSNotification.Name("StartVideoSession"), object: nil)
        
        self.hasObserverBeenAdded = true
        
        // Setup audio device change monitoring
        setupAudioDeviceChangeListener()
    }
    
    /// Sets up a listener for audio device changes
    private func setupAudioDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // IMPORTANT: This audio device listener affects video hot-plugging functionality.
        // Do not remove this code as it indirectly helps with video device reconnection.
        self.audioPropertyListenerID = { (numberAddresses, addresses) in
            // Check for the presence of our audio device
            // This call seems to trigger system device refresh which helps with video reconnection
            let audioDevice = self.audioManager.getAudioDeviceByNames(names: ["OpenterfaceA", "USB2 Digital Audio"])
            
            // Log the detection for debugging purposes
            self.logger.log(content: "Audio device change detected: OpenterfaceA or USB2 Digital Audio \(audioDevice != nil ? "connected" : "not found")")
            
            // When audio device changes are detected, check if we need to refresh video
            if AppStatus.isHDMIConnected == false {
                // If video is disconnected, try to prepare video again
                // This helps with automatic reconnection
                DispatchQueue.main.async {
                    self.prepareVideo()
                }
            }
        }
        
        // Register the audio property listener with the system
        let result = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            nil,
            self.audioPropertyListenerID!
        )

        if result != kAudioHardwareNoError {
            logger.log(content: "Error adding audio property listener: \(result)")
        } else {
            logger.log(content: "Audio device change listener registered successfully")
        }
    }
    
    /// Removes all observers and listeners
    private func cleanupObservers() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.removeObserver(self, name: .AVCaptureDeviceWasConnected, object: nil)
        notificationCenter.removeObserver(self, name: .AVCaptureDeviceWasDisconnected, object: nil)
        notificationCenter.removeObserver(self, name: NSNotification.Name("StopVideoSession"), object: nil)
        notificationCenter.removeObserver(self, name: NSNotification.Name("StartVideoSession"), object: nil)
        
        // Remove audio property listener
        if let listenerID = audioPropertyListenerID {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                nil,
                listenerID
            )
            audioPropertyListenerID = nil
        }
    }
    
    // MARK: - Authorization
    
    /// Checks and requests camera permissions
    func checkAuthorization() {
        checkVideoAuthorization()
    }
    
    /// Checks video capture authorization
    private func checkVideoAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.isVideoGranted = true
                
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    if granted {
                        DispatchQueue.main.async {
                            self?.isVideoGranted = granted
                        }
                    }
                }
                
            case .denied:
                alertToEncourageAccessInitially(for: "Camera")
                self.isVideoGranted = false
                return
                
            case .restricted:
                self.isVideoGranted = false
                return
                
            @unknown default:
                fatalError("Unknown authorization status for video capture")
        }
    }
    
    /// Shows an alert encouraging the user to enable camera access
    func alertToEncourageAccessInitially(for device: String) {
        let alert = NSAlert()
        alert.messageText = "\(device) Access Required"
        alert.informativeText = "⚠️ This application does not have permission to access your \(device.lowercased()).\n\nYou can enable it in \"System Preferences\" -> \"Privacy\" -> \"\(device)\"."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.runModal()
    }
    
    // MARK: - Video Handling
    
    /// Prepares and starts video capture
    func prepareVideo() {
        // Reduce debounce interval to avoid missing valid start requests
        let now = Date()
        if now.timeIntervalSince(lastVideoSessionStartTime) < 0.3 { // Reduced from 1 second to 0.3 seconds
            logger.log(content: "Video preparation ignored - too frequent")
            return
        }
        
        // If video session is already running, return directly, but don't check isVideoSessionStarting
        // This allows new start requests to potentially override a stuck startup process
        if captureSession.isRunning {
            logger.log(content: "Video already running, skipping preparation")
            return
        }
        
        // Update last start time
        lastVideoSessionStartTime = now
        
        // Mark as starting
        isVideoSessionStarting = true
        
        logger.log(content: "Preparing video capture...")
        
        // Update USB devices - execute the entire process on the main thread to avoid thread synchronization issues
        updateUSBDevices()
        
        // Configure capture session quality
        captureSession.sessionPreset = .high
        
        // Get available video devices
        let videoDeviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .externalUnknown
        ]
        
        let videoDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: videoDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
                                                             
        // Find matching video devices
        let videoDevices = findMatchingVideoDevices(from: videoDiscoverySession.devices)

        // If devices found, set up video capture
        if !videoDevices.isEmpty {
            setupVideoCapture(with: videoDevices[0])
        } else {
            logger.log(content: "No matching video devices found")
            isVideoSessionStarting = false
        }
    }
    
    /// Updates USB device manager if available on macOS 12.0+
    private func updateUSBDevices() {
        if #available(macOS 12.0, *) {
            usbDevicesManager?.update()
        } else {
            logger.log(content: "Warning: USB device management requires macOS 12.0 or later. Current device status cannot be updated.")
        }
    }
    
    /// Finds video devices that match the default video device
    private func findMatchingVideoDevices(from devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var matchingDevices = [AVCaptureDevice]()
        
        for device in devices {
            if let defaultDevice = AppStatus.DefaultVideoDevice {
                if matchesLocalID(device.uniqueID, defaultDevice.locationID) {
                    matchingDevices.append(device)
                    AppStatus.isMatchVideoDevice = true
                }
            }
        }
        
        return matchingDevices
    }
    
    /// Sets up video capture with the specified device
    private func setupVideoCapture(with device: AVCaptureDevice) {
        // Check session status again
        if captureSession.isRunning {
            logger.log(content: "Video session already running, skipping setup")
            isVideoSessionStarting = false
            return
        }
        
        // Prevent device from being empty or invalid
        guard device.hasMediaType(.video) else {
            logger.log(content: "Invalid video device provided")
            isVideoSessionStarting = false
            return
        }
        
        do {
            // Use beginConfiguration and commitConfiguration to ensure atomic operations
            captureSession.beginConfiguration()
            
            // Clear existing inputs to prevent duplicate additions
            let existingInputs = captureSession.inputs.filter { $0 is AVCaptureDeviceInput }
            existingInputs.forEach { captureSession.removeInput($0) }
            
            // Create and add new device input
            let input = try AVCaptureDeviceInput(device: device)
            
            guard captureSession.canAddInput(input) else {
                logger.log(content: "Cannot add input to capture session")
                captureSession.commitConfiguration()
                isVideoSessionStarting = false
                return
            }
            
            captureSession.addInput(input)
            
            // Commit configuration changes
            captureSession.commitConfiguration()
            
            // Get camera video resolution
            if let formatDescription = device.activeFormat.formatDescription as CMFormatDescription? {
                dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
                AppStatus.videoDimensions.width = CGFloat(dimensions.width)
                AppStatus.videoDimensions.height = CGFloat(dimensions.height)
            }
 
            // Start video session
            logger.log(content: "Video device setup successful, starting session...")
            startVideoSession()
            AppStatus.isHDMIConnected = true
            DispatchQueue.main.async {
                self.isVideoConnected = true
            }
        } catch {
            logger.log(content: "Failed to set up video capture: \(error.localizedDescription)")
            // Reset start flag when error occurs
            isVideoSessionStarting = false
        }
        
        // print("Supported pixel format--------")
        // for format in device.formats {
        //     let description = format.formatDescription
        //     let pixelFormat = CMFormatDescriptionGetMediaSubType(description)
        //     print("Supported pixel format: \(pixelFormat)")
        // }
    }
    
    /// Starts video capture session
    func startVideoSession() {
        // Status check: if session is already running, return directly
        if captureSession.isRunning {
            logger.log(content: "Video session already running, skipping start...")
            isVideoSessionStarting = false
            return
        }
        
        logger.log(content: "Starting video session...")
        
        // Delay capture session start by 1 second to avoid crash
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            
            // Start session directly in current thread, avoiding extra asynchronous operations
            self.captureSession.startRunning()
            
            // Log record
            self.logger.log(content: "Video session started successfully")
            
            // Reset start flag
            self.isVideoSessionStarting = false
        }
    }

    /// Stops video capture session
    func stopVideoSession() {
        guard captureSession.isRunning else { return }
        captureSession.stopRunning()
        AppStatus.isHDMIConnected = false
        DispatchQueue.main.async {
            self.isVideoConnected = false
        }
    }
    
    /// Adds an input to the capture session if possible
    func addInput(_ input: AVCaptureInput) {
        // Ensure checking if session is running before adding input, if running it needs to be stopped
        let wasRunning = captureSession.isRunning
        if wasRunning {
            captureSession.stopRunning()
        }
        
        // Use beginConfiguration and commitConfiguration to ensure atomic operations
        captureSession.beginConfiguration()
        
        // Check if input can be added
        guard captureSession.canAddInput(input) else {
            logger.log(content: "Cannot add input to capture session")
            captureSession.commitConfiguration()
            
            // If it was running before, restore running state
            if wasRunning {
                captureSession.startRunning()
            }
            return
        }
        
        // Add input and commit configuration
        captureSession.addInput(input)
        captureSession.commitConfiguration()
        
        // If it was running before, restore running state
        if wasRunning {
            captureSession.startRunning()
        }
        
        logger.log(content: "Input added successfully to capture session")
    }
    
    /// Checks if a device unique ID matches a location ID
    func matchesLocalID(_ uniqueID: String, _ locationID: String) -> Bool {
        func hexToInt64(_ hex: String) -> UInt64 {
            return UInt64(hex.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
        }

        let uniqueIDValue = hexToInt64(uniqueID)
        let locationIDValue = hexToInt64(locationID)
        let maskedUniqueID = uniqueIDValue >> 32
        
        return maskedUniqueID == locationIDValue
    }
    
    // MARK: - Notification Handlers
    
    /// Handles when a video device is connected
    @objc func videoWasConnected(notification: NSNotification) {
        if #available(macOS 12.0, *) {
           usbDevicesManager?.update()
        }
        
        if let defaultDevice = AppStatus.DefaultVideoDevice, 
           let device = notification.object as? AVCaptureDevice, 
           matchesLocalID(device.uniqueID, defaultDevice.locationID) {
            
            logger.log(content: "Matching video device connected, preparing video with HAL")
            
            // Add delay to ensure device is fully initialized
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.prepareVideoWithHAL()
                self.hidManager.startHID()
            }
        }
    }
    
    /// Handles when a video device is disconnected
    @objc func videoWasDisconnected(notification: NSNotification) {
        if let defaultDevice = AppStatus.DefaultVideoDevice, 
           let device = notification.object as? AVCaptureDevice, 
           matchesLocalID(device.uniqueID, defaultDevice.locationID) {
            
            logger.log(content: "Matching video device disconnected, stopping session")
            
            // Reset flag to ensure we can restart
            isVideoSessionStarting = false
            
            // Ensure UI-related operations are executed on the main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.stopVideoSession()
                
                // Use beginConfiguration and commitConfiguration to ensure atomic operations
                self.captureSession.beginConfiguration()
                
                // Remove all existing video inputs
                let videoInputs = self.captureSession.inputs.filter { $0 is AVCaptureDeviceInput }
                videoInputs.forEach { self.captureSession.removeInput($0) }
                
                self.captureSession.commitConfiguration()
                
                // Close HID manager
                self.hidManager.closeHID()
                
                self.logger.log(content: "Video session and inputs cleaned up")
            }
        }
            
        if #available(macOS 12.0, *) {
           usbDevicesManager?.update()
        }
    }
    
    // MARK: - Firmware Update Video Session Control
    
    /// Handles notification to stop video session for firmware update
    @objc func handleStopVideoSession(_ notification: Notification) {
        logger.log(content: "Received request to stop video session for firmware update")
        logger.log(content: "Current video session state: isRunning=\(self.captureSession.isRunning), isVideoSessionStarting=\(self.isVideoSessionStarting)")
        DispatchQueue.main.async { [weak self] in
            self?.stopVideoSession()
            self?.logger.log(content: "Video session stopped for firmware update. New state: isRunning=\(self?.captureSession.isRunning ?? false)")
        }
    }
    
    /// Handles notification to start video session after firmware update
    @objc func handleStartVideoSession(_ notification: Notification) {
        logger.log(content: "Received request to restart video session after firmware update")
        logger.log(content: "Current video session state: isRunning=\(self.captureSession.isRunning), isVideoSessionStarting=\(self.isVideoSessionStarting)")
        DispatchQueue.main.async { [weak self] in
            // Add a small delay to ensure firmware update operations are completely finished
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.prepareVideo()
                self?.logger.log(content: "Video session restart initiated after firmware update. New state: isRunning=\(self?.captureSession.isRunning ?? false)")
            }
        }
    }
    
    // MARK: - HAL Integration
    
    /// Get HAL instance for hardware abstraction
    private var hal: HardwareAbstractionLayer {
        return HardwareAbstractionLayer.shared
    }
    
    /// Check if HAL has detected compatible video hardware
    private func isHALVideoHardwareAvailable() -> Bool {
        let systemInfo = hal.getSystemInfo()
        return systemInfo.isVideoActive && systemInfo.videoChipset != nil
    }
    
    /// Get video capabilities from HAL
    private func getHALVideoCapabilities() -> [String] {
        let systemInfo = hal.getSystemInfo()
        return systemInfo.systemCapabilities.features.filter { feature in
            feature.contains("Video") || feature.contains("HDMI") || feature.contains("Capture")
        }
    }
    
    /// Enhanced video preparation with HAL integration
    private func prepareVideoWithHAL() {
        logger.log(content: "🔧 Preparing video with HAL integration...")
        
        // Check if HAL has detected compatible hardware
        if isHALVideoHardwareAvailable() {
            logger.log(content: "✅ HAL-compatible video hardware detected")
            
            // Get capabilities from HAL
            let capabilities = getHALVideoCapabilities()
            logger.log(content: "📋 Video capabilities: \(capabilities.joined(separator: ", "))")
            
            // Use HAL-enhanced video preparation
            prepareVideo()
        } else {
            logger.log(content: "⚠️ No HAL-compatible video hardware detected, using standard preparation")
            prepareVideo()
        }
    }
}
