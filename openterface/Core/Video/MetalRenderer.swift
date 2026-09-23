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
import MetalKit
import Foundation

/// Metal renderer for GPU-accelerated video frame rendering
///
/// This class manages the Metal render pipeline and executes GPU rendering
/// commands to display YUV textures with color space conversion.
class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)

    /// Initialize Metal renderer with a specific device
    init?(device: MTLDevice) {
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            print("❌ Failed to create Metal command queue")
            return nil
        }
        self.commandQueue = queue

        // Load shader functions from default library
        guard let library = device.makeDefaultLibrary() else {
            logger.log(content: "❌ Failed to create Metal default library")
            return nil
        }

        let vertexFunc = library.makeFunction(name: "vertex_main")
        let fragmentFunc = library.makeFunction(name: "fragment_main")

        guard let vertexFunction = vertexFunc, let fragmentFunction = fragmentFunc else {
            logger.log(content: "❌ Failed to load shader functions")
            return nil
        }

        // Configure render pipeline
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.label = "VideoRenderPipeline"
        pipelineDesc.vertexFunction = vertexFunction
        pipelineDesc.fragmentFunction = fragmentFunction
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Enable blending for smooth rendering
        pipelineDesc.colorAttachments[0].isBlendingEnabled = false

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
            logger.log(content: "✅ MetalRenderer initialized successfully")
        } catch {
            logger.log(content: "❌ Failed to create render pipeline state: \(error.localizedDescription)")
            return nil
        }
    }

    /// Render YUV textures to drawable
    /// - Parameters:
    ///   - yTexture: Y plane texture (luminance)
    ///   - uvTexture: UV plane texture (chrominance)
    ///   - drawable: Target drawable for rendering
    ///   - onComplete: Called once the GPU has finished rendering this frame
    func render(yTexture: MTLTexture, uvTexture: MTLTexture, to drawable: CAMetalDrawable, onComplete: @escaping () -> Void) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            logger.log(content: "❌ Failed to create command buffer")
            return
        }

        commandBuffer.label = "VideoFrameRenderCommand"

        // Create render pass descriptor manually
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture

        // Configure render pass
        renderPassDescriptor.colorAttachments[0].loadAction = .dontCare
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        // Create render command encoder
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            logger.log(content: "❌ Failed to create render command encoder")
            return
        }

        encoder.label = "VideoFrameEncoder"
        encoder.setRenderPipelineState(pipelineState)

        // Bind Y and UV textures to fragment shader
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)

        // Draw fullscreen quad (6 vertices: 2 triangles)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        // Present drawable via command buffer - ensures correct frame ordering
        // The drawable will be presented after GPU finishes rendering
        commandBuffer.present(drawable)

        // Schedule cleanup after GPU completes
        commandBuffer.addCompletedHandler { _ in
            onComplete()
        }

        commandBuffer.commit()
    }

    /// Get Metal device
    var metalDevice: MTLDevice {
        return device
    }
}
