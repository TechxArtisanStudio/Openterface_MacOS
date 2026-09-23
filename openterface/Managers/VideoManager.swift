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
import Metal

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

    /// Cached list of available video formats from the current device
    @Published private(set) var availableVideoFormats: [VideoFormat] = []

    /// Selected video format from UserSettings (computed for easier access)
    var selectedVideoFormat: VideoFormat {
        get {
            VideoFormat(
                resolution: UserSettings.shared.selectedVideoResolution,
                frameRate: UserSettings.shared.selectedVideoFrameRate,
                pixelFormat: UserSettings.shared.selectedVideoPixelFormat
            )
        }
        set {
            UserSettings.shared.selectedVideoResolution = newValue.resolution
            UserSettings.shared.selectedVideoFrameRate = newValue.frameRate
            UserSettings.shared.selectedVideoPixelFormat = newValue.pixelFormat
        }
    }

    /// Audio property listener ID for observing audio device changes
    private var audioPropertyListenerID: AudioObjectPropertyListenerBlock?
    
    /// Flag to prevent adding observers multiple times
    var hasObserverBeenAdded = false
    
    /// Flag to prevent multiple simultaneous starts of video session
    private var isVideoSessionStarting = false
    
    /// Last video session start time
    private var lastVideoSessionStartTime = Date(timeIntervalSince1970: 0)
    
    /// Last format enumeration time (to prevent rapid re-enumeration)
    private var lastFormatEnumerationTime = Date(timeIntervalSince1970: 0)
    
    /// Minimum interval for video session start (1 second)
    private let videoSessionStartMinInterval: TimeInterval = 1.0
    
    /// Previous activeRect result for stability check
    private var previousActiveRect: CGRect?
    
    /// Current candidate activeRect being validated
    private var candidateActiveRect: CGRect?
    
    /// Number of consecutive frames with same candidate rect
    private var consecutiveFramesSameRect: Int = 0
    
    /// Minimum consecutive frames required to confirm a new rect (consensus threshold)
    private let minConsecutiveFramesForUpdate: Int = 3
    
    /// Tolerance threshold for ignoring minor activeRect changes (in pixels)
    /// Increased to handle capture card jitter in both dimensions and position
    private let activeRectChangeThreshold: Int = 25
    
    /// Tracks whether aspect ratio has been initialized on first detection
    private var isAspectRatioInitialized: Bool = false

    /// Delegate for handling video output
    private var videoOutputDelegate: VideoOutputDelegate?

    /// Public access to video output delegate for OCR processing
    var outputDelegate: VideoOutputDelegate? {
        return videoOutputDelegate
    }

    // MARK: - Metal Rendering

    /// Metal texture manager for zero-copy texture creation
    private var metalTextureManager: MetalTextureManager?

    /// Metal video view for GPU-accelerated rendering
    private var videoMetalView: VideoMetalView?

    /// Get the Metal video view for display
    func getVideoMetalView() -> VideoMetalView? {
        return videoMetalView
    }

    /// Initialize Metal rendering components
    private func initializeMetalRendering() {
        guard metalTextureManager == nil else { return }

        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.log(content: "❌ Failed to create Metal device for video rendering")
            return
        }

        metalTextureManager = MetalTextureManager(device: device)
        videoMetalView = VideoMetalView(frame: .zero, device: device)

        if let textureManager = metalTextureManager, let metalView = videoMetalView {
            videoOutputDelegate?.setMetalTextureManager(textureManager)
            videoOutputDelegate?.setVideoMetalView(metalView)
            logger.log(content: "✅ Metal rendering components initialized successfully")
        } else {
            logger.log(content: "❌ Failed to initialize Metal rendering components")
        }
    }
    
    // MARK: - Initialization
    
    override init() {
        captureSession = AVCaptureSession()
        super.init()

        self.setupBindings()
        setupSession()
        initializeMetalRendering()
        // Listen for first-frame resolution analysis from VideoOutputDelegate
        NotificationCenter.default.addObserver(self, selector: #selector(handleFrameResolution(_:)),
                name: Notification.Name("checkActiveResolution"), object: nil)


        // Add device notification observers
        self.observeDeviceNotifications()
    }
    
    deinit {
        cleanupObservers()
    }
    
    // MARK: - Setup Methods
    
    /// Sets up the capture session with outputs
    func setupSession() {
        let videoDataOutput = AVCaptureVideoDataOutput()
        // Force NV12 (bi-planar YUV 4:2:0) output for Metal rendering.
        // MetalTextureManager and the YUV→RGB shader only support NV12.
        // Without this, AVFoundation may output the device's native format
        // (e.g. 4:2:2 single-plane), causing silent texture creation failure.
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true

        self.videoOutputDelegate = VideoOutputDelegate(videoManager: self)
        videoDataOutput.setSampleBufferDelegate(videoOutputDelegate, queue: DispatchQueue(label: "VideoOutputQueue"))

        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
            logger.log(content: "✅ Video data output added to capture session")
        } else {
            logger.log(content: "❌ Cannot add video data output to capture session - this will cause black screen!")
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

        // If video session is running AND has at least one input, check if device has changed
        // If it's running but has NO inputs, it was started before hardware was available.
        if captureSession.isRunning && !captureSession.inputs.isEmpty {
            // Check if we've received frames recently (within 3 seconds)
            // If not, the session is in a zombie state and needs to be restarted
            let timeSinceLastFrame = Date().timeIntervalSince(videoOutputDelegate?.lastFrameTime ?? Date(timeIntervalSince1970: 0))
            if timeSinceLastFrame > 3.0 {
                logger.log(content: "Video session running but no frames received for \(String(format: "%.1f", timeSinceLastFrame))s, restarting")
                captureSession.stopRunning()
            } else {
                // Get the current input's device unique ID
                if let currentInput = captureSession.inputs.first as? AVCaptureDeviceInput {
                    let currentDeviceID = currentInput.device.uniqueID
                    
                    // Find the matching video device to compare
                    let videoDeviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .externalUnknown]
                    let videoDiscoverySession = AVCaptureDevice.DiscoverySession(
                        deviceTypes: videoDeviceTypes,
                        mediaType: .video,
                        position: .unspecified
                    )
                    let videoDevices = findMatchingVideoDevices(from: videoDiscoverySession.devices)
                    
                    if let newDevice = videoDevices.first {
                        if newDevice.uniqueID == currentDeviceID {
                            logger.log(content: "Video already running with same device, skipping preparation")
                            return
                        } else {
                            logger.log(content: "Video device changed (old: \(currentDeviceID), new: \(newDevice.uniqueID)), restarting session")
                            captureSession.stopRunning()
                        }
                    } else {
                        logger.log(content: "Video already running, skipping preparation")
                        return
                    }
                } else {
                    logger.log(content: "Video already running, skipping preparation")
                    return
                }
            }
        }

        if captureSession.isRunning && captureSession.inputs.isEmpty {
            logger.log(content: "Video session running but empty (no hardware at startup) — restarting with detected hardware")
            captureSession.stopRunning()
        }
        
        // Update last start time
        lastVideoSessionStartTime = now
        
        // Mark as starting
        isVideoSessionStarting = true
        
        logger.log(content: "Preparing video capture...")
        
        // Update USB devices - execute the entire process on the main thread to avoid thread synchronization issues
        updateUSBDevices()
        
        // Configure capture session quality
        // NOTE: Do NOT set sessionPreset to .high - it limits resolution to 1080p
        // Let the device's activeFormat determine the resolution instead
        // captureSession.sessionPreset = .high

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

            // Enumerate available formats first
            enumerateAvailableVideoFormats()

            // Set desired resolution from user-selected format
            // This ensures setupVideoCapture applies the correct resolution
            let selectedRes = selectedVideoFormat.resolution
            desiredResolution = CMVideoDimensions(width: Int32(selectedRes.width), height: Int32(selectedRes.height))
            logger.log(content: "Set desired resolution to \(selectedRes.width)x\(selectedRes.height) from selected format")

            // Setup video capture (format will be applied inside the configuration block)
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
            if let defaultDevice = AppStatus.videoChipDevice {
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

            // Apply user-selected format (inside configuration block)
            applySelectedVideoFormat(to: device)

            // Set desired resolution if specified
            // NOTE: Format matching is handled by applySelectedVideoFormat() called earlier in prepareVideo()
            // This section is kept for backward compatibility but does nothing if desiredResolution is set
            if let desiredRes = desiredResolution {
                logger.log(content: "Desired resolution set to \(desiredRes.width)x\(desiredRes.height) - format matching handled by applySelectedVideoFormat")
                // Skip format matching here to avoid conflicts with applySelectedVideoFormat
                // The device.activeFormat and videoSettings were already set by applySelectedVideoFormat
            }

            // Commit configuration changes
            logger.log(content: "🔬 [TRACE] About to commitConfiguration...")
            captureSession.commitConfiguration()
            logger.log(content: "🔬 [TRACE] commitConfiguration done")

            // Get camera video resolution
            if let formatDescription = device.activeFormat.formatDescription as CMFormatDescription? {
                dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
                AppStatus.videoDimensions.width = CGFloat(dimensions.width)
                AppStatus.videoDimensions.height = CGFloat(dimensions.height)
            }

            // Start video session
            logger.log(content: "🔬 [TRACE] About to call startVideoSession...")
            logger.log(content: "Video device setup successful, starting session...")
            startVideoSession()
            logger.log(content: "🔬 [TRACE] startVideoSession returned")
            AppStatus.isHDMIConnected = true
            DispatchQueue.main.async {
                self.isVideoConnected = true
            }
        } catch {
            logger.log(content: "🔬 [TRACE] EXCEPTION in setupVideoCapture: \(error)")
            logger.log(content: "Failed to set up video capture: \(error.localizedDescription)")
            // Reset start flag when error occurs
            isVideoSessionStarting = false
        }
        
// Removed verbose format enumeration for cleaner logs
        // print("Supported pixel format--------")
        // for format in device.formats {
        //     let description = format.formatDescription
        //     let pixelFormat = CMFormatDescriptionGetMediaSubType(description)
        //     let formatDescription = pixelFormatDescription(pixelFormat)
        //     print("Supported pixel format: \(formatDescription)")
        // }
    }

    // MARK: - Video Format Enumeration

    /// Enumerates and caches all available video formats from detected video devices
    func enumerateAvailableVideoFormats() {
        // Prevent rapid re-enumeration (within 2 seconds)
        let now = Date()
        if now.timeIntervalSince(lastFormatEnumerationTime) < 2.0 {
            return
        }
        lastFormatEnumerationTime = now
        
        logger.log(content: "Enumerating available video formats...")

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

        let videoDevices = findMatchingVideoDevices(from: videoDiscoverySession.devices)

        var formats: [VideoFormat] = []

        for device in videoDevices {
            logger.log(content: "\n=== Device: \(device.localizedName) ===")
            
            // Group formats by resolution and find max fps for each
            var resolutionMap: [String: Double] = [:]
            var formatDetails: [String] = []
            for format in device.formats {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let key = "\(dimensions.width)x\(dimensions.height)"
                let maxFps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
                resolutionMap[key] = max(resolutionMap[key] ?? 0, maxFps)

                // Detailed format info (local enhancement)
                let codecType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                let pixelFormatHex = String(format: "0x%X", codecType)
                let pixelFormatName = fourCCToString(codecType)

                // Determine if this is a compressed format (MJPEG, H.264, etc.)
                let isCompressed: Bool
                let compressionType: String
                switch codecType {
                case kCMVideoCodecType_JPEG:
                    isCompressed = true
                    compressionType = "MJPEG/JPEG"
                case kCMVideoCodecType_H264:
                    isCompressed = true
                    compressionType = "H.264"
                case kCMVideoCodecType_HEVC:
                    isCompressed = true
                    compressionType = "HEVC"
                default:
                    isCompressed = false
                    compressionType = "Uncompressed"
                }

                // Get frame rate ranges
                let frameRateRanges = format.videoSupportedFrameRateRanges
                var frameRateInfo = ""
                for range in frameRateRanges {
                    frameRateInfo += "\(Int(range.minFrameRate))-\(Int(range.maxFrameRate))fps "
                }

                let detail = "Format \(formatDetails.count): \(dimensions.width)x\(dimensions.height) @ \(frameRateInfo)format=\(pixelFormatHex) (\(pixelFormatName)) [\(compressionType)]"
                formatDetails.append(detail)
                logger.log(content: detail)
            }
            
            // Sort by resolution (width desc) and show compact summary
            let sortedResolutions = resolutionMap.sorted { $0.key > $1.key }
            let formatSummary = sortedResolutions.map { "\($0.key)@\(Int($0.value))fps" }.joined(separator: ", ")
            
            logger.log(content: "Formats: \(device.formats.count) total, \(resolutionMap.count) resolutions: \(formatSummary)")

            for format in device.formats {
                let videoFormat = format.toVideoFormat()

                // Avoid duplicates (same resolution, fps, and pixel format)
                if !formats.contains(where: { $0.resolution == videoFormat.resolution &&
                                           abs($0.frameRate - videoFormat.frameRate) < 1.0 &&
                                           $0.pixelFormat == videoFormat.pixelFormat }) {
                    formats.append(videoFormat)
                }
            }

        }

        // Sort by resolution (desc), then frame rate (desc), then pixel format
        availableVideoFormats = formats.sorted {
            if $0.resolution.width != $1.resolution.width {
                return $0.resolution.width > $1.resolution.width
            }
            if $0.resolution.height != $1.resolution.height {
                return $0.resolution.height > $1.resolution.height
            }
            if abs($0.frameRate - $1.frameRate) > 0.1 {
                return $0.frameRate > $1.frameRate
            }
            return $0.pixelFormat < $1.pixelFormat
        }

        logger.log(content: "Found \(availableVideoFormats.count) unique video formats")

        // If current selection is not in available formats, find closest match
        if !availableVideoFormats.contains(where: { $0 == selectedVideoFormat }) {
            // Prefer 420v (NV12) format since video output is configured for NV12
            let nv12PixelFormat = String(format: "0x%X", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            let closest = availableVideoFormats
                .filter { format in
                    format.resolution.width == selectedVideoFormat.resolution.width &&
                    format.resolution.height == selectedVideoFormat.resolution.height
                }
                .sorted { a, b in
                    // Prefer 420v format
                    let aIsNV12 = a.pixelFormat == nv12PixelFormat
                    let bIsNV12 = b.pixelFormat == nv12PixelFormat
                    if aIsNV12 != bIsNV12 { return aIsNV12 }
                    return (a.frameRate) > (b.frameRate)
                }
                .first ?? availableVideoFormats.first

            if let closest = closest {
                logger.log(content: "Selected format not available, using closest match: \(closest.description)")
                selectedVideoFormat = closest
            }
        }

        // Print a nice summary of all available formats
        printAvailableFormatsSummary()
    }

    /// Converts a FourCC pixel format code to a human-readable string
    /// - Parameter code: FourCC code as UInt32
    /// - Returns: String representation of the FourCC
    private func fourCCToString(_ code: FourCharCode) -> String {
        switch code {
        case kCVPixelFormatType_32BGRA:
            return "BGRA (Uncompressed 32-bit)"
        case kCVPixelFormatType_32ARGB:
            return "ARGB (Uncompressed 32-bit)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return "420v (Bi-planar YUV 8-bit, Video Range)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "420f (Bi-planar YUV 8-bit, Full Range)"
        case kCVPixelFormatType_422YpCbCr8:
            return "422v (YUV 4:2:2, Uncompressed 8-bit)"
        case kCVPixelFormatType_422YpCbCr8_yuvs:
            return "422v_yuvs (YUV 4:2:2, Uncompressed 8-bit)"
        case kCMVideoCodecType_JPEG:
            return "JPEG/MJPEG (Compressed)"
        case kCMVideoCodecType_H264:
            return "H.264 (Compressed)"
        case kCMVideoCodecType_HEVC:
            return "HEVC/H.265 (Compressed)"
        default:
            // Convert to FourCC characters
            let bytes: [UInt8] = [
                UInt8((code >> 24) & 0xFF),
                UInt8((code >> 16) & 0xFF),
                UInt8((code >> 8) & 0xFF),
                UInt8(code & 0xFF)
            ]
            if let str = String(bytes: bytes, encoding: .ascii) {
                return str.trimmingCharacters(in: .controlCharacters)
            }
            return "Unknown"
        }
    }

    /// Returns all available video formats from the connected device
    /// - Returns: Array of VideoFormat objects
    func getAvailableVideoFormats() -> [VideoFormat] {
        return availableVideoFormats
    }

    /// Prints a summary of all available resolutions and formats to the console
    /// Useful for debugging format selection issues
    func printAvailableFormatsSummary() {
        logger.log(content: "\n========== AVAILABLE VIDEO FORMATS SUMMARY ==========")
        logger.log(content: "Total unique formats: \(availableVideoFormats.count)")
        logger.log(content: "Currently selected: \(selectedVideoFormat.description)")
        logger.log(content: "Actual device format: \(dimensions.width)x\(dimensions.height)")
        logger.log(content: "")

        // Group by resolution
        let grouped = Dictionary(grouping: availableVideoFormats) { "\($0.resolution.width)x\($0.resolution.height)" }
        let sortedResolutions = grouped.keys.sorted { a, b in
            let aParts = a.split(separator: "x").compactMap { Int($0) }
            let bParts = b.split(separator: "x").compactMap { Int($0) }
            guard aParts.count == 2, bParts.count == 2 else { return false }
            if aParts[0] != bParts[0] { return aParts[0] > bParts[0] }
            return aParts[1] > bParts[1]
        }

        for resolution in sortedResolutions {
            let formats = grouped[resolution] ?? []
            logger.log(content: "📺 \(resolution) (\(formats.count) formats):")
            for format in formats {
                let formatName = fourCCToString(UInt32(format.pixelFormat.dropFirst(2), radix: 16) ?? 0)
                logger.log(content: "   - \(format.frameRate)fps, format=\(format.pixelFormat) [\(formatName)]")
            }
        }
        logger.log(content: "=====================================================\n")
    }

    /// Applies the user-selected video format to the device if available
    private func applySelectedVideoFormat(to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()

            // Log current active format BEFORE change
            let beforeDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let beforePixelFormat = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
            logger.log(content: "📍 Device active format BEFORE change: \(beforeDims.width)x\(beforeDims.height), pixel format: \(String(format: "0x%X", beforePixelFormat))")

            // Log all available formats for debugging
            logger.log(content: "🔍 Available device formats:")
            for (index, format) in device.formats.enumerated() {
                let videoFormat = format.toVideoFormat()
                logger.log(content: "  Format \(index): \(videoFormat.description)")
            }

            logger.log(content: "🎯 Selected format: \(selectedVideoFormat.description)")

            // Cascading format matching strategy:
            // 1. Try exact match (resolution + fps + pixel format)
            // 2. Relax pixel format requirement (resolution + fps only)
            // 3. Relax frame rate requirement (resolution only, pick best fps)
            var matchingFormat: AVCaptureDevice.Format?

            // Strategy 1: Exact match (resolution + fps + pixel format)
// Pick the one with highest maxFrameRate among matches
            let exactMatches = device.formats.filter { format in
                let videoFormat = format.toVideoFormat()
                return videoFormat.resolution.width == selectedVideoFormat.resolution.width &&
                       videoFormat.resolution.height == selectedVideoFormat.resolution.height &&
                       abs(videoFormat.frameRate - selectedVideoFormat.frameRate) < 1.0 &&
                       videoFormat.pixelFormat == selectedVideoFormat.pixelFormat
            }

            if !exactMatches.isEmpty {
                // For MS2130S: Select format with max frame rate closest to 60fps
                // This prevents selecting high-fps formats (e.g., 240fps) when user wants 60fps
                matchingFormat = exactMatches.min { a, b in
                    // Get the maximum frame rate from all ranges
                    let maxFpsA = (a.videoSupportedFrameRateRanges as? [AVFrameRateRange])?.map { $0.maxFrameRate }.max() ?? 0
                    let maxFpsB = (b.videoSupportedFrameRateRanges as? [AVFrameRateRange])?.map { $0.maxFrameRate }.max() ?? 0
                    // Prefer format with max fps closest to 60
                    let diffA = abs(maxFpsA - 60.0)
                    let diffB = abs(maxFpsB - 60.0)
                    return diffA < diffB
                }
                let selectedMaxFps = (matchingFormat?.videoSupportedFrameRateRanges as? [AVFrameRateRange])?.map { $0.maxFrameRate }.max() ?? 0
                logger.log(content: "✅ Strategy 1: Exact format match found (selected format with max fps closest to 60: \(selectedMaxFps)fps)")
            }

            // Strategy 2: Match resolution + frame rate, prefer 420v (NV12) pixel format
            if matchingFormat == nil {
                let nv12PixelFormat = String(format: "0x%X", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                let matches = device.formats.filter { format in
                    let videoFormat = format.toVideoFormat()
                    return videoFormat.resolution.width == selectedVideoFormat.resolution.width &&
                           videoFormat.resolution.height == selectedVideoFormat.resolution.height &&
                           abs(videoFormat.frameRate - selectedVideoFormat.frameRate) < 1.0
                }
                // Prefer 420v format for NV12 video output compatibility
                matchingFormat = matches.first { format in
                    let codecType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                    return String(format: "0x%X", codecType) == nv12PixelFormat
                } ?? matches.first
                if matchingFormat != nil {
                    logger.log(content: "✅ Strategy 2: Resolution+FPS match found (preferred 420v)")
                }
            }

            // Strategy 3: Match resolution only, prefer 420v, pick format with highest max frame rate
            if matchingFormat == nil {
                let nv12PixelFormat = String(format: "0x%X", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                let resolutionFormats = device.formats.filter { format in
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return dims.width == selectedVideoFormat.resolution.width &&
                           dims.height == selectedVideoFormat.resolution.height
                }
                // Sort: prefer 420v, then highest maximum frame rate
                let sorted = resolutionFormats.sorted { a, b in
                    let codecA = String(format: "0x%X", CMFormatDescriptionGetMediaSubType(a.formatDescription))
                    let codecB = String(format: "0x%X", CMFormatDescriptionGetMediaSubType(b.formatDescription))
                    let aIsNV12 = codecA == nv12PixelFormat
                    let bIsNV12 = codecB == nv12PixelFormat
                    if aIsNV12 != bIsNV12 { return aIsNV12 }
                    let maxFpsA = (a.videoSupportedFrameRateRanges as? [AVFrameRateRange])?.map { $0.maxFrameRate }.max() ?? 0
                    let maxFpsB = (b.videoSupportedFrameRateRanges as? [AVFrameRateRange])?.map { $0.maxFrameRate }.max() ?? 0
                    return maxFpsA > maxFpsB
                }
                matchingFormat = sorted.first
                let selectedMaxFps = (matchingFormat?.videoSupportedFrameRateRanges as? [AVFrameRateRange])?.map { $0.maxFrameRate }.max() ?? 0
                logger.log(content: "✅ Strategy 3: Resolution-only match found (preferred 420v, highest max fps: \(selectedMaxFps))")
            }

            if let matchingFormat = matchingFormat {
                // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                // Frame Rate Locking (60fps) - MUST be set BEFORE activeFormat
                // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                // On MS2130S chipset, setting frame duration may throw NSException.
                // We use ObjCExceptionCatcher to safely attempt this.
                // IMPORTANT: Set frame duration BEFORE activeFormat for MS2130S compatibility
                var frameDurationSuccess = false
                let exceptionCaught = ObjCExceptionCatcher.catchException({
                    // Use the exact maximum frame rate from the format's first range
                    if let frameRateRanges = matchingFormat.videoSupportedFrameRateRanges as? [AVFrameRateRange],
                       let maxFpsRange = frameRateRanges.first(where: { $0.maxFrameRate >= 59.9 && $0.maxFrameRate <= 60.1 }) ?? frameRateRanges.first {
                        // Try multiple approaches to set frame duration
                        var durationSet = false

                        // Approach 1: Use CMTimeMakeWithSeconds with high timescale
                        let frameDurationSeconds = 1.0 / maxFpsRange.maxFrameRate
                        let duration1 = CMTimeMakeWithSeconds(frameDurationSeconds, preferredTimescale: 6000)
                        do {
                            try device.lockForConfiguration()
                            device.activeVideoMinFrameDuration = duration1
                            device.activeVideoMaxFrameDuration = duration1
                            device.unlockForConfiguration()
                            durationSet = true
                            self.logger.log(content: "🔒 Attempting frame rate lock to \(maxFpsRange.maxFrameRate)fps via CMTimeMakeWithSeconds (timescale: 6000)")
                        } catch {
                            self.logger.log(content: "⚠️ Approach 1 failed: \(error.localizedDescription)")
                        }

                        // Approach 2: Use CMTimeMake with integer timescale (if approach 1 failed)
                        if !durationSet {
                            let timescale = Int64(maxFpsRange.maxFrameRate * 1000) // Scale by 1000 for precision
                            let duration2 = CMTimeMake(value: timescale, timescale: Int32(maxFpsRange.maxFrameRate * 1000 * 1000))
                            do {
                                try device.lockForConfiguration()
                                device.activeVideoMinFrameDuration = duration2
                                device.activeVideoMaxFrameDuration = duration2
                                device.unlockForConfiguration()
                                durationSet = true
                                self.logger.log(content: "🔒 Attempting frame rate lock to \(maxFpsRange.maxFrameRate)fps via CMTimeMake (scaled)")
                            } catch {
                                self.logger.log(content: "⚠️ Approach 2 failed: \(error.localizedDescription)")
                            }
                        }

                        // Approach 3: Try exact 60fps as fallback
                        if !durationSet {
                            let duration3 = CMTimeMake(value: 1, timescale: 60)
                            do {
                                try device.lockForConfiguration()
                                device.activeVideoMinFrameDuration = duration3
                                device.activeVideoMaxFrameDuration = duration3
                                device.unlockForConfiguration()
                                durationSet = true
                                self.logger.log(content: "🔒 Attempting frame rate lock to 60.0fps via CMTimeMake(1,60)")
                            } catch {
                                self.logger.log(content: "⚠️ Approach 3 failed: \(error.localizedDescription)")
                            }
                        }

                        frameDurationSuccess = durationSet
                        if !durationSet {
                            self.logger.log(content: "⚠️ All frame rate lock approaches failed")
                        }
                    } else {
                        // Fallback to 60fps
                        let duration = CMTimeMake(value: 1, timescale: 60)
                        do {
                            try device.lockForConfiguration()
                            device.activeVideoMinFrameDuration = duration
                            device.activeVideoMaxFrameDuration = duration
                            device.unlockForConfiguration()
                            frameDurationSuccess = true
                        } catch {
                            self.logger.log(content: "⚠️ Fallback frame rate lock failed: \(error.localizedDescription)")
                        }
                    }
                })

                if !exceptionCaught {
                    frameDurationSuccess = false
                }

                if frameDurationSuccess {
                    logger.log(content: "🔒 Frame rate locked (before activeFormat)")
                } else {
                    logger.log(content: "⚠️ Frame rate lock failed before activeFormat. Will retry after.")
                }

                device.activeFormat = matchingFormat
                let actualDimensions = CMVideoFormatDescriptionGetDimensions(matchingFormat.formatDescription)
                let actualPixelFormat = CMFormatDescriptionGetMediaSubType(matchingFormat.formatDescription)
                logger.log(content: "✅ Applied video format: \(actualDimensions.width)x\(actualDimensions.height), pixel format: \(String(format: "0x%X", actualPixelFormat))")

                // Diagnostic: Log frame rate ranges for selected format
                if let frameRateRanges = matchingFormat.videoSupportedFrameRateRanges as? [AVFrameRateRange] {
                    let rangeDescriptions = frameRateRanges.map { range in
                        "\(range.minFrameRate)-\(range.maxFrameRate)fps"
                    }.joined(separator: ", ")
                    logger.log(content: "📊 Selected format frame rate ranges: \(rangeDescriptions)")
                    let maxSupportedFps = frameRateRanges.map { $0.maxFrameRate }.max() ?? 0
                    logger.log(content: "📊 Maximum supported FPS: \(maxSupportedFps)")
                }

                let requestedFps = Double(selectedVideoFormat.frameRate)

                // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                // USB Bandwidth Diagnostic
                // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                // Calculate and log USB bandwidth requirements for the selected format.
                //
                // Bandwidth formula (NV12 = 1.5 bytes/pixel):
                //   width × height × 1.5 bytes/pixel × fps
                // USB 3.0 practical bandwidth: ~400 MB/s
                let bytesPerPixelNV12 = 1.5
                let maxUsbBandwidthBytesPerSec = 400_000_000.0
                let pixelCount = Double(actualDimensions.width) * Double(actualDimensions.height)
                let bandwidthPerFps = pixelCount * bytesPerPixelNV12
                let bandwidthAtRequestedFps = bandwidthPerFps * requestedFps / 1_000_000.0
                let safeMaxFps = maxUsbBandwidthBytesPerSec / bandwidthPerFps

                if requestedFps > safeMaxFps {
                    logger.log(content: "⚠️ USB bandwidth: \(actualDimensions.width)x\(actualDimensions.height)@\(Int(requestedFps))fps needs \(String(format: "%.0f", bandwidthAtRequestedFps))MB/s > \(String(format: "%.0f", maxUsbBandwidthBytesPerSec / 1_000_000.0))MB/s limit (safe max: \(String(format: "%.0f", safeMaxFps))fps)")
                    logger.log(content: "💡 To reduce flickering, select a lower frame rate (e.g., 30fps) in video settings")
                } else {
                    logger.log(content: "✅ Bandwidth OK: \(String(format: "%.0f", bandwidthAtRequestedFps))MB/s at \(Int(requestedFps))fps (limit: \(String(format: "%.0f", maxUsbBandwidthBytesPerSec / 1_000_000.0))MB/s)")
                }

                // Verify the format was actually set on the device
                let verifyDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let verifyPixelFormat = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
                logger.log(content: "📍 Device active format AFTER change: \(verifyDims.width)x\(verifyDims.height), pixel format: \(String(format: "0x%X", verifyPixelFormat))")

                // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                // Frame Rate Locking Retry (after activeFormat)
                // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                // If frame duration setting failed before, retry after activeFormat is set
                if !frameDurationSuccess {
                    var retrySuccess = false
                    let retryExceptionCaught = ObjCExceptionCatcher.catchException({
                        // Use the exact maximum frame rate from the format's first range
                        if let frameRateRanges = matchingFormat.videoSupportedFrameRateRanges as? [AVFrameRateRange],
                           let maxFpsRange = frameRateRanges.first(where: { $0.maxFrameRate >= 59.9 && $0.maxFrameRate <= 60.1 }) ?? frameRateRanges.first {
                            // Try multiple approaches to set frame duration
                            var durationSet = false

                            // Approach 1: Use CMTimeMakeWithSeconds with high timescale
                            let frameDurationSeconds = 1.0 / maxFpsRange.maxFrameRate
                            let duration1 = CMTimeMakeWithSeconds(frameDurationSeconds, preferredTimescale: 6000)
                            do {
                                try device.lockForConfiguration()
                                device.activeVideoMinFrameDuration = duration1
                                device.activeVideoMaxFrameDuration = duration1
                                device.unlockForConfiguration()
                                durationSet = true
                                self.logger.log(content: "🔒 Retrying frame rate lock to \(maxFpsRange.maxFrameRate)fps via CMTimeMakeWithSeconds (timescale: 6000)")
                            } catch {
                                self.logger.log(content: "⚠️ Retry Approach 1 failed: \(error.localizedDescription)")
                            }

                            // Approach 2: Use CMTimeMake with integer timescale
                            if !durationSet {
                                let timescale = Int64(maxFpsRange.maxFrameRate * 1000)
                                let duration2 = CMTimeMake(value: timescale, timescale: Int32(maxFpsRange.maxFrameRate * 1000 * 1000))
                                do {
                                    try device.lockForConfiguration()
                                    device.activeVideoMinFrameDuration = duration2
                                    device.activeVideoMaxFrameDuration = duration2
                                    device.unlockForConfiguration()
                                    durationSet = true
                                    self.logger.log(content: "🔒 Retrying frame rate lock to \(maxFpsRange.maxFrameRate)fps via CMTimeMake (scaled)")
                                } catch {
                                    self.logger.log(content: "⚠️ Retry Approach 2 failed: \(error.localizedDescription)")
                                }
                            }

                            // Approach 3: Try exact 60fps as fallback
                            if !durationSet {
                                let duration3 = CMTimeMake(value: 1, timescale: 60)
                                do {
                                    try device.lockForConfiguration()
                                    device.activeVideoMinFrameDuration = duration3
                                    device.activeVideoMaxFrameDuration = duration3
                                    device.unlockForConfiguration()
                                    durationSet = true
                                    self.logger.log(content: "🔒 Retrying frame rate lock to 60.0fps via CMTimeMake(1,60)")
                                } catch {
                                    self.logger.log(content: "⚠️ Retry Approach 3 failed: \(error.localizedDescription)")
                                }
                            }

                            retrySuccess = durationSet
                        } else {
                            // Fallback to 60fps
                            let duration = CMTimeMake(value: 1, timescale: 60)
                            do {
                                try device.lockForConfiguration()
                                device.activeVideoMinFrameDuration = duration
                                device.activeVideoMaxFrameDuration = duration
                                device.unlockForConfiguration()
                                retrySuccess = true
                            } catch {
                                self.logger.log(content: "⚠️ Retry fallback frame rate lock failed: \(error.localizedDescription)")
                            }
                        }
                    })

                    if !retryExceptionCaught {
                        retrySuccess = false
                    }

                    if retrySuccess {
                        logger.log(content: "🔒 Frame rate locked (after activeFormat retry)")
                    } else {
                        logger.log(content: "⚠️ Frame rate lock failed completely. Device defaults to 25fps (MS2130S limitation).")
                    }
                }

                // Update video data output pixel format
                // IMPORTANT: Force NV12 bi-planar format for Metal rendering, regardless of device native format
                // AVFoundation will handle any necessary format conversion
                // This ensures MetalTextureManager can always create Y and UV plane textures
                if let videoOutput = captureSession.outputs.first(where: { $0 is AVCaptureVideoDataOutput }) as? AVCaptureVideoDataOutput {
                    videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    ]
                    logger.log(content: "Updated video output pixel format to NV12 (420v) for Metal rendering (device native: 0x\(String(format: "%X", actualPixelFormat)))")
                }
            } else {
                logger.log(content: "⚠️ No format found matching resolution \(selectedVideoFormat.resolution.width)x\(selectedVideoFormat.resolution.height) on device.")
                logger.log(content: "⚠️ Available formats:")
                for format in device.formats {
                    let videoFormat = format.toVideoFormat()
                    logger.log(content: "  - \(videoFormat.description)")
                }
            }

            // Log what format is actually active on the device after our selection attempt
            let finalDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let finalPixelFormat = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
            logger.log(content: "🎯 FINAL ACTIVE FORMAT: \(finalDims.width)x\(finalDims.height), pixel format: 0x\(String(format: "%X", finalPixelFormat))")

            device.unlockForConfiguration()
            logger.log(content: "🔬 [TRACE] applySelectedVideoFormat completed successfully")
        } catch {
            logger.log(content: "🔬 [TRACE] EXCEPTION in applySelectedVideoFormat: \(error)")
            logger.log(content: "Failed to apply video format: \(error.localizedDescription)")
        }
    }

    /// Starts video capture session
    func startVideoSession() {
        logger.log(content: "🔬 [TRACE] startVideoSession() called, isFirmwareFlashing=\(AppStatus.isFirmwareFlashing), isRunning=\(captureSession.isRunning)")

        // Avoid HID/video bus conflicts during firmware flashing
        if AppStatus.isFirmwareFlashing {
            logger.log(content: "🔬 [TRACE] startVideoSession: blocked by firmware flashing")
            logger.log(content: "Firmware flash in progress: skipping video session start")
            isVideoSessionStarting = false
            return
        }

        // Status check: if session is already running, return directly
        if captureSession.isRunning {
            logger.log(content: "🔬 [TRACE] startVideoSession: already running, skip")
            logger.log(content: "Video session already running, skipping start...")
            isVideoSessionStarting = false
            return
        }

        logger.log(content: "🔬 [TRACE] startVideoSession: scheduling startRunning with 1s delay")
        logger.log(content: "Starting video session...")

        // Delay capture session start by 1 second to avoid crash
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }

            logger.log(content: "🔬 [TRACE] 1s delay fired, about to startRunning, inputs=\(self.captureSession.inputs.count)")

            // Log device active format BEFORE starting session
            if let device = self.captureSession.inputs.first(where: { $0 is AVCaptureDeviceInput }) as? AVCaptureDeviceInput {
                let preStartDims = CMVideoFormatDescriptionGetDimensions(device.device.activeFormat.formatDescription)
                let preStartPixelFormat = CMFormatDescriptionGetMediaSubType(device.device.activeFormat.formatDescription)
                self.logger.log(content: "📍 Device active format BEFORE session start: \(preStartDims.width)x\(preStartDims.height), pixel format: \(String(format: "0x%X", preStartPixelFormat))")
            }

            // Start session directly in current thread, avoiding extra asynchronous operations
            self.captureSession.startRunning()
            logger.log(content: "🔬 [TRACE] startRunning() completed, isRunning=\(self.captureSession.isRunning)")

            // Log device active format AFTER starting session
            if let device = self.captureSession.inputs.first(where: { $0 is AVCaptureDeviceInput }) as? AVCaptureDeviceInput {
                let postStartDims = CMVideoFormatDescriptionGetDimensions(device.device.activeFormat.formatDescription)
                let postStartPixelFormat = CMFormatDescriptionGetMediaSubType(device.device.activeFormat.formatDescription)
                self.logger.log(content: "📍 Device active format AFTER session start: \(postStartDims.width)x\(postStartDims.height), pixel format: \(String(format: "0x%X", postStartPixelFormat))")

                // If the format was reset by startRunning(), re-apply it
                let desiredDims = self.selectedVideoFormat.resolution
                if Int(postStartDims.width) != desiredDims.width || Int(postStartDims.height) != desiredDims.height {
                    self.logger.log(content: "⚠️ Format was reset by session start, re-applying format...")
                    self.applySelectedVideoFormat(to: device.device)

                    // Verify the format was re-applied
                    let reapplyDims = CMVideoFormatDescriptionGetDimensions(device.device.activeFormat.formatDescription)
                    let reapplyPixelFormat = CMFormatDescriptionGetMediaSubType(device.device.activeFormat.formatDescription)
                    self.logger.log(content: "📍 Device active format AFTER re-apply: \(reapplyDims.width)x\(reapplyDims.height), pixel format: \(String(format: "0x%X", reapplyPixelFormat))")
                }
            }

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
    
    // MARK: - Active Display Detection
    
    /// Detects the bounding rect of non-black pixels in the image (image coordinates)
    /// Assumes video image symmetry - uses closer-to-edge values for more reliable border detection
    /// - Parameter cgImage: The image to analyze
    /// - Returns: CGRect representing the active (non-black) area, or nil if no active area found
    func detectActiveRect(from cgImage: CGImage) -> CGRect? {
        let width = cgImage.width
        let height = cgImage.height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8

        guard let contextData = malloc(height * bytesPerRow) else { return nil }
        defer { free(contextData) }

        guard let context = CGContext(data: contextData,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: bitsPerComponent,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        // Draw into RGBA context
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(cgImage, in: rect)

        let threshold: UInt8 = 32 // pixel > threshold considered active (not black)

        var minX = width
        var minY = height
        var maxX: Int = 0
        var maxY: Int = 0

        let data = context.data!.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            let row = data.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixel = row.advanced(by: x * bytesPerPixel)
                let r = pixel[0]
                let g = pixel[1]
                let b = pixel[2]

                if r > threshold || g > threshold || b > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        if minX <= maxX && minY <= maxY {
            // Assuming video image symmetry, use the closer-to-edge values for more reliable border detection
            // For horizontal: compare distance from left (minX) vs distance from right (width - maxX - 1)
            let leftBorder = minX
            let rightBorder = width - maxX - 1
            let useLeftAsReference = leftBorder <= rightBorder
            let finalMinX = useLeftAsReference ? minX : (width - maxX - 1)
            let finalMaxX = useLeftAsReference ? (width - 1 - minX) : maxX
            
            // For vertical: compare distance from top (minY) vs distance from bottom (height - maxY - 1)
            let topBorder = minY
            let bottomBorder = height - maxY - 1
            let useTopAsReference = topBorder <= bottomBorder
            let finalMinY = useTopAsReference ? minY : (height - maxY - 1)
            let finalMaxY = useTopAsReference ? (height - 1 - minY) : maxY
            
            // Calculate final active rectangle
            let w = finalMaxX - finalMinX + 1
            let h = finalMaxY - finalMinY + 1
            let activeRect = CGRect(x: finalMinX, y: finalMinY, width: w, height: h)
            
            return activeRect
        }

        return nil
    }
    
    // MARK: - Notification Handlers
    
    /// Handles when a video device is connected
    @objc func videoWasConnected(notification: NSNotification) {
        usbDevicesManager?.update()
        
        // Perform HAL hardware check when video is connected
        logger.log(content: "🔍 Initiating HAL hardware check for video connection...")
        let _ = hal.detectAndInitializeHardware()

        if let defaultDevice = AppStatus.videoChipDevice,
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
        if let defaultDevice = AppStatus.videoChipDevice, 
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
    // MARK: - Active Display Frame Resolution Handling
    
    /// Handles frame resolution notification and updates display dimensions
    /// - Parameter notification: Contains activeWidth, activeHeight, and optional activeRect info
    @objc private func handleFrameResolution(_ notification: Notification) {
        guard let info = notification.userInfo as? [String: Any],
              let width = info["activeWidth"] as? Int,
              let height = info["activeHeight"] as? Int else { return }

        // Use the actual frame dimensions for the capture resolution
        dimensions = CMVideoDimensions(width: Int32(width), height: Int32(height))     
        logger.log(content: "Frame resolution received: \(width)x\(height) - dimensions updated")

        // Calculate aspect ratio and apply auto-matching
        let activeAspectRatio = calculateAspectRatio(width: width, height: height)
        applyAspectRatioMatching(activeAspectRatio: activeAspectRatio)

        // Handle active video area if provided
        if let ax = info["activeX"] as? Int,
           let ay = info["activeY"] as? Int,
           let aw = info["activeWidth"] as? Int,
           let ah = info["activeHeight"] as? Int {
            handleActiveVideoArea(x: ax, y: ay, width: aw, height: ah, aspectRatio: activeAspectRatio)
        }
    }
    
    /// Calculates aspect ratio from video dimensions
    /// - Parameters:
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    /// - Returns: Width-to-height aspect ratio
    func calculateAspectRatio(width: Int, height: Int) -> CGFloat {
        return CGFloat(width) / max(1.0, CGFloat(height))
    }
    
    /// Finds the best matching aspect ratio option within tolerance
    /// - Parameters:
    ///   - activeAspectRatio: Calculated aspect ratio from video frame
    ///   - tolerance: Maximum acceptable difference ratio (default: 2%)
    /// - Returns: Matching AspectRatioOption or nil if no match found
    func findMatchingAspectRatio(_ activeAspectRatio: CGFloat, tolerance: CGFloat = 0.01) -> AspectRatioOption? {
        var bestMatch: AspectRatioOption? = nil
        var bestDistance: CGFloat = CGFloat.greatestFiniteMagnitude
        
        for option in AspectRatioOption.allCases {
            let optionRatio = option.widthToHeightRatio
            let distance = abs(optionRatio - activeAspectRatio) / activeAspectRatio
            
            // Only consider options within tolerance
            if distance <= tolerance && distance < bestDistance {
                bestDistance = distance
                bestMatch = option
            }
        }
        
        return bestMatch
    }
    
    /// Applies aspect ratio matching and updates user settings if chan ged
    /// - Parameter activeAspectRatio: Calculated aspect ratio from video frame
    private func applyAspectRatioMatching(activeAspectRatio: CGFloat) {
        let matchedOption = findMatchingAspectRatio(activeAspectRatio)
        // On first time, previousAspect should be nil to ensure aspect ratio is always applied
        let previousAspect: AspectRatioOption? = isAspectRatioInitialized ? UserSettings.shared.customAspectRatio : nil
        
        if let matched = matchedOption {
            // Update aspect ratio if changed or if this is the first time (previousAspect is nil)
            if previousAspect == nil || previousAspect != matched {
                UserSettings.shared.customAspectRatio = matched
                isAspectRatioInitialized = true
                logger.log(content: "Auto-matched aspect ratio: \(matched.rawValue) (aspect=\(String(format: "%.3f", activeAspectRatio)))")
                
                notifyAspectRatioChanged()
            } else {
                logger.log(content: "Aspect ratio already set to \(matched.rawValue), no change needed")
            }
        } else {
            // No match and we already have a valid aspect ratio:
            // keep the previous setting to avoid false updates from noisy/black frames.
            if let previous = previousAspect {
                logger.log(content: "No preset match found (aspect=\(String(format: "%.3f", activeAspectRatio))). Keeping previous aspect ratio: \(previous.rawValue)")
                return
            }

            // First-time fallback when no previous aspect ratio exists.
            UserSettings.shared.customAspectRatioValue = activeAspectRatio
            UserSettings.shared.gravity = .resizeAspect
            isAspectRatioInitialized = true
            logger.log(content: "No preset match found. Storing initial custom aspect ratio value: \(String(format: "%.3f", activeAspectRatio))")

            notifyAspectRatioChanged()
        }
    }
    
    /// Handles active video area detection and auto-zoom
    /// - Parameters:
    ///   - x: Active area left position
    ///   - y: Active area top position
    ///   - width: Active area width
    ///   - height: Active area height
    ///   - aspectRatio: Calculated aspect ratio
    private func handleActiveVideoArea(x: Int, y: Int, width: Int, height: Int, aspectRatio: CGFloat) {
        let newRect = CGRect(x: x, y: y, width: width, height: height)
        
        // Check if this is a minor change from the previous activeRect (capture card instability)
        // let (isMinorChange, stableRect) = checkAndFilterMinorActiveRectChange(newRect)
        
        // Use the stable rect (either the new one or previous one if change is minor)
        let rect = newRect
        let finalX = Int(rect.origin.x)
        let finalY = Int(rect.origin.y)
        let finalWidth = Int(rect.size.width)
        let finalHeight = Int(rect.size.height)
        
        // Update app status and persist to user settings
        AppStatus.activeVideoRect = rect
        UserSettings.shared.activeVideoX = finalX
        UserSettings.shared.activeVideoY = finalY
        UserSettings.shared.activeVideoWidth = finalWidth
        UserSettings.shared.activeVideoHeight = finalHeight
        
        // let logMessage = isMinorChange 
        //     ? "Frame active video area (filtered minor change), activeX:\(finalX), activeY:\(finalY), activeWidth:\(finalWidth), activeHeight:\(finalHeight), aspect ratio: \(String(format: "%.3f", rect.width / rect.height))"
        //     : "Frame active video area, activeX:\(finalX), activeY:\(finalY), activeWidth:\(finalWidth), activeHeight:\(finalHeight), aspect ratio: \(String(format: "%.3f", rect.width / rect.height))"
        // logger.log(content: logMessage)
        
        // Trigger auto-zoom based on detected blank areas
        applyAutoZoom(blankAreaX: finalX, blankAreaY: finalY, activeWidth: finalWidth, activeHeight: finalHeight, aspectRatio: aspectRatio)
    }
    
    /// Checks if the new activeRect represents a minor change from the previous one
    /// Uses a consensus approach: requires multiple consecutive frames showing the same rect before updating
    /// - Parameter newRect: The newly detected active rectangle
    /// - Returns: Tuple of (isMinorChange: Bool, rectToUse: CGRect)
    private func checkAndFilterMinorActiveRectChange(_ newRect: CGRect) -> (isMinorChange: Bool, rectToUse: CGRect) {
        guard let prevRect = previousActiveRect else {
            // No previous rect, this is the first detection
            previousActiveRect = newRect
            candidateActiveRect = newRect
            consecutiveFramesSameRect = 1
            logger.log(content: "[ActiveRect Stability] First detection: \(Int(newRect.width))x\(Int(newRect.height)) at (\(Int(newRect.origin.x)), \(Int(newRect.origin.y)))")
            return (isMinorChange: false, rectToUse: newRect)
        }
        
        // Check if new rect is the same as current candidate (within threshold)
        let isSameAsCandidate = isRectSimilar(newRect, candidateActiveRect ?? newRect)
        
        if isSameAsCandidate {
            // Same as candidate, increment consecutive frame counter
            consecutiveFramesSameRect += 1
            
            if consecutiveFramesSameRect >= minConsecutiveFramesForUpdate {
                // We have consensus - update to new rect
                let widthDifference = abs(Int(newRect.width) - Int(prevRect.width))
                let heightDifference = abs(Int(newRect.height) - Int(prevRect.height))
                let xDifference = abs(Int(newRect.origin.x) - Int(prevRect.origin.x))
                let yDifference = abs(Int(newRect.origin.y) - Int(prevRect.origin.y))
                
                if widthDifference > activeRectChangeThreshold || 
                   heightDifference > activeRectChangeThreshold ||
                   xDifference > activeRectChangeThreshold ||
                   yDifference > activeRectChangeThreshold {
                    // Significant change confirmed by consensus
                    previousActiveRect = newRect
                    logger.log(content: "[ActiveRect Stability] Consensus reached after \(consecutiveFramesSameRect) frames. Updating: \(Int(newRect.width))x\(Int(newRect.height))@(\(Int(newRect.origin.x)),\(Int(newRect.origin.y))) (diffs: w=\(widthDifference), h=\(heightDifference), x=\(xDifference), y=\(yDifference))")
                    consecutiveFramesSameRect = 0
                    return (isMinorChange: false, rectToUse: newRect)
                } else {
                    // Minor changes, keep using previous rect
                    return (isMinorChange: true, rectToUse: prevRect)
                }
            } else {
                // Still accumulating consensus, use previous rect
                logger.log(content: "[ActiveRect Stability] Candidate \(Int(newRect.width))x\(Int(newRect.height)) seen \(consecutiveFramesSameRect)/\(minConsecutiveFramesForUpdate) times. Keeping previous.")
                return (isMinorChange: true, rectToUse: prevRect)
            }
        } else {
            // Different from candidate, reset counter and start new candidate
            logger.log(content: "[ActiveRect Stability] New candidate detected: \(Int(newRect.width))x\(Int(newRect.height))@(\(Int(newRect.origin.x)),\(Int(newRect.origin.y))). Previous candidate: \(Int(candidateActiveRect?.width ?? 0))x\(Int(candidateActiveRect?.height ?? 0))")
            candidateActiveRect = newRect
            consecutiveFramesSameRect = 1
            return (isMinorChange: true, rectToUse: prevRect)
        }
    }
    
    /// Checks if two rectangles are similar within the threshold
    /// - Parameters:
    ///   - rect1: First rectangle to compare
    ///   - rect2: Second rectangle to compare
    /// - Returns: True if rectangles are within threshold of each other
    private func isRectSimilar(_ rect1: CGRect, _ rect2: CGRect) -> Bool {
        let widthDiff = abs(Int(rect1.width) - Int(rect2.width))
        let heightDiff = abs(Int(rect1.height) - Int(rect2.height))
        let xDiff = abs(Int(rect1.origin.x) - Int(rect2.origin.x))
        let yDiff = abs(Int(rect1.origin.y) - Int(rect2.origin.y))
        
        return widthDiff <= activeRectChangeThreshold && 
               heightDiff <= activeRectChangeThreshold &&
               xDiff <= activeRectChangeThreshold &&
               yDiff <= activeRectChangeThreshold
    }
    
    /// Applies auto-zoom based on detected blank area position
    /// - Parameters:
    ///   - blankAreaX: X offset of active area (left blank area width)
    ///   - blankAreaY: Y offset of active area (top blank area height)
    ///   - activeWidth: Width of active area
    ///   - activeHeight: Height of active area
    ///   - aspectRatio: Calculated aspect ratio of active area
    private func applyAutoZoom(blankAreaX: Int, blankAreaY: Int, activeWidth: Int, activeHeight: Int, aspectRatio: CGFloat) {
        // Pillarbox: black bars on left/right (blankAreaX > 0, blankAreaY == 0)
        if blankAreaX > 0 && blankAreaY == 0 && activeWidth > 0 && activeHeight > 0 {
            if aspectRatio > 1.0 {
                logger.log(content: "Pillarbox detected (left/right black bar), auto-zooming to width to fill horizontal space")
                NotificationCenter.default.post(name: Notification.Name("AutoZoomToWidthTriggered"), object: nil, userInfo: ["isAutoResize": true])
            }
        }
        // Letterbox: black bars on top/bottom (blankAreaX == 0, blankAreaY > 0)
        else if blankAreaX == 0 && blankAreaY > 0 && activeWidth > 0 && activeHeight > 0 {
            if aspectRatio > 1.0 {
                logger.log(content: "Letterbox detected (top/bottom black bar), auto-zooming to height to fill vertical space")
                NotificationCenter.default.post(name: Notification.Name("AutoZoomToHeightTriggered"), object: nil, userInfo: ["isAutoResize": true])
            }
        }
        // Mixed blank areas (blankAreaX > 0 AND blankAreaY > 0)
        else if blankAreaX > 0 && blankAreaY > 0 && activeWidth > 0 && activeHeight > 0 {
            if aspectRatio < 1.0 {
                logger.log(content: "Mixed blank areas with portrait aspect ratio, auto-zooming to height")
                NotificationCenter.default.post(name: Notification.Name("AutoZoomToHeightTriggered"), object: nil, userInfo: ["isAutoResize": true])
            } else {
                logger.log(content: "Mixed blank areas with landscape aspect ratio, auto-zooming to width")
                NotificationCenter.default.post(name: Notification.Name("AutoZoomToWidthTriggered"), object: nil, userInfo: ["isAutoResize": true])
            }
        }
    }
    
    /// Notifies that aspect ratio settings have changed
    private func notifyAspectRatioChanged() {
        NotificationCenter.default.post(name: .gravitySettingsChanged, object: nil)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name.updateWindowSize, object: nil)
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
