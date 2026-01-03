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
    
    /// Desired video resolution (optional)
    var desiredResolution: CMVideoDimensions?
    
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
        // Listen for first-frame resolution analysis from VideoOutputDelegate
        NotificationCenter.default.addObserver(self, selector: #selector(handleFrameResolution(_:)),
                name: Notification.Name("checkActiveResolution"), object: nil)
        
        if AppStatus.isFristRun == false {
            // Add device notification observers
            self.observeDeviceNotifications()
            AppStatus.isFristRun = true
        }

        // Restore persisted active video rect from user settings if present
        let savedRect = UserSettings.shared.activeVideoRect
        if savedRect.width > 0 && savedRect.height > 0 {
            AppStatus.activeVideoRect = savedRect
            logger.log(content: "Restored active video rect from user settings: \(savedRect)")
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
        notificationCenter.removeObserver(self, name: Notification.Name("checkActiveResolution"), object: nil)
        
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
            let device = videoDevices[0]
            
            // Set to 1920x1080 resolution with highest FPS
            setVideoResolution(width: 1920, height: 1080)
            logger.log(content: "Setting video to 1920x1080 resolution with highest FPS")
            
            setupVideoCapture(with: device)
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
            
            // Set desired resolution if specified
            if let desiredRes = desiredResolution {
                do {
                    try device.lockForConfiguration()
                    
                    // List all supported formats before matching
                    logger.log(content: "Listing all supported video formats for device: \(device.localizedName)")
                    for (index, format) in device.formats.enumerated() {
                        let formatDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                        let formatDescription = pixelFormatDescription(pixelFormat)
                        logger.log(content: "Format \(index): \(formatDimensions.width)x\(formatDimensions.height) - \(formatDescription)")
                    }
                    
                    // Print supported resolutions with frame rates
                    logger.log(content: "Supported video resolutions and frame rates:")
                    for (index, format) in device.formats.enumerated() {
                        let formatDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                        let formatDescription = pixelFormatDescription(pixelFormat)
                        
                        // Get frame rate ranges for this format
                        var frameRateInfo = "N/A"
                        if let frameRateRanges = format.videoSupportedFrameRateRanges as? [AVFrameRateRange] {
                            let frameRates = frameRateRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)fps" }.joined(separator: ", ")
                            frameRateInfo = frameRates
                        }
                        
                        logger.log(content: "Format \(index): \(formatDimensions.width)x\(formatDimensions.height) @ \(frameRateInfo) - \(formatDescription)")
                    }
                    
                    // Find the best matching format for the desired resolution
                    if let matchingFormat = device.formats.first(where: { format in
                        let formatDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        return formatDimensions.width == desiredRes.width && formatDimensions.height == desiredRes.height
                    }) {
                        device.activeFormat = matchingFormat
                        let pixelFormat = CMFormatDescriptionGetMediaSubType(matchingFormat.formatDescription)
                        let formatDescription = pixelFormatDescription(pixelFormat)
                        logger.log(content: "Set video resolution to \(desiredRes.width)x\(desiredRes.height) using format: \(formatDescription)")
                        
                        // Set to 144fps for 1920x1080 if available
                        if let frameRateRanges = matchingFormat.videoSupportedFrameRateRanges as? [AVFrameRateRange] {
                            logger.log(content: "Available frame rate ranges for 1920x1080: \(frameRateRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)fps" }.joined(separator: ", "))")
                            
                            // First try to find 144fps specifically
                            if let fps144Range = frameRateRanges.first(where: { abs($0.maxFrameRate - 144.0) < 1.0 }) {
                                device.activeVideoMinFrameDuration = fps144Range.minFrameDuration
                                device.activeVideoMaxFrameDuration = fps144Range.maxFrameDuration
                                logger.log(content: "Successfully set frame rate to 144fps for 1920x1080")
                            } else {
                                // Fall back to highest available frame rate
                                let bestFrameRateRange = frameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })!
                                device.activeVideoMinFrameDuration = bestFrameRateRange.minFrameDuration
                                device.activeVideoMaxFrameDuration = bestFrameRateRange.maxFrameDuration
                                logger.log(content: "144fps not found, using highest available frame rate \(bestFrameRateRange.maxFrameRate)fps for 1920x1080")
                            }
                        }
                        
                        // Update video data output to capture at the full resolution
                        if let videoOutput = captureSession.outputs.first(where: { $0 is AVCaptureVideoDataOutput }) as? AVCaptureVideoDataOutput {
                            // Configure output to capture at the device's active resolution
                            videoOutput.videoSettings = [
                                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                kCVPixelBufferWidthKey as String: desiredRes.width,
                                kCVPixelBufferHeightKey as String: desiredRes.height
                            ]
                            logger.log(content: "Updated video output to capture at \(desiredRes.width)x\(desiredRes.height)")
                        }
                    } else {
                        logger.log(content: "Desired resolution \(desiredRes.width)x\(desiredRes.height) not supported, using default")
                    }
                    
                    device.unlockForConfiguration()
                } catch {
                    logger.log(content: "Failed to configure device resolution: \(error.localizedDescription)")
                }
            }
            
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
        
        print("Supported pixel format--------")
        for format in device.formats {
            let description = format.formatDescription
            let pixelFormat = CMFormatDescriptionGetMediaSubType(description)
            let formatDescription = pixelFormatDescription(pixelFormat)
            print("Supported pixel format: \(formatDescription)")
        }
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
    
    /// Converts a pixel format FourCC code to a human-readable name
    private func pixelFormatDescription(_ pixelFormat: FourCharCode) -> String {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return "NV12 (YUV 4:2:0, Video Range)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "NV12 (YUV 4:2:0, Full Range)"
        case kCVPixelFormatType_422YpCbCr8:
            return "UYVY (YUV 4:2:2)"
        case kCVPixelFormatType_32BGRA:
            return "BGRA (32-bit)"
        case kCVPixelFormatType_32ARGB:
            return "ARGB (32-bit)"
        case kCVPixelFormatType_24RGB:
            return "RGB (24-bit)"
        case kCVPixelFormatType_24BGR:
            return "BGR (24-bit)"
        case kCVPixelFormatType_420YpCbCr8Planar:
            return "I420 (YUV 4:2:0 Planar)"
        case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            return "I420 (YUV 4:2:0 Planar, Full Range)"
        default:
            // Convert FourCC to string safely
            let chars: [CChar] = [
                CChar(pixelFormat >> 24 & 0xFF),
                CChar(pixelFormat >> 16 & 0xFF),
                CChar(pixelFormat >> 8 & 0xFF),
                CChar(pixelFormat & 0xFF),
                0 // Null terminator
            ]
            let fourCCString = String(cString: chars)
            return "Unknown (\(fourCCString), \(pixelFormat))"
        }
    }
    
    /// Sets the desired video resolution
    func setVideoResolution(width: Int32, height: Int32) {
        desiredResolution = CMVideoDimensions(width: width, height: height)
        logger.log(content: "Desired video resolution set to \(width)x\(height)")
        
        // If video is currently running, restart with new resolution
        if captureSession.isRunning {
            logger.log(content: "Restarting video session with new resolution")
            stopVideoSession()
            prepareVideo()
        }
    }
    
    // MARK: - Notification Handlers
    
    /// Handles when a video device is connected
    @objc func videoWasConnected(notification: NSNotification) {
        usbDevicesManager?.update()
        
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

    /// Handle first-frame resolution notification and update dimensions
    @objc private func handleFrameResolution(_ notification: Notification) {
        guard let info = notification.userInfo as? [String: Any],
              let width = info["activeWidth"] as? Int,
              let height = info["activeHeight"] as? Int else { return }

        // Use the actual frame dimensions for the capture resolution
        dimensions = CMVideoDimensions(width: Int32(width), height: Int32(height))     
        logger.log(content: "First frame resolution received: \(width)x\(height) - dimensions updated")

        // Auto-match aspect ratio from first frame and update user settings
//        let videoAspectRatio = CGFloat(width) / max(1.0, CGFloat(height))
        let activeAspectRatio = CGFloat(width) / max(1.0, CGFloat(height))
        let tolerance: CGFloat = 0.02 // 2% tolerance
        var matched: AspectRatioOption? = nil
        for option in AspectRatioOption.allCases {
            let r = option.widthToHeightRatio
            if abs(r - activeAspectRatio) / activeAspectRatio <= tolerance {
                matched = option
                break
            }
        }

        // Determine if applying the matched aspect ratio would change current settings
        let previousAspect = UserSettings.shared.customAspectRatio
        let previousUseCustom = UserSettings.shared.useCustomAspectRatio
        let previousGravity = UserSettings.shared.gravity

        if let matched = matched {
            var didChange = false
            if previousUseCustom == false || previousAspect != matched {
                UserSettings.shared.customAspectRatio = matched
                UserSettings.shared.useCustomAspectRatio = true
                didChange = true
            }

            logger.log(content: "Auto-matched aspect ratio: \(matched.rawValue) (aspect=\(String(format: "%.3f", activeAspectRatio)))")

            if didChange {
                NotificationCenter.default.post(name: .gravitySettingsChanged, object: nil)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name.updateWindowSize, object: nil)
                }
            }
        } else {
            // No match: revert to default aspect handling only if it represents a change
            if previousUseCustom == true || previousGravity != .resizeAspect {
                UserSettings.shared.useCustomAspectRatio = false
                UserSettings.shared.gravity = .resizeAspect
                logger.log(content: "No aspect ratio match (aspect=\(String(format: "%.3f", activeAspectRatio))). Reverting to default gravity: resizeAspect")
                NotificationCenter.default.post(name: .gravitySettingsChanged, object: nil)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name.updateWindowSize, object: nil)
                }
            } else {
                logger.log(content: "No aspect ratio match and settings unchanged; no UI update posted")
            }
        }

        // If active rect provided, update AppStatus and log
        if let ax = info["activeX"] as? Int,
           let ay = info["activeY"] as? Int,
           let aw = info["activeWidth"] as? Int,
           let ah = info["activeHeight"] as? Int {
            let rect = CGRect(x: ax, y: ay, width: aw, height: ah)

            AppStatus.activeVideoRect = rect
            
            logger.log(content: "Frame active video area, activeX:\(ax), activeY:\(ay), activeWidth:\(aw), activeHeight:\(ah), aspect ratio: \(String(format: "%.3f", rect.width / rect.height))")

            // Persist to user settings so it's remembered
            UserSettings.shared.activeVideoX = ax
            UserSettings.shared.activeVideoY = ay
            UserSettings.shared.activeVideoWidth = aw
            UserSettings.shared.activeVideoHeight = ah
            
            // Auto zoom to height if aspect ratio is less than 1 (portrait mode)
            if activeAspectRatio < 1.0 {
                logger.log(content: "🎯 Aspect ratio < 1.0 (portrait mode detected), auto-zooming to height")
                NotificationCenter.default.post(name: Notification.Name("MenuZoomToHeightTriggered"), object: nil)
            }
        }
    }
    
    // MARK: - Firmware Update Video Session Control
    
    /// Handles notification to stop video session for firmware updatecalculateConstrainedWindowSize
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
