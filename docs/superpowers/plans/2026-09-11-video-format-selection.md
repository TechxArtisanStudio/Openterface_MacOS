# Video Format Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a user-selectable video capture format option in Settings > Audio & Video that allows users to choose resolution, frame rate, and pixel format for their video capture device, with immediate application of the selected format.

**Architecture:** This feature extends the existing Audio & Video settings UI with a new "Video Capture Format" section containing three dropdown selectors (resolution, frame rate, pixel format) and applies the selection immediately by modifying VideoManager's setup logic. User selections are persisted via UserSettings.

**Tech Stack:** Swift, SwiftUI, AVFoundation, UserDefaults, AVCaptureDevice

**Spec:** docs/superpowers/specs/2026-09-11-video-format-selection-design.md (to be created from brainstorming session)

## Global Constraints

- Minimum macOS version: 12.0 (for AVFoundation features)
- Uses existing UserSettings pattern for persistence
- Maintains backward compatibility - defaults to current behavior if no selection made
- Applies format changes immediately (with session restart when needed)
- Follows existing code patterns in UserSettings and VideoManager

---

### Task 1: Add Video Format Storage Properties to UserSettings

**Files:**
- Modify: `/Users/txa/project/Openterface_MacOS/openterface/Settings/UserSetting.swift:320-400` (add new properties in init and @Published declarations)

**Interfaces:**
- Consumes: None (standalone storage addition)
- Produces: `selectedVideoResolution`, `selectedVideoFrameRate`, `selectedVideoPixelFormat` @Published properties that persist to UserDefaults

**Step 1: Write the failing test**

This task adds storage properties, so we'll verify by checking compilation and runtime access.

Run: `swift build`
Expected: FAIL with "UserSettings has no member 'selectedVideoResolution'" etc.

**Step 2: Add the storage properties**

```swift
// Add these properties after line 325 (after activeVideoHeight) in UserSettings.swift
@Published var selectedVideoResolution: VideoResolution {
    didSet {
        // Store as encoded string "widthxheight@fps" for simplicity
        let value = "\(selectedVideoResolution.width)x\(selectedVideoResolution.height)@\(selectedVideoResolution.refreshRate)"
        UserDefaults.standard.set(value, forKey: "selectedVideoResolution")
    }
}

@Published var selectedVideoFrameRate: Float {
    didSet {
        UserDefaults.standard.set(selectedVideoFrameRate, forKey: "selectedVideoFrameRate")
    }
}

@Published var selectedVideoPixelFormat: String {
    didSet {
        UserDefaults.standard.set(selectedVideoPixelFormat, forKey: "selectedVideoPixelFormat")
    }
}
```

Also add the corresponding UserDefaults reads in init() after line 325:

```swift
// Add these lines after activeVideoHeight initialization
if let resolutionStr = UserDefaults.standard.string(forKey: "selectedVideoResolution"),
   let components = resolutionStr.split(separator: "@").first,
   let wh = components.split(separator: "x").map({ Int($0) }),
   wh.count == 2,
   let fpsStr = resolutionStr.split(separator: "@").last,
   let fps = Float(fpsStr) {
    self.selectedVideoResolution = VideoResolution(width: wh[0], height: wh[1], refreshRate: fps)
} else {
    // Default to 1920x1080@60 (current hardcoded default)
    self.selectedVideoResolution = VideoResolution(width: 1920, height: 1080, refreshRate: 60.0)
}

self.selectedVideoFrameRate = UserDefaults.standard.float(forKey: "selectedVideoFrameRate")
if self.selectedVideoFrameRate == 0.0 {
    self.selectedVideoFrameRate = 60.0 // Default fallback
}

self.selectedVideoPixelFormat = UserDefaults.standard.string(forKey: "selectedVideoPixelFormat") ?? String(format: "0x%X", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
```

**Step 3: Verify it compiles**

Run: `swift build`
Expected: PASS

**Step 4: Commit**

```bash
git add openterface/Settings/UserSetting.swift
git commit -m "feat(video): add video format storage properties to UserSettings"
```

---

### Task 2: Create VideoFormat Model and Enumeration Helpers

**Files:**
- Create: `/Users/txa/project/Openterface_MacOS/openterface/Managers/VideoFormat.swift`
- Create: `/Users/txa/project/Openterface_MacOS/openterface/Managers/VideoFormatExtensions.swift`

**Interfaces:**
- Consumes: None
- Produces: VideoFormat struct with resolution, frameRate, pixelFormat properties; extensions for AVCaptureDevice.Format conversion

**Step 1: Write the failing test**

Run: `swift build`
Expected: FAIL with "VideoFormat.swift: No such file"

**Step 2: Create VideoFormat.swift**

```swift
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
```

**Step 3: Create VideoFormatExtensions.swift for AVCaptureDevice conversion**

```swift
import Foundation
import AVFoundation
import CoreMedia

extension AVCaptureDevice.Format {
    /// Converts to our VideoFormat model
    func toVideoFormat() -> VideoFormat {
        let dimensions = CMVideoFormatDescriptionGetDimensions(self.formatDescription)
        let codecType = CMFormatDescriptionGetMediaSubType(self.formatDescription)
        let pixelFormat = String(format: "0x%X", codecType)
        
        let maxFps = videoSupportedFrameRateRanges
            .compactMap { $0 as? AVFrameRateRange }
            .map { $0.maxFrameRate }
            .max() ?? 0.0
        
        return VideoFormat(
            resolution: VideoResolution(width: Int(dimensions.width), height: Int(dimensions.height), refreshRate: maxFps),
            frameRate: maxFps,
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
        case kCMVideoCodecType_JPEG:
            formatName = "MJPEG"
        case kCMVideoCodecType_H264:
            formatName = "H.264"
        default:
            var bytes: [UInt8] = [
                UInt8((codecType >> 24) & 0xFF),
                UInt8((codecType >> 16) & 0xFF),
                UInt8((codecType >> 8) & 0xFF),
                UInt8(codecType & 0xFF)
            ]
            formatName = String(bytes: &bytes, encoding: .ascii) ?? "Unknown"
        }
        
        let maxFps = videoSupportedFrameRateRanges
            .compactMap { $0 as? AVFrameRateRange }
            .map { $0.maxFrameRate }
            .max() ?? 0.0
        
        return "\(Int(dimensions.width))x\(Int(dimensions.height)) @ \(Int(maxFps))fps \(formatName)"
    }
}
```

**Step 4: Verify it compiles**

Run: `swift build`
Expected: PASS

**Step 5: Commit**

```bash
git add openterface/Managers/VideoFormat.swift openterface/Managers/VideoFormatExtensions.swift
git commit -m "feat(video): add VideoFormat model and AVCaptureDevice conversion helpers"
```

---

### Task 3: Add Video Format Enumeration and Caching to VideoManager

**Files:**
- Modify: `/Users/txa/project/Openterface_MacOS/openterface/Managers/VideoManager.swift:58-70` (add properties)
- Modify: `/Users/txa/project/Openterface_MacOS/openterface/Managers/VideoManager.swift:300-400` (add enumeration method)
- Modify: `/Users/txa/project/Openterface_MacOS/openterface/Managers/VideoManager.swift:340-370` (modify prepareVideo to use selection)

**Interfaces:**
- Consumes: VideoFormat model, UserSettings storage
- Produces: `availableVideoFormats` property and `enumerateAvailableFormats()` method

**Step 1: Write the failing test**

Run: `swift build`
Expected: FAIL with "VideoManager has no member 'availableVideoFormats'"

**Step 2: Add properties and enumeration method**

Add these properties after line 65 (after cancellables):

```swift
/// Cached list of available video formats from the current device
@Published private(set) var availableVideoFormats: [VideoFormat] = []

/// Selected video format from UserSettings (computed for easier access)
var selectedVideoFormat: VideoFormat {
    get {
        VideoFormat(
            resolution: UserSettings.shared.selectedVideoResolution,
            frameRate: UserSettings.shared.selectedVideoFrameRate,
            pixelFormat: UserSettings.shared.selectedVideoPixelFormat
        )
    }
    set {
        UserSettings.shared.selectedVideoResolution = newValue.resolution
        UserSettings.shared.selectedVideoFrameRate = newValue.frameRate
        UserSettings.shared.selectedVideoPixelFormat = newValue.pixelFormat
    }
}
```

Add the enumeration method after line 400 (after setupVideoCapture):

```swift
/// Enumerates and caches all available video formats from detected video devices
func enumerateAvailableVideoFormats() {
    guard !isVideoSessionStarting else { return }
    
    logger.log(content: "Enumerating available video formats...")
    
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
    
    let videoDevices = findMatchingVideoDevices(from: videoDiscoverySession.devices)
    
    var formats: [VideoFormat] = []
    
    for device in videoDevices {
        do {
            try device.lockForConfiguration()
            
            for format in device.formats {
                let videoFormat = format.toVideoFormat()
                
                // Avoid duplicates (same resolution, fps, and pixel format)
                if !formats.contains(where: { $0.resolution == videoFormat.resolution &&
                                           abs($0.frameRate - videoFormat.frameRate) < 1.0 &&
                                           $0.pixelFormat == videoFormat.pixelFormat }) {
                    formats.append(videoFormat)
                }
            }
            
            device.unlockForConfiguration()
        } catch {
            logger.log(content: "Failed to lock device for configuration: \(error.localizedDescription)")
        }
    }
    
    // Sort by resolution (desc), then frame rate (desc), then pixel format
    availableVideoFormats = formats.sorted {
        if $0.resolution.width != $1.resolution.width {
            return $0.resolution.width > $1.resolution.width
        }
        if $0.resolution.height != $1.resolution.height {
            return $0.resolution.height > $1.resolution.height
        }
        if abs($0.frameRate - $1.frameRate) > 0.1 {
            return $0.frameRate > $1.frameRate
        }
        return $0.pixelFormat < $1.pixelFormat
    }
    
    logger.log(content: "Found \(availableVideoFormats.count) unique video formats")
    
    // If current selection is not in available formats, find closest match
    if !availableVideoFormats.contains(selectedVideoFormat) {
        let closest = availableVideoFormats.first { format in
            format.resolution.width == selectedVideoFormat.resolution.width &&
            format.resolution.height == selectedVideoFormat.resolution.height
        } ?? availableVideoFormats.first
        
        if let closest = closest {
            logger.log(content: "Selected format not available, using closest match: \(closest.description)")
            selectedVideoFormat = closest
        }
    }
}
```

**Step 3: Modify prepareVideo to call enumeration and use selection**

Replace the `prepareVideo()` method body (lines 304-367) with:

```swift
/// Prepares and starts video capture
func prepareVideo() {
    // Reduce debounce interval to avoid missing valid start requests
    let now = Date()
    if now.timeIntervalSince(lastVideoSessionStartTime) < 0.3 { // Reduced from 1 second to 0.3 seconds
        logger.log(content: "Video preparation ignored - too frequent")
        return
    }

    // If video session is running AND has at least one input, skip — it's already working.
    // If it's running but has NO inputs, it was started before hardware was available.
    // Stop the empty session and re-prepare with the newly detected hardware.
    if captureSession.isRunning && !captureSession.inputs.isEmpty {
        logger.log(content: "Video already running, skipping preparation")
        return
    }

    if captureSession.isRunning && captureSession.inputs.isEmpty {
        logger.log(content: "Video session running but empty (no hardware at startup) — restarting with detected hardware")
        captureSession.stopRunning()
    }
    
    // Update last start time
    lastVideoSessionStartTime = now
    
    // Mark as starting
    isVideoSessionStarting = true
    
    logger.log(content: "Preparing video capture...")
    
    // Enumerate available formats first
    enumerateAvailableVideoFormats()
    
    // Update USB devices - execute the entire process on the main thread to avoid thread synchronization issues
    updateUSBDevices()
    
    // Configure capture session quality
    captureSession.sessionPreset = .high
    
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
    
    // Find matching video devices
    let videoDevices = findMatchingVideoDevices(from: videoDiscoverySession.devices)
    
    // If devices found, set up video capture
    if !videoDevices.isEmpty {
        let device = videoDevices[0]
        
        // Apply user-selected format if available
        applySelectedVideoFormat(to: device)
        
        setupVideoCapture(with: device)
    } else {
        logger.log(content: "No matching video devices found")
        isVideoSessionStarting = false
    }
}
```

Add the `applySelectedVideoFormat` helper method after `enumerateAvailableVideoFormats`:

```swift
/// Applies the user-selected video format to the device if available
private func applySelectedVideoFormat(to device: AVCaptureDevice) {
    do {
        try device.lockForConfiguration()
        
        // Find matching format in device's supported formats
        let matchingFormat = device.formats.first { format in
            let videoFormat = format.toVideoFormat()
            return videoFormat.resolution.width == selectedVideoFormat.resolution.width &&
                   videoFormat.resolution.height == selectedVideoFormat.resolution.height &&
                   abs(videoFormat.frameRate - selectedVideoFormat.frameRate) < 1.0 &&
                   videoFormat.pixelFormat == selectedVideoFormat.pixelFormat
        }
        
        if let matchingFormat = matchingFormat {
            device.activeFormat = matchingFormat
            logger.log(content: "Applied user-selected video format: \(selectedVideoFormat.description)")
            
            // Update video data output to capture at the selected resolution
            if let videoOutput = captureSession.outputs.first(where: { $0 is AVCaptureVideoDataOutput }) as? AVCaptureVideoDataOutput {
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: selectedVideoFormat.pixelFormat,
                    kCVPixelBufferWidthKey as String: selectedVideoFormat.resolution.width,
                    kCVPixelBufferHeightKey as String: selectedVideoFormat.resolution.height
                ]
                logger.log(content: "Updated video output to \(selectedVideoFormat.resolution.width)x\(selectedVideoFormat.resolution.height)")
            }
        } else {
            logger.log(content: "Selected format \(selectedVideoFormat.description) not available on device, using first matching resolution")
            
            // Fallback to first format with matching resolution
            let fallbackFormat = device.formats.first { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return Int(dimensions.width) == selectedVideoFormat.resolution.width &&
                       Int(dimensions.height) == selectedVideoFormat.resolution.height
            }
            
            if let fallbackFormat = fallbackFormat {
                device.activeFormat = fallbackFormat
                let appliedFormat = fallbackFormat.toVideoFormat()
                logger.log(content: "Applied fallback format: \(appliedFormat.description)")
                
                // Update selection to match what we actually applied
                selectedVideoFormat = appliedFormat
                
                // Update video data output
                if let videoOutput = captureSession.outputs.first(where: { $0 is AVCaptureVideoDataOutput }) as? AVCaptureVideoDataOutput {
                    videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: appliedFormat.pixelFormat,
                        kCVPixelBufferWidthKey as String: appliedFormat.resolution.width,
                        kCVPixelBufferHeightKey as String: appliedFormat.resolution.height
                    ]
                }
            } else {
                logger.log(content: "No fallback format found for resolution \(selectedVideoFormat.resolution.width)x\(selectedVideoFormat.resolution.height)")
            }
        }
        
        device.unlockForConfiguration()
    } catch {
        logger.log(content: "Failed to apply video format: \(error.localizedDescription)")
    }
}
```

**Step 4: Verify it compiles**

Run: `swift build`
Expected: PASS

**Step 5: Commit**

```bash
git add openterface/Managers/VideoManager.swift
git commit -m "feat(video): add video format enumeration and application logic to VideoManager"
```

---

### Task 4: Add Video Format UI to Audio & Video Settings

**Files:**
- Modify: `/Users/txa/project/Openterface_MacOS/openterface/Views/Settings/AudioVideoSettingsView.swift:50-96` (add Video Format section)

**Interfaces:**
- Consumes: VideoManager.availableVideoFormats, UserSettings video format selections
- Produces: UI with resolution, frame rate, and pixel format pickers

**Step 1: Write the failing test**

This is UI work, so we verify by compilation and visual inspection.

Run: `swift build`
Expected: FAIL if there are syntax errors

**Step 2: Add Video Format section to AudioVideoSettingsView**

Replace the content of AudioVideoSettingsView.swift with:

```swift
import SwiftUI

struct AudioVideoSettingsView: View {
    @ObservedObject private var audioManager = AudioManager.shared
    @ObservedObject private var userSettings = UserSettings.shared
    @ObservedObject private var videoManager = VideoManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Audio & Video Configuration")
                .font(.title2)
                .bold()
            
            // Audio Settings
            GroupBox("Audio Control") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable audio streaming", isOn: $userSettings.isAudioEnabled)
                        .onChange(of: userSettings.isAudioEnabled) { enabled in
                            audioManager.setAudioEnabled(enabled)
                        }
                    
                    Text("Status: \(audioManager.statusMessage)")
                        .font(.caption)
                        .foregroundColor(audioManager.isAudioDeviceConnected ? .green : .orange)
                    
                    HStack {
                        Text("Available input devices: \(audioManager.availableInputDevices.count)")
                        Spacer()
                        Button("Refresh Devices") {
                            audioManager.updateAvailableAudioDevices()
                        }
                    }
                    .font(.caption)
                    
                    if let selectedDevice = audioManager.selectedInputDevice {
                        Text("Input: \(selectedDevice.name)")
                            .font(.caption)
                    }
                    
                    if let selectedDevice = audioManager.selectedOutputDevice {
                        Text("Output: \(selectedDevice.name)")
                            .font(.caption)
                    }
                }
                .padding(.vertical, 8)
            }
            
            // Video Settings
            GroupBox("Display & Video Settings") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Full screen mode", isOn: $userSettings.isFullScreen)
                    
                    // Aspect Ratio Mode Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Aspect Ratio Mode")
                            .font(.system(size: 14, weight: .medium))
                        
                        Picker("", selection: $userSettings.aspectRatioMode) {
                            ForEach(AspectRatioMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        
                        Text(userSettings.aspectRatioMode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Custom Aspect Ratio Picker - only show when in custom mode
                    if userSettings.aspectRatioMode == .custom {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Aspect ratio:")
                                Picker("", selection: $userSettings.customAspectRatio) {
                                    ForEach(AspectRatioOption.allCases, id: \.self) { ratio in
                                        Text(ratio.toString).tag(ratio)
                                    }
                                }
                                .frame(width: 120)
                            }
                            
                            Text("Current ratio: \(String(format: "%.3f", userSettings.customAspectRatio.widthToHeightRatio))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // NEW: Video Capture Format Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Video Capture Format")
                            .font(.system(size: 14, weight: .medium))
                        
                        if videoManager.availableVideoFormats.isEmpty {
                            Text("Scanning available formats...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(8)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                // Resolution Picker
                                HStack {
                                    Text("Resolution:")
                                    Picker("", selection: Binding(
                                        get: {
                                            // Find index of current selection
                                            if let index = videoManager.availableVideoFormats.firstIndex(where: {
                                                $0.resolution.width == userSettings.selectedVideoResolution.width &&
                                                $0.resolution.height == userSettings.selectedVideoResolution.height
                                            }) {
                                                return index
                                            }
                                            return 0
                                        },
                                        set: { newIndex in
                                            if newIndex >= 0 && newIndex < videoManager.availableVideoFormats.count {
                                                let selected = videoManager.availableVideoFormats[newIndex]
                                                userSettings.selectedVideoResolution = selected.resolution
                                                userSettings.selectedVideoFrameRate = selected.frameRate
                                                userSettings.selectedVideoPixelFormat = selected.pixelFormat
                                                
                                                // Apply immediately if video is running
                                                if VideoManager.shared.captureSession.isRunning {
                                                    VideoManager.shared.stopVideoSession()
                                                    VideoManager.shared.prepareVideo()
                                                }
                                            }
                                        }
                                    )) {
                                        ForEach(videoManager.availableVideoFormats.indices, id: \.self) { index in
                                            let format = videoManager.availableVideoFormats[index]
                                            Text("\(format.resolution.width)x\(format.resolution.height)")
                                                .tag(index)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                
                                // Frame Rate Picker
                                HStack {
                                    Text("Frame Rate:")
                                    Picker("", selection: Binding(
                                        get: {
                                            // Find index of current selection
                                            if let index = videoManager.availableVideoFormats.firstIndex(where: {
                                                abs($0.frameRate - userSettings.selectedVideoFrameRate) < 1.0
                                            }) {
                                                return index
                                            }
                                            return 0
                                        },
                                        set: { newIndex in
                                            if newIndex >= 0 && newIndex < videoManager.availableVideoFormats.count {
                                                let selected = videoManager.availableVideoFormats[newIndex]
                                                userSettings.selectedVideoResolution = selected.resolution
                                                userSettings.selectedVideoFrameRate = selected.frameRate
                                                userSettings.selectedVideoPixelFormat = selected.pixelFormat
                                                
                                                // Apply immediately if video is running
                                                if VideoManager.shared.captureSession.isRunning {
                                                    VideoManager.shared.stopVideoSession()
                                                    VideoManager.shared.prepareVideo()
                                                }
                                            }
                                        }
                                    )) {
                                        ForEach(videoManager.availableVideoFormats.indices, id: \.self) { index in
                                            let format = videoManager.availableVideoFormats[index]
                                            Text("\(Int(format.frameRate))fps")
                                                .tag(index)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                
                                // Pixel Format Picker
                                HStack {
                                    Text("Pixel Format:")
                                    Picker("", selection: Binding(
                                        get: {
                                            // Find index of current selection
                                            if let index = videoManager.availableVideoFormats.firstIndex(where: {
                                                $0.pixelFormat == userSettings.selectedVideoPixelFormat
                                            }) {
                                                return index
                                            }
                                            return 0
                                        },
                                        set: { newIndex in
                                            if newIndex >= 0 && newIndex < videoManager.availableVideoFormats.count {
                                                let selected = videoManager.availableVideoFormats[newIndex]
                                                userSettings.selectedVideoResolution = selected.resolution
                                                userSettings.selectedVideoFrameRate = selected.frameRate
                                                userSettings.selectedVideoPixelFormat = selected.pixelFormat
                                                
                                                // Apply immediately if video is running
                                                if VideoManager.shared.captureSession.isRunning {
                                                    VideoManager.shared.stopVideoSession()
                                                    VideoManager.shared.prepareVideo()
                                                }
                                            }
                                        }
                                    )) {
                                        ForEach(videoManager.availableVideoFormats.indices, id: \.self) { index in
                                            let format = videoManager.availableVideoFormats[index]
                                            Text(format.displayName.split(separator: "@").last ?? "Unknown")
                                                .tag(index)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                        }
                    }
                    
                    Toggle("Show HID resolution change alerts", isOn: Binding(
                        get: { !userSettings.doNotShowHidResolutionAlert },
                        set: { userSettings.doNotShowHidResolutionAlert = !$0 }
                    ))
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
```

**Step 3: Verify it compiles**

Run: `swift build`
Expected: PASS

**Step 4: Commit**

```bash
git add openterface/Views/Settings/AudioVideoSettingsView.swift
git commit -m "feat(video): add video format selection UI to Audio & Video settings"
```

---

### Task 5: Initialize Video Format Enumeration on App Start

**Files:**
- Modify: `/Users/txa/project/Openterface_MacOS/openterface/AppDelegate.swift:20-30` (add initialization)
- Modify: `/Users/txa/project/Openterface_MacOS/openterface/AppDelegate.swift:applicationDidFinishLaunching` (call enumeration)

**Interfaces:**
- Consumes: VideoManager instance
- Produces: Automatic format enumeration at app startup

**Step 1: Write the failing test**

Run: `swift build`
Expected: PASS if no syntax errors

**Step 2: Add VideoManager import and initialization call**

Add import after existing imports in AppDelegate.swift:

```swift
import AVFoundation
```

Add the call to enumerate formats in applicationDidFinishLaunching after existing setup:

```swift
func applicationDidFinishLaunching(_ aNotification: Notification) {
    // Insert code here to initialize your application
    Logger.shared.log(content: "Application finished launching")
    
    // Initialize video format enumeration
    VideoManager.shared.enumerateAvailableVideoFormats()
    
    // ... rest of existing method
}
```

**Step 3: Verify it compiles**

Run: `swift build`
Expected: PASS

**Step 4: Commit**

```bash
git add openterface/AppDelegate.swift
git commit -m "feat(video): initialize video format enumeration at app startup"
```

---

### Task 6: Test the Feature End-to-End

**Files:**
- Test: Manual verification in running application

**Interfaces:**
- Consumes: All implemented features
- Produces: Working video format selection UI

**Step 1: Build and run the application**

Run: `swift run`
Expected: Application launches successfully

**Step 2: Verify UI appears**

Navigate to Settings → Audio & Video
Expected: See new "Video Capture Format" section with resolution, frame rate, and pixel format pickers

**Step 3: Test format selection**

Select different combinations from the dropdowns
Expected: Selections apply immediately (if video is running, session restarts with new format)

**Step 4: Test persistence**

Quit and relaunch application
Expected: Previously selected format is restored and applied

**Step 5: Test edge cases**

Try selecting unsupported formats (if any exist in test environment)
Expected: Falls back to closest available format and updates selection accordingly

**Step 6: Commit test verification**

```bash
git commit -m "test(video): verify video format selection feature works end-to-end"
```

---

## Plan Complete and Saved

Plan complete and saved to `docs/superpowers/plans/2026-09-11-video-format-selection.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**

Once you choose an approach, I'll proceed with implementation following the plan exactly as written.