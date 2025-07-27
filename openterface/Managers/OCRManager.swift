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

import Foundation
import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreGraphics
import Vision

private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)

@available(macOS 12.3, *)
class OCRManager: OCRManagerProtocol {
    static let shared = OCRManager()
    
    // MARK: - Protocol-based Dependencies (Lazy to avoid circular dependency)
    private lazy var tipLayerManager: TipLayerManagerProtocol = DependencyContainer.shared.resolve(TipLayerManagerProtocol.self)
    private lazy var videoManager: VideoManagerProtocol = DependencyContainer.shared.resolve(VideoManagerProtocol.self)
    private lazy var clipboardManager: ClipboardManagerProtocol = ClipboardManager.shared
    
    // MARK: - Text Selection Properties
    private var textSelectionOverlay: TextSelectionOverlayView?
    private var selectedArea: NSRect?
    var isTextSelectionActive: Bool {
        return textSelectionOverlay != nil && AppStatus.isAreaOCRing
    }
    
    private init() {}
    
    // MARK: - OCRManagerProtocol Implementation
    
    func performOCR(on image: CGImage, completion: @escaping (OCRResult) -> Void) {
        logger.log(content: "🔍 Starting OCR on image with dimensions: \(image.width)x\(image.height)")
        
        // Enhance the image for better OCR results
        let enhancedImage = enhanceImageForOCR(image)
        
        let textDetectionRequest = VNRecognizeTextRequest { [weak self] request, error in
            self?.handleDetectionResult(request: request, error: error, completion: completion)
        }
        
        // Configure for better multiline text detection
        textDetectionRequest.recognitionLevel = .accurate
        textDetectionRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-GB", "en-US"]
        textDetectionRequest.usesLanguageCorrection = true
        textDetectionRequest.minimumTextHeight = 0.008 // Lower threshold for small text
        
        // Enable automatic language detection for better multiline support
        if #available(macOS 13.0, *) {
            textDetectionRequest.automaticallyDetectsLanguage = true
        } else {
            // Fallback on earlier versions
        }
        
        // Configure for better line detection
        if #available(macOS 13.0, *) {
            textDetectionRequest.revision = VNRecognizeTextRequestRevision3
        }
        
        let requests = [textDetectionRequest]
        let imageRequestHandler = VNImageRequestHandler(cgImage: enhancedImage, orientation: .up, options: [:])
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try imageRequestHandler.perform(requests)
            } catch let error {
                logger.log(content: "Failed to perform text detection on image: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failed(error))
                }
            }
        }
    }
    
    func performOCR(on rect: NSRect?, completion: @escaping (OCRResult) -> Void) {
        guard let image = captureScreenArea(rect) else {
            logger.log(content: "Failed to capture screen area for OCR")
            completion(.failed(OCRError.screenCaptureFailure))
            return
        }
        
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logger.log(content: "Failed to convert NSImage to CGImage for OCR")
            completion(.failed(OCRError.imageConversionFailure))
            return
        }
        
        performOCR(on: cgImage) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self?.copyTextToClipboard(text: text)
                    let lineCount = text.components(separatedBy: .newlines).count
                    let message = lineCount > 1 ? "Multiline Text Copied (\(lineCount) lines)" : "Text Copied to Clipboard"
                    self?.showTipMessage(message)
                case .noTextFound:
                    self?.showTipMessage("No Text Found")
                case .failed(_):
                    self?.showTipMessage("OCR Failed")
                }
                completion(result)
            }
        }
    }
    
    func captureScreenArea(_ rect: NSRect?) -> NSImage? {
        logger.log(content: "🎬 captureScreenArea called with rect: \(String(describing: rect))")
        
        let captureRect: NSRect
        
        if let rect = rect {
            captureRect = rect
            logger.log(content: "🎬 Using provided rect: \(captureRect)")
        } else if let selectedArea = self.selectedArea {
            captureRect = selectedArea
            logger.log(content: "🎬 Using selected area: \(captureRect)")
        } else {
            // Use a default area if nothing is selected
            captureRect = NSRect(x: 0, y: 0, width: 500, height: 500)
            logger.log(content: "🎬 Using default rect: \(captureRect)")
        }
        
        logger.log(content: "🎬 Final capture rect: \(captureRect)")
        
        // Try to capture from the video feed first
        if let videoImage = captureFromVideoFeed(captureRect) {
            logger.log(content: "Captured from video feed: \(captureRect)")
            return videoImage
        }
        
        // Fallback to window capture if video capture fails
        if let mainWindow = NSApplication.shared.mainWindow,
           let windowImage = captureFromWindow(mainWindow, rect: captureRect) {
            logger.log(content: "Captured from window (fallback): \(captureRect)")
            return windowImage
        }
        
        // Final fallback to screen capture
        let screenHeight = Int(NSScreen.main?.frame.height ?? 0)
        let y = screenHeight - Int(captureRect.minY) - Int(captureRect.height)
        
        let bounds = CGRect(
            x: Int(captureRect.minX),
            y: y,
            width: Int(captureRect.width),
            height: Int(captureRect.height)
        )
        
        guard let screenShot = CGWindowListCreateImage(bounds, .optionOnScreenOnly, kCGNullWindowID, .boundsIgnoreFraming) else {
            logger.log(content: "Failed to create screen capture image")
            return nil
        }
        
        // Scale down the image for better OCR performance
        let scaledImage = scaleImageByHalf(screenShot)
        let finalImage = NSImage(cgImage: scaledImage, size: NSSize.zero)
        logger.log(content: "Captured from screen (final fallback): \(captureRect)")
        return finalImage
    }
    
    func performOCROnSelectedArea(completion: @escaping (OCRResult) -> Void) {
        guard let selectedArea = self.selectedArea else {
            logger.log(content: "❌ No area selected for OCR")
            // Restore cursor to normal state if no area selected
            DispatchQueue.main.async {
                NSCursor.arrow.set()
            }
            completion(.failed(OCRError.screenCaptureFailure))
            return
        }
        
        logger.log(content: "performOCROnSelectedArea called with selectedArea: \(selectedArea)")
        
        // Check if the selected area is too small for reliable OCR
        let areaSize = selectedArea.width * selectedArea.height
        if areaSize < 1000 { // Less than roughly 32x32 pixels
            logger.log(content: "⚠️ Selected area might be too small for reliable OCR: \(selectedArea.width)x\(selectedArea.height) = \(areaSize) pixels")
            showTipMessage("Selected area is small - try selecting a larger area for better OCR results")
        }
        
        // Since we're working directly with video coordinates now, 
        // we can directly capture from the video feed using the selected area
        logger.log(content: "📹 Capturing video area: \(selectedArea)")
        if let videoImage = captureFromVideoFeed(selectedArea) {
            guard let cgImage = videoImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                logger.log(content: "Failed to convert captured video image to CGImage for OCR")
                // Restore cursor to normal state if conversion fails
                DispatchQueue.main.async {
                    NSCursor.arrow.set()
                }
                completion(.failed(OCRError.imageConversionFailure))
                return
            }
            
            logger.log(content: "🔍 Starting multiline OCR on captured area with dimensions: \(cgImage.width)x\(cgImage.height)")
            performOCR(on: cgImage) { [weak self] result in
                DispatchQueue.main.async {
                    // Restore cursor to normal state after OCR completes
                    NSCursor.arrow.set()
                    
                    switch result {
                    case .success(let text):
                        self?.copyTextToClipboard(text: text)
                        let lineCount = text.components(separatedBy: .newlines).count
                        let displayText = lineCount > 1 ? "\(lineCount) lines copied" : text
                        self?.showTipMessage("✅ Text Copied: \(displayText)")
                        logger.log(content: "✅ Multiline OCR successful (\(lineCount) lines): \(text)")
                    case .noTextFound:
                        self?.showTipMessage("⚠️ No Text Found - try selecting a larger area or area with clearer text")
                        logger.log(content: "⚠️ OCR completed but no text found")
                    case .failed(let error):
                        self?.showTipMessage("❌ OCR Failed")
                        logger.log(content: "❌ OCR failed: \(error.localizedDescription)")
                    }
                    completion(result)
                }
            }
        } else {
            logger.log(content: "❌ Failed to capture video area for OCR")
            // Restore cursor to normal state if capture fails
            DispatchQueue.main.async {
                NSCursor.arrow.set()
            }
            completion(.failed(OCRError.screenCaptureFailure))
        }
    }
    
    func handleAreaSelectionComplete() {
        logger.log(content: "Handling area selection completion")
        cancelAreaSelection()
    }
    
    func startAreaSelection() {
        // Force reset the state first to handle any stuck states
        AppStatus.isAreaOCRing = false
        textSelectionOverlay?.removeFromSuperview()
        textSelectionOverlay = nil
        selectedArea = nil
        
        logger.log(content: "Starting area selection - state reset")
        
        guard !isTextSelectionActive else {
            logger.log(content: "Text selection already active after reset - this should not happen")
            return
        }
        
        // Show tip before starting text selection
        DispatchQueue.main.async { [weak self] in
            if let window = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow ?? NSApp.mainWindow {
                self?.tipLayerManager.showTip(
                    text: "Select multiline text area to copy from target",
                    yOffset: 1.5,
                    window: window
                )
            }
        }
        
        // Wait a moment to let user read the tip, then start text selection
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            // Try immediate execution first
            self?.showTextSelectionOverlay()
            
            // If that fails, try again after a short delay to ensure window is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if self?.textSelectionOverlay == nil {
                    self?.showTextSelectionOverlay()
                }
            }
        }
    }
    
    func cancelAreaSelection() {
        DispatchQueue.main.async { [weak self] in
            // Clean up overlay and its key monitor
            if let overlay = self?.textSelectionOverlay {
                // The deinit will clean up the key monitor automatically
                overlay.removeFromSuperview()
            }
            self?.textSelectionOverlay = nil
            self?.selectedArea = nil
            AppStatus.isAreaOCRing = false
            logger.log(content: "Text selection cancelled and OCR state reset")
        }
    }
    
    // MARK: - Private Methods
    
    /// Capture image content from the video feed within the given rect
    private func captureFromVideoFeed(_ rect: NSRect) -> NSImage? {
        logger.log(content: "📹 captureFromVideoFeed called with rect: \(rect)")
        
        // Get the video manager as concrete type to access outputDelegate
        guard let concreteVideoManager = videoManager as? VideoManager,
              let outputDelegate = concreteVideoManager.outputDelegate else {
            logger.log(content: "❌ Video output delegate not available")
            return nil
        }
        
        // Convert area selection coordinates to video coordinates
        let videoRect = convertAreaSelectionToVideoCoordinates(rect)
        
        // Check if converted rect is valid
        guard videoRect.width > 0 && videoRect.height > 0 else {
            logger.log(content: "❌ Invalid video rect after conversion: \(videoRect)")
            return nil
        }
        
        // Get video dimensions for validation
        let videoDimensions = videoManager.dimensions
        let videoWidth = CGFloat(videoDimensions.width)
        let videoHeight = CGFloat(videoDimensions.height)
        
        logger.log(content: "📹 Video dimensions: \(videoWidth) x \(videoHeight)")
        
        // Validate that the rect is within video bounds
        guard videoRect.minX >= 0 && videoRect.minY >= 0 && 
              videoRect.maxX <= videoWidth && videoRect.maxY <= videoHeight else {
            logger.log(content: "❌ Video rect out of bounds: \(videoRect) for video size: \(videoWidth)x\(videoHeight)")
            return nil
        }
        
        logger.log(content: "📹 Calling outputDelegate.captureArea with videoRect: \(videoRect)")
        let capturedImage = outputDelegate.captureArea(videoRect)
        
        if let image = capturedImage {
            logger.log(content: "✅ Successfully captured from video feed. Image size: \(image.size)")
        } else {
            logger.log(content: "❌ Failed to capture from video feed")
        }
        
        return capturedImage
    }
    
    /// Convert coordinates from area selection overlay to video frame coordinates
    private func convertAreaSelectionToVideoCoordinates(_ rect: NSRect) -> NSRect {
        // Since the overlay is positioned directly over PlayerView,
        // the rect coordinates are already in PlayerView coordinate space
        // We just need to convert from PlayerView space to video space
        
        // Get video dimensions
        let videoDimensions = videoManager.dimensions
        let videoWidth = CGFloat(videoDimensions.width)
        let videoHeight = CGFloat(videoDimensions.height)
        
        // Find the PlayerView to get its size
        guard let mainWindow = NSApplication.shared.mainWindow,
              let contentView = mainWindow.contentView else {
            return rect
        }
        
        var playerView: NSView?
        func findPlayerView(in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("PlayerView") {
                return view
            }
            for subview in view.subviews {
                if let found = findPlayerView(in: subview) {
                    return found
                }
            }
            return nil
        }
        
        playerView = findPlayerView(in: contentView)
        
        guard let playerView = playerView else {
            return rect
        }
        
        let playerSize = playerView.bounds.size
        
        // Calculate aspect ratios to determine video scaling method
        let videoAspectRatio = videoWidth / videoHeight
        let playerAspectRatio = playerSize.width / playerSize.height
        
        var actualVideoDisplaySize: CGSize
        var videoOffsetInPlayer: CGPoint
        
        if abs(videoAspectRatio - playerAspectRatio) < 0.01 {
            // Aspect ratios match - video fills player exactly
            actualVideoDisplaySize = playerSize
            videoOffsetInPlayer = CGPoint(x: 0, y: 0)
        } else if videoAspectRatio > playerAspectRatio {
            // Video is wider - aspect fit with letterboxing top/bottom
            actualVideoDisplaySize = CGSize(
                width: playerSize.width,
                height: playerSize.width / videoAspectRatio
            )
            videoOffsetInPlayer = CGPoint(
                x: 0,
                y: (playerSize.height - actualVideoDisplaySize.height) / 2
            )
        } else {
            // Video is taller - aspect fit with letterboxing left/right
            actualVideoDisplaySize = CGSize(
                width: playerSize.height * videoAspectRatio,
                height: playerSize.height
            )
            videoOffsetInPlayer = CGPoint(
                x: (playerSize.width - actualVideoDisplaySize.width) / 2,
                y: 0
            )
        }
        
        // Adjust rect coordinates relative to the actual video display area
        let adjustedRect = NSRect(
            x: rect.minX - videoOffsetInPlayer.x,
            y: rect.minY - videoOffsetInPlayer.y,
            width: rect.width,
            height: rect.height
        )
        
        // Clamp to video display area
        let clampedAdjustedRect = NSRect(
            x: max(0, adjustedRect.minX),
            y: max(0, adjustedRect.minY),
            width: min(adjustedRect.width, actualVideoDisplaySize.width - max(0, adjustedRect.minX)),
            height: min(adjustedRect.height, actualVideoDisplaySize.height - max(0, adjustedRect.minY))
        )
        
        // Scale from displayed video size to actual video coordinates
        let scaleX = videoWidth / actualVideoDisplaySize.width
        let scaleY = videoHeight / actualVideoDisplaySize.height
        
        // Convert to video coordinates with scaling
        let scaledRect = NSRect(
            x: clampedAdjustedRect.minX * scaleX,
            y: clampedAdjustedRect.minY * scaleY,
            width: clampedAdjustedRect.width * scaleX,
            height: clampedAdjustedRect.height * scaleY
        )
        
        // Apply Y-axis flip for video coordinates (video has origin at top-left, macOS at bottom-left)
        let videoRect = NSRect(
            x: scaledRect.minX,
            y: videoHeight - scaledRect.maxY, // Flip Y coordinate
            width: scaledRect.width,
            height: scaledRect.height
        )
        
        // Final bounds check and clamp
        let finalClampedRect = NSRect(
            x: min(max(0, videoRect.minX), videoWidth - 1),
            y: min(max(0, videoRect.minY), videoHeight - 1),
            width: min(max(1, videoRect.width), videoWidth - videoRect.minX),
            height: min(max(1, videoRect.height), videoHeight - videoRect.minY)
        )
        
        return finalClampedRect
    }
    
    private func convertWithContentView(_ rect: NSRect, contentView: NSView) -> NSRect {
        // Get video dimensions from the video manager
        let videoDimensions = videoManager.dimensions
        let videoWidth = CGFloat(videoDimensions.width)
        let videoHeight = CGFloat(videoDimensions.height)
        
        // Get the content view size
        let contentSize = contentView.bounds.size
        
        // Calculate scaling factors - but consider aspect ratio preservation
        let scaleX = videoWidth / contentSize.width
        let scaleY = videoHeight / contentSize.height
        
        // Use the smaller scale to maintain aspect ratio (letterboxing)
        let scale = min(scaleX, scaleY)
        
        // Calculate the actual video display area within the content view
        let scaledVideoWidth = videoWidth / scale
        let scaledVideoHeight = videoHeight / scale
        
        // Calculate offsets for centered video
        let offsetX = (contentSize.width - scaledVideoWidth) / 2
        let offsetY = (contentSize.height - scaledVideoHeight) / 2
        
        // Adjust rect coordinates relative to the video display area
        let adjustedRect = NSRect(
            x: max(0, rect.minX - offsetX),
            y: max(0, rect.minY - offsetY),
            width: rect.width,
            height: rect.height
        )
        
        // Convert and scale the rectangle to video coordinates
        let convertedRect = NSRect(
            x: adjustedRect.minX * scale,
            y: adjustedRect.minY * scale,
            width: adjustedRect.width * scale,
            height: adjustedRect.height * scale
        )
        
         // Apply Y-axis flip for video coordinates (video has origin at top-left, macOS at bottom-left)
         let flippedRect = NSRect(
             x: convertedRect.minX,
             y: videoHeight - convertedRect.maxY, // Flip Y coordinate
             width: convertedRect.width,
             height: convertedRect.height
         )
        
         // Clamp to video bounds
         let clampedRect = NSRect(
             x: min(max(0, flippedRect.minX), videoWidth - 1),
             y: min(max(0, flippedRect.minY), videoHeight - 1),
             width: min(flippedRect.width, videoWidth - flippedRect.minX),
             height: min(flippedRect.height, videoHeight - flippedRect.minY)
         )
        
        return clampedRect
    }
    
    /// Capture image content from a specific window within the given rect
    private func captureFromWindow(_ window: NSWindow, rect: NSRect) -> NSImage? {
        guard let contentView = window.contentView else {
            logger.log(content: "Window has no content view")
            return nil
        }
        
        // Use the original rect coordinates for window capture (no conversion needed)
        let windowRect = rect
        
        // Ensure the rect is within the content view bounds
        let contentBounds = contentView.bounds
        let clampedRect = NSRect(
            x: max(0, min(windowRect.minX, contentBounds.width - 1)),
            y: max(0, min(windowRect.minY, contentBounds.height - 1)),
            width: min(windowRect.width, contentBounds.width - max(0, windowRect.minX)),
            height: min(windowRect.height, contentBounds.height - max(0, windowRect.minY))
        )
        
        guard clampedRect.width > 0 && clampedRect.height > 0 else {
            logger.log(content: "Capture rect is outside window bounds: \(windowRect) vs content bounds: \(contentBounds)")
            return nil
        }
        
        // Create bitmap representation of the content view area
        guard let bitmapRep = contentView.bitmapImageRepForCachingDisplay(in: clampedRect) else {
            logger.log(content: "Failed to create bitmap representation")
            return nil
        }
        
        contentView.cacheDisplay(in: clampedRect, to: bitmapRep)
        
        let image = NSImage(size: clampedRect.size)
        image.addRepresentation(bitmapRep)
        
        logger.log(content: "Captured window content area: \(clampedRect)")
        return image
    }

    private func handleDetectionResult(request: VNRequest?, error: Error?, completion: @escaping (OCRResult) -> Void) {
        if let error = error {
            logger.log(content: "Text detection failed with error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                completion(.failed(error))
            }
            return
        }
        
        guard let results = request?.results, !results.isEmpty else {
            logger.log(content: "Text detection completed: No text found in image")
            DispatchQueue.main.async {
                completion(.noTextFound)
            }
            return
        }
        
        logger.log(content: "🔍 Found \(results.count) text observation(s)")
        
        // Collect text observations with their positions for multiline support
        var textObservations: [(text: String, boundingBox: CGRect, confidence: Float)] = []
        
        for result in results {
            if let observation = result as? VNRecognizedTextObservation {
                // Get the best candidate for each observation
                if let topCandidate = observation.topCandidates(1).first {
                    let boundingBox = observation.boundingBox
                    textObservations.append((
                        text: topCandidate.string,
                        boundingBox: boundingBox,
                        confidence: topCandidate.confidence
                    ))
                    logger.log(content: "🔍 Text observation: '\(topCandidate.string)' at \(boundingBox) (confidence: \(topCandidate.confidence))")
                }
            }
        }
        
        guard !textObservations.isEmpty else {
            DispatchQueue.main.async {
                completion(.noTextFound)
            }
            return
        }
        
        // Sort observations by vertical position (top to bottom)
        // Vision framework uses normalized coordinates with origin at bottom-left
        // So we sort by descending Y coordinate to get top-to-bottom order
        textObservations.sort { $0.boundingBox.maxY > $1.boundingBox.maxY }
        
        // Group observations into lines based on Y position overlap
        var lines: [[String]] = []
        var currentLine: [String] = []
        var lastY: CGFloat = -1
        
        for observation in textObservations {
            let currentY = observation.boundingBox.midY
            
            // If this is the first observation or the Y position differs significantly (new line)
            if lastY == -1 || abs(currentY - lastY) > 0.02 { // 2% threshold for line detection
                if !currentLine.isEmpty {
                    lines.append(currentLine)
                    currentLine = []
                }
                lastY = currentY
            }
            
            currentLine.append(observation.text)
        }
        
        // Add the last line if not empty
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        
        // Combine lines into final multiline text
        var finalText = ""
        for (index, line) in lines.enumerated() {
            // Sort words in each line by X position (left to right)
            let sortedObservationsInLine = textObservations.filter { obs in
                line.contains(obs.text)
            }.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            
            let lineText = sortedObservationsInLine.map { $0.text }.joined(separator: " ")
            finalText += lineText
            
            // Add newline if not the last line
            if index < lines.count - 1 {
                finalText += "\n"
            }
        }
        
        // Remove any duplicate spaces or extra whitespace
        finalText = finalText.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !finalText.isEmpty {
            logger.log(content: "🔍 Final multiline text result:\n\(finalText)")
            DispatchQueue.main.async {
                completion(.success(finalText))
            }
        } else {
            DispatchQueue.main.async {
                completion(.noTextFound)
            }
        }
    }
    
    /// Enhance image for better OCR results
    private func enhanceImageForOCR(_ originalImage: CGImage) -> CGImage {
        let width = originalImage.width
        let height = originalImage.height
        
        // Adjust upscaling criteria for better multiline text detection
        // Consider both dimensions and total area for better decision making
        let totalPixels = width * height
        let shouldUpscale = width < 300 || height < 100 || totalPixels < 50000
        let scaleFactor: CGFloat = shouldUpscale ? 2.5 : 1.0
        
        let newWidth = Int(CGFloat(width) * scaleFactor)
        let newHeight = Int(CGFloat(height) * scaleFactor)
        
        logger.log(content: "🔍 Enhancing image for multiline OCR: \(width)x\(height) -> \(newWidth)x\(newHeight) (scale: \(scaleFactor))")
        
        let colorSpace = originalImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
                  data: nil,
                  width: newWidth,
                  height: newHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            logger.log(content: "⚠️ Failed to create context for image enhancement, using original")
            return originalImage
        }
        
        // Configure for optimal text rendering
        context.interpolationQuality = .high
        context.setShouldAntialias(false) // Better for text clarity
        context.setShouldSmoothFonts(false) // Preserve text edges
        
        // Fill with white background to improve contrast for text
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        
        // Set blend mode for better text contrast
        context.setBlendMode(.multiply)
        
        // Draw the original image scaled up
        context.draw(originalImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        
        guard let enhancedImage = context.makeImage() else {
            logger.log(content: "⚠️ Failed to create enhanced image, using original")
            return originalImage
        }
        
        // Log enhancement details
        if shouldUpscale {
            logger.log(content: "🔍 Image enhanced for multiline OCR: upscaled \(scaleFactor)x, optimized contrast")
        } else {
            logger.log(content: "🔍 Image processed for multiline OCR: contrast optimized")
        }
        
        return enhancedImage
    }
    
    private func scaleImageByHalf(_ originalImage: CGImage) -> CGImage {
        let originalWidth = originalImage.width
        let originalHeight = originalImage.height
        let bitsPerComponent = originalImage.bitsPerComponent
        let colorSpace = originalImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = originalImage.bitmapInfo.rawValue
        
        guard let context = CGContext(
            data: nil,
            width: originalWidth / 2,
            height: originalHeight / 2,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            logger.log(content: "Unable to create graphics context for image scaling")
            return originalImage
        }
        
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.draw(originalImage, in: CGRect(x: 0, y: 0, width: CGFloat(originalWidth) / 2, height: CGFloat(originalHeight) / 2))
        
        return context.makeImage() ?? originalImage
    }
    
    private func copyTextToClipboard(text: String) {
        // Use the ClipboardManager instead of direct pasteboard access
        clipboardManager.copyToClipboard(text)
        logger.log(content: "Copied text to clipboard via ClipboardManager: \(text)")
    }
    
    private func showTipMessage(_ message: String) {
        tipLayerManager.showTip(text: message, yOffset: 1.5, window: NSApp.mainWindow)
    }
    
    // MARK: - Text Selection UI
    
    private func showTextSelectionOverlay() {
        logger.log(content: "showTextSelectionOverlay called")
        
        // Try multiple approaches to get the main window
        var mainWindow: NSWindow?
        var contentView: NSView?
        
        // First try: NSApplication.shared.mainWindow
        if let window = NSApplication.shared.mainWindow {
            mainWindow = window
            contentView = window.contentView
        }
        
        // Second try: Key window
        if mainWindow == nil, let window = NSApplication.shared.keyWindow {
            mainWindow = window
            contentView = window.contentView
        }
        
        // Third try: First window in windows array
        if mainWindow == nil, let window = NSApplication.shared.windows.first {
            mainWindow = window
            contentView = window.contentView
        }
        
        // Fourth try: Use NSApp.mainWindow
        if mainWindow == nil, let window = NSApp.mainWindow {
            mainWindow = window
            contentView = window.contentView
        }
        
        guard let _ = mainWindow, let view = contentView else {
            logger.log(content: "Could not get application window for text selection")
            showTipMessage("Cannot access main window for text selection")
            return
        }
        
        // Capture the current video frame
        guard let currentVideoImage = captureCurrentVideoFrame() else {
            logger.log(content: "Failed to capture current video frame for text selection")
            showTipMessage("Failed to capture video frame")
            return
        }
        
        AppStatus.isAreaOCRing = true
        
        let overlayView = TextSelectionOverlayView(
            videoImage: currentVideoImage,
            onTextSelected: { [weak self] selectedRect in
                self?.selectedArea = selectedRect
                self?.performOCROnSelectedArea { _ in
                    self?.handleAreaSelectionComplete()
                }
            },
            onCancel: { [weak self] in
                self?.cancelAreaSelection()
            }
        )
        
        // Set overlay properties to ensure it's always on top
        overlayView.frame = view.bounds
        overlayView.autoresizingMask = [.width, .height]
        overlayView.wantsLayer = false
        overlayView.alphaValue = 1.0
        overlayView.isHidden = false
        overlayView.canDrawSubviewsIntoLayer = false // Prevent drawing issues
        

        
        // Remove any existing overlay views first
        view.subviews.forEach { subview in
            if subview is TextSelectionOverlayView {
                subview.removeFromSuperview()
            }
        }
        
        // Find the PlayerView within the content view hierarchy to position overlay correctly
        var playerView: NSView?
        func findPlayerView(in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("PlayerView") {
                return view
            }
            for subview in view.subviews {
                if let found = findPlayerView(in: subview) {
                    return found
                }
            }
            return nil
        }
        
        playerView = findPlayerView(in: view)
        
        if let playerView = playerView {
            // Position overlay directly as a subview of PlayerView for perfect alignment
            overlayView.frame = playerView.bounds
            overlayView.autoresizingMask = [.width, .height] // Resize with PlayerView
            
            // Add overlay directly to PlayerView instead of content view
            playerView.addSubview(overlayView, positioned: .above, relativeTo: nil)
        } else {
            // Fallback to full content view if PlayerView not found
            overlayView.frame = view.bounds
            overlayView.autoresizingMask = [.width, .height]
            
            // Add overlay to the main window's content view, positioned above ALL other views
            view.addSubview(overlayView, positioned: .above, relativeTo: nil)
        }
        
        // Immediately force display after adding to superview
        overlayView.setNeedsDisplay(overlayView.bounds)
        overlayView.needsDisplay = true
        overlayView.display()
        
        self.textSelectionOverlay = overlayView
        
        // Force the overlay to become first responder and trigger immediate draw
        DispatchQueue.main.async {
            // Ensure the overlay can become first responder
            if overlayView.acceptsFirstResponder {
                let success = overlayView.window?.makeFirstResponder(overlayView) ?? false
                logger.log(content: "First responder status: \(success)")
                
                // If making first responder failed, try again after a short delay
                if !success {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let retrySuccess = overlayView.window?.makeFirstResponder(overlayView) ?? false
                        logger.log(content: "Retry first responder status: \(retrySuccess)")
                    }
                }
            }
            
            // Disable layer backing to ensure draw() method is called
            if overlayView.wantsLayer {
                overlayView.wantsLayer = false
            }
            
            // Force drawing
            overlayView.setNeedsDisplay(overlayView.bounds)
            overlayView.needsDisplay = true
            overlayView.needsLayout = true
            overlayView.layout()
            overlayView.layoutSubtreeIfNeeded()
            overlayView.display()
            overlayView.displayIfNeeded()
            
            // Force window to update and display
            if let window = overlayView.window {
                window.displayIfNeeded()
                window.viewsNeedDisplay = true
            }
        }
        
        // Force immediate layout and display
        overlayView.needsLayout = true
        overlayView.layout()
        
        logger.log(content: "✅ Text selection overlay displayed with video frame")
    }
    
    private func captureCurrentVideoFrame() -> NSImage? {
        // Get the video manager as concrete type to access outputDelegate
        guard let concreteVideoManager = videoManager as? VideoManager,
              let outputDelegate = concreteVideoManager.outputDelegate else {
            logger.log(content: "❌ Video output delegate not available for frame capture")
            return nil
        }
        
        // Get video dimensions
        let videoDimensions = videoManager.dimensions
        let videoWidth = CGFloat(videoDimensions.width)
        let videoHeight = CGFloat(videoDimensions.height)
        
        // Capture the entire video frame
        let fullVideoRect = NSRect(x: 0, y: 0, width: videoWidth, height: videoHeight)
        
        logger.log(content: "📹 Capturing full video frame: \(fullVideoRect)")
        let capturedImage = outputDelegate.captureArea(fullVideoRect)
        
        if let image = capturedImage {
            logger.log(content: "✅ Successfully captured full video frame. Image size: \(image.size)")
            
            // Additional validation
            if image.size.width > 0 && image.size.height > 0 {
                logger.log(content: "✅ Video image validation passed: \(image.size.width)x\(image.size.height)")
                
                // Test if the image has valid representations
                if !image.representations.isEmpty {
                    logger.log(content: "✅ Video image has \(image.representations.count) representation(s)")
                } else {
                    logger.log(content: "⚠️ Video image has no representations")
                }
            } else {
                logger.log(content: "❌ Video image has invalid size: \(image.size)")
                return nil
            }
        } else {
            logger.log(content: "❌ Failed to capture video frame")
        }
        
        return capturedImage
    }
}

// MARK: - OCR Error Types

enum OCRError: Error, LocalizedError {
    case screenCaptureFailure
    case imageConversionFailure
    case visionFrameworkError(String)
    
    var errorDescription: String? {
        switch self {
        case .screenCaptureFailure:
            return "Failed to capture screen area"
        case .imageConversionFailure:
            return "Failed to convert image for OCR processing"
        case .visionFrameworkError(let message):
            return "Vision framework error: \(message)"
        }
    }
}

// MARK: - Text Selection Overlay View

@available(macOS 12.3, *)
class TextSelectionOverlayView: NSView {
    private let videoImage: NSImage
    private var selectionRect: NSRect?
    private var temporarySelectionRect: NSRect? // For live preview during dragging
    private var initialLocation: NSPoint?
    private var controlPointSize: CGFloat = 8.0
    private let controlPointColor: NSColor = NSColor.systemBlue
    private var lastMouseLocation: NSPoint?
    private var activeHandle: ResizeHandle = .none
    private var isDragging: Bool = false
    private let onTextSelected: (NSRect) -> Void
    private let onCancel: () -> Void
    
    // Copy button properties
    private var copyButtonSize: CGSize = CGSize(width: 60, height: 30)
    private var copyButtonRect: NSRect = .zero
    private var isCopyButtonHovered: Bool = false
    
    // Video display properties
    private var videoDisplayRect: NSRect = .zero
    private var videoScale: CGFloat = 1.0
    
    // Key monitoring for ESC key as backup
    private var keyMonitor: Any?
    
    init(videoImage: NSImage, onTextSelected: @escaping (NSRect) -> Void, onCancel: @escaping () -> Void) {
        self.videoImage = videoImage
        self.onTextSelected = onTextSelected
        self.onCancel = onCancel
        super.init(frame: .zero)
        
        // Set up proper mouse tracking and drawing
        self.wantsLayer = false
        
        // Set up a local key monitor as backup for ESC key
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape key
                logger.log(content: "ESC key detected in local monitor - cancelling selection")
                DispatchQueue.main.async {
                    // Restore cursor in case OCR was in progress
                    NSCursor.arrow.set()
                    self?.temporarySelectionRect = nil
                    self?.selectionRect = nil
                    self?.needsDisplay = true
                    self?.onCancel()
                }
                return nil // Consume the event
            }
            return event
        }
        
        // Force immediate display after init
        self.needsDisplay = true
    }
    
    override var isOpaque: Bool {
        return false
    }
    
    override var wantsUpdateLayer: Bool {
        return false
    }
    
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        
        if superview != nil {
            // If we're added directly to PlayerView, use its bounds exactly
            // If we're added to content view, maintain the frame set during creation
            if String(describing: type(of: superview!)).contains("PlayerView") {
                self.frame = superview!.bounds
                self.autoresizingMask = [.width, .height] // Resize with PlayerView
            }
            
            self.needsDisplay = true
            self.setNeedsDisplay(self.bounds)
            self.display()
            
            // Force layout and tracking areas update
            self.needsLayout = true
            self.layout()
            self.updateTrackingAreas()
            
            // Ensure we become first responder for key events
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.acceptsFirstResponder {
                    let success = self.window?.makeFirstResponder(self) ?? false
                    logger.log(content: "TextSelectionOverlayView first responder in viewDidMoveToSuperview: \(success)")
                }
            }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        // Clean up the key monitor
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        // Remove existing tracking areas
        trackingAreas.forEach { removeTrackingArea($0) }
        
        // Add a new tracking area covering the entire view
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func keyDown(with event: NSEvent) {
        logger.log(content: "TextSelectionOverlayView keyDown event: keyCode=\(event.keyCode), characters=\(event.characters ?? "nil")")
        
        if event.keyCode == 53 { // Escape key
            logger.log(content: "ESC key pressed in TextSelectionOverlayView - cancelling selection")
            // Restore cursor in case OCR was in progress
            NSCursor.arrow.set()
            // Clear any temporary or finalized selection
            temporarySelectionRect = nil
            selectionRect = nil
            needsDisplay = true
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }
    
    override func flagsChanged(with event: NSEvent) {
        // Handle modifier keys if needed
        super.flagsChanged(with: event)
    }
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Handle ESC as a key equivalent as well
        if event.keyCode == 53 {
            logger.log(content: "ESC key equivalent in TextSelectionOverlayView - cancelling selection")
            // Restore cursor in case OCR was in progress
            NSCursor.arrow.set()
            temporarySelectionRect = nil
            selectionRect = nil
            needsDisplay = true
            onCancel()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        guard window != nil else { return }
        
        // Set up mouse tracking
        updateTrackingAreas()
        
        // Calculate video display rect initially
        calculateVideoDisplayRect()
        selectionRect = nil // Start with no selection
        temporarySelectionRect = nil // Clear any temporary selection
        
        // Force a redraw to ensure everything is displayed
        needsDisplay = true
        
        // Make this view the first responder to receive key events
        // Do this multiple times with delays to ensure it works
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.acceptsFirstResponder {
                let success = self.window?.makeFirstResponder(self) ?? false
                logger.log(content: "TextSelectionOverlayView first responder in viewDidMoveToWindow: \(success)")
                
                // If first attempt failed, try again
                if !success {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self = self else { return }
                        let retrySuccess = self.window?.makeFirstResponder(self) ?? false
                        logger.log(content: "TextSelectionOverlayView retry first responder: \(retrySuccess)")
                    }
                }
            }
        }
    }
    
    override func layout() {
        super.layout()
        // Recalculate when layout changes
        calculateVideoDisplayRect()
        updateTrackingAreas()
        needsDisplay = true
    }
    
    private func calculateVideoDisplayRect() {
        let viewBounds = bounds
        let imageSize = videoImage.size
        
        // Calculate aspect ratios to determine video scaling method (aspect fit)
        let videoAspectRatio = imageSize.width / imageSize.height
        let viewAspectRatio = viewBounds.width / viewBounds.height
        
        if abs(videoAspectRatio - viewAspectRatio) < 0.01 {
            // Aspect ratios match - video fills view exactly
            videoDisplayRect = viewBounds
            videoScale = viewBounds.width / imageSize.width
        } else if videoAspectRatio > viewAspectRatio {
            // Video is wider - aspect fit with letterboxing top/bottom
            let scaledHeight = viewBounds.width / videoAspectRatio
            videoDisplayRect = NSRect(
                x: 0,
                y: (viewBounds.height - scaledHeight) / 2,
                width: viewBounds.width,
                height: scaledHeight
            )
            videoScale = viewBounds.width / imageSize.width
        } else {
            // Video is taller - aspect fit with letterboxing left/right
            let scaledWidth = viewBounds.height * videoAspectRatio
            videoDisplayRect = NSRect(
                x: (viewBounds.width - scaledWidth) / 2,
                y: 0,
                width: scaledWidth,
                height: viewBounds.height
            )
            videoScale = viewBounds.height / imageSize.height
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Ensure we have a graphics context
        guard NSGraphicsContext.current != nil else {
            return
        }
        
        // Fill entire view with semi-transparent dark background for visibility
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        
        // Draw the video image with proper aspect ratio and letterboxing/pillarboxing
        if videoImage.size.width > 0 && videoImage.size.height > 0 {
            videoImage.draw(in: videoDisplayRect)
        }
        
        // Always draw instructions at the top
        drawInstructions()
        
        // Determine which selection to draw - temporary takes precedence during dragging
        let rectToDraw = temporarySelectionRect ?? selectionRect
        
        // Draw selection rectangle if exists and has valid size
        guard let rect = rectToDraw, rect.width > 0, rect.height > 0 else {
            return
        }
        
        // Since we're now storing selections in PlayerView coordinates,
        // use the rect directly without conversion
        let displayRect = rect
        
        // Validate rect to prevent NaN values from reaching CoreGraphics
        guard displayRect.minX.isFinite && displayRect.minY.isFinite && 
              displayRect.width.isFinite && displayRect.height.isFinite &&
              displayRect.width > 0 && displayRect.height > 0 else {
            print("⚠️ Invalid displayRect with NaN or invalid values: \(displayRect)")
            return
        }
        
        // Draw selection rectangle with high visibility
        let dashPattern: [CGFloat] = [8.0, 4.0]
        let dashedBorder = NSBezierPath(rect: displayRect)
        dashedBorder.lineWidth = 4.0
        dashedBorder.setLineDash(dashPattern, count: 2, phase: 0.0)
        NSColor.systemYellow.setStroke()
        dashedBorder.stroke()
        
        // Draw a solid inner border for better visibility
        let innerBorder = NSBezierPath(rect: displayRect.insetBy(dx: 2, dy: 2))
        innerBorder.lineWidth = 2.0
        NSColor.white.setStroke()
        innerBorder.stroke()
        
        // Only draw control points and copy button for finalized selection, not temporary
        if temporarySelectionRect == nil {
            drawControlPoints(for: displayRect)
            drawCopyButton(for: displayRect)
        }
        
        // Draw a simple live rectangle during drag (bypassing all coordinate conversion)
        if let initial = initialLocation, isDragging == false && activeHandle == .none,
           initial.x.isFinite && initial.y.isFinite {
            if let current = lastMouseLocation,
               current.x.isFinite && current.y.isFinite {
                let liveRect = NSRect(
                    x: min(initial.x, current.x),
                    y: min(initial.y, current.y), 
                    width: abs(current.x - initial.x),
                    height: abs(current.y - initial.y)
                )
                
                // Validate live rectangle
                if liveRect.width.isFinite && liveRect.height.isFinite && 
                   liveRect.width > 0 && liveRect.height > 0 {
                    // Draw a bright green rectangle for immediate visual feedback
                    let livePath = NSBezierPath(rect: liveRect)
                    NSColor.green.setStroke()
                    livePath.lineWidth = 3.0
                    livePath.stroke()
                }
            }
        }
    }
    
    private func drawControlPoints(for rect: NSRect) {
        for handle in ResizeHandle.allCases {
            guard handle != .none else { continue }
            if let point = controlPointForHandle(handle, inRect: rect),
               point.x.isFinite && point.y.isFinite {
                let controlPointRect = NSRect(
                    origin: point,
                    size: CGSize(width: controlPointSize, height: controlPointSize)
                )
                
                // Validate control point rect
                guard controlPointRect.minX.isFinite && controlPointRect.minY.isFinite &&
                      controlPointRect.width.isFinite && controlPointRect.height.isFinite else {
                    print("⚠️ Invalid controlPointRect with NaN values: \(controlPointRect)")
                    continue
                }
                
                let controlPointPath = NSBezierPath(ovalIn: controlPointRect)
                
                // Draw shadow first
                NSColor.black.withAlphaComponent(0.5).setFill()
                let shadowRect = controlPointRect.offsetBy(dx: 2, dy: -2)
                
                // Validate shadow rect
                if shadowRect.minX.isFinite && shadowRect.minY.isFinite &&
                   shadowRect.width.isFinite && shadowRect.height.isFinite {
                    let shadowPath = NSBezierPath(ovalIn: shadowRect)
                    shadowPath.fill()
                }
                
                // Draw control point
                NSColor.systemYellow.setFill()
                controlPointPath.fill()
                
                // Draw border
                NSColor.black.setStroke()
                controlPointPath.lineWidth = 2.0
                controlPointPath.stroke()
            }
        }
    }
    
    private func drawInstructions() {
        let instructionText = selectionRect == nil ? 
            "Select multiline text area • Click and drag to select • ESC to cancel" :
            "Click Copy button to extract multiline text • Drag corners to resize • ESC to cancel"
            
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .shadow: {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
                shadow.shadowOffset = NSSize(width: 1, height: -1)
                shadow.shadowBlurRadius = 3
                return shadow
            }()
        ]
        
        let textSize = instructionText.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: bounds.height - textSize.height - 30,
            width: textSize.width,
            height: textSize.height
        )
        
        // Draw background for text
        let backgroundRect = textRect.insetBy(dx: -10, dy: -5)
        let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.6).setFill()
        backgroundPath.fill()
        
        instructionText.draw(in: textRect, withAttributes: attributes)
    }

    
    private func convertFromDisplayCoordinates(_ displayRect: NSRect) -> NSRect {
        // Convert from PlayerView coordinates back to video coordinates
        // Use the calculated videoDisplayRect for accurate conversion
        
        let imageSize = videoImage.size
        
        // Remove video offset to get relative coordinates within the video display area
        let relativeRect = NSRect(
            x: displayRect.minX - videoDisplayRect.minX,
            y: displayRect.minY - videoDisplayRect.minY,
            width: displayRect.width,
            height: displayRect.height
        )
        
        // Scale from displayed size to video coordinates
        let scaleX = imageSize.width / videoDisplayRect.width
        let scaleY = imageSize.height / videoDisplayRect.height
        
        // No Y-flip needed since both PlayerView and video use top-left origin
        return NSRect(
            x: relativeRect.minX * scaleX,
            y: relativeRect.minY * scaleY,
            width: relativeRect.width * scaleX,
            height: relativeRect.height * scaleY
        )
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        
        // Check if user clicked the copy button
        if selectionRect != nil && copyButtonRect.contains(location) {
            // Change cursor to indicate processing
            NSCursor.crosshair.set()
            
            // Add visual feedback
            NSSound.beep()
            if let rect = selectionRect {
                onTextSelected(rect)
            }
            return
        }
        
        // Visual feedback - flash the overlay briefly to show interaction
        let originalAlpha = alphaValue
        alphaValue = 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.alphaValue = originalAlpha
        }
        
        // Only allow interactions within the actual video display area
        guard videoDisplayRect.contains(location) else {
            return
        }
        
        initialLocation = location
        lastMouseLocation = location
        activeHandle = .none
        isDragging = false
        
        // Check if we're clicking on an existing selection
        if let rect = selectionRect {
            // Since selectionRect is now in PlayerView coordinates, use directly
            let displayRect = rect
            activeHandle = handleForPoint(location, inRect: displayRect)
            
            if displayRect.contains(location) {
                isDragging = true
            }
        }
        
        setNeedsDisplay(bounds) // Force redraw
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let initialLocation = initialLocation else { return }
        let currentLocation = convert(event.locationInWindow, from: nil)
        
        // Visual feedback during drag
        let originalAlpha = alphaValue
        alphaValue = 0.9
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.alphaValue = originalAlpha
        }
        
        // Clamp to video display area instead of full overlay bounds
        let clampedLocation = NSPoint(
            x: max(videoDisplayRect.minX, min(videoDisplayRect.maxX, currentLocation.x)),
            y: max(videoDisplayRect.minY, min(videoDisplayRect.maxY, currentLocation.y))
        )
        
        if activeHandle != .none {
            resizeSelection(to: clampedLocation)
        } else if isDragging {
            moveSelection(to: clampedLocation, from: initialLocation)
            self.initialLocation = clampedLocation
        } else {
            // Create temporary selection for live preview in PlayerView coordinates
            let playerViewRect = NSRect(
                x: min(initialLocation.x, clampedLocation.x),
                y: min(initialLocation.y, clampedLocation.y),
                width: abs(clampedLocation.x - initialLocation.x),
                height: abs(clampedLocation.y - initialLocation.y)
            )
            
            // Always show temporary selection during drag, even if small
            if playerViewRect.width > 0 && playerViewRect.height > 0 {
                // Store in PlayerView coordinates - no conversion needed
                temporarySelectionRect = playerViewRect
            }
        }
        
        lastMouseLocation = clampedLocation
        setNeedsDisplay(bounds) // Force redraw of entire view
    }
    
    override func mouseUp(with event: NSEvent) {
        defer {
            initialLocation = nil
            activeHandle = .none
            isDragging = false
        }
        
        // If we have a temporary selection, finalize it if it's large enough
        if let tempRect = temporarySelectionRect {
            let minSize: CGFloat = 5
            
            if tempRect.width >= minSize && tempRect.height >= minSize {
                // Store the selection in PlayerView coordinates (no conversion needed)
                selectionRect = tempRect
            }
            
            temporarySelectionRect = nil
            needsDisplay = true
        }
    }
    
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        
        // Check if mouse is over the copy button
        let wasHovered = isCopyButtonHovered
        isCopyButtonHovered = selectionRect != nil && copyButtonRect.contains(location)
        
        // Redraw if hover state changed
        if wasHovered != isCopyButtonHovered {
            setNeedsDisplay(copyButtonRect)
        }
        
        super.mouseMoved(with: event)
    }
    
    // MARK: - Helper Methods
    
    private func controlPointForHandle(_ handle: ResizeHandle, inRect rect: NSRect) -> NSPoint? {
        switch handle {
        case .topLeft:
            return NSPoint(x: rect.minX - controlPointSize / 2, y: rect.maxY - controlPointSize / 2)
        case .top:
            return NSPoint(x: rect.midX - controlPointSize / 2, y: rect.maxY - controlPointSize / 2)
        case .topRight:
            return NSPoint(x: rect.maxX - controlPointSize / 2, y: rect.maxY - controlPointSize / 2)
        case .right:
            return NSPoint(x: rect.maxX - controlPointSize / 2, y: rect.midY - controlPointSize / 2)
        case .bottomRight:
            return NSPoint(x: rect.maxX - controlPointSize / 2, y: rect.minY - controlPointSize / 2)
        case .bottom:
            return NSPoint(x: rect.midX - controlPointSize / 2, y: rect.minY - controlPointSize / 2)
        case .bottomLeft:
            return NSPoint(x: rect.minX - controlPointSize / 2, y: rect.minY - controlPointSize / 2)
        case .left:
            return NSPoint(x: rect.minX - controlPointSize / 2, y: rect.midY - controlPointSize / 2)
        case .none:
            return nil
        }
    }
    
    private func handleForPoint(_ point: NSPoint, inRect rect: NSRect) -> ResizeHandle {
        for handle in ResizeHandle.allCases {
            if let controlPoint = controlPointForHandle(handle, inRect: rect) {
                let controlRect = NSRect(
                    origin: controlPoint,
                    size: CGSize(width: controlPointSize, height: controlPointSize)
                )
                if controlRect.contains(point) {
                    return handle
                }
            }
        }
        return .none
    }
    
    private func createNewSelection(from start: NSPoint, to end: NSPoint) {
        // Create selection in PlayerView coordinates
        let playerViewRect = NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        
        // Only create selection if it's large enough - reduce minimum size for better usability
        let minSize: CGFloat = 5
        if playerViewRect.width >= minSize && playerViewRect.height >= minSize {
            // Store directly in PlayerView coordinates
            selectionRect = playerViewRect
        } else {
            selectionRect = nil
        }
    }
    
    private func moveSelection(to currentLocation: NSPoint, from initialLocation: NSPoint) {
        guard let rect = selectionRect else { return }
        
        // Since selectionRect is in PlayerView coordinates, use directly
        let deltaX = currentLocation.x - initialLocation.x
        let deltaY = currentLocation.y - initialLocation.y
        
        let newPlayerViewRect = NSRect(
            x: max(videoDisplayRect.minX, min(videoDisplayRect.maxX - rect.width, rect.minX + deltaX)),
            y: max(videoDisplayRect.minY, min(videoDisplayRect.maxY - rect.height, rect.minY + deltaY)),
            width: rect.width,
            height: rect.height
        )
        
        // Store directly in PlayerView coordinates
        selectionRect = newPlayerViewRect
    }
    
    private func resizeSelection(to currentLocation: NSPoint) {
        guard let rect = selectionRect else { return }
        guard let lastLocation = lastMouseLocation else { return }
        
        // Since selectionRect is in PlayerView coordinates, use directly
        let deltaX = currentLocation.x - lastLocation.x
        let deltaY = currentLocation.y - lastLocation.y
        let minSize: CGFloat = 20
        
        var newPlayerViewRect = rect
        
        // Adjust rectangle based on which handle is being dragged
        switch activeHandle {
        case .topLeft:
            newPlayerViewRect.origin.x = min(rect.maxX - minSize, rect.minX + deltaX)
            newPlayerViewRect.origin.y = min(rect.maxY - minSize, rect.minY + deltaY)
            newPlayerViewRect.size.width = rect.maxX - newPlayerViewRect.minX
            newPlayerViewRect.size.height = rect.maxY - newPlayerViewRect.minY
        case .top:
            newPlayerViewRect.origin.y = min(rect.maxY - minSize, rect.minY + deltaY)
            newPlayerViewRect.size.height = rect.maxY - newPlayerViewRect.minY
        case .topRight:
            newPlayerViewRect.size.width = max(minSize, rect.width + deltaX)
            newPlayerViewRect.origin.y = min(rect.maxY - minSize, rect.minY + deltaY)
            newPlayerViewRect.size.height = rect.maxY - newPlayerViewRect.minY
        case .right:
            newPlayerViewRect.size.width = max(minSize, rect.width + deltaX)
        case .bottomRight:
            newPlayerViewRect.size.width = max(minSize, rect.width + deltaX)
            newPlayerViewRect.size.height = max(minSize, rect.height + deltaY)
        case .bottom:
            newPlayerViewRect.size.height = max(minSize, rect.height + deltaY)
        case .bottomLeft:
            newPlayerViewRect.origin.x = min(rect.maxX - minSize, rect.minX + deltaX)
            newPlayerViewRect.size.width = rect.maxX - newPlayerViewRect.minX
            newPlayerViewRect.size.height = max(minSize, rect.height + deltaY)
        case .left:
            newPlayerViewRect.origin.x = min(rect.maxX - minSize, rect.minX + deltaX)
            newPlayerViewRect.size.width = rect.maxX - newPlayerViewRect.minX
        case .none:
            break
        }
        
        // Clamp to video display area
        newPlayerViewRect = newPlayerViewRect.intersection(videoDisplayRect)
        
        // Store directly in PlayerView coordinates
        selectionRect = newPlayerViewRect
    }
    
    private func drawCopyButton(for rect: NSRect) {
        // Position the copy button next to the selection area (top-right)
        copyButtonRect = NSRect(
            x: rect.maxX + 10,
            y: rect.maxY - copyButtonSize.height,
            width: copyButtonSize.width,
            height: copyButtonSize.height
        )
        
        // Ensure the button stays within bounds
        if copyButtonRect.maxX > bounds.maxX {
            copyButtonRect.origin.x = rect.minX - copyButtonSize.width - 10
        }
        if copyButtonRect.minY < bounds.minY {
            copyButtonRect.origin.y = rect.minY
        }
        
        // Validate copy button rect
        guard copyButtonRect.minX.isFinite && copyButtonRect.minY.isFinite &&
              copyButtonRect.width.isFinite && copyButtonRect.height.isFinite else {
            print("⚠️ Invalid copyButtonRect with NaN values: \(copyButtonRect)")
            return
        }
        
        // Draw button background
        let buttonPath = NSBezierPath(roundedRect: copyButtonRect, xRadius: 6, yRadius: 6)
        
        // Set button color based on hover state
        if isCopyButtonHovered {
            NSColor.systemBlue.withAlphaComponent(0.9).setFill()
        } else {
            NSColor.systemBlue.withAlphaComponent(0.8).setFill()
        }
        buttonPath.fill()
        
        // Draw button border
        NSColor.white.setStroke()
        buttonPath.lineWidth = 2.0
        buttonPath.stroke()
        
        // Draw button text
        let buttonText = "Copy"
        let textAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 14, weight: .medium)
        ]
        
        let textSize = buttonText.size(withAttributes: textAttributes)
        let textRect = NSRect(
            x: copyButtonRect.midX - textSize.width / 2,
            y: copyButtonRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        
        buttonText.draw(in: textRect, withAttributes: textAttributes)
    }
    
    override func removeFromSuperview() {
        // Clean up key monitor before removing from superview
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
            logger.log(content: "Key monitor removed from TextSelectionOverlayView")
        }
        super.removeFromSuperview()
    }
}

// MARK: - Resize Handle Enum

enum ResizeHandle: CaseIterable {
    case none
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}
