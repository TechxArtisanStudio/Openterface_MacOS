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
import AVFoundation
import CoreMedia

/// Represents a video format selection made by the user
struct VideoFormat: Equatable, Hashable {
    let resolution: VideoResolution
    let frameRate: Float
    let pixelFormat: String // FourCC as string for simplicity

    var description: String {
        let formatName: String
        switch pixelFormat {
        case String(format: "0x%X", kCVPixelFormatType_32BGRA):
            formatName = "BGRA"
        case String(format: "0x%X", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange):
            formatName = "420v"
        case String(format: "0x%X", kCVPixelFormatType_420YpCbCr8BiPlanarFullRange):
            formatName = "420f"
        case String(format: "0x%X", kCVPixelFormatType_422YpCbCr8):
            formatName = "422"
        case String(format: "0x%X", kCMVideoCodecType_JPEG):
            formatName = "MJPEG"
        case String(format: "0x%X", kCMVideoCodecType_H264):
            formatName = "H.264"
        default:
            formatName = "Unknown(\(pixelFormat))"
        }
        return "\(resolution.width)x\(resolution.height)@\(Int(frameRate))fps \(formatName)"
    }
}
