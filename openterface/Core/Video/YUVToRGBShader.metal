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

#include <metal_stdlib>
using namespace metal;

// Vertex output structure
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Vertex shader: generates a fullscreen quad (two triangles)
// Using vertex_id to avoid needing a vertex buffer
// 6 vertices: 2 triangles covering the entire viewport
vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
    // Fullscreen quad positions in clip space (NDC: x,y from -1 to 1)
    // Triangle 1: bottom-left, bottom-right, top-right
    // Triangle 2: bottom-left, top-right, top-left
    const float2 positions[6] = {
        float2(-1.0, -1.0),  // 0: Bottom-left
        float2( 1.0, -1.0),  // 1: Bottom-right
        float2( 1.0,  1.0),  // 2: Top-right
        float2(-1.0, -1.0),  // 3: Bottom-left (same as 0)
        float2( 1.0,  1.0),  // 4: Top-right (same as 2)
        float2(-1.0,  1.0)   // 5: Top-left
    };

    // Texture coordinates with Y-flip
    // CVPixelBuffer has origin at top-left (row 0 = top of image)
    // Metal texture with normalized coordinates has (0,0) at bottom-left
    // So we need to flip Y: viewport top (clip y=1) → texture V=0 (image top)
    //                       viewport bottom (clip y=-1) → texture V=1 (image bottom)
    const float2 texCoords[6] = {
        float2(0.0, 1.0),    // 0: Bottom-left → texture bottom-left
        float2(1.0, 1.0),    // 1: Bottom-right → texture bottom-right
        float2(1.0, 0.0),    // 2: Top-right → texture top-right
        float2(0.0, 1.0),    // 3: Bottom-left → texture bottom-left
        float2(1.0, 0.0),    // 4: Top-right → texture top-right
        float2(0.0, 0.0)     // 5: Top-left → texture top-left
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Fragment shader: YUV to RGB color space conversion
// Converts NV12 format (Y + UV planes) to RGB
// Uses BT.709 color space standard for HD video
fragment float4 fragment_main(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> yTexture  [[texture(0)]],
    texture2d<float, access::sample> uvTexture [[texture(1)]]
) {
    // Sampler: clamp_to_edge ensures coordinates outside [0,1] don't wrap
    // linear filtering for smooth interpolation
    // normalized coordinates (0.0 to 1.0 range)
    constexpr sampler sam(address::clamp_to_edge, filter::linear, coord::normalized);

    // Sample Y (luminance) and UV (chrominance) channels
    // Both use the same normalized coordinates (0,0)-(1,1)
    float y = yTexture.sample(sam, in.texCoord).r;
    float2 uv = uvTexture.sample(sam, in.texCoord).rg;

    // Convert from video range [16, 235] to full range [0, 255]
    // Then normalize to [0, 1] for shader calculations
    float yNorm = (y - 16.0 / 255.0) * (255.0 / 219.0);

    // Center UV values around 0
    float u = uv.x - 0.5;
    float v = uv.y - 0.5;

    // BT.709 color space conversion matrix
    // [R]   [ 1.0       0.0         1.5748]   [Y']
    // [G] = [ 1.0      -0.1873     -0.4681] * [Cb]
    // [B]   [ 1.0       1.8556      0.0    ]   [Cr]
    float r = yNorm + 1.5748 * v;
    float g = yNorm - 0.1873 * u - 0.4681 * v;
    float b = yNorm + 1.8556 * u;

    // Clamp to valid color range [0, 1]
    r = saturate(r);
    g = saturate(g);
    b = saturate(b);

    return float4(r, g, b, 1.0);
}