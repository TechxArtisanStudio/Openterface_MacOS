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
*    Public License for more details.                                        *
*                                                                            *
*    You should have received a copy of the GNU General Public License       *
*    along with this program. If not, see <http://www.gnu.org/licenses/>.    *
*                                                                            *
* ========================================================================== *
*/

import MetalKit
import CoreVideo
import Foundation
import Metal

/// Metal-based video view for displaying camera frames
///
/// This view replaces AVCaptureVideoPreviewLayer with Metal rendering
/// to provide zero-copy frame processing and better performance at high resolutions.
class VideoMetalView: MTKView {
    private var renderer: MetalRenderer?
    private var textureManager: MetalTextureManager?
    private let logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)

    // Current frame textures (accessed from render loop)
    private var currentYTexture: MTLTexture?
    private var currentUVTexture: MTLTexture?
    private var currentRefs: MetalTextureManager.TextureRefs?  // For GPU completion handler
    /// Refs from frames that were overwritten before being drawn.
    /// Must be released after the NEXT successful GPU render completes,
    /// because draw() may have already sampled the previous frame's textures
    /// before updateFrame() replaced them.
    private var pendingOrphanRefs: [MetalTextureManager.TextureRefs] = []

    /// Frame version counter — incremented each updateFrame(), read by draw()
    /// to detect if the render loop is falling behind (skipping frames).
    private var frameVersion: UInt64 = 0
    private var lastRenderedVersion: UInt64 = 0
    private var framesSkipped: UInt64 = 0

    /// Frame throttle: skip every Nth frame to reduce USB bandwidth pressure.
    /// Set to 1 = no throttle, 2 = skip every other frame (30fps from 60fps capture).
    /// This is a DIAGNOSTIC tool — if flickering stops at 30fps, it confirms
    /// the issue is USB bandwidth saturation at high resolution.
    private let frameSkipDivisor: Int = 1  // 1 = no throttle
    private var frameSkipCounter: Int = 0

    /// Queue to synchronize texture updates from video callback
    private let textureUpdateQueue = DispatchQueue(label: "com.openterface.videometalview.textureupdate")

    /// Frame rate measurement
    private var frameCount: Int = 0
    private var lastFrameRateLogTime: Date = Date()
    private var drawCount: Int = 0
    private var lastDrawLogTime: Date = Date()

    /// Initialize the Metal video view
    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)

        guard let metalDevice = device else {
            logger.log(content: "❌ No Metal device provided")
            return
        }

        self.renderer = MetalRenderer(device: metalDevice)
        self.textureManager = MetalTextureManager(device: metalDevice)

        // Configure MTKView — let VSync drive the render loop.
        // Setting isPaused to true prevents currentDrawable from being
        // available, which causes persistent black screen.
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.isPaused = false           // VSync-driven render loop (draw() called at display refresh)
        self.enableSetNeedsDisplay = false // Not needed — VSync drives rendering automatically
        self.preferredFramesPerSecond = 60
        self.depthStencilPixelFormat = .invalid

        // Set explicit black background to avoid green screen at startup
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.layer?.backgroundColor = NSColor.black.cgColor

        logger.log(content: "✅ VideoMetalView initialized successfully")

        // 检测显示器刷新率并让 MTKView 适配它（不修改显示器设置）
        let displayRefreshRate: Int
        if let window = self.window, let screen = window.screen {
            let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
            displayRefreshRate = Self.getDisplayRefreshRate(displayId: displayId)
        } else {
            displayRefreshRate = Self.getDisplayRefreshRate(displayId: CGMainDisplayID())
        }
        // Match MTKView's render rate to the display's native refresh rate.
        // This avoids frame rate oscillation (e.g., 60fps preferred on 75Hz → 37.5fps actual).
        self.preferredFramesPerSecond = displayRefreshRate
        logger.log(content: "🎯 MTKView preferredFramesPerSecond set to \(displayRefreshRate) (matching display)")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Update the view with a new frame from CVPixelBuffer
    /// Called from video capture thread - stores latest frame for rendering
    /// - Parameter pixelBuffer: NV12 format pixel buffer from camera
    ///
    /// PERFORMANCE: Texture creation (the expensive part) happens OUTSIDE the
    /// textureUpdateQueue lock, so the render loop's draw() is not blocked.
    /// Only the brief pointer swap is done under the lock.
    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let textureManager = textureManager else { return }

        // Measure actual frame rate
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFrameRateLogTime)
        if elapsed >= 5.0 {  // Log every 5 seconds instead of every second
            let fps = Double(frameCount) / elapsed
            logger.log(content: "📊 Actual capture FPS: \(String(format: "%.1f", fps))")
            frameCount = 0
            lastFrameRateLogTime = now
        }

        // DIAGNOSTIC: Frame throttle to test USB bandwidth hypothesis.
        // Skip every Nth frame to halve the effective capture rate.
        if frameSkipDivisor > 1 {
            frameSkipCounter += 1
            if frameSkipCounter % frameSkipDivisor != 0 {
                return  // Skip this frame — don't create textures
            }
        }

        // Create Metal textures from pixel buffer (zero-copy) — OUTSIDE the lock.
        // CVMetalTextureCache is thread-safe, so this can run on the capture thread.
        // At 2560x1440 this can take several milliseconds; we must not block draw().
        guard let result = textureManager.createTextures(from: pixelBuffer) else {
            return
        }

        // Swap textures and refs under the lock — this is fast (just pointer writes).
        // If the previous frame's refs haven't been drawn yet (updateFrame was called
        // again before draw()), they become orphans. We hold them in pendingOrphanRefs
        // and release them after the NEXT GPU render completes.
        textureUpdateQueue.sync {
            if let oldRefs = self.currentRefs {
                // The previous frame was overwritten before being drawn.
                // Append to orphan list; draw() will release them all.
                self.pendingOrphanRefs.append(oldRefs)
            }
            self.currentYTexture = result.yTexture
            self.currentUVTexture = result.uvTexture
            self.currentRefs = result.refs
            self.frameVersion &+= 1
        }
    }

    /// MTKView draw method - called automatically by the render loop at VSync
    override func draw(_ rect: CGRect) {
        guard let drawable = currentDrawable else { return }
        guard let renderer = renderer else { return }
        guard let textureManager = textureManager else { return }

        // Get latest textures and refs (thread-safe)
        var yTexture: MTLTexture?
        var uvTexture: MTLTexture?
        var refs: MetalTextureManager.TextureRefs?
        var orphanRefs: [MetalTextureManager.TextureRefs] = []
        var currentVersion: UInt64 = 0
        let drawStartTime = Date()
        textureUpdateQueue.sync {
            yTexture = self.currentYTexture
            uvTexture = self.currentUVTexture
            refs = self.currentRefs
            currentVersion = self.frameVersion
            // Pick up orphaned refs from frames that were overwritten before draw()
            orphanRefs = self.pendingOrphanRefs
            self.pendingOrphanRefs.removeAll()
        }

        // Render the latest frame if we have textures
        if let yTexture = yTexture, let uvTexture = uvTexture, let refs = refs {
            // Diagnostic: detect if render loop is skipping frames
            let skipped = Int64(currentVersion) - Int64(lastRenderedVersion) - 1
            if skipped > 0 {
                framesSkipped &+= UInt64(skipped)
                if framesSkipped % 60 == 0 || skipped > 5 {
                    logger.log(content: "📉 Frame skip: \(skipped) frames dropped (total skipped: \(framesSkipped), orphans: \(orphanRefs.count))")
                }
            }
            lastRenderedVersion = currentVersion

            // Retain refs before rendering — ensures the CVMetalTexture stays valid
            // even if multiple command buffers use the same texture (e.g., when draw()
            // is called multiple times before updateFrame() creates new textures).
            textureManager.retainRefs(refs)
            for orphan in orphanRefs {
                textureManager.retainRefs(orphan)
            }

            renderer.render(yTexture: yTexture, uvTexture: uvTexture, to: drawable) {
                // GPU finished — release the CVMetalTexture refs for this command buffer.
                // The refs will only be actually freed when ALL command buffers that
                // retained them have completed (reference counting).
                textureManager.releaseRefs(refs)
                for orphan in orphanRefs {
                    textureManager.releaseRefs(orphan)
                }
            }
        }
        // If no textures available, the clear color (black) will be shown

        // Measure draw FPS
        drawCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastDrawLogTime)
        if elapsed >= 1.0 {
            let fps = Double(drawCount) / elapsed
            let drawTime = now.timeIntervalSince(drawStartTime) * 1000
            logger.log(content: "🎨 Render FPS: \(String(format: "%.1f", fps)), draw() time: \(String(format: "%.1f", drawTime))ms")
            drawCount = 0
            lastDrawLogTime = now
        }
    }

    /// Get the current frame as a CGImage (for screenshots)
    func getCurrentFrameAsCGImage() -> CGImage? {
        var yTexture: MTLTexture? = nil
        textureUpdateQueue.sync {
            yTexture = self.currentYTexture
        }

        guard let texture = yTexture else { return nil }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&data, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
              let cgImage = context.makeImage() else { return nil }
        return cgImage
    }

    /// 获取显示器当前刷新率（用于 MTKView 适配）
    static func getDisplayRefreshRate(displayId: CGDirectDisplayID) -> Int {
        if let mode = CGDisplayCopyDisplayMode(displayId) {
            return Int(mode.refreshRate)
        }
        return 60  // 默认值
    }

    deinit {
        logger.log(content: "🧹 VideoMetalView deinitialized")
    }
}
