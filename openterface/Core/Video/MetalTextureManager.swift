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

import Metal
import CoreVideo
import Foundation

/// Manages Metal texture cache for zero-copy CVPixelBuffer to MTLTexture conversion
///
/// This class provides efficient GPU texture creation from camera frames using
/// CVMetalTextureCache, which automatically manages texture lifecycle and supports
/// planar formats like NV12 (Y + UV planes).
class MetalTextureManager {
    private var textureCache: CVMetalTextureCache?
    private let device: MTLDevice
    private let logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)

    /// Per-frame CVMetalTexture references, retained until the GPU finishes rendering that frame.
    ///
    /// The CVMetalTexture is what retains the backing CVPixelBuffer / IOSurface.
    /// If it is released while the GPU is still sampling the extracted MTLTexture,
    /// the capture session may recycle the pixel buffer and the GPU reads corrupted
    /// memory — the primary cause of high-resolution flickering.
    ///
    /// Each call to `createTextures` returns a `TextureRefs` handle. The caller passes
    /// it back via `releaseRetainedRefs(_:)` from a GPU completion handler, which
    /// safely frees the backing storage after the GPU is done.
    struct TextureRefs {
        let y: CVMetalTexture
        let uv: CVMetalTexture
    }

    private var retainedRefsPool: [TextureRefs] = []
    private var refsUsageCount: [ObjectIdentifier: Int] = [:]  // Track how many command buffers use each refs
    private let refLock = DispatchQueue(label: "com.openterface.metaltexturemanager.reflock")

    // Logging optimization: only log format info once or on resolution change
    private var didLogFormatInfo = false
    private var lastLoggedWidth: Int = 0
    private var lastLoggedHeight: Int = 0

    /// Maximum pool size as a safety net. Normal operation keeps 1-2 refs;
    /// if the pool grows beyond this, something is seriously wrong and we
    /// must not leak memory unboundedly.
    private let maxPoolSize = 8

    /// Initialize Metal texture manager with a specific device
    init?(device: MTLDevice) {
        self.device = device

        // Create texture cache for zero-copy texture creation
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)

        guard result == kCVReturnSuccess, let validCache = cache else {
            print("❌ Failed to create Metal texture cache: \(result)")
            return nil
        }

        self.textureCache = validCache
        logger.log(content: "✅ MetalTextureManager initialized successfully")
    }

    /// Create Metal textures from CVPixelBuffer (zero-copy)
    /// - Parameter pixelBuffer: NV12 format pixel buffer
    /// - Returns: Tuple of (Y texture, UV texture) and a TextureRefs handle
    ///   that must be released via `releaseRetainedRefs(_:)` once the GPU
    ///   finishes rendering with these textures.
    ///
    /// NV12 format has two planes:
    /// - Y plane: luminance, full resolution (width x height)
    /// - UV plane: chrominance, half resolution (width/2 x height/2)
    ///
    /// IMPORTANT: The returned MTLTextures share backing storage with the
    /// CVPixelBuffer's IOSurface. The CVMetalTexture refs that hold the
    /// pixel buffer are retained internally until the caller calls
    /// `releaseRetainedRefs(_:)`, so the caller does NOT need to retain
    /// the pixel buffer separately.
    func createTextures(from pixelBuffer: CVPixelBuffer) -> (yTexture: MTLTexture, uvTexture: MTLTexture, refs: TextureRefs)? {
        guard let textureCache = textureCache else {
            logger.log(content: "❌ Texture cache not initialized")
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)

        // DIAGNOSTIC: Log pixel format info only on first call
        // logger.log(content: "🔍 [DIAG] createTextures: \(width)x\(height), format=\(formatStr), planes=\(planeCount)")

        var yTextureRef: CVMetalTexture?
        var uvTextureRef: CVMetalTexture?

        // Create Y plane texture (single channel, full resolution)
        let yResult = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,      // Y plane is single channel 8-bit
            width,
            height,
            0,             // plane 0 = Y
            &yTextureRef
        )

        guard yResult == kCVReturnSuccess, let yRef = yTextureRef else {
            logger.log(content: "❌ Failed to create Y texture: \(yResult)")
            return nil
        }

        // Create UV plane texture (two channels, half resolution)
        let uvResult = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg8Unorm,     // UV plane is two channels 8-bit
            width / 2,
            height / 2,
            1,             // plane 1 = UV
            &uvTextureRef
        )

        guard uvResult == kCVReturnSuccess, let uvRef = uvTextureRef else {
            logger.log(content: "❌ Failed to create UV texture: \(uvResult)")
            return nil
        }

        // Convert CVMetalTexture to MTLTexture
        guard let yMTLTexture = CVMetalTextureGetTexture(yRef),
              let uvMTLTexture = CVMetalTextureGetTexture(uvRef) else {
            logger.log(content: "❌ Failed to convert CVMetalTexture to MTLTexture")
            return nil
        }

        // Log texture info
        // logger.log(content: "✅ Y texture: \(yMTLTexture.width)x\(yMTLTexture.height), format=\(yMTLTexture.pixelFormat)")
        // logger.log(content: "✅ UV texture: \(uvMTLTexture.width)x\(uvMTLTexture.height), format=\(uvMTLTexture.pixelFormat)")

        // Create refs handle.
        // NOTE: We do NOT add to retainedRefsPool here. The refs are kept alive by
        // the caller (VideoMetalView.currentRefs or pendingOrphanRefs). They only enter
        // the pool when draw() calls retainRefs, ensuring the pool size matches actual
        // GPU usage — not capture rate. At high resolutions (2560x1440) the capture
        // thread produces frames faster than draw() can consume them, causing orphans
        // to accumulate. Adding to pool here would cause double-entry (createTextures
        // + retainRefs) and overflow drops that corrupt GPU textures mid-render.
        let refs = TextureRefs(y: yRef, uv: uvRef)

        return (yMTLTexture, uvMTLTexture, refs)
    }

    /// Flush texture cache to prevent memory leaks
    /// Should be called when the view is torn down or the capture session stops.
    /// Do NOT call per-frame — it releases the CVMetalTexture refs that keep
    /// the backing pixel buffer alive during GPU rendering.
    func flushCache() {
        guard let textureCache = textureCache else { return }
        CVMetalTextureCacheFlush(textureCache, 0)
        refLock.sync {
            retainedRefsPool.removeAll()
        }
    }

    /// Retain a refs handle for use by a command buffer.
    /// Each call to `retainRefs` must be balanced by a call to `releaseRefs`.
    /// The underlying CVMetalTexture will only be released when all command buffers
    /// that retained it have completed.
    func retainRefs(_ refs: TextureRefs) {
        let id = ObjectIdentifier(refs.y)
        refLock.sync {
            refsUsageCount[id, default: 0] += 1
            // Ensure refs is in the pool
            if !retainedRefsPool.contains(where: { $0.y === refs.y && $0.uv === refs.uv }) {
                retainedRefsPool.append(refs)
            }
        }
    }

    /// Release a refs handle after a command buffer completes.
    /// The underlying CVMetalTexture will only be released when all command buffers
    /// that retained it have completed (usage count reaches 0).
    func releaseRefs(_ refs: TextureRefs) {
        let id = ObjectIdentifier(refs.y)
        refLock.sync {
            if let count = refsUsageCount[id] {
                if count <= 1 {
                    // Last reference — remove from pool and usage count
                    refsUsageCount.removeValue(forKey: id)
                    retainedRefsPool.removeAll { $0.y === refs.y && $0.uv === refs.uv }
                } else {
                    // Still in use by other command buffers
                    refsUsageCount[id] = count - 1
                }
            }
        }
    }

    /// Release specific per-frame CVMetalTexture references once the GPU has
    /// finished rendering that frame. Called from a command buffer completion
    /// handler to ensure the backing IOSurface stays valid for the duration
    /// of GPU sampling.
    ///
    /// DEPRECATED: Use `retainRefs`/`releaseRefs` instead for proper reference counting.
    func releaseRetainedRefs(_ refs: TextureRefs) {
        releaseRefs(refs)
    }

    /// Get Metal device
    var metalDevice: MTLDevice {
        return device
    }
}
