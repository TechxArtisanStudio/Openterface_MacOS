import SwiftUI
import AVFoundation
import AppKit

public class TipLayerManager: TipLayerManagerProtocol {
    
    public init() {}
    
    // Single dictionary to track active windows and their timers
    private var activeWindows: [NSWindow: Timer] = [:]
    
    private func map(value: Double, inMin: Double, inMax: Double, outMin: Double, outMax: Double) -> Double {
        // Prevent division by zero
        guard inMax - inMin != 0 else { return outMin }
      
        // Calculate the input value's ratio within the input range
        let inputScale = (value - inMin) / (inMax - inMin)
      
        // Map the input ratio to the output range
        let outputValue = outMin + (outMax - outMin) * inputScale
        return outputValue
    }
    
    public func showTip(text: String, yOffset: CGFloat = 1.5, window: NSWindow?) {
        guard let window = window, let screen = window.screen else { return }
        
        // Create a new window for the tip
        let tipWindow = NSWindow(
            contentRect: screen.frame, // Use screen frame instead of window frame
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Set window to appear above all other windows, including system UI
        tipWindow.level = .screenSaver // This is above most system UI
        tipWindow.backgroundColor = .clear
        tipWindow.isOpaque = false
        tipWindow.hasShadow = false
        tipWindow.ignoresMouseEvents = true // Allow clicks to pass through
        tipWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // Show in all spaces and full screen
        
        // Create a view to host the text layer
        let hostView = NSView(frame: screen.frame)
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = .clear
        
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.fontSize = map(value: screen.frame.width, inMin: 100, inMax: 2000, outMin: 10, outMax: 30)
        
        let width = CGFloat(CGFloat(text.count) * textLayer.fontSize * 0.5)
        let height = textLayer.fontSize * 1.5
        let xPosition = screen.frame.width - width - 20 // Add some padding
        let yPosition = screen.frame.height - textLayer.fontSize * yOffset
        
        textLayer.frame = CGRect(x: xPosition, y: yPosition, width: width, height: height)
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.backgroundColor = NSColor.black.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = screen.backingScaleFactor
        
        hostView.layer?.addSublayer(textLayer)
        tipWindow.contentView = hostView
        
        // Position the tip window to cover the entire screen
        tipWindow.setFrame(screen.frame, display: true)
        
        tipWindow.orderFront(nil)
        
        // Invalidate existing timer if there is one
        if let existingTimer = activeWindows[tipWindow] {
            existingTimer.invalidate()
        }
        
        // Create and store new timer
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                if tipWindow.isVisible {
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.3
                        tipWindow.animator().alphaValue = 0
                    }, completionHandler: {
                        if tipWindow.isVisible {
                            tipWindow.orderOut(nil)
                            self?.activeWindows.removeValue(forKey: tipWindow)
                        }
                    })
                }
            }
        }
        
        activeWindows[tipWindow] = timer
    }
} 
