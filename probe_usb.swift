/*
 * MS2130S USB Descriptor Probe
 *
 * This tool probes the MS2130S USB video capture device to check if it
 * supports 120fps video formats via MJPEG compression.
 *
 * Build and run from Xcode as part of the Openterface project.
 */

import Foundation
import AVFoundation

class MS2130SProbe {
    static let VENDOR_ID = 0x345F
    static let PRODUCT_ID = 0x2132

    static func probe() {
        print("=== MS2130S USB Descriptor Probe ===")
        print()

        // List all video capture devices
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )

        print("Found \(discoverySession.devices.count) video capture devices:")
        print()

        for device in discoverySession.devices {
            print("Device: \(device.localizedName)")
            print("  Unique ID: \(device.uniqueID)")
            print("  Model ID: \(device.modelID)")

            // Check if this is our MS2130S
            if isMS2130S(device: device) {
                print("  ✅ This is MS2130S!")
                probeDeviceFormats(device: device)
            }
            print()
        }

        print("=== Probe Complete ===")
    }

    private static func isMS2130S(device: AVCaptureDevice) -> Bool {
        // Check by device name or other identifiers
        let name = device.localizedName.lowercased()
        return name.contains("openterface") ||
               name.contains("ms2130") ||
               name.contains("capture")
    }

    private static func probeDeviceFormats(device: AVCaptureDevice) {
        print()
        print("Probing supported formats:")
        print()

        var formatIndex = 0
        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let codecType = CMFormatDescriptionGetMediaSubType(desc)
            let codecName = codecTypeToString(codecType)

            print("Format \(formatIndex): \(dims.width)x\(dims.height)")
            print("  Codec: \(codecName) (0x\(String(format: "%08X", codecType)))")

            // Get frame rate ranges
            if let frameRateRanges = format.videoSupportedFrameRateRanges as? [AVFrameRateRange] {
                for range in frameRateRanges {
                    let minFps = range.minFrameRate
                    let maxFps = range.maxFrameRate

                    if minFps == maxFps {
                        print("  Frame Rate: \(String(format: "%.2f", maxFps)) fps")
                    } else {
                        print("  Frame Rate: \(String(format: "%.2f", minFps))-\(String(format: "%.2f", maxFps)) fps")
                    }

                    // Highlight high frame rates
                    if maxFps >= 120.0 {
                        print("  ⚡️ HIGH FRAME RATE DETECTED!")
                    }
                }
            }

            // Check for MJPEG specifically
            if codecType == kCMVideoCodecType_JPEG {
                print("  🎬 JPEG FORMAT FOUND!")
            }

            print()
            formatIndex += 1
        }

        // Summary
        print("Summary for \(device.localizedName):")
        let allFormats = device.formats
        let maxFrameRate = allFormats.compactMap { format -> Double? in
            guard let ranges = format.videoSupportedFrameRateRanges as? [AVFrameRateRange] else { return nil }
            return ranges.map { $0.maxFrameRate }.max()
        }.max() ?? 0

        print("  Maximum frame rate: \(String(format: "%.2f", maxFrameRate)) fps")

        if maxFrameRate >= 120.0 {
            print("  ✅ Device supports 120fps!")
        } else {
            print("  ❌ Device does NOT support 120fps via AVFoundation")
            print()
            print("  This means:")
            print("  1. The device may not support 120fps at all")
            print("  2. OR the macOS UVC driver doesn't expose 120fps formats")
            print("  3. OR 120fps requires a different codec (MJPEG) that the driver doesn't support")
        }
    }

    private static func codecTypeToString(_ codecType: FourCharCode) -> String {
        switch codecType {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return "NV12 (420YpCbCr8BiPlanarVideoRange)"
        case kCVPixelFormatType_422YpCbCr8:
            return "UYVY (422YpCbCr8)"
        case kCMVideoCodecType_JPEG:
            return "JPEG"
        case kCMVideoCodecType_H264:
            return "H.264"
        default:
            // Try to convert FourCC to string
            let bytes = [
                UInt8((codecType >> 24) & 0xFF),
                UInt8((codecType >> 16) & 0xFF),
                UInt8((codecType >> 8) & 0xFF),
                UInt8(codecType & 0xFF)
            ]
            if let str = String(bytes: bytes, encoding: .utf8) {
                return str
            }
            return "Unknown"
        }
    }
}

// Run the probe
MS2130SProbe.probe()
