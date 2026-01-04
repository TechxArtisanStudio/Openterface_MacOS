import AVFoundation
import CoreVideo
import VideoToolbox
import AppKit

/// Delegate for handling video data output
class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private weak var videoManager: VideoManager?
    
    // Store the latest video frame for OCR processing
    private var latestPixelBuffer: CVPixelBuffer?
    // Timestamp of the last processed frame (seconds)
    private var lastProcessedTime: TimeInterval? = nil
    private let bufferQueue = DispatchQueue(label: "VideoOutputDelegate.bufferQueue", qos: .userInitiated)
    
    /// Initializes the video output delegate with a reference to the video manager
    /// - Parameter videoManager: The VideoManager instance for accessing active display detection
    init(videoManager: VideoManager) {
        self.videoManager = videoManager
        super.init()
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // Verify and set attachments for the pixel buffer
        let transferFunctionKey = kCVImageBufferTransferFunction_ITU_R_709_2
        let yCbCrMatrixKey = kCVImageBufferYCbCrMatrix_ITU_R_709_2

        // Check if the transfer function key is already set
        let existingTransferFunctionAttachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil)
        if existingTransferFunctionAttachment == nil {
            CVBufferSetAttachment(pixelBuffer,
                                  kCVImageBufferTransferFunctionKey,
                                  transferFunctionKey as CFString,
                                  .shouldPropagate)
        }

        // Check if the YCbCr matrix key is already set
        let existingYCbCrMatrixAttachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
        if existingYCbCrMatrixAttachment == nil {
            CVBufferSetAttachment(pixelBuffer,
                                  kCVImageBufferYCbCrMatrixKey,
                                  yCbCrMatrixKey as CFString,
                                  .shouldPropagate)
        }

        // Store the latest frame for OCR processing
        bufferQueue.async { [weak self] in
            self?.latestPixelBuffer = pixelBuffer
        }

        // Process the pixel buffer using the sample buffer's presentation timestamp
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        processPixelBuffer(pixelBuffer, timestamp: timestamp)
    }
    
    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let currentTime = CMTimeGetSeconds(timestamp)
        guard !currentTime.isNaN else { return }

        // Respect user setting: only run active resolution checking when enabled
        if !UserSettings.shared.doActiveResolutionCheck {
            return
        }

        // Use a shorter interval for the very first processing (0.5s),
        // then a 3s interval for subsequent processing
        let interval: TimeInterval = (lastProcessedTime == nil) ? 0.5 : 3.0
        if let last = lastProcessedTime, currentTime - last < interval {
            return
        }

        if let cgImage = createCGImage(from: pixelBuffer) {
            let width = cgImage.width
            let height = cgImage.height

            // Detect active (non-black) area within the frame using VideoManager
            var userInfo: [String: Any] = ["width": width, "height": height, "timestamp": currentTime]
            if let activeRect = videoManager?.detectActiveRect(from: cgImage) {
                userInfo["activeX"] = Int(activeRect.origin.x)
                userInfo["activeY"] = Int(activeRect.origin.y)
                userInfo["activeWidth"] = Int(activeRect.size.width)
                userInfo["activeHeight"] = Int(activeRect.size.height)
            } else {
                logger.log(content: "ℹ️ No active (non-black) area detected at \(currentTime)s")
            }

            NotificationCenter.default.post(name: Notification.Name("checkActiveResolution"), object: nil, userInfo: userInfo)

            lastProcessedTime = currentTime
        } else {
            logger.log(content: "❌ Failed to create CGImage for frame analysis at \(currentTime)s")
        }
    }

    /// Gets the latest video frame for OCR processing
    func getLatestFrame() -> CVPixelBuffer? {
        return bufferQueue.sync {
            return latestPixelBuffer
        }
    }
    
    /// Captures a specific area from the latest video frame
    func captureArea(_ rect: NSRect) -> NSImage? {
        logger.log(content: "🎬 VideoOutputDelegate.captureArea called with rect: \(rect)")
        
        guard let pixelBuffer = getLatestFrame() else {
            logger.log(content: "❌ No latest frame available for video capture")
            return nil
        }
        
        // Convert CVPixelBuffer to CGImage
        guard let cgImage = createCGImage(from: pixelBuffer) else {
            logger.log(content: "❌ Failed to create CGImage from pixel buffer")
            return nil
        }
        
        // Calculate the crop rectangle in image coordinates
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        
        logger.log(content: "🎬 Video frame dimensions: \(imageWidth) x \(imageHeight)")
        logger.log(content: "🎬 Requested crop rect: \(rect)")
        
        // Create crop rect and ensure it's within bounds
        let cropRect = CGRect(
            x: max(0, min(rect.minX, imageWidth - 1)),
            y: max(0, min(rect.minY, imageHeight - 1)),
            width: min(rect.width, imageWidth - max(0, rect.minX)),
            height: min(rect.height, imageHeight - max(0, rect.minY))
        )
        
        logger.log(content: "🎬 Calculated crop rect: \(cropRect)")
        logger.log(content: "🎬 Crop rect bounds check: x=\(cropRect.minX), y=\(cropRect.minY), w=\(cropRect.width), h=\(cropRect.height)")
        
        // Ensure crop rect is valid
        guard cropRect.width > 0 && cropRect.height > 0 else {
            logger.log(content: "❌ Invalid crop rect dimensions: \(cropRect)")
            return nil
        }
        
        // Crop the image
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            logger.log(content: "❌ Failed to crop CGImage with rect: \(cropRect)")
            return nil
        }
        
        let resultImage = NSImage(cgImage: croppedCGImage, size: NSSize(width: cropRect.width, height: cropRect.height))
        logger.log(content: "✅ Successfully captured video area. Result image size: \(resultImage.size)")
        
        return resultImage
    }
    
    /// Converts CVPixelBuffer to CGImage
    private func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        return cgImage
    }
}
