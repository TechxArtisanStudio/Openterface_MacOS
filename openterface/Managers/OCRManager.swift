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

@available(macOS 12.3, *)
class OCRManager: OCRManagerProtocol {
    static let shared = OCRManager()
    
    // MARK: - Protocol-based Dependencies (Lazy to avoid circular dependency)
    private lazy var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private lazy var tipLayerManager: TipLayerManagerProtocol = DependencyContainer.shared.resolve(TipLayerManagerProtocol.self)
    private lazy var videoManager: VideoManagerProtocol = DependencyContainer.shared.resolve(VideoManagerProtocol.self)
    
    // MARK: - Area Selection Properties
    private var areaSelectionWindow: NSWindow?
    private var selectedArea: NSRect?
    var isAreaSelectionActive: Bool {
        return areaSelectionWindow != nil && AppStatus.isAreaOCRing
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
        
        textDetectionRequest.recognitionLevel = .accurate
        textDetectionRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-GB", "en-US"]
        textDetectionRequest.usesLanguageCorrection = true
        textDetectionRequest.minimumTextHeight = 0.01 // Lower threshold for small text
        
        let requests = [textDetectionRequest]
        let imageRequestHandler = VNImageRequestHandler(cgImage: enhancedImage, orientation: .up, options: [:])
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try imageRequestHandler.perform(requests)
            } catch let error {
                self.logger.log(content: "Failed to perform text detection on image: \(error.localizedDescription)")
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
                    self?.showTipMessage("Text Copied to Clipboard")
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
            completion(.failed(OCRError.screenCaptureFailure))
            return
        }
        
        logger.log(content: "🎯 performOCROnSelectedArea called with selectedArea: \(selectedArea)")
        
        // Check if the selected area is too small for reliable OCR
        let areaSize = selectedArea.width * selectedArea.height
        if areaSize < 2000 { // Less than roughly 45x45 pixels
            logger.log(content: "⚠️ Selected area might be too small for reliable OCR: \(selectedArea.width)x\(selectedArea.height) = \(areaSize) pixels")
            showTipMessage("Selected area is small - try selecting a larger area for better OCR results")
        }
        
        // Save selected area image for debug
        logger.log(content: "🎯 Performing OCR on selected area: \(selectedArea)")
        performOCR(on: selectedArea) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self?.copyTextToClipboard(text: text)
                    self?.showTipMessage("Text Copied to Clipboard")
                    self?.logger.log(content: "✅ OCR successful: \(text)")
                case .noTextFound:
                    self?.showTipMessage("No Text Found - try selecting a larger area or area with clearer text")
                    self?.logger.log(content: "⚠️ OCR completed but no text found")
                case .failed(let error):
                    self?.showTipMessage("OCR Failed")
                    self?.logger.log(content: "❌ OCR failed: \(error.localizedDescription)")
                }
                completion(result)
            }
        }
    }
    
    func handleAreaSelectionComplete() {
        logger.log(content: "Handling area selection completion")
        cancelAreaSelection()
    }
    
    func startAreaSelection() {
        guard !isAreaSelectionActive else {
            logger.log(content: "Area selection already active")
            return
        }
        
        // Show tip before starting area selection
        DispatchQueue.main.async { [weak self] in
            if let window = NSApplication.shared.mainWindow {
                self?.tipLayerManager.showTip(
                    text: "Double Click to copy text from target",
                    yOffset: 1.5,
                    window: window
                )
            }
        }
        
        // Wait a moment to let user read the tip, then start area selection
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.showAreaSelectionWindow()
        }
    }
    
    func cancelAreaSelection() {
        DispatchQueue.main.async { [weak self] in
            self?.areaSelectionWindow?.close()
            self?.areaSelectionWindow = nil
            self?.selectedArea = nil
            AppStatus.isAreaOCRing = false
            self?.logger.log(content: "Area selection cancelled and OCR state reset")
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
        logger.log(content: "📹 Converting area selection to video coordinates...")
        let videoRect = convertAreaSelectionToVideoCoordinates(rect)
        logger.log(content: "📹 Converted rect: \(videoRect)")
        
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
        // Get the main window and its content view
        guard let mainWindow = NSApplication.shared.mainWindow,
              let contentView = mainWindow.contentView else {
            logger.log(content: "❌ Cannot get main window or content view for coordinate conversion")
            return rect
        }
        
        // Step 1: Convert from screen coordinates to window coordinates
        let windowRect = mainWindow.convertFromScreen(rect)
        
        // Step 2: Convert from window coordinates to content view coordinates
        // Note: In macOS, window coordinates have origin at bottom-left, content view also has origin at bottom-left
        // But we need to account for the titlebar and flip the Y coordinate properly
        let titlebarHeight = mainWindow.frame.height - contentView.bounds.height
        let contentRect = NSRect(
            x: windowRect.minX,
            y: contentView.bounds.height - (windowRect.minY - titlebarHeight) - windowRect.height, // Flip Y and account for titlebar
            width: windowRect.width,
            height: windowRect.height
        )
        
        // Step 3: Find the PlayerView within the content view hierarchy
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
            logger.log(content: "❌ Could not find PlayerView in view hierarchy, using content view as fallback")
            // Fallback to content view
            return convertWithContentView(contentRect, contentView: contentView)
        }
        
        // Step 4: Convert content coordinates to PlayerView coordinates
        let playerRect = contentView.convert(contentRect, to: playerView)
        
        // Step 5: Get video dimensions and calculate how video is displayed in PlayerView
        let videoDimensions = videoManager.dimensions
        let videoWidth = CGFloat(videoDimensions.width)
        let videoHeight = CGFloat(videoDimensions.height)
        
        // Step 6: Calculate video display scaling and positioning within PlayerView
        // The video uses aspect FILL scaling (resizeAspectFill in the PlayerView)
        // This means the video fills the entire player, potentially cropping parts
        let playerSize = playerView.bounds.size
        let videoAspectRatio = videoWidth / videoHeight
        let playerAspectRatio = playerSize.width / playerSize.height
        
        var displayedVideoSize: CGSize
        var videoOffsetInPlayer: CGPoint
        
        if videoAspectRatio > playerAspectRatio {
            // Video is wider than player - fit to height, crop left/right
            displayedVideoSize = CGSize(
                width: playerSize.height * videoAspectRatio,
                height: playerSize.height
            )
            videoOffsetInPlayer = CGPoint(
                x: -(displayedVideoSize.width - playerSize.width) / 2,
                y: 0
            )
        } else {
            // Video is taller than player - fit to width, crop top/bottom
            displayedVideoSize = CGSize(
                width: playerSize.width,
                height: playerSize.width / videoAspectRatio
            )
            videoOffsetInPlayer = CGPoint(
                x: 0,
                y: -(displayedVideoSize.height - playerSize.height) / 2
            )
        }
        
        // Step 7: Convert PlayerView coordinates to video-relative coordinates
        // Since we're using aspect fill, we need to account for the cropped portions
        let videoRelativeRect = NSRect(
            x: playerRect.minX - videoOffsetInPlayer.x,
            y: playerRect.minY - videoOffsetInPlayer.y,
            width: playerRect.width,
            height: playerRect.height
        )
        
        // Step 8: Scale from displayed video size to actual video size
        let scaleX = videoWidth / displayedVideoSize.width
        let scaleY = videoHeight / displayedVideoSize.height
        
        let scaledRect = NSRect(
            x: videoRelativeRect.minX * scaleX,
            y: videoRelativeRect.minY * scaleY,
            width: videoRelativeRect.width * scaleX,
            height: videoRelativeRect.height * scaleY
        )
        
        // Step 9: Final Y-axis flip for video coordinates (video has origin at top-left)
        // Convert from bottom-left origin (macOS) to top-left origin (video)
        let videoFlippedRect = NSRect(
            x: scaledRect.minX,
            y: videoHeight - scaledRect.maxY, // Flip Y coordinate for video frame
            width: scaledRect.width,
            height: scaledRect.height
        )
        
        // Step 10: Clamp to video bounds and ensure valid rectangle
        let clampedRect = NSRect(
            x: min(max(0, videoFlippedRect.minX), videoWidth - 1),
            y: min(max(0, videoFlippedRect.minY), videoHeight - 1),
            width: min(max(1, videoFlippedRect.width), videoWidth - videoFlippedRect.minX),
            height: min(max(1, videoFlippedRect.height), videoHeight - videoFlippedRect.minY)
        )
        
        return clampedRect
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
        
        // Collect all text candidates with confidence scores
        var allTextCandidates: [(text: String, confidence: Float)] = []
        
        for result in results {
            if let observation = result as? VNRecognizedTextObservation {
                let candidates = observation.topCandidates(3) // Get top 3 candidates
                for candidate in candidates {
                    allTextCandidates.append((candidate.string, candidate.confidence))
                    logger.log(content: "🔍 Text candidate: '\(candidate.string)' (confidence: \(candidate.confidence))")
                }
            }
        }
        
        // Find the best text result
        if let bestCandidate = allTextCandidates.max(by: { $0.confidence < $1.confidence }) {
            logger.log(content: "🔍 Best text result: '\(bestCandidate.text)' (confidence: \(bestCandidate.confidence))")
            DispatchQueue.main.async {
                completion(.success(bestCandidate.text))
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
        
        // Only upscale if the image is very small
        let shouldUpscale = width < 200 || height < 50
        let scaleFactor: CGFloat = shouldUpscale ? 3.0 : 1.0
        
        let newWidth = Int(CGFloat(width) * scaleFactor)
        let newHeight = Int(CGFloat(height) * scaleFactor)
        
        logger.log(content: "🔍 Enhancing image: \(width)x\(height) -> \(newWidth)x\(newHeight) (scale: \(scaleFactor))")
        
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
        
        // High quality scaling
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        
        // Draw the original image scaled up
        context.draw(originalImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        
        guard let enhancedImage = context.makeImage() else {
            logger.log(content: "⚠️ Failed to create enhanced image, using original")
            return originalImage
        }
        
        // Save enhanced image for debugging if it was actually enhanced
        if shouldUpscale {
            logger.log(content: "🔍 Image upscaled for better OCR accuracy")
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.log(content: "Copied text to clipboard: \(text)")
    }
    
    private func showTipMessage(_ message: String) {
        tipLayerManager.showTip(text: message, yOffset: 1.5, window: NSApp.mainWindow)
    }
    
    // MARK: - Area Selection UI
    
    private func showAreaSelectionWindow() {
        guard let screen = getScreenWithMouse() else {
            logger.log(content: "Could not determine screen for area selection")
            return
        }
        
        AppStatus.isAreaOCRing = true
        
        let overlayView = AreaSelectionView { [weak self] selectedRect in
            self?.logger.log(content: "🎯 Area selection completed. Selected rect: \(selectedRect)")
            self?.logger.log(content: "🎯 Screen used for selection: \(screen.frame)")
            self?.selectedArea = selectedRect
            self?.performOCROnSelectedArea { _ in
                self?.handleAreaSelectionComplete()
            }
        }
        
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.level = .statusBar
        window.backgroundColor = NSColor.clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.contentView = overlayView
        window.title = "Area Selector"
        
        self.areaSelectionWindow = window
        
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        logger.log(content: "Area selection window displayed")
    }
    
    private func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
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

// MARK: - Area Selection View

@available(macOS 12.3, *)
class AreaSelectionView: NSView {
    private var selectionRect: NSRect?
    private var initialLocation: NSPoint?
    private var controlPointSize: CGFloat = 6.0
    private let controlPointColor: NSColor = NSColor.systemYellow
    private var lastMouseLocation: NSPoint?
    private var activeHandle: ResizeHandle = .none
    private var isDragging: Bool = false
    private let onAreaSelected: (NSRect) -> Void
    
    init(onAreaSelected: @escaping (NSRect) -> Void) {
        self.onAreaSelected = onAreaSelected
        super.init(frame: .zero)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Draw semi-transparent overlay
        NSColor.black.withAlphaComponent(0.5).setFill()
        dirtyRect.fill()
        
        guard let rect = selectionRect else { return }
        
        // Update control point size
        controlPointSize = rect.width > 1 ? 6.0 : 0
        
        // Draw selection rectangle
        let dashPattern: [CGFloat] = [4.0, 4.0]
        let dashedBorder = NSBezierPath(rect: rect)
        dashedBorder.lineWidth = 4.0
        dashedBorder.setLineDash(dashPattern, count: 2, phase: 0.0)
        NSColor.white.setStroke()
        dashedBorder.stroke()
        
        // Fill selection area with transparent color
        NSColor(white: 1, alpha: 0.01).setFill()
        rect.fill()
        
        // Draw control points
        for handle in ResizeHandle.allCases {
            if let point = controlPointForHandle(handle, inRect: rect) {
                let controlPointRect = NSRect(
                    origin: point,
                    size: CGSize(width: controlPointSize, height: controlPointSize)
                )
                let controlPointPath = NSBezierPath(ovalIn: controlPointRect)
                controlPointColor.setFill()
                controlPointPath.fill()
            }
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        selectionRect = NSRect(x: 0, y: 0, width: 0, height: 0)
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        print("🎯 mouseDown: event.locationInWindow=\(event.locationInWindow)")
        print("🎯 mouseDown: converted location=\(location)")
        print("🎯 mouseDown: view bounds=\(bounds)")
        
        initialLocation = location
        lastMouseLocation = location
        activeHandle = handleForPoint(location)
        
        if let rect = selectionRect, rect.contains(location) {
            isDragging = true
        }
        
        needsDisplay = true
        
        // Handle double-click for OCR
        if event.clickCount == 2 {
            let pointInView = convert(event.locationInWindow, from: nil)
            if let rect = selectionRect, rect.contains(pointInView) {
                print("🎯 Area selection double-click detected")
                print("🎯 Point in view: \(pointInView)")
                print("🎯 Selection rect in view: \(rect)")
                print("🎯 Window frame: \(String(describing: window?.frame))")
                print("🎯 View bounds: \(bounds)")
                onAreaSelected(rect)
            }
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard var initialLocation = initialLocation else { return }
        let currentLocation = convert(event.locationInWindow, from: nil)
        
        if activeHandle != .none {
            resizeSelection(to: currentLocation)
        } else if isDragging {
            moveSelection(to: currentLocation, from: initialLocation)
            self.initialLocation = currentLocation
        } else {
            createNewSelection(from: initialLocation, to: currentLocation)
        }
        
        lastMouseLocation = currentLocation
        needsDisplay = true
    }
    
    override func mouseUp(with event: NSEvent) {
        initialLocation = nil
        activeHandle = .none
        isDragging = false
    }
    
    // MARK: - Helper Methods
    
    private func controlPointForHandle(_ handle: ResizeHandle, inRect rect: NSRect) -> NSPoint? {
        switch handle {
        case .topLeft:
            return NSPoint(x: rect.minX - controlPointSize / 2 - 1, y: rect.maxY - controlPointSize / 2 + 1)
        case .top:
            return NSPoint(x: rect.midX - controlPointSize / 2, y: rect.maxY - controlPointSize / 2 + 1)
        case .topRight:
            return NSPoint(x: rect.maxX - controlPointSize / 2 + 1, y: rect.maxY - controlPointSize / 2 + 1)
        case .right:
            return NSPoint(x: rect.maxX - controlPointSize / 2 + 1, y: rect.midY - controlPointSize / 2)
        case .bottomRight:
            return NSPoint(x: rect.maxX - controlPointSize / 2 + 1, y: rect.minY - controlPointSize / 2 - 1)
        case .bottom:
            return NSPoint(x: rect.midX - controlPointSize / 2, y: rect.minY - controlPointSize / 2 - 1)
        case .bottomLeft:
            return NSPoint(x: rect.minX - controlPointSize / 2 - 1, y: rect.minY - controlPointSize / 2 - 1)
        case .left:
            return NSPoint(x: rect.minX - controlPointSize / 2 - 1, y: rect.midY - controlPointSize / 2)
        case .none:
            return nil
        }
    }
    
    private func handleForPoint(_ point: NSPoint) -> ResizeHandle {
        guard let rect = selectionRect else { return .none }
        
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
        let origin = NSPoint(x: min(start.x, end.x), y: min(start.y, end.y))
        let size = NSSize(width: abs(end.x - start.x), height: abs(end.y - start.y))
        selectionRect = NSRect(origin: origin, size: size)
        
        print("🎯 createNewSelection: start=\(start), end=\(end)")
        print("🎯 createNewSelection: resulting rect=\(selectionRect!)")
        print("🎯 createNewSelection: view bounds=\(bounds)")
    }
    
    private func moveSelection(to currentLocation: NSPoint, from initialLocation: NSPoint) {
        guard var rect = selectionRect else { return }
        
        let deltaX = currentLocation.x - initialLocation.x
        let deltaY = currentLocation.y - initialLocation.y
        
        rect.origin.x = min(max(0, rect.origin.x + deltaX), frame.width - rect.width)
        rect.origin.y = min(max(0, rect.origin.y + deltaY), frame.height - rect.height)
        
        selectionRect = rect
    }
    
    private func resizeSelection(to currentLocation: NSPoint) {
        guard var rect = selectionRect else { return }
        guard let lastLocation = lastMouseLocation else { return }
        
        let deltaX = currentLocation.x - lastLocation.x
        let deltaY = currentLocation.y - lastLocation.y
        let minSize: CGFloat = 20
        
        switch activeHandle {
        case .topLeft:
            rect.origin.x = min(rect.origin.x + rect.width - minSize, rect.origin.x + deltaX)
            rect.size.width = max(minSize, rect.size.width - deltaX)
            rect.size.height = max(minSize, rect.size.height + deltaY)
        case .top:
            rect.size.height = max(minSize, rect.size.height + deltaY)
        case .topRight:
            rect.size.width = max(minSize, rect.size.width + deltaX)
            rect.size.height = max(minSize, rect.size.height + deltaY)
        case .right:
            rect.size.width = max(minSize, rect.size.width + deltaX)
        case .bottomRight:
            rect.origin.y = min(rect.origin.y + rect.height - minSize, rect.origin.y + deltaY)
            rect.size.width = max(minSize, rect.size.width + deltaX)
            rect.size.height = max(minSize, rect.size.height - deltaY)
        case .bottom:
            rect.origin.y = min(rect.origin.y + rect.height - minSize, rect.origin.y + deltaY)
            rect.size.height = max(minSize, rect.size.height - deltaY)
        case .bottomLeft:
            rect.origin.y = min(rect.origin.y + rect.height - minSize, rect.origin.y + deltaY)
            rect.origin.x = min(rect.origin.x + rect.width - minSize, rect.origin.x + deltaX)
            rect.size.width = max(minSize, rect.size.width - deltaX)
            rect.size.height = max(minSize, rect.size.height - deltaY)
        case .left:
            rect.origin.x = min(rect.origin.x + rect.width - minSize, rect.origin.x + deltaX)
            rect.size.width = max(minSize, rect.size.width - deltaX)
        case .none:
            break
        }
        
        selectionRect = rect
    }
}

// MARK: - Resize Handle Enum

enum ResizeHandle: CaseIterable {
    case none
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}
