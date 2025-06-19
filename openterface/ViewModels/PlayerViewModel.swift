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

/// ViewModel for handling audio and video capture and playback
class PlayerViewModel: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    
    /// Indicates if camera permission is granted
    @Published var isVideoGranted: Bool = false
    
    /// Indicates if microphone permission is granted
    @Published var isAudioGranted: Bool = false
    
    /// Current video dimensions
    @Published var dimensions = CMVideoDimensions()
    
    // MARK: - Properties
    
    /// Session for capturing video and audio
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
    
    // MARK: - Initialization
    
    override init() {
        captureSession = AVCaptureSession()
        // engine = AVAudioEngine()
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
                    self?.prepareVideo()
                } else {
                    self?.stopVideoSession()
                }
            }
            .store(in: &cancellables)
        
    }
    
    /// Sets up notification observers for device connections and window events
    func observeDeviceNotifications() {
        let notificationCenter = NotificationCenter.default
        
        guard !hasObserverBeenAdded else { return }
        
        // Video device connection events
        notificationCenter.addObserver(self, selector: #selector(videoWasConnected), 
                                     name: .AVCaptureDeviceWasConnected, object: nil)
        notificationCenter.addObserver(self, selector: #selector(videoWasDisconnected), 
                                     name: .AVCaptureDeviceWasDisconnected, object: nil)
        
        // Window focus events
        notificationCenter.addObserver(self, selector: #selector(windowDidBecomeMain(_:)), 
                                     name: NSWindow.didBecomeMainNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(windowdidResignMain(_:)), 
                                     name: NSWindow.didResignMainNotification, object: nil)
        
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
            let audioDevice = self.getAudioDeviceByName(name: "OpenterfaceA")
            
            // Log the detection for debugging purposes
            Logger.shared.log(content: "Audio device change detected: OpenterfaceA \(audioDevice != nil ? "connected" : "not found")")
            
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
            Logger.shared.log(content: "Error adding audio property listener: \(result)")
        } else {
            Logger.shared.log(content: "Audio device change listener registered successfully")
        }
    }
    
    /// Removes all observers and listeners
    private func cleanupObservers() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.removeObserver(self, name: .AVCaptureDeviceWasConnected, object: nil)
        notificationCenter.removeObserver(self, name: .AVCaptureDeviceWasDisconnected, object: nil)
        notificationCenter.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: nil)
        notificationCenter.removeObserver(self, name: NSWindow.didResignMainNotification, object: nil)
        
//        // Stop audio engine
//        stopAudioSession()
        
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
    
    /// Checks and requests camera and microphone permissions
    func checkAuthorization() {
        checkVideoAuthorization()
//        checkAudioAuthorization()
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
    
    /// Shows an alert encouraging the user to enable camera or microphone access
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
            Logger.shared.log(content: "Video preparation ignored - too frequent")
            return
        }
        
        // If video session is already running, return directly, but don't check isVideoSessionStarting
        // This allows new start requests to potentially override a stuck startup process
        if captureSession.isRunning {
            Logger.shared.log(content: "Video already running, skipping preparation")
            return
        }
        
        // Update last start time
        lastVideoSessionStartTime = now
        
        // Mark as starting
        isVideoSessionStarting = true
        
        Logger.shared.log(content: "Preparing video capture...")
        
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
            Logger.shared.log(content: "No matching video devices found")
            isVideoSessionStarting = false
        }
    }
    
    /// Updates USB device manager if available on macOS 12.0+
    private func updateUSBDevices() {
        if #available(macOS 12.0, *) {
            USBDeivcesManager.shared.update()
        } else {
            Logger.shared.log(content: "Warning: USB device management requires macOS 12.0 or later. Current device status cannot be updated.")
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
            Logger.shared.log(content: "Video session already running, skipping setup")
            isVideoSessionStarting = false
            return
        }
        
        // Prevent device from being empty or invalid
        guard device.hasMediaType(.video) else {
            Logger.shared.log(content: "Invalid video device provided")
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
                Logger.shared.log(content: "Cannot add input to capture session")
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
            Logger.shared.log(content: "Video device setup successful, starting session...")
            startVideoSession()
            AppStatus.isHDMIConnected = true
        } catch {
            Logger.shared.log(content: "Failed to set up video capture: \(error.localizedDescription)")
            // Reset start flag when error occurs
            isVideoSessionStarting = false
        }
        
        print("Supported pixel format--------")
        for format in device.formats {
            let description = format.formatDescription
            let pixelFormat = CMFormatDescriptionGetMediaSubType(description)
            print("Supported pixel format: \(pixelFormat)")
        }
    }
    
    /// Starts video capture session
    func startVideoSession() {
        // Status check: if session is already running, return directly
        if captureSession.isRunning {
            Logger.shared.log(content: "Video session already running, skipping start...")
            isVideoSessionStarting = false
            return
        }
        
        Logger.shared.log(content: "Starting video session...")
        
        // Start session directly in current thread, avoiding extra asynchronous operations
        captureSession.startRunning()
        
        // Log record
        Logger.shared.log(content: "Video session started successfully")
        
        // Reset start flag
        isVideoSessionStarting = false
    }

    /// Stops video capture session
    func stopVideoSession() {
        guard captureSession.isRunning else { return }
        captureSession.stopRunning()
        AppStatus.isHDMIConnected = false
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
            Logger.shared.log(content: "Cannot add input to capture session")
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
        
        Logger.shared.log(content: "Input added successfully to capture session")
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
            Logger.shared.log(content: "Failed to set up audio capture: \(error.localizedDescription)")
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
            
            Logger.shared.log(content: "Adjusting sample rate from \(inputFormat.sampleRate) to \(outputFormat.sampleRate)")
        }
        
        return format
    }
    
    /// Gets an audio device by its name
    func getAudioDeviceByName(name: String) -> AudioDeviceID? {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Get the size of the property data
        var result = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), 
            &address, 
            0, 
            nil, 
            &propSize
        )
        
        guard result == noErr else {
            Logger.shared.log(content: "Error \(result) in AudioObjectGetPropertyDataSize")
            return nil
        }

        // Calculate device count and prepare array
        let deviceCount = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array<AudioDeviceID>(repeating: 0, count: deviceCount)

        // Get the device IDs
        result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), 
            &address, 
            0, 
            nil, 
            &propSize, 
            &deviceIDs
        )
        
        guard result == noErr else {
            Logger.shared.log(content: "Error \(result) in AudioObjectGetPropertyData")
            return nil
        }

        // Search for device with matching name
        for deviceID in deviceIDs {
            let deviceName = getAudioDeviceName(for: deviceID)
            
            if deviceName == name {
                return deviceID
            }
        }

        return nil
    }
    
    /// Gets the name of an audio device
    private func getAudioDeviceName(for deviceID: AudioDeviceID) -> String? {
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Get the size of the name property
        let result = AudioObjectGetPropertyDataSize(
            deviceID, 
            &nameAddress, 
            0, 
            nil, 
            &nameSize
        )
        
        guard result == noErr else {
            Logger.shared.log(content: "Error \(result) getting audio device name size")
            return nil
        }

        // Get the device name
        var deviceName: Unmanaged<CFString>?
        let nameResult = AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0,
            nil,
            &nameSize,
            &deviceName
        )
        
        guard nameResult == noErr else {
            Logger.shared.log(content: "Error \(nameResult) getting audio device name")
            return nil
        }
        
        return deviceName?.takeRetainedValue() as String?
    }
    
    // MARK: - Notification Handlers
    
    /// Handles when a video device is connected
    @objc func videoWasConnected(notification: NSNotification) {
        if #available(macOS 12.0, *) {
           USBDeivcesManager.shared.update()
        }
        
        if let defaultDevice = AppStatus.DefaultVideoDevice, 
           let device = notification.object as? AVCaptureDevice, 
           matchesLocalID(device.uniqueID, defaultDevice.locationID) {
            
            Logger.shared.log(content: "Matching video device connected, preparing video")
            
            // Add delay to ensure device is fully initialized
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                let hidManager = HIDManager.shared
                self?.prepareVideo()
                hidManager.startHID()
            }
        }
    }
    
    /// Handles when a video device is disconnected
    @objc func videoWasDisconnected(notification: NSNotification) {
        if let defaultDevice = AppStatus.DefaultVideoDevice, 
           let device = notification.object as? AVCaptureDevice, 
           matchesLocalID(device.uniqueID, defaultDevice.locationID) {
            
            Logger.shared.log(content: "Matching video device disconnected, stopping session")
            
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
                let hidManager = HIDManager.shared
                hidManager.closeHID()
                
                Logger.shared.log(content: "Video session and inputs cleaned up")
            }
        }
            
        if #available(macOS 12.0, *) {
           USBDeivcesManager.shared.update()
        }
    }
    
    /// Handles when window becomes main
    @objc func windowDidBecomeMain(_ notification: Notification) {
        if UserSettings.shared.MouseControl == MouseControlMode.relative && AppStatus.isExit == false {
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
            Logger.shared.log(content: "Removing monitor handler")
            NSEvent.removeMonitor(handler)
            AppStatus.eventHandler = nil
        }
    }
    
    /// Handles fullscreen mode changes
    @objc func handleDidEnterFullScreenNotification(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window.styleMask.contains(.fullScreen) {
                Logger.shared.log(content: "The window just entered full screen mode.")
            } else {
                Logger.shared.log(content: "The window just exited full screen mode.")
            }
        }
    }
}
