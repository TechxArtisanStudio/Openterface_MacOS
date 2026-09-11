import XCTest
import AVFoundation
import CoreMedia
@testable import openterface

final class VideoFormatTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testListAllSupportedVideoFormats() throws {
        // Get available video devices
        let videoDeviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .externalUnknown
        ]

        let videoDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: videoDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        print("\n=== Supported Video Formats ===\n")

        for device in videoDiscoverySession.devices {
            print("Device: \(device.localizedName)")
            print("Unique ID: \(device.uniqueID)")
            print("Total formats: \(device.formats.count)\n")

            for (index, format) in device.formats.enumerated() {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let codecType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                let pixelFormat = String(format: "0x%X", codecType)

                // Get frame rate ranges
                let frameRateRanges = format.videoSupportedFrameRateRanges
                var frameRateInfo = ""
                for range in frameRateRanges {
                    frameRateInfo += "min=\(range.minFrameRate)fps, max=\(range.maxFrameRate)fps "
                }

                print("Format \(index): \(dimensions.width)x\(dimensions.height) @ \(frameRateInfo) - \(pixelFormat)")
            }
            print("\n")
        }

        // This test always passes, it's just for logging
        XCTAssertTrue(true)
    }

    func testVideoFormatConversion() throws {
        // Test that VideoFormat correctly extracts information from AVCaptureDevice.Format
        let videoDeviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .externalUnknown
        ]

        let videoDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: videoDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        guard let device = videoDiscoverySession.devices.first else {
            print("No video device found, skipping test")
            return
        }

        print("\n=== VideoFormat Conversion Test ===\n")

        for format in device.formats.prefix(10) { // Test first 10 formats
            let videoFormat = format.toVideoFormat()
            print("Converted: \(videoFormat.description)")

            XCTAssertGreaterThan(videoFormat.resolution.width, 0)
            XCTAssertGreaterThan(videoFormat.resolution.height, 0)
            XCTAssertGreaterThan(videoFormat.frameRate, 0)
            XCTAssertFalse(videoFormat.pixelFormat.isEmpty)
        }
    }

    func testFrameRateFiltering() throws {
        // Test that frame rates are correctly filtered
        let videoDeviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .externalUnknown
        ]

        let videoDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: videoDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        guard let device = videoDiscoverySession.devices.first else {
            print("No video device found, skipping test")
            return
        }

        print("\n=== Frame Rate Filtering Test ===\n")

        for format in device.formats.prefix(5) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            print("\nResolution: \(dimensions.width)x\(dimensions.height)")

            let ranges = format.videoSupportedFrameRateRanges
            for range in ranges {
                print("  Range: \(range.minFrameRate) - \(range.maxFrameRate) fps")
            }

            let videoFormat = format.toVideoFormat()
            print("  Selected frame rate: \(videoFormat.frameRate) fps")

            // Verify the selected frame rate is within a reasonable range
            XCTAssertLessThanOrEqual(videoFormat.frameRate, 60.0, "Frame rate should not exceed 60fps for stability")
        }
    }
}
