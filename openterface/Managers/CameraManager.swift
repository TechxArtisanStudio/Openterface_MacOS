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

class CameraManager: NSObject, ObservableObject, CameraManagerProtocol {
    private var logger: LoggerProtocol!
    private var videoManager: VideoManagerProtocol!
    
    // Published properties for UI status display
    @Published var isRecording: Bool = false
    @Published var canTakePicture: Bool = false
    @Published var statusMessage: String = "Camera ready"
    
    // Singleton instance
    static let shared = CameraManager()
    
    // Recording properties
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime: Date?
    private var recordingURL: URL?
    
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
        setupCaptureDirectory()
        updateCaptureStatus()
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
            showNotification(title: "Picture Captured", message: "Saved to \(filename)")
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
        isRecording = false
        recordingStartTime = nil
        
        assetWriter?.finishWriting { [weak self] in
            DispatchQueue.main.async {
                if let url = self?.recordingURL {
                    self?.logger.log(content: "Video saved to: \(url.path)")
                    self?.statusMessage = "Video saved successfully"
                    self?.showNotification(title: "Video Recorded", message: "Saved to \(url.lastPathComponent)")
                }
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
                assetWriter?.startSession(atSourceTime: .zero)
                isRecording = true
                recordingStartTime = Date()
                statusMessage = "Recording..."
                logger.log(content: "Started video recording with dimensions: \(videoWidth)x\(videoHeight)")
                
                // Start recording timer
                startRecordingTimer()
            }
            
        } catch {
            logger.log(content: "Failed to setup video recording: \(error)")
            statusMessage = "Failed to start recording"
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
        pixelBufferAdaptor = nil
        recordingURL = nil
    }
    
    private func generateFilename(extension: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        return "Openterface_\(timestamp).\(`extension`)"
    }
    
    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        
        NSUserNotificationCenter.default.deliver(notification)
    }
}

// MARK: - Video Capture Delegate (for future implementation)
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // This would be used to capture frames for video recording
        // Implementation would depend on how the VideoManager is set up
    }
}
