#!/usr/bin/env swift
// Simple AVFoundation format enumeration - no capture attempt
import Foundation
import AVFoundation
import CoreMedia

print("=== AVFoundation Format Enumeration (USB 3.0) ===")
print()

// Check camera permission
if #available(macOS 14.0, *) {
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .video) { ok in
        granted = ok
        sem.signal()
    }
    let _ = sem.wait(timeout: .now() + 10)
    if !granted {
        print("❌ Camera permission denied")
        exit(1)
    }
    print("✅ Camera permission granted")
    print()
}

// Discover devices
let discoverySession = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external],
    mediaType: .video,
    position: .unspecified
)

let devices = discoverySession.devices
print("Found \(devices.count) external video capture device(s)")
print()

guard !devices.isEmpty else {
    print("❌ No external video capture devices found")
    print("   Make sure the MS2130S is connected via USB 3.0")
    exit(0)
}

for (idx, device) in devices.enumerated() {
    print("Device \(idx): \(device.localizedName)")
    print("  Model: \(device.modelID)")
    print("  Unique ID: \(device.uniqueID)")
    print()

    // Count formats by frame rate capability
    var formats60fps = 0
    var formats120fps = 0
    var maxFpsOverall: Double = 0

    print("  Formats (\(device.formats.count) total):")
    print("  " + String(repeating: "-", count: 70))

    for (i, format) in device.formats.enumerated() {
        let desc = format.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let codec = CMFormatDescriptionGetMediaSubType(desc)

        // Get codec name
        var codecName = "Unknown"
        switch codec {
        case kCMVideoCodecType_JPEG:
            codecName = "MJPEG"
        case kCMVideoCodecType_H264:
            codecName = "H.264"
        case kCVPixelFormatType_422YpCbCr8:
            codecName = "UYVY"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            codecName = "NV12"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            codecName = "NV12-full"
        default:
            let bytes: [UInt8] = [
                UInt8((codec >> 24) & 0xFF),
                UInt8((codec >> 16) & 0xFF),
                UInt8((codec >> 8) & 0xFF),
                UInt8(codec & 0xFF)
            ]
            codecName = String(bytes: bytes, encoding: .ascii) ?? "Unknown"
        }

        // Get max frame rate
        let ranges = format.videoSupportedFrameRateRanges
        let maxFps = ranges.map { $0.maxFrameRate }.max() ?? 0
        let minFps = ranges.map { $0.minFrameRate }.min() ?? 0

        if maxFps >= 120 { formats120fps += 1 }
        else if maxFps >= 60 { formats60fps += 1 }
        if maxFps > maxFpsOverall { maxFpsOverall = maxFps }

        let marker = maxFps >= 120 ? " ⚡️120fps" : (maxFps >= 60 ? " ✓60fps" : "")
        print(String(format: "    [%3d] %5dx%-5d  %-12s  %.1f-%.1f fps%s",
                     i, dims.width, dims.height, codecName, minFps, maxFps, marker))
    }

    print()
    print("  Summary:")
    print("    Formats with ≥120fps: \(formats120fps)")
    print("    Formats with ≥60fps:  \(formats60fps + formats120fps)")
    print("    Maximum frame rate:   \(String(format: "%.1f", maxFpsOverall)) fps")
    print()

    if formats120fps > 0 {
        print("  ✅ Device supports 120fps via AVFoundation!")
        print()
        print("  120fps-capable formats:")
        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let codec = CMFormatDescriptionGetMediaSubType(desc)
            let ranges = format.videoSupportedFrameRateRanges
            let maxFps = ranges.map { $0.maxFrameRate }.max() ?? 0

            if maxFps >= 120 {
                let codecName = codec == kCMVideoCodecType_JPEG ? "MJPEG" :
                               codec == kCVPixelFormatType_422YpCbCr8 ? "UYVY" : "Other"
                print("    - \(dims.width)x\(dims.height) @ \(Int(maxFps))fps (\(codecName))")
            }
        }
    } else {
        print("  ❌ Device does NOT support 120fps via AVFoundation")
        print()
        print("  Possible reasons:")
        print("    1. Device firmware doesn't expose 120fps UVC descriptors")
        print("    2. macOS UVC driver doesn't surface 120fps modes")
        print("    3. USB bandwidth negotiation issue (check System Information)")
        print()
        print("  Next step: Run `probe_mjpeg` to check raw USB descriptors")
    }
    print()
}

print("=== Enumeration Complete ===")
