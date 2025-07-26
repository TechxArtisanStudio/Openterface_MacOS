import AVFoundation
import CoreVideo
import VideoToolbox
import AppKit

/// Delegate for handling video data output
class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    // Store the latest video frame for OCR processing
    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferQueue = DispatchQueue(label: "VideoOutputDelegate.bufferQueue", qos: .userInitiated)
    
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

        // Process the pixel buffer (e.g., pass it to another method or store it)
        processPixelBuffer(pixelBuffer)
    }

    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        // Add your custom processing logic here
    }
    
    /// Gets the latest video frame for OCR processing
    func getLatestFrame() -> CVPixelBuffer? {
        return bufferQueue.sync {
            return latestPixelBuffer
        }
    }
    
    /// Captures a specific area from the latest video frame
    func captureArea(_ rect: NSRect) -> NSImage? {
        print("🎬 VideoOutputDelegate.captureArea called with rect: \(rect)")
        
        guard let pixelBuffer = getLatestFrame() else {
            print("❌ No latest frame available for video capture")
            return nil
        }
        
        // Convert CVPixelBuffer to CGImage
        guard let cgImage = createCGImage(from: pixelBuffer) else {
            print("❌ Failed to create CGImage from pixel buffer")
            return nil
        }
        
        // Calculate the crop rectangle in image coordinates
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        
        print("🎬 Video frame dimensions: \(imageWidth) x \(imageHeight)")
        print("🎬 Requested crop rect: \(rect)")
        
        // Create crop rect and ensure it's within bounds
        let cropRect = CGRect(
            x: max(0, min(rect.minX, imageWidth - 1)),
            y: max(0, min(rect.minY, imageHeight - 1)),
            width: min(rect.width, imageWidth - max(0, rect.minX)),
            height: min(rect.height, imageHeight - max(0, rect.minY))
        )
        
        print("🎬 Calculated crop rect: \(cropRect)")
        print("🎬 Crop rect bounds check: x=\(cropRect.minX), y=\(cropRect.minY), w=\(cropRect.width), h=\(cropRect.height)")
        
        // Ensure crop rect is valid
        guard cropRect.width > 0 && cropRect.height > 0 else {
            print("❌ Invalid crop rect dimensions: \(cropRect)")
            return nil
        }
        
        // Crop the image
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            print("❌ Failed to crop CGImage with rect: \(cropRect)")
            return nil
        }
        
        let resultImage = NSImage(cgImage: croppedCGImage, size: NSSize(width: cropRect.width, height: cropRect.height))
        print("✅ Successfully captured video area. Result image size: \(resultImage.size)")
        
        return resultImage
    }
    
    /// Converts CVPixelBuffer to CGImage
    private func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        return cgImage
    }
}
