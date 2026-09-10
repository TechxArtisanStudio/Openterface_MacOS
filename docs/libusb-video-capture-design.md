# LibUSB Video Capture Design for MS2130S 120fps Support

## Executive Summary

**Problem:** macOS AVFoundation driver only exposes 60fps formats for MS2130S device, even though the device hardware supports 120fps via MJPEG compression. Windows ffmpeg can access 120fps because it uses direct UVC control commands.

**Solution:** Implement a libusb-based video capture layer that bypasses AVFoundation and directly communicates with the MS2130S device using UVC protocol commands to enable 120fps MJPEG streaming.

**Key Discovery:** USB descriptors only list 60fps discrete frame rates, but UVC control commands successfully accept 120fps settings (verified: SET_CUR with 83333μs interval = 120.1fps).

---

## 1. Architecture Overview

### 1.1 Current Architecture (AVFoundation)

```
AVCaptureDevice (MS2130S)
    ↓
AVCaptureDeviceInput
    ↓
AVCaptureSession
    ↓
AVCaptureVideoDataOutput (NV12 format)
    ↓
VideoOutputDelegate (CVPixelBuffer callback)
    ↓
VideoManager (display + OCR)
```

**Limitation:** AVFoundation only exposes formats listed in USB descriptors (max 60fps).

### 1.2 Proposed Architecture (LibUSB)

```
MS2130S USB Device (VID: 0x345F, PID: 0x2132)
    ↓
LibUSB Video Transport (libusb-1.0)
    ↓
UVC Protocol Controller (control transfers)
    ↓
USB Video Stream (bulk transfers, MJPEG encoded)
    ↓
MJPEG Decoder (VideoToolbox / libjpeg-turbo)
    ↓
CVPixelBuffer Producer (NV12/BGRA format)
    ↓
VideoOutputDelegate (existing pipeline)
    ↓
VideoManager (display + OCR)
```

**Advantage:** Bypasses AVFoundation, enables 120fps via direct UVC commands.

---

## 2. Component Design

### 2.1 LibUSBVideoTransport

**Purpose:** Low-level USB communication layer for MS2130S video streaming.

**Responsibilities:**
- Initialize libusb context
- Enumerate and open MS2130S device
- Detach macOS UVC kernel driver (if needed)
- Claim Video Streaming interface (interface 1)
- Send UVC control commands (SET_CUR, GET_CUR)
- Receive MJPEG video frames via bulk transfers
- Handle USB hot-plug events

**Key Methods:**
```swift
class LibUSBVideoTransport {
    // Lifecycle
    func initialize() -> Bool
    func deinitialize()
    
    // Device management
    func openDevice() -> Bool
    func closeDevice()
    func detachKernelDriver() -> Bool
    func claimInterface() -> Bool
    
    // UVC control
    func setVideoFormat(format: UVCVideoFormat) -> Bool
    func startStream() -> Bool
    func stopStream() -> Bool
    
    // Data transfer
    func readFrame() -> Data?
    func readFrameAsync(completion: @escaping (Data?) -> Void)
}
```

**USB Endpoints (from probe):**
- **Interface 1, Alt 0:** Video Streaming
  - Endpoint 0x83: BULK IN, MaxPacketSize=512
  - Used for receiving MJPEG video data

**UVC Control Commands:**
- VS_PROBE_CONTROL (0x01): Negotiate video format parameters
- VS_COMMIT_CONTROL (0x02): Commit negotiated parameters
- SET_CUR / GET_CUR: Set/get current values

**Reference Implementation:** `WCHLibusbTransport.swift` (firmware flashing)

### 2.2 UVCProtocolController

**Purpose:** High-level UVC protocol implementation for video format negotiation.

**Responsibilities:**
- Build UVC probe/commit data structures
- Negotiate video format (MJPEG), resolution, frame rate
- Query device capabilities
- Handle UVC error conditions

**Key Data Structure (34 bytes per UVC spec):**
```c
struct UVCProbeData {
    uint16_t bmHint;              // Byte 0-1
    uint8_t  bFormatIndex;        // Byte 2 (1 = MJPEG)
    uint8_t  bFrameIndex;         // Byte 3 (1 = 1920x1080)
    uint32_t dwFrameInterval;     // Byte 4-7 (83333 = 120fps)
    uint16_t wKeyFrameRate;       // Byte 8-9
    uint16_t wPFrameRate;         // Byte 10-11
    uint16_t wCompQuality;        // Byte 12-13
    uint16_t wCompWindowSize;     // Byte 14-15
    uint16_t wDelay;              // Byte 16-17
    uint32_t dwMaxVideoFrameSize; // Byte 18-21
    uint32_t dwMaxPayloadTransferSize; // Byte 22-25
}
```

**Supported Formats (from USB descriptors):**
- 1920x1080 @ 120fps (MJPEG) ← **NEW, via UVC control**
- 1920x1080 @ 60fps (MJPEG)
- 1280x720 @ 120fps (MJPEG) ← **NEW, via UVC control**
- 1280x720 @ 60fps (MJPEG)
- 720x576 @ 60fps (MJPEG)
- 720x480 @ 60fps (MJPEG)
- 640x480 @ 60fps (MJPEG)

**Key Methods:**
```swift
class UVCProtocolController {
    func probeFormat(formatIndex: UInt8, frameIndex: UInt8, frameInterval: UInt32) -> Bool
    func commitFormat() -> Bool
    func getCurrentFormat() -> UVCVideoFormat?
    func getMaxFrameRate(format: UInt8, frame: UInt8) -> Double?
}
```

### 2.3 MJPEGDecoder

**Purpose:** Decode MJPEG frames into CVPixelBuffer for display and processing.

**Options:**

#### Option A: VideoToolbox (Recommended)
- **Pros:** Hardware-accelerated, already available on macOS, no external dependencies
- **Cons:** Requires proper format configuration
- **Implementation:**
  ```swift
  class MJPEGDecoder {
      private var decompressionSession: VTDecompressionSession?
      
      func initialize() -> Bool
      func decodeFrame(mjpegData: Data) -> CVPixelBuffer?
      func deinitialize()
  }
  ```

#### Option B: libjpeg-turbo
- **Pros:** High performance, mature library
- **Cons:** External dependency, requires linking
- **Implementation:** Use libjpeg-turbo to decode to YUV, then convert to CVPixelBuffer

#### Option C: Core Image
- **Pros:** Simple API, hardware-accelerated
- **Cons:** May not be as fast as VideoToolbox
- **Implementation:** Use CIFilter to decode JPEG

**Recommendation:** Use **VideoToolbox** (Option A) for best performance and zero dependencies.

**Output Format:** CVPixelBuffer in NV12 (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) to match existing pipeline.

### 2.4 LibUSBVideoCaptureManager

**Purpose:** High-level video capture manager that integrates LibUSB transport with the existing VideoManager pipeline.

**Responsibilities:**
- Coordinate LibUSBVideoTransport, UVCProtocolController, and MJPEGDecoder
- Manage video stream lifecycle (start/stop)
- Convert decoded frames to CVPixelBuffer
- Feed frames into VideoOutputDelegate (reuse existing pipeline)
- Handle frame rate control and dropped frames

**Key Methods:**
```swift
class LibUSBVideoCaptureManager {
    // Lifecycle
    func startCapture(resolution: VideoResolution) -> Bool
    func stopCapture()
    
    // Configuration
    func setResolution(_ resolution: VideoResolution) -> Bool
    func setFrameRate(_ fps: Float) -> Bool
    
    // Frame delivery
    func getFrame() -> CVPixelBuffer?
    func startFrameDelivery(delegate: VideoOutputDelegate)
}
```

**Integration Strategy:**
- Create a parallel capture path alongside AVCaptureSession
- Use a flag in VideoManager to switch between AVFoundation and LibUSB paths
- For MS2130S, prefer LibUSB path when 120fps is requested
- For other chipsets, continue using AVFoundation

---

## 3. Data Flow

### 3.1 Video Capture Flow

```
1. User selects 1920x1080 @ 120fps in UI
   ↓
2. VideoManager detects MS2130S chipset
   ↓
3. VideoManager creates LibUSBVideoCaptureManager
   ↓
4. LibUSBVideoCaptureManager initializes LibUSBVideoTransport
   ↓
5. LibUSBVideoTransport opens device, claims interface
   ↓
6. UVCProtocolController negotiates format:
   - bFormatIndex = 1 (MJPEG)
   - bFrameIndex = 1 (1920x1080)
   - dwFrameInterval = 83333 (120fps)
   ↓
7. UVC SET_CUR command sent to device
   ↓
8. LibUSBVideoTransport starts bulk transfer loop
   ↓
9. MJPEG frames received via endpoint 0x83
   ↓
10. MJPEGDecoder decodes frame to CVPixelBuffer (NV12)
   ↓
11. CVPixelBuffer passed to VideoOutputDelegate
   ↓
12. VideoOutputDelegate processes frame (active rect detection, OCR)
   ↓
13. Frame displayed in UI
```

### 3.2 Frame Synchronization

**Challenge:** USB bulk transfers may deliver frames at irregular intervals.

**Solution:**
- Use a frame queue (ring buffer) to smooth delivery
- Drop frames if processing is too slow (maintain real-time feel)
- Use CADisplayLink or timer to pace frame delivery to display refresh rate

---

## 4. Thread Model

```
Main Thread
    ↓ (UI updates)
VideoManager
    ↓ (coordinates capture)
LibUSBVideoCaptureManager
    ↓
    ├─→ LibUSB Transfer Thread (receives USB data)
    │       ↓
    │   MJPEG Decode Thread (decodes frames)
    │       ↓
    └─→ Video Output Queue (delivers CVPixelBuffer)
            ↓
        VideoOutputDelegate (processes frames)
```

**Thread Safety:**
- LibUSB context is thread-safe
- Use serial dispatch queues for frame delivery
- Use locks for shared state (device handle, stream status)

---

## 5. Error Handling

### 5.1 USB Errors

| Error | Cause | Recovery |
|-------|-------|----------|
| LIBUSB_ERROR_NO_DEVICE | Device disconnected | Stop capture, notify user |
| LIBUSB_ERROR_ACCESS | Permission denied | Request USB access, show instructions |
| LIBUSB_ERROR_TIMEOUT | Transfer timeout | Retry with exponential backoff |
| LIBUSB_ERROR_OVERFLOW | Buffer overflow | Increase buffer size, reduce frame rate |

### 5.2 UVC Errors

| Error | Cause | Recovery |
|-------|-------|----------|
| SET_CUR fails | Unsupported format | Fall back to 60fps |
| GET_CUR returns invalid data | Device not ready | Retry after delay |
| Stream stops unexpectedly | USB bandwidth issue | Restart stream, reduce resolution |

### 5.3 MJPEG Decode Errors

| Error | Cause | Recovery |
|-------|-------|----------|
| Decode fails | Corrupted frame | Skip frame, request next |
| Format mismatch | Wrong pixel format | Re-initialize decoder |

---

## 6. Performance Considerations

### 6.1 USB Bandwidth

**USB 2.0:** 480 Mbps theoretical, ~280 Mbps practical

**1920x1080 @ 120fps MJPEG:**
- Typical MJPEG compression: 10:1 to 20:1
- Uncompressed: 1920 × 1080 × 3 bytes × 120 fps = 746 MB/s = 5968 Mbps
- Compressed (10:1): ~597 Mbps
- **Problem:** Exceeds USB 2.0 bandwidth!

**Solution:**
- Use higher compression ratio (20:1 or more)
- Reduce resolution (1280x720 @ 120fps = ~265 MB/s compressed)
- Use USB 3.0 if device supports it (probe shows USB 2.0)

**Recommendation:**
- 1920x1080 @ 60fps (MJPEG, high quality)
- 1280x720 @ 120fps (MJPEG, medium quality)

### 6.2 CPU Usage

**MJPEG Decoding:**
- VideoToolbox: Hardware-accelerated, ~5% CPU per frame
- Software decode: ~20-30% CPU per frame

**Optimization:**
- Use VideoToolbox for hardware acceleration
- Decode on background thread
- Batch process frames if needed

### 6.3 Memory Usage

**Frame Buffers:**
- 1920x1080 NV12: ~3 MB per frame
- 1280x720 NV12: ~1.4 MB per frame

**Optimization:**
- Use CVPixelBuffer pool (reuse buffers)
- Limit queue depth to 2-3 frames
- Release frames immediately after processing

---

## 7. Integration with Existing Code

### 7.1 VideoManager Changes

**Add flag to select capture path:**
```swift
class VideoManager {
    private var useLibUSBCapture = false
    private var libUSBCaptureManager: LibUSBVideoCaptureManager?
    
    func setupSession() {
        if halVideoChipset is MS2130SVideoChipset {
            // Use LibUSB for MS2130S to enable 120fps
            useLibUSBCapture = true
            libUSBCaptureManager = LibUSBVideoCaptureManager()
            libUSBCaptureManager?.startCapture(resolution: currentResolution)
        } else {
            // Use AVFoundation for other chipsets
            useLibUSBCapture = false
            // ... existing AVCaptureSession code ...
        }
    }
}
```

### 7.2 VideoOutputDelegate Reuse

**No changes needed!** The existing VideoOutputDelegate already processes CVPixelBuffer. LibUSB capture will produce CVPixelBuffer in the same format (NV12), so the entire downstream pipeline works unchanged.

### 7.3 MS2130SVideoChipset Changes

**Already done in worktree:**
- maxFrameRate = 120.0
- supportedResolutions includes 120fps options

**No additional changes needed.**

---

## 8. Testing Strategy

### 8.1 Unit Tests

1. **LibUSBVideoTransport Tests**
   - Test device enumeration
   - Test UVC control commands
   - Test bulk transfer

2. **UVCProtocolController Tests**
   - Test format negotiation
   - Test frame rate setting
   - Test error handling

3. **MJPEGDecoder Tests**
   - Test decode correctness
   - Test performance (FPS)
   - Test memory usage

### 8.2 Integration Tests

1. **End-to-end capture test**
   - Capture 100 frames at 120fps
   - Verify no frame drops
   - Verify image quality

2. **Hot-plug test**
   - Disconnect device during capture
   - Reconnect device
   - Verify auto-recovery

3. **Resolution switching test**
   - Switch between 1080p@60fps and 720p@120fps
   - Verify clean transitions

### 8.3 Performance Tests

1. **Frame rate test**
   - Measure actual FPS at 120fps setting
   - Target: >115 FPS sustained

2. **Latency test**
   - Measure USB transfer latency
   - Measure decode latency
   - Target: <50ms total

3. **CPU usage test**
   - Measure CPU usage during 120fps capture
   - Target: <30% on M1 Mac

---

## 9. Implementation Plan

### Phase 1: Core LibUSB Transport (2-3 days)

1. Create `LibUSBVideoTransport.swift`
2. Implement device enumeration and opening
3. Implement UVC control commands (SET_CUR, GET_CUR)
4. Implement bulk transfer for video data
5. Test with probe program (verify 120fps setting)

### Phase 2: MJPEG Decoding (1-2 days)

1. Create `MJPEGDecoder.swift` using VideoToolbox
2. Implement CVPixelBuffer production
3. Test decode correctness and performance

### Phase 3: Integration (2-3 days)

1. Create `LibUSBVideoCaptureManager.swift`
2. Integrate with VideoManager
3. Add UI toggle for 120fps mode
4. Test end-to-end capture

### Phase 4: Polish (1-2 days)

1. Error handling and recovery
2. Performance optimization
3. Documentation
4. Code review

**Total: 6-10 days**

---

## 10. Risks and Mitigations

### Risk 1: USB Bandwidth Limitation

**Risk:** 1920x1080 @ 120fps may exceed USB 2.0 bandwidth.

**Mitigation:**
- Test actual bandwidth usage
- Fall back to 720p @ 120fps if needed
- Use aggressive MJPEG compression

### Risk 2: macOS Kernel Driver Conflict

**Risk:** macOS UVC driver may prevent libusb from claiming interface.

**Mitigation:**
- Use `libusb_detach_kernel_driver()` to detach driver
- May require root privileges or kext unload
- Test on multiple macOS versions

### Risk 3: Device Compatibility

**Risk:** Device may not actually support 120fps (UVC command succeeds but stream fails).

**Mitigation:**
- Test actual video stream at 120fps
- Implement fallback to 60fps
- Verify with user (Windows test confirms hardware support)

### Risk 4: Performance

**Risk:** MJPEG decoding may be too slow for 120fps.

**Mitigation:**
- Use VideoToolbox hardware acceleration
- Optimize decode pipeline
- Drop frames if needed (maintain real-time feel)

---

## 11. Success Criteria

1. **Functional:** Can capture video at 1280x720 @ 120fps (MJPEG)
2. **Performance:** Sustained >115 FPS, <50ms latency
3. **Quality:** Image quality comparable to 60fps mode
4. **Stability:** No crashes, clean error recovery
5. **Compatibility:** Works on macOS 12.0+, M1 and Intel Macs

---

## 12. Future Enhancements

1. **HDR support:** If device supports HDR, expose via UVC
2. **Multiple devices:** Support multiple MS2130S devices simultaneously
3. **Recording:** Add video recording capability
4. **Audio capture:** Integrate USB audio streaming (interface 3)
5. **USB 3.0 support:** If future hardware supports USB 3.0, enable higher resolutions

---

## 13. Conclusion

The libusb-based video capture approach is **feasible and recommended** for enabling 120fps support on MS2130S. The key insight is that UVC control commands can set frame rates beyond what USB descriptors advertise, and Windows ffmpeg uses this mechanism to achieve 120fps.

**Next Steps:**
1. Review and approve this design
2. Implement Phase 1 (core LibUSB transport)
3. Test 120fps streaming with probe program
4. Proceed to full implementation if tests succeed

**Recommendation:** Proceed with implementation. The risk is low (can fall back to AVFoundation), and the potential gain is high (120fps support on macOS).
