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

extension AVCaptureDevice.Format {
    /// Converts to our VideoFormat model
    func toVideoFormat() -> VideoFormat {
        let dimensions = CMVideoFormatDescriptionGetDimensions(self.formatDescription)
        let codecType = CMFormatDescriptionGetMediaSubType(self.formatDescription)
        let pixelFormat = String(format: "0x%X", codecType)

        // Get all supported frame rates and filter by device capability
        let supportedFrameRates = videoSupportedFrameRateRanges
            .flatMap { range -> [Float] in
                // Generate common frame rates within the supported range
                var rates: [Float] = []
                let commonRates: [Float] = [15, 24, 25, 30, 50, 60]
                for rate in commonRates {
                    if Float(rate) >= Float(range.minFrameRate) && Float(rate) <= Float(range.maxFrameRate) {
                        rates.append(rate)
                    }
                }
                return rates
            }

        let maxFps = supportedFrameRates.max() ?? 30.0

        return VideoFormat(
            resolution: VideoResolution(width: Int(dimensions.width), height: Int(dimensions.height), refreshRate: Float(maxFps)),
            frameRate: Float(maxFps),
            pixelFormat: pixelFormat
        )
    }

    /// Creates a format string for display
    var displayName: String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(self.formatDescription)
        let codecType = CMFormatDescriptionGetMediaSubType(self.formatDescription)

        // Get friendly name for pixel format
        let formatName: String
        switch codecType {
        case kCVPixelFormatType_32BGRA:
            formatName = "BGRA"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            formatName = "420v"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            formatName = "420f"
        case kCVPixelFormatType_422YpCbCr8:
            formatName = "422"
        case kCVPixelFormatType_422YpCbCr8_yuvs:
            formatName = "422 (yuvs)"
        case kCMVideoCodecType_JPEG:
            formatName = "MJPEG"
        case kCMVideoCodecType_H264:
            formatName = "H.264"
        default:
            let bytes: [UInt8] = [
                UInt8((codecType >> 24) & 0xFF),
                UInt8((codecType >> 16) & 0xFF),
                UInt8((codecType >> 8) & 0xFF),
                UInt8(codecType & 0xFF)
            ]
            formatName = String(bytes: bytes, encoding: .ascii) ?? "Unknown"
        }

        let maxFps = videoSupportedFrameRateRanges
            .map { $0.maxFrameRate }
            .max() ?? 0.0

        return "\(Int(dimensions.width))x\(Int(dimensions.height)) @ \(Int(maxFps))fps \(formatName)"
    }
}
