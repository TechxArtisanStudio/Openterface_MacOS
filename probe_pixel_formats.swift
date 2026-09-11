#!/usr/bin/env swift
// Probe: enumerate resolutions supported by BGRA and 420v/420f pixel formats
import Foundation
import AVFoundation
import CoreMedia

print("=== Pixel Format Resolution Probe: BGRA vs 420v/420f ===")
print()

// Request camera permission
func requestPermission() -> Bool {
    if #available(macOS 14.0, *) {
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .video) { ok in
            granted = ok
            sem.signal()
        }
        let _ = sem.wait(timeout: .now() + 10)
        return granted
    }
    return true
}

guard requestPermission() else {
    print("❌ Camera permission denied")
    exit(1)
}
print("✅ Camera permission granted")
print()

// Discover devices
let discoverySession = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external],
    mediaType: .video,
    position: .unspecified
)

let devices = discoverySession.devices
guard !devices.isEmpty else {
    print("❌ No external video capture devices found")
    exit(0)
}

print("Found \(devices.count) external video capture device(s)")
print()

func codecName(_ code: CMVideoCodecType) -> String {
    switch code {
    case kCMVideoCodecType_JPEG: return "MJPEG"
    case kCMVideoCodecType_H264: return "H.264"
    case kCVPixelFormatType_422YpCbCr8: return "422(UYVY)"
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "420v"
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "420f"
    case kCVPixelFormatType_32BGRA: return "BGRA"
    default:
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "Unknown"
    }
}

func pixelFormatFamily(_ code: CMVideoCodecType) -> String {
    switch code {
    case kCVPixelFormatType_32BGRA: return "BGRA"
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "420"
    case kCVPixelFormatType_422YpCbCr8: return "422"
    case kCMVideoCodecType_JPEG: return "MJPEG"
    case kCMVideoCodecType_H264: return "H.264"
    default: return "Other"
    }
}

func fpsStr(_ v: Double) -> String {
    return String(format: "%.1f", v)
}

struct FormatEntry {
    let dims: CMVideoDimensions
    let codec: CMVideoCodecType
    let maxFps: Double
    let minFps: Double
}

for (idx, device) in devices.enumerated() {
    print("Device \(idx): \(device.localizedName)")
    print("  Model: \(device.modelID)")
    print()

    var byFamily: [String: [FormatEntry]] = [:]

    for format in device.formats {
        let desc = format.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let codec = CMFormatDescriptionGetMediaSubType(desc)
        let ranges = format.videoSupportedFrameRateRanges
        guard !ranges.isEmpty else { continue }
        let maxFps = ranges.map { $0.maxFrameRate }.max() ?? 0
        let minFps = ranges.map { $0.minFrameRate }.min() ?? 0
        let family = pixelFormatFamily(codec)
        byFamily[family, default: []].append(FormatEntry(dims: dims, codec: codec, maxFps: maxFps, minFps: minFps))
    }

    // Sort each family by resolution desc, then fps desc
    for key in byFamily.keys {
        byFamily[key]?.sort {
            if $0.dims.width != $1.dims.width { return $0.dims.width > $1.dims.width }
            if $0.dims.height != $1.dims.height { return $0.dims.height > $1.dims.height }
            return $0.maxFps > $1.maxFps
        }
    }

    let summaryOrder = ["BGRA", "420", "422", "MJPEG", "H.264", "Other"]
    for family in summaryOrder {
        guard let entries = byFamily[family], !entries.isEmpty else { continue }

        // Unique resolutions
        var seen = Set<String>()
        var resolutions: [(w: Int32, h: Int32)] = []
        for e in entries {
            let key = "\(e.dims.width)x\(e.dims.height)"
            if !seen.contains(key) {
                seen.insert(key)
                resolutions.append((e.dims.width, e.dims.height))
            }
        }

        print("  📦 \(family) family — \(entries.count) format(s), \(resolutions.count) unique resolution(s):")
        print("  " + String(repeating: "-", count: 80))

        // Header
        let header = ["Resolution".padding(toLength: 14, withPad: " ", startingAt: 0),
                      "MaxFPS".padding(toLength: 10, withPad: " ", startingAt: 0),
                      "Formats"].joined(separator: "  ")
        print("    " + header)
        print("  " + String(repeating: "-", count: 80))

        for res in resolutions {
            let matchingEntries = entries.filter { $0.dims.width == res.w && $0.dims.height == res.h }
            let fpsMax = matchingEntries.map { $0.maxFps }.max() ?? 0
            let formatStrs = matchingEntries.map { "\(codecName($0.codec)) \(fpsStr($0.minFps))-\(fpsStr($0.maxFps))" }
            let resStr = "\(res.w)x\(res.h)".padding(toLength: 14, withPad: " ", startingAt: 0)
            let fpsStrPadded = fpsStr(fpsMax).padding(toLength: 10, withPad: " ", startingAt: 0)
            print("    \(resStr)  \(fpsStrPadded)  \(formatStrs.joined(separator: "; "))")
        }
        print()
    }

    // Direct comparison: BGRA vs 420/420f resolution sets
    print("  🔍 BGRA vs 420 分辨率对比:")
    print("  " + String(repeating: "-", count: 80))
    let bgraRes = Set(byFamily["BGRA"]?.map { "\($0.dims.width)x\($0.dims.height)" } ?? [])
    let yuv420Res = Set((byFamily["420"] ?? []).map { "\($0.dims.width)x\($0.dims.height)" })
    let common = bgraRes.intersection(yuv420Res).sorted()
    let onlyBgra = bgraRes.subtracting(yuv420Res).sorted()
    let only420 = yuv420Res.subtracting(bgraRes).sorted()

    print("    BGRA 独有分辨率 (\(onlyBgra.count)):")
    for r in onlyBgra { print("      - \(r)") }
    if onlyBgra.isEmpty { print("      (无)") }
    print()
    print("    420v/420f 独有分辨率 (\(only420.count)):")
    for r in only420 { print("      - \(r)") }
    if only420.isEmpty { print("      (无)") }
    print()
    print("    两者都支持的分辨率 (\(common.count)):")
    for r in common { print("      - \(r)") }
    if common.isEmpty { print("      (无)") }
    print()

    // Per common resolution, compare max fps
    if !common.isEmpty {
        print("  📊 共同分辨率下帧率对比:")
        print("  " + String(repeating: "-", count: 80))
        let header = ["Resolution".padding(toLength: 14, withPad: " ", startingAt: 0),
                      "BGRA fps".padding(toLength: 12, withPad: " ", startingAt: 0),
                      "420 fps".padding(toLength: 12, withPad: " ", startingAt: 0)].joined(separator: "  ")
        print("    " + header)
        print("  " + String(repeating: "-", count: 80))
        for r in common {
            let parts = r.split(separator: "x")
            guard let w = Int32(parts[0]), let h = Int32(parts[1]) else { continue }
            let bgraMax = byFamily["BGRA"]?
                .filter { $0.dims.width == w && $0.dims.height == h }
                .map { $0.maxFps }.max() ?? 0
            let yuv420Max = byFamily["420"]?
                .filter { $0.dims.width == w && $0.dims.height == h }
                .map { $0.maxFps }.max() ?? 0
            let resStr = r.padding(toLength: 14, withPad: " ", startingAt: 0)
            let bgraStr = fpsStr(bgraMax).padding(toLength: 12, withPad: " ", startingAt: 0)
            let yuvStr = fpsStr(yuv420Max).padding(toLength: 12, withPad: " ", startingAt: 0)
            print("    \(resStr)  \(bgraStr)  \(yuvStr)")
        }
        print()
    }
}

print("=== Probe Complete ===")
