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

import AVFoundation
import MetalKit
import CoreVideo
import Foundation
import Metal
import QuartzCore

// MARK: - Notification Names for Frame Anomaly Detection
extension Notification.Name {
    /// Posted when frame content anomaly is detected (potential screen corruption/flickering)
    static let frameAnomalyDetected = Notification.Name("frameAnomalyDetected")

    /// Posted when Metal device error occurs (GPU timeout, memory corruption, etc.)
    static let metalDeviceError = Notification.Name("metalDeviceError")

    /// Posted when the view starts/stops showing live captured frames.
    /// userInfo["isLive"]: Bool. object: the VideoMetalView instance.
    static let videoFrameAvailabilityChanged = Notification.Name("videoFrameAvailabilityChanged")
}

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

    /// Timestamp (CACurrentMediaTime) of the last frame accepted from the
    /// capture thread. Guarded by textureUpdateQueue.
    private var lastFrameUpdateTime: TimeInterval = 0

    /// True while the cached textures represent a live capture stream.
    /// Guarded by textureUpdateQueue.
    private var isShowingLiveFrame = false

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

    // MARK: - Frame Anomaly Detection Properties

    /// Frame content anomaly detection (screen corruption/flickering)
    private var lastFrameHash: UInt64 = 0
    private var contentAnomalyCount: Int = 0
    private let contentAnomalyThreshold: Int = 5  // Consecutive anomalous frames before alert

    /// Frame timestamp anomaly detection (frame rate jitter)
    private var lastFrameTimestamp: CMTime = .invalid
    private var timestampAnomalyCount: Int = 0
    private let timestampAnomalyThreshold: Int = 5  // Consecutive anomalous timestamps before alert

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

        // Set up frame anomaly detection auto-recovery strategy
        setupAnomalyRecoveryObserver()

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
        var becameLive = false
        textureUpdateQueue.sync {
            if let oldRefs = self.currentRefs {
                // The previous frame was overwritten before being drawn.
                // Append to orphan list; draw() will release them all.
                self.pendingOrphanRefs.append(oldRefs)
            }
            self.currentYTexture = result.yTexture
            self.currentUVTexture = result.uvTexture
            self.currentRefs = result.refs
            self.lastFrameUpdateTime = CACurrentMediaTime()
            self.frameVersion &+= 1
            if !self.isShowingLiveFrame {
                self.isShowingLiveFrame = true
                becameLive = true
            }
        }

        if becameLive {
            logger.log(content: "🟢 First live frame accepted — capture stream is live")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                NotificationCenter.default.post(
                    name: .videoFrameAvailabilityChanged,
                    object: self,
                    userInfo: ["isLive": true]
                )
            }
        }
    }

    /// Whether the view currently holds frames from a live capture stream.
    var hasLiveFrame: Bool {
        textureUpdateQueue.sync { isShowingLiveFrame }
    }

    /// Seconds since the last frame arrived. `.infinity` when no live frame
    /// has ever been accepted (or it was cleared), so callers can treat a
    /// running-but-silent session as a zombie.
    func secondsSinceLastFrame() -> TimeInterval {
        textureUpdateQueue.sync {
            guard isShowingLiveFrame, lastFrameUpdateTime > 0 else { return .infinity }
            return CACurrentMediaTime() - lastFrameUpdateTime
        }
    }

    /// Drop the cached frame and pending texture references so the next draw
    /// shows the clear color (black / hidden view) instead of a frozen image.
    /// Call on device loss, session stop, or when staleness is detected.
    func clearFrame() {
        var wasLive = false
        textureUpdateQueue.sync {
            wasLive = self.isShowingLiveFrame
            self.currentYTexture = nil
            self.currentUVTexture = nil
            self.currentRefs = nil
            self.pendingOrphanRefs.removeAll()
            self.lastFrameUpdateTime = 0
            self.isShowingLiveFrame = false
            self.frameVersion &+= 1
        }

        lastFrameHash = 0
        contentAnomalyCount = 0

        guard wasLive else { return }
        logger.log(content: "⚪ Live stream cleared — no live frames")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            NotificationCenter.default.post(
                name: .videoFrameAvailabilityChanged,
                object: self,
                userInfo: ["isLive": false]
            )
        }
    }

    /// Detect frame content anomaly (screen corruption/flickering)
    /// Samples 4x4 pixels and computes FNV-1a hash to detect drastic changes between frames
    /// - Parameter yTexture: The Y plane texture to sample
    private func detectContentAnomaly(yTexture: MTLTexture) {
        // Sample every 30 frames to further reduce overhead
        if drawCount % 30 != 0 { return }

        // Sample 4x4 = 16 pixels (extremely low overhead)
        var pixels = [UInt32](repeating: 0, count: 16)
        let region = MTLRegionMake2D(0, 0, 4, 4)
        yTexture.getBytes(&pixels, bytesPerRow: 16, from: region, mipmapLevel: 0)

        // FNV-1a hash
        var hash: UInt64 = 1469598103934665603  // FNV offset basis
        for p in pixels {
            hash ^= UInt64(p)
            hash &*= 1099511628211  // FNV prime
        }

        // Detect anomalous jumps
        if lastFrameHash != 0 {
            let diff = hash ^ lastFrameHash
            let changedBits = diff.nonzeroBitCount

            // If more than 50% of bits changed, consider it anomalous
            // 16 pixels * 32 bits = 512 bits total, 50% = 256 bits
            if changedBits > 256 {
                contentAnomalyCount += 1
                if contentAnomalyCount >= contentAnomalyThreshold {
                    logger.log(content: "🚨 Suspected screen corruption/flickering: \(contentAnomalyCount) consecutive frames with drastic content changes")
                    NotificationCenter.default.post(name: .frameAnomalyDetected, object: nil)
                    contentAnomalyCount = 0  // Reset to avoid repeated alerts
                }
            } else {
                contentAnomalyCount = 0
            }
        }
        lastFrameHash = hash
    }

    /// Detect frame timestamp anomaly (frame rate jitter)
    /// Validates that frame intervals match expected timing (e.g., ~16.67ms for 60fps)
    /// - Parameter timestamp: The presentation timestamp of the frame
    func detectTimestampAnomaly(timestamp: CMTime) {
        if CMTimeCompare(lastFrameTimestamp, .invalid) != 0 {
            let diff = CMTimeSubtract(timestamp, lastFrameTimestamp)
            let expectedInterval = CMTime(value: 1, timescale: 60)  // 16.67ms
            let tolerance = CMTime(value: 1, timescale: 240)        // ~4ms tolerance

            let lowerBound = CMTimeSubtract(expectedInterval, tolerance)
            let upperBound = CMTimeAdd(expectedInterval, tolerance)

            if CMTimeCompare(diff, lowerBound) < 0 || CMTimeCompare(diff, upperBound) > 0 {
                timestampAnomalyCount += 1
                if timestampAnomalyCount >= timestampAnomalyThreshold {
                    logger.log(content: "⚠️ Frame rate jitter: \(timestampAnomalyCount) consecutive frames with anomalous timestamps")
                    timestampAnomalyCount = 0
                }
            } else {
                timestampAnomalyCount = 0
            }
        }
        lastFrameTimestamp = timestamp
    }

    /// MTKView draw method - called automatically by the render loop at VSync
    override func draw(_ rect: CGRect) {
        guard let drawable = currentDrawable else { return }
        guard let renderer = renderer else { return }
        guard let textureManager = textureManager else { return }

        // Drop stale frames: capture can stop without the session stopping
        // (device unplugged mid-stream). Re-rendering the cached textures
        // would freeze the last frame on screen indefinitely.
        var stale = false
        textureUpdateQueue.sync {
            stale = VideoRecoveryPolicy.isFrameStale(lastUpdate: self.lastFrameUpdateTime,
                                                     now: CACurrentMediaTime(),
                                                     isLive: self.isShowingLiveFrame)
        }
        if stale {
            clearFrame()
        }

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
            // Frame anomaly detection: check for content corruption/flickering
            detectContentAnomaly(yTexture: yTexture)

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

    /// Set up observer for frame anomaly detection to trigger auto-recovery
    private func setupAnomalyRecoveryObserver() {
        NotificationCenter.default.addObserver(
            forName: .frameAnomalyDetected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // Strategy 1: Rebuild texture cache (safest, minimal disruption)
            self.textureManager?.flushCache()
            self.logger.log(content: "🔄 Texture cache rebuilt due to frame anomaly detection")

            // Note: More aggressive strategies (resetting renderer, reapplying video format)
            // are not implemented in Phase 1 to minimize risk. They can be added later
            // if texture cache rebuild proves insufficient.
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        logger.log(content: "🧹 VideoMetalView deinitialized")
    }
}
