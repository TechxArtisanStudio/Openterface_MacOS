//
//  AreaSeletor.swift
//  shotV
//
//  Created by Shawn Ling on 2024/5/6.
//
import Foundation
import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreGraphics
import Vision


func takeScreenshot(of rect: NSRect?) {
    let cimg = captureFullScreen()
}

func captureFullScreen() -> NSImage? {
    let bounds = CGRect(
        x: Int(SCContext.screenArea?.minX ?? 0),
        y: 1050 - Int(SCContext.screenArea?.minY ?? 0)-Int(SCContext.screenArea?.height ?? 500) ,
        width: Int((SCContext.screenArea?.width ?? 500) ),
        height: Int((SCContext.screenArea?.height ?? 500) )
    )

    guard let screenShot = CGWindowListCreateImage(bounds, .optionOnScreenOnly, kCGNullWindowID, .boundsIgnoreFraming) else { return nil }
    let originalCGImage: CGImage
    originalCGImage = screenShot

    let originalWidth = originalCGImage.width
    let originalHeight = originalCGImage.height
    let bitsPerComponent = originalCGImage.bitsPerComponent
    let colorSpace = originalCGImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = originalCGImage.bitmapInfo.rawValue
    guard let context = CGContext(data: nil, width: originalWidth / 2, height: originalHeight / 2, bitsPerComponent: bitsPerComponent, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
        fatalError("Unable to create graphics context")
    }

    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.draw(originalCGImage, in: CGRect(x: 0, y: 0, width: CGFloat(originalWidth) / 2, height: CGFloat(originalHeight) / 2))

    if let scaledImage = context.makeImage() {
        lazy var textDetectionRequest: VNRecognizeTextRequest = {
            let request = VNRecognizeTextRequest(completionHandler: handleDetectedText)
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-GB", "en-US"]
            return request
        }()
        
        let requests = [textDetectionRequest]
        let imageRequestHandler = VNImageRequestHandler(cgImage: scaledImage, orientation: .right, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try imageRequestHandler.perform(requests)
            } catch let error {
                print("Error: \(error)")
            }
        }
        
        return NSImage(cgImage: scaledImage, size: NSSize.zero)
    }
    
    return NSImage(cgImage: screenShot, size: NSSize.zero)
}

func handleDetectedText(request: VNRequest?, error: Error?) {
    if let error = error {
        print("ERROR: \(error)")
        return
    }
    guard let results = request?.results, results.count > 0 else {
        print("No text found")
        return
    }
    for result in results {
        if let observation = result as? VNRecognizedTextObservation {
            for text in observation.topCandidates(1) {
                copyTextToClipboard(text: text.string)
            }
        }
    }
}

func copyTextToClipboard(text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

class ScreenshotOverlayView: NSView {
    var selectionRect: NSRect?
    var initialLocation: NSPoint?
    var maskLayer: CALayer?
    var controlPointSize: CGFloat = 6.0
    let controlPointColor: NSColor = NSColor.systemYellow
    var lastMouseLocation: NSPoint?
    var activeHandle: ResizeHandle = .none
    var dragIng: Bool = false
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        selectionRect = NSRect(x: 0, y: 0, width: 0, height: 0)
        // selectionRect = nil
        SCContext.screenArea = selectionRect
    }
    

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.5).setFill()
        dirtyRect.fill()
        // Draw selection rectangle
        
        if let rect = selectionRect {
            if rect.width > 1 {
                controlPointSize = 6.0
            } else {
                controlPointSize = 0
            }
            let dashPattern: [CGFloat] = [4.0, 4.0]
            let dashedBorder = NSBezierPath(rect: rect)
            dashedBorder.lineWidth = 4.0
            dashedBorder.setLineDash(dashPattern, count: 2, phase: 0.0)
            NSColor.white.setStroke()
            dashedBorder.stroke()
            NSColor.init(white: 1, alpha: 0.01).setFill()
            __NSRectFill(rect)
            
            // Draw control points
            for handle in ResizeHandle.allCases {

                if let point = controlPointForHandle(handle, inRect: rect) {
                    let controlPointRect = NSRect(origin: point, size: CGSize(width: controlPointSize, height: controlPointSize))
                    let controlPointPath = NSBezierPath(ovalIn: controlPointRect)
                    controlPointColor.setFill()
                    controlPointPath.fill()
                }
            }
        }
    }
    
    
    func controlPointForHandle(_ handle: ResizeHandle, inRect rect: NSRect) -> NSPoint? {
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
    
    func handleForPoint(_ point: NSPoint) -> ResizeHandle {
        guard let rect = selectionRect else { return .none }
        print("rect: \(rect)")
        
        for handle in ResizeHandle.allCases {
            if let controlPoint = controlPointForHandle(handle, inRect: rect), NSRect(origin: controlPoint, size: CGSize(width: controlPointSize, height: controlPointSize)).contains(point) {
                return handle
            }
        }
        return .none
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        initialLocation = location
        lastMouseLocation = location
        activeHandle = handleForPoint(location)
        if let rect = selectionRect, NSPointInRect(location, rect) { dragIng = true }
        needsDisplay = true
        
        if event.clickCount == 2 {
           let pointInView = convert(event.locationInWindow, from: nil)
           if let rect = selectionRect, rect.contains(pointInView) {
               takeScreenshot(of: SCContext.screenArea!)
    
               for w in NSApplication.shared.windows {
                   if w.title == "Area Selector" {
                       w.close()
                       AppStatus.isAreaOCRing = false
                   }
               }
           }
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard var initialLocation = initialLocation else { return }
        let currentLocation = convert(event.locationInWindow, from: nil)
        if activeHandle != .none {
            
            // Calculate new rectangle size and position
            var newRect = selectionRect ?? CGRect.zero
            
            // Get last mouse location
            let lastLocation = lastMouseLocation ?? currentLocation
            
            let deltaX = currentLocation.x - lastLocation.x
            let deltaY = currentLocation.y - lastLocation.y

            switch activeHandle {
            case .topLeft:
                newRect.origin.x = min(newRect.origin.x + newRect.size.width - 20, newRect.origin.x + deltaX)
                newRect.size.width = max(20, newRect.size.width - deltaX)
                newRect.size.height = max(20, newRect.size.height + deltaY)
            case .top:
                newRect.size.height = max(20, newRect.size.height + deltaY)
            case .topRight:
                newRect.size.width = max(20, newRect.size.width + deltaX)
                newRect.size.height = max(20, newRect.size.height + deltaY)
            case .right:
                newRect.size.width = max(20, newRect.size.width + deltaX)
            case .bottomRight:
                newRect.origin.y = min(newRect.origin.y + newRect.size.height - 20, newRect.origin.y + deltaY)
                newRect.size.width = max(20, newRect.size.width + deltaX)
                newRect.size.height = max(20, newRect.size.height - deltaY)
            case .bottom:
                newRect.origin.y = min(newRect.origin.y + newRect.size.height - 20, newRect.origin.y + deltaY)
                newRect.size.height = max(20, newRect.size.height - deltaY)
            case .bottomLeft:
                newRect.origin.y = min(newRect.origin.y + newRect.size.height - 20, newRect.origin.y + deltaY)
                newRect.origin.x = min(newRect.origin.x + newRect.size.width - 20, newRect.origin.x + deltaX)
                newRect.size.width = max(20, newRect.size.width - deltaX)
                newRect.size.height = max(20, newRect.size.height - deltaY)
            case .left:
                newRect.origin.x = min(newRect.origin.x + newRect.size.width - 20, newRect.origin.x + deltaX)
                newRect.size.width = max(20, newRect.size.width - deltaX)
            default:
                break
            }
            self.selectionRect = newRect
            initialLocation = currentLocation // Update initial location for continuous dragging
            lastMouseLocation = currentLocation // Update last mouse location
        } else {
            if dragIng {
                dragIng = true
                let deltaX = currentLocation.x - initialLocation.x
                let deltaY = currentLocation.y - initialLocation.y
                
                let x = self.selectionRect?.origin.x
                let y = self.selectionRect?.origin.y
                let w = self.selectionRect?.size.width
                let h = self.selectionRect?.size.height
                self.selectionRect?.origin.x = min(max(0.0, x! + deltaX), self.frame.width - w!)
                self.selectionRect?.origin.y = min(max(0.0, y! + deltaY), self.frame.height - h!)
                initialLocation = currentLocation
            } else {
                //dragIng = false
                let origin = NSPoint(x: min(initialLocation.x, currentLocation.x), y: min(initialLocation.y, currentLocation.y))
                let size = NSSize(width: abs(currentLocation.x - initialLocation.x), height: abs(currentLocation.y - initialLocation.y))
                self.selectionRect = NSRect(origin: origin, size: size)
                //initialLocation = currentLocation
            }
            self.initialLocation = initialLocation
        }
        lastMouseLocation = currentLocation
        needsDisplay = true
    }
    
    override func mouseUp(with event: NSEvent) {
        initialLocation = nil
        activeHandle = .none
        dragIng = false
        if let rect = selectionRect {
            SCContext.screenArea = rect
        }
    }
    
}


class ScreenshotWindow: NSWindow {
    let overlayView = ScreenshotOverlayView()
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: bufferingType, defer: flag)
        self.isOpaque = false
        self.level = .statusBar
        self.backgroundColor = NSColor.clear
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]
        self.isReleasedWhenClosed = false
        self.contentView = overlayView
        //NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask.keyDown, handler: myKeyDownEvent)
    }

//    func myKeyDownEvent(event: NSEvent) -> NSEvent {
//        if event.keyCode == 53 {
//            self.close()
//            for w in NSApplication.shared.windows.filter({ $0.title == "Area Selector".local }) { w.close() }
//        }
//        return event
//    }
}

enum ResizeHandle: CaseIterable {
    case none
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    
    static var allCases: [ResizeHandle] {
        return [.none, .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
    }
}
