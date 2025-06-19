import AVFoundation
import CoreVideo

/// Delegate for handling video data output
class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
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

        // Process the pixel buffer (e.g., pass it to another method or store it)
        processPixelBuffer(pixelBuffer)
    }

    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        // Add your custom processing logic here

    }
}
