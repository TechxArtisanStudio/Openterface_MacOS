#!/usr/bin/env swift
// Minimal device detection test
import Foundation
import AVFoundation

print("=== Minimal AVFoundation Device Detection ===")
print()

// Don't request access for now, just see what we can get
let discoverySession = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external],
    mediaType: .video,
    position: .unspecified
)

let devices = discoverySession.devices
print("External video devices found: \(devices.count)")

for (idx, device) in devices.enumerated() {
    print("  [\(idx)] \(device.localizedName)")
    print("      modelID: \(device.modelID)")
    print("      uniqueID: \(device.uniqueID)")

    // Safely check if we can access formats
    do {
        let formats = device.formats
        print("      formats: \(formats.count)")

        if !formats.isEmpty {
            let first = formats[0]
            let desc = first.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            print("      first format: \(dims.width)x\(dims.height)")
        }
    } catch {
        print("      Error accessing formats: \(error)")
    }
    print()
}

print("Done.")