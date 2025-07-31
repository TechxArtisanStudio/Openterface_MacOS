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
import CoreMedia
import VideoToolbox
import AppKit
import UserNotifications

class CameraManager: NSObject, ObservableObject, CameraManagerProtocol {
    private var logger: LoggerProtocol!
    private var videoManager: VideoManagerProtocol!
    private var audioManager: AudioManagerProtocol!
    
    // Published properties for UI status display
    @Published var isRecording: Bool = false
    @Published var canTakePicture: Bool = false
    @Published var statusMessage: String = "Camera ready"
    
    // Singleton instance
    static let shared = CameraManager()
    
    // Recording properties
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime: Date?
    private var sessionStartTime: CMTime?
    private var recordingURL: URL?
    
    // Audio recording properties
    private var audioCaptureSession: AVCaptureSession?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var audioQueue: DispatchQueue?
    
    // File management
    private let fileManager = FileManager.default
    private lazy var documentsDirectory: URL = {
        return fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Openterface_Captures")
    }()
    
    override init() {
        super.init()
        // Initialize dependencies after super.init()
        self.logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
        self.videoManager = DependencyContainer.shared.resolve(VideoManagerProtocol.self)
        self.audioManager = DependencyContainer.shared.resolve(AudioManagerProtocol.self)
        setupCaptureDirectory()
        updateCaptureStatus()
        setupNotificationCenter()
    }
    
    deinit {
        stopVideoRecording()
    }
    
    // MARK: - Public Interface
    
    func takePicture() {
        guard canTakePicture else {
            logger.log(content: "Cannot take picture - video not available")
            statusMessage = "Video source not available"
            return
        }
        
        // Get current frame from video manager
        guard let currentFrame = captureCurrentFrame() else {
            logger.log(content: "Failed to capture current frame")
            statusMessage = "Failed to capture frame"
            return
        }
        
        // Save the image
        let filename = generateFilename(extension: "png")
        let fileURL = documentsDirectory.appendingPathComponent(filename)
        
        if saveImage(currentFrame, to: fileURL) {
            logger.log(content: "Picture saved to: \(fileURL.path)")
            statusMessage = "Picture saved successfully"
            
            // Show notification
            showNotification(title: "Picture Captured", 
                           message: "Saved to \(filename). Click to open folder.",
                           folderPath: documentsDirectory.path)
        } else {
            logger.log(content: "Failed to save picture")
            statusMessage = "Failed to save picture"
        }
    }
    
    func startVideoRecording() {
        guard !isRecording else {
            logger.log(content: "Recording already in progress")
            return
        }
        
        guard canTakePicture else {
            logger.log(content: "Cannot start recording - video not available")
            statusMessage = "Video source not available"
            return
        }
        
        setupVideoRecording()
    }
    
    func stopVideoRecording() {
        guard isRecording else {
            return
        }
        
        stopRecordingTimer()
        stopAudioRecording()
        isRecording = false
        
        // Get the actual recording duration for proper ending
        let actualDuration = recordingStartTime != nil ? Date().timeIntervalSince(recordingStartTime!) : 0
        
        // End the session at the final frame time
        if let assetWriter = assetWriter {
            let endTime = CMTime(value: frameCount, timescale: 30)
            assetWriter.endSession(atSourceTime: endTime)
            logger.log(content: "Session ended at frame \(frameCount), duration: \(CMTimeGetSeconds(endTime)) seconds")
        }
        
        recordingStartTime = nil
        sessionStartTime = nil
        
        guard let assetWriter = assetWriter, let recordingURL = recordingURL else {
            logger.log(content: "No asset writer or recording URL available")
            cleanupRecording()
            return
        }
        
        logger.log(content: "Starting asset writer finish writing process")
        assetWriter.finishWriting { [weak self] in
            DispatchQueue.main.async {
                self?.logger.log(content: "Asset writer finished writing")
                
                let hasAudio = self?.audioManager.isAudioEnabled == true && 
                               self?.audioManager.selectedInputDevice != nil && 
                               self?.audioManager.microphonePermissionGranted == true
                
                self?.logger.log(content: "Video \(hasAudio ? "with audio " : "")saved to: \(recordingURL.path)")
                self?.logger.log(content: "Recording duration: \(String(format: "%.2f", actualDuration)) seconds")
                self?.statusMessage = "Video \(hasAudio ? "with audio " : "")saved successfully"
                
                self?.logger.log(content: "About to show notification for video recording")
                self?.showNotification(title: "Video Recorded", 
                                     message: "Saved to \(recordingURL.lastPathComponent). Click to open folder.",
                                     folderPath: recordingURL.deletingLastPathComponent().path)
                
                self?.cleanupRecording()
            }
        }
    }
    
    func getRecordingDuration() -> TimeInterval {
        guard let startTime = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }
    
    func getSavedFilesDirectory() -> URL? {
        return documentsDirectory
    }
    
    func updateStatus() {
        updateCaptureStatus()
    }

    // MARK: - Private Methods
    
    private func setupCaptureDirectory() {
        do {
            try fileManager.createDirectory(at: documentsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.log(content: "Failed to create capture directory: \(error)")
        }
    }
    
    private func setupNotificationCenter() {
        UNUserNotificationCenter.current().delegate = self
        
        // Check current authorization status
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.logger.log(content: "Current notification authorization status: \(settings.authorizationStatus.rawValue)")
                
                switch settings.authorizationStatus {
                case .notDetermined:
                    self.logger.log(content: "Notification permission not determined - requesting permission")
                    self.requestNotificationPermissions()
                case .denied:
                    self.logger.log(content: "Notification permissions denied by user - notifications will not be shown")
                    self.logger.log(content: "User can enable notifications in System Preferences > Notifications > Openterface")
                case .authorized, .provisional, .ephemeral:
                    self.logger.log(content: "Notification permissions already granted")
                @unknown default:
                    self.logger.log(content: "Unknown notification authorization status")
                }
            }
        }
    }
    
    private func requestNotificationPermissions() {
        // Request notification permissions with all necessary options
        var options: UNAuthorizationOptions = [.alert, .sound, .badge]
        
        // Add provisional for macOS 11+
        if #available(macOS 11.0, *) {
            options.insert(.provisional)
        }
        
        UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.logger.log(content: "Failed to request notification permissions: \(error)")
                } else if granted {
                    self.logger.log(content: "Notification permissions granted")
                } else {
                    self.logger.log(content: "Notification permissions denied")
                }
            }
        }
    }
    
    private func updateCaptureStatus() {
        // Check if video is available from VideoManager
        canTakePicture = videoManager.isVideoConnected && videoManager.outputDelegate != nil
    }
    
    private func captureCurrentFrame() -> NSImage? {
        // Get the current frame from VideoOutputDelegate
        guard let outputDelegate = videoManager.outputDelegate,
              let pixelBuffer = outputDelegate.getLatestFrame() else {
            logger.log(content: "No video output delegate or latest frame available")
            return nil
        }
        
        // Convert CVPixelBuffer to CGImage
        guard let cgImage = createCGImage(from: pixelBuffer) else {
            logger.log(content: "Failed to convert pixel buffer to CGImage")
            return nil
        }
        
        // Convert CGImage to NSImage
        let image = NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
        return image
    }
    
    private func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        return cgImage
    }
    
    private func saveImage(_ image: NSImage, to url: URL) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return false
        }
        
        do {
            try pngData.write(to: url)
            return true
        } catch {
            logger.log(content: "Failed to save image: \(error)")
            return false
        }
    }
    
    private func setupVideoRecording() {
        let filename = generateFilename(extension: "mov")
        recordingURL = documentsDirectory.appendingPathComponent(filename)
        
        guard let url = recordingURL else { return }
        
        do {
            assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
            
            // Get actual dimensions from video manager if available
            let videoWidth = videoManager.dimensions.width > 0 ? Int(videoManager.dimensions.width) : 1920
            let videoHeight = videoManager.dimensions.height > 0 ? Int(videoManager.dimensions.height) : 1080
            
            // Video input setup
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2000000
                ]
            ]
            
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true
            
            if let videoInput = videoInput, assetWriter?.canAdd(videoInput) == true {
                assetWriter?.add(videoInput)
            }
            
            // Audio input setup
            setupAudioInput()
            
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight
            ]
            
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput!,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )
            
            if assetWriter?.startWriting() == true {
                recordingStartTime = Date()
                sessionStartTime = CMTime.zero
                assetWriter?.startSession(atSourceTime: sessionStartTime!)
                isRecording = true
                
                // Determine recording status message based on audio availability
                let hasAudio = audioManager.isAudioEnabled && 
                               audioManager.selectedInputDevice != nil && 
                               audioManager.microphonePermissionGranted
                statusMessage = hasAudio ? "Recording video with audio..." : "Recording video only..."
                logger.log(content: "Started video recording \(hasAudio ? "with audio" : "(video only)"), dimensions: \(videoWidth)x\(videoHeight)")
                
                if !hasAudio {
                    if !audioManager.isAudioEnabled {
                        logger.log(content: "Audio recording disabled in settings")
                    } else if audioManager.selectedInputDevice == nil {
                        logger.log(content: "No audio input device selected")
                    } else if !audioManager.microphonePermissionGranted {
                        logger.log(content: "Microphone permission not granted")
                    }
                }
                
                // Start recording timer
                startRecordingTimer()
                
                // Start audio recording
                startAudioRecording()
            } else {
                logger.log(content: "Failed to start recording")
                statusMessage = "Failed to start recording"
            }
            
        } catch {
            logger.log(content: "Failed to setup video recording: \(error)")
            statusMessage = "Failed to start recording"
        }
    }
    
    private func setupAudioInput() {
        // Check if audio is enabled, a device is selected, and microphone permission is granted
        guard audioManager.isAudioEnabled,
              audioManager.selectedInputDevice != nil,
              audioManager.microphonePermissionGranted else {
            if !audioManager.isAudioEnabled {
                logger.log(content: "Audio disabled in settings, skipping audio setup")
            } else if audioManager.selectedInputDevice == nil {
                logger.log(content: "No input device selected, skipping audio setup")
            } else if !audioManager.microphonePermissionGranted {
                logger.log(content: "Microphone permission not granted, skipping audio setup")
            }
            return
        }
        
        // Audio input settings - optimized for better performance
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput?.expectsMediaDataInRealTime = true
        
        // Configure the audio input for better performance
        if let audioInput = audioInput {
            // Set media data location to optimize for real-time processing
            audioInput.mediaDataLocation = AVAssetWriterInput.MediaDataLocation.interleavedWithMainMediaData
            
            if assetWriter?.canAdd(audioInput) == true {
                assetWriter?.add(audioInput)
                logger.log(content: "Audio input added to asset writer with optimized settings")
            } else {
                logger.log(content: "Failed to add audio input to asset writer")
            }
        }
    }
    
    private func startAudioRecording() {
        guard audioInput != nil,
              audioManager.isAudioEnabled,
              let selectedInputDevice = audioManager.selectedInputDevice else {
            logger.log(content: "Audio input not available, skipping audio recording")
            return
        }
        
        // Check microphone permission
        guard audioManager.microphonePermissionGranted else {
            logger.log(content: "Microphone permission not granted, skipping audio recording")
            return
        }
        
        logger.log(content: "Setting up audio capture session...")
        
        // Setup audio capture session
        audioCaptureSession = AVCaptureSession()
        guard let audioCaptureSession = audioCaptureSession else { 
            logger.log(content: "Failed to create audio capture session")
            return 
        }
        
        // Set session preset for better performance
        audioCaptureSession.sessionPreset = .medium
        
        // Begin configuration
        audioCaptureSession.beginConfiguration()
        
        // Find the specific audio device by name or ID
        let audioDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices
        
        logger.log(content: "Found \(audioDevices.count) audio devices")
        for device in audioDevices {
            logger.log(content: "Audio device: \(device.localizedName)")
        }
        
        // Try to find the selected device by name first
        var audioDevice = audioDevices.first { device in
            device.localizedName == selectedInputDevice.name
        }
        
        // If not found by name, use the default audio device
        if audioDevice == nil {
            audioDevice = AVCaptureDevice.default(for: .audio)
            logger.log(content: "Selected audio device not found, using default audio device")
        } else {
            logger.log(content: "Using selected audio device: \(selectedInputDevice.name)")
        }
        
        guard let audioDevice = audioDevice else {
            logger.log(content: "No audio device found for recording")
            audioCaptureSession.commitConfiguration()
            return
        }
        
        do {
            // Create audio input
            let audioInputDevice = try AVCaptureDeviceInput(device: audioDevice)
            
            if audioCaptureSession.canAddInput(audioInputDevice) {
                audioCaptureSession.addInput(audioInputDevice)
                logger.log(content: "Audio input device added to session")
            } else {
                logger.log(content: "Cannot add audio input device to session")
                audioCaptureSession.commitConfiguration()
                return
            }
            
            // Create audio output
            audioDataOutput = AVCaptureAudioDataOutput()
            audioQueue = DispatchQueue(label: "audioQueue", qos: .userInitiated)
            
            guard let audioDataOutput = audioDataOutput,
                  let audioQueue = audioQueue else {
                logger.log(content: "Failed to create audio output or queue")
                audioCaptureSession.commitConfiguration()
                return
            }
            
            // Configure audio output for better performance
            audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
            
            logger.log(content: "Audio delegate set with optimizations")
            
            if audioCaptureSession.canAddOutput(audioDataOutput) {
                audioCaptureSession.addOutput(audioDataOutput)
                logger.log(content: "Audio output added to session")
            } else {
                logger.log(content: "Cannot add audio output to session")
                audioCaptureSession.commitConfiguration()
                return
            }
            
            // Commit configuration before starting
            audioCaptureSession.commitConfiguration()
            logger.log(content: "Audio session configuration committed")
            
            // Start audio capture
            audioCaptureSession.startRunning()
            logger.log(content: "Audio recording started with device: \(audioDevice.localizedName)")
            logger.log(content: "Audio capture session running: \(audioCaptureSession.isRunning)")
            
        } catch {
            logger.log(content: "Failed to setup audio recording: \(error)")
            audioCaptureSession.commitConfiguration()
        }
    }
    
    private func stopAudioRecording() {
        logger.log(content: "Stopping audio recording...")
        
        if let audioCaptureSession = audioCaptureSession {
            if audioCaptureSession.isRunning {
                audioCaptureSession.stopRunning()
                logger.log(content: "Audio capture session stopped")
            } else {
                logger.log(content: "Audio capture session was not running")
            }
            
            self.audioCaptureSession = nil
            self.audioDataOutput = nil
            self.audioQueue = nil
            logger.log(content: "Audio recording resources cleaned up")
        } else {
            logger.log(content: "No audio capture session to stop")
        }
    }
    
    private var recordingTimer: Timer?
    private var frameCount: Int64 = 0
    
    private func startRecordingTimer() {
        frameCount = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.recordFrame()
        }
    }
    
    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
    
    private func recordFrame() {
        guard isRecording,
              let videoInput = videoInput,
              let pixelBufferAdaptor = pixelBufferAdaptor,
              videoInput.isReadyForMoreMediaData else {
            return
        }
        
        guard let outputDelegate = videoManager.outputDelegate,
              let pixelBuffer = outputDelegate.getLatestFrame() else {
            return
        }
        
        // Calculate presentation time based on frame count and fixed frame rate
        let presentationTime = CMTime(value: frameCount, timescale: 30)
        
        if pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            frameCount += 1
        } else {
            logger.log(content: "Failed to append frame to video")
        }
    }
    
    private func cleanupRecording() {
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        pixelBufferAdaptor = nil
        recordingURL = nil
        sessionStartTime = nil
        audioCaptureSession = nil
        audioDataOutput = nil
        audioQueue = nil
    }
    
    private func generateFilename(extension: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        return "Openterface_\(timestamp).\(`extension`)"
    }
    
    private func showNotification(title: String, message: String, folderPath: String? = nil) {
        logger.log(content: "showNotification called with title: \(title), message: \(message)")
        
        // Check notification authorization status first
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.logger.log(content: "Notification authorization status: \(settings.authorizationStatus.rawValue)")
                
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    // Notifications are allowed, proceed normally
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = message
                    content.sound = .default
                    
                    // Add folder path to user info if provided
                    if let folderPath = folderPath {
                        content.userInfo = ["folderPath": folderPath]
                        self.logger.log(content: "Added folder path to notification: \(folderPath)")
                    }
                    
                    // Create immediate trigger for instant delivery
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
                    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
                    
                    UNUserNotificationCenter.current().add(request) { error in
                        if let error = error {
                            self.logger.log(content: "Failed to show notification: \(error)")
                        } else {
                            self.logger.log(content: "Notification request added successfully")
                        }
                    }
                    
                case .denied:
                    self.logger.log(content: "Notifications denied - showing alternative feedback")
                    self.showAlternativeNotification(title: title, message: message, folderPath: folderPath)
                    
                case .notDetermined:
                    self.logger.log(content: "Notification permission not determined - requesting permission")
                    self.requestNotificationPermissions()
                    // Show alternative feedback for now
                    self.showAlternativeNotification(title: title, message: message, folderPath: folderPath)
                    
                @unknown default:
                    self.logger.log(content: "Unknown notification authorization status - showing alternative feedback")
                    self.showAlternativeNotification(title: title, message: message, folderPath: folderPath)
                }
            }
        }
    }
    
    private func showAlternativeNotification(title: String, message: String, folderPath: String? = nil) {
        // Show a system sound and update status message as alternative feedback
        NSSound.beep()
        
        // Update the status message to inform the user
        self.statusMessage = "\(title): \(message)"
        
        // Optionally open the folder directly
        if let folderPath = folderPath {
            let folderURL = URL(fileURLWithPath: folderPath)
            NSWorkspace.shared.open(folderURL)
            self.logger.log(content: "Opened folder as alternative to notification: \(folderPath)")
        }
        
        self.logger.log(content: "Showed alternative notification feedback: \(title)")
    }
}

// MARK: - Capture Delegates
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            // Handle audio data
            guard isRecording else {
                return
            }
            
            guard let audioInput = audioInput else {
                return
            }
            
            // Check if audio input is ready for more data before processing
            guard audioInput.isReadyForMoreMediaData else {
                // Only log this occasionally to avoid spam
                if Int.random(in: 0...99) == 0 {
                    logger.log(content: "Audio input not ready for more data (logged occasionally)")
                }
                return
            }
            
            // Get the original presentation time from the sample buffer
            let _ = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            // Calculate synchronized presentation time based on recording start
            guard let recordingStartTime = recordingStartTime else {
                logger.log(content: "No recording start time available")
                return
            }
            
            let currentTime = Date()
            let elapsedTime = currentTime.timeIntervalSince(recordingStartTime)
            let synchronizedTime = CMTime(seconds: elapsedTime, preferredTimescale: 44100)
            
            // Create a new sample buffer with synchronized timing
            var timingInfo = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: synchronizedTime,
                decodeTimeStamp: CMTime.invalid
            )
            
            var adjustedSampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleBufferOut: &adjustedSampleBuffer
            )
            
            guard status == noErr, let adjustedSampleBuffer = adjustedSampleBuffer else {
                logger.log(content: "Failed to adjust audio sample buffer timing")
                return
            }
            
            // Append the adjusted audio sample buffer
            let success = audioInput.append(adjustedSampleBuffer)
            if !success {
                // Only log this occasionally to avoid spam
                if Int.random(in: 0...19) == 0 {
                    logger.log(content: "Failed to append audio sample buffer (logged occasionally)")
                }
            }
        } else if output is AVCaptureVideoDataOutput {
            // Handle video data - this would be used for video recording
            // Implementation would depend on how the VideoManager is set up
        }
    }
}

// MARK: - Notification Delegate
extension CameraManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        logger.log(content: "Notification clicked")
        // Handle notification click
        if let folderPath = response.notification.request.content.userInfo["folderPath"] as? String {
            let folderURL = URL(fileURLWithPath: folderPath)
            NSWorkspace.shared.open(folderURL)
            logger.log(content: "Opened folder: \(folderPath)")
        } else {
            logger.log(content: "No folder path found in notification user info")
        }
        completionHandler()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        logger.log(content: "Will present notification: \(notification.request.content.title)")
        // Show notification even when app is in foreground with all presentation options
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }
}
