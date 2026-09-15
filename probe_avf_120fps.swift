#!/usr/bin/env swift
// Test whether AVFoundation can actually capture at 120fps over USB 3.0
// Build: swiftc -o probe_avf_120fps probe_avf_120fps.swift -framework AVFoundation -framework CoreMedia -framework CoreVideo
// Run:   ./probe_avf_120fps

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - Frame counter delegate
class FrameCounter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var frameCount: Int = 0
    var startTime: CFTimeInterval = 0
    var lastFrameTime: CFTimeInterval = 0
    var fpsHistory: [Double] = []
    var width: Int = 0
    var height: Int = 0
    var codecDesc: String = ""
    let lock = NSLock()

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let now = CACurrentMediaTime()
        if frameCount == 0 {
            startTime = now
            // Get frame dimensions
            if let desc = CMSampleBufferGetImageBuffer(sampleBuffer) {
                width = CVPixelBufferGetWidth(desc)
                height = CVPixelBufferGetHeight(desc)
                let pf = CVPixelBufferGetPixelFormatType(desc)
                codecDesc = String(format: "0x%08X", pf)
            }
        }
        frameCount += 1

        // Track inter-frame interval
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt > 0 {
                fpsHistory.append(1.0 / dt)
                if fpsHistory.count > 200 { fpsHistory.removeFirst() }
            }
        }
        lastFrameTime = now
        lock.unlock()
    }

    func snapshot() -> (count: Int, elapsed: Double, avgFps: Double, medianFps: Double, p95Fps: Double, width: Int, height: Int, codecDesc: String) {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = lastFrameTime > 0 ? lastFrameTime - startTime : 0
        let avgFps = elapsed > 0 ? Double(frameCount) / elapsed : 0
        var median = 0.0, p95 = 0.0
        if !fpsHistory.isEmpty {
            let sorted = fpsHistory.sorted()
            median = sorted[sorted.count / 2]
            p95 = sorted[Int(Double(sorted.count) * 0.95)]
        }
        return (frameCount, elapsed, avgFps, median, p95, width, height, codecDesc)
    }
}

// MARK: - Helpers
func codecName(_ subType: FourCharCode) -> String {
    switch subType {
    case kCMVideoCodecType_JPEG: return "MJPEG"
    case kCMVideoCodecType_H264: return "H.264"
    case kCVPixelFormatType_422YpCbCr8: return "UYVY"
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "NV12"
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "NV12-full"
    default:
        let bytes: [UInt8] = [
            UInt8((subType >> 24) & 0xFF), UInt8((subType >> 16) & 0xFF),
            UInt8((subType >> 8) & 0xFF), UInt8(subType & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? "Unknown"
    }
}

func pixelFormatName(_ pf: FourCharCode) -> String {
    switch pf {
    case kCVPixelFormatType_422YpCbCr8: return "UYVY (4:2:2 8-bit)"
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "NV12 (4:2:0 8-bit)"
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "NV12-full (4:2:0 8-bit)"
    case kCVPixelFormatType_422YpCbCr8FullRange: return "UYVY-full (4:2:2 8-bit)"
    case kCVPixelFormatType_32BGRA: return "BGRA"
    default: return String(format: "0x%08X", pf)
    }
}

// MARK: - Main
print("=== AVFoundation 120fps Capture Test (USB 3.0) ===")
print()

// Check camera permission (needed on macOS 14+)
if #available(macOS 14.0, *) {
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .video) { ok in
        granted = ok
        sem.signal()
    }
    let _ = sem.wait(timeout: .now() + 10)
    if !granted {
        print("❌ Camera permission denied. Grant it in System Settings > Privacy & Security > Camera.")
        exit(1)
    }
    print("✅ Camera permission granted")
    print()
}

// Discover devices
let discoverySession = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera, .external],
    mediaType: .video,
    position: .unspecified
)

let devices = discoverySession.devices
print("Found \(devices.count) video capture device(s):")
for (i, d) in devices.enumerated() {
    print("  [\(i)] \(d.localizedName)  (modelID=\(d.modelID), uniqueID=\(d.uniqueID))")
}
print()

guard !devices.isEmpty else {
    print("❌ No video capture devices found.")
    exit(1)
}

// Pick device — prefer MS2130S / Openterface / capture card by name, else first external
let target: AVCaptureDevice = devices.first { d in
    let n = d.localizedName.lowercased()
    return n.contains("openterface") || n.contains("ms2130") || n.contains("capture")
} ?? devices.first { d in
    d.modelID.contains("USB") || d.uniqueID.contains("USB") || d.localizedName.contains("USB")
} ?? devices[0]

print("🎯 Target device: \(target.localizedName)")
print()

// MARK: - Enumerate all formats and find 120fps candidates
print("--- All formats on target device ---")
struct FormatCandidate {
    let format: AVCaptureDevice.Format
    let width: Int32
    let height: Int32
    let codec: FourCharCode
    let maxFps: Double
    let pixelFormats: [FourCharCode]  // actual pixel formats in the description
}

var candidates: [FormatCandidate] = []
var idx = 0
for fmt in target.formats {
    let desc = fmt.formatDescription
    let dims = CMVideoFormatDescriptionGetDimensions(desc)
    let codec = CMFormatDescriptionGetMediaSubType(desc)

    // Get max fps
    var maxFps: Double = 0
    let ranges = fmt.videoSupportedFrameRateRanges
    maxFps = ranges.map { $0.maxFrameRate }.max() ?? 0

    // Collect pixel formats (the codec FourCC may be a compressed codec or a raw pixel format)
    var pixelFormats: [FourCharCode] = []
    if let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
        if let pf = extensions[kCVPixelBufferPixelFormatTypeKey as String] as? FourCharCode {
            pixelFormats.append(pf)
        }
    }

    let marker = maxFps >= 120 ? " ⚡️" : (maxFps >= 60 ? " ✓" : "")
    let codecStr = codecName(codec)
    let pfStr = pixelFormats.map { pixelFormatName($0) }.joined(separator: ", ")

    print(String(format: "  [%3d] %5dx%-5d  codec=%-12s  maxFps=%6.1f  pixelFormat=%s%s",
                 idx, dims.width, dims.height, codecStr, maxFps, pfStr, marker))

    if maxFps >= 120 {
        candidates.append(FormatCandidate(format: fmt, width: dims.width, height: dims.height,
                                          codec: codec, maxFps: maxFps, pixelFormats: pixelFormats))
    }
    idx += 1
}
print()
print("Total formats: \(target.formats.count)")
print("Formats with ≥120fps: \(candidates.count)")
print()

// MARK: - Try to capture at 120fps on each candidate (prefer 1920x1080 first)
if candidates.isEmpty {
    print("❌ No AVFoundation format on this device advertises ≥120fps.")
    print()
    print("Possible reasons:")
    print("  1. The device firmware does not expose 120fps UVC frame descriptors")
    print("  2. macOS UVC driver does not surface MJPEG 120fps modes")
    print("  3. USB bandwidth negotiation fell back to USB 2.0 (check System Information)")
    print()
    print("Next: run `probe_mjpeg` to check the raw USB descriptors for 120fps frames.")
    exit(0)
}

// Sort candidates: prefer 1920x1080, then highest fps, then MJPEG
let sorted = candidates.sorted { a, b in
    // Prefer 1080p
    let aIs1080 = a.width == 1920 && a.height == 1080
    let bIs1080 = b.width == 1920 && b.height == 1080
    if aIs1080 != bIs1080 { return aIs1080 }
    // Then highest fps
    if a.maxFps != b.maxFps { return a.maxFps > b.maxFps }
    // Then MJPEG
    let aMjpeg = a.codec == kCMVideoCodecType_JPEG
    let bMjpeg = b.codec == kCMVideoCodecType_JPEG
    if aMjpeg != bMjpeg { return aMjpeg }
    return false
}

let runLoop = CFRunLoopGetCurrent()
let testDurationSec: Double = 4.0

for (ci, cand) in sorted.enumerated() {
    print("--- Test \(ci + 1)/\(sorted.count): \(cand.width)x\(cand.height) @ \(Int(cand.maxFps))fps (codec=\(codecName(cand.codec))) ---")

    // Set up session
    let session = AVCaptureSession()
    session.beginConfiguration()

    do {
        let input = try AVCaptureDeviceInput(device: target)
        guard session.canAddInput(input) else {
            print("  ❌ Cannot add input")
            session.commitConfiguration()
            continue
        }
        session.addInput(input)

        // Set format + frame rate BEFORE adding output
        try target.lockForConfiguration()
        target.activeFormat = cand.format
        target.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(cand.maxFps))
        target.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(cand.maxFps))

        // Disable auto light / focus if possible to avoid delays
        // (torch not available on macOS external capture devices)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        // Request the native pixel format — let AVFoundation give us whatever the device outputs
        if !cand.pixelFormats.isEmpty {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: cand.pixelFormats[0]
            ]
        }

        let counter = FrameCounter()
        let queue = DispatchQueue(label: "avf.probe.\(ci)")
        output.setSampleBufferDelegate(counter, queue: queue)

        guard session.canAddOutput(output) else {
            print("  ❌ Cannot add output")
            target.unlockForConfiguration()
            session.commitConfiguration()
            continue
        }
        session.addOutput(output)
        session.commitConfiguration()

        // Print actual negotiated format
        print("  Active format after lock: \(CMVideoFormatDescriptionGetDimensions(target.activeFormat.formatDescription))")
        if let r = target.activeFormat.videoSupportedFrameRateRanges as? [AVFrameRateRange], let rr = r.first {
            print("  Frame rate range: \(rr.minFrameRate)-\(rr.maxFrameRate) fps")
        }
        print("  minFrameDuration=\(CMTimeGetSeconds(target.activeVideoMinFrameDuration) * 1000) ms")
        print("  maxFrameDuration=\(CMTimeGetSeconds(target.activeVideoMaxFrameDuration) * 1000) ms")

        // Start running
        session.startRunning()
        print("  Session running, capturing for \(testDurationSec)s...")

        // Run the run loop for the test duration
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < testDurationSec {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, true)
        }

        session.stopRunning()
        target.unlockForConfiguration()

        let snap = counter.snapshot()
        print()
        print("  📊 Results:")
        print("     Frames captured : \(snap.count)")
        print("     Elapsed         : \(String(format: "%.2f", snap.elapsed))s")
        print("     Average FPS     : \(String(format: "%.1f", snap.avgFps))")
        print("     Median inst. FPS: \(String(format: "%.1f", snap.medianFps))")
        print("     P95 inst. FPS   : \(String(format: "%.1f", snap.p95Fps))")
        if snap.width > 0 {
            print("     Frame size      : \(snap.width)x\(snap.height)  pixelFormat=\(snap.codecDesc)")
        }

        let expectedFrames = Int(cand.maxFps * testDurationSec)
        let achievedPct = expectedFrames > 0 ? Double(snap.count) / Double(expectedFrames) * 100 : 0
        print("     Expected frames : \(expectedFrames)  (achieved \(String(format: "%.0f", achievedPct))%)")

        if snap.avgFps >= cand.maxFps * 0.9 {
            print("  ✅ SUCCESS — captured at ≥90% of target fps")
        } else if snap.avgFps >= cand.maxFps * 0.5 {
            print("  ⚠️  PARTIAL — captured at ≥50% but <90% of target fps")
        } else {
            print("  ❌ FAILED — captured at <50% of target fps")
        }
        print()

    } catch {
        print("  ❌ Error: \(error)")
        try? target.unlockForConfiguration()
        session.commitConfiguration()
    }
}

print("=== Test Complete ===")
