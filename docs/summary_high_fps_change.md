# Summary of Changes: Limit Frame Rate to 60fps with Warning Dialog

## Overview
This document summarizes the changes made to address the issue where the Openterface device appeared blurry at 120fps while being clear at 60fps. Investigation revealed that Apple's AVFoundation framework does not support the device's compressed video format at 120fps, causing decoding issues despite stable frame rate reporting.

## Key Changes

### 1. AppStatus.swift
- Modified `maxSupportedFrameRate` to always return 60.0 (removed dynamic USB speed-based switching)
- USB speed tracking retained for diagnostics but no longer influences frame rate cap

### 2. MS2130SVideoChipset.swift
- Removed `checkBandwidthCompatibility()` and `showBandwidthWarning()` methods (these were ineffective because they ran before HID read target fps)
- Cleaned up unused code

### 3. VideoManager.swift
- Updated comments to reflect fixed 60fps limit due to AVFoundation limitation
- Changed logging examples from 120fps references to 60fps
- Updated log messages to show "max 60fps limit"
- Maintained quality warnings for theoretical >90fps scenarios
- Preserved detailed format logging for debugging

### 4. VideoOutputDelegate.swift
- Removed reference to 120fps on USB 3.0+
- Clarified that frame rate blurriness stems from chip/AVFoundation compatibility

### 5. PlayerView.swift (New Warning System)
- Completely redesigned the high frame rate warning to use a modal `NSAlert` dialog
- Triggered via `UnsupportedInputFrameRate` notification from `HALIntegration.swift` when `hidReadFps > 60.0`
- Dialog features:
  - **Title**: "⚠️ Target Frame Rate Too High"
  - **Icon**: Warning symbol
  - **Informative Text** includes:
    - Current target device output rate (e.g., 120Hz)
    - Explanation: Apple's AVFoundation does not support this device's compressed video format at that rate
    - Maximum supported frame rate: 60Hz
    - System behavior: Automatically limits capture to 60fps
    - Step-by-step instructions:
      1. Open target computer's display settings
      2. Change refresh rate to 60Hz or lower
      3. Openterface automatically adapts to new frame rate
    - Note: Device functions normally; limitation is due to video compression/AVFoundation compatibility
  - **Button**: "OK"

## Technical Details

### Warning Trigger Condition
- Fires when `AppStatus.hidReadFps > 60.0`
- Uses `UnsupportedInputFrameRate` notification posted in `HALIntegration.swift` after HID reads fps
- Debounced with `hasWarnedAboutUnsupportedFps` flag to show only once per device connection

### Why AVFoundation Limitation?
The MS2130S capture chip uses a proprietary compressed video format. While the hardware can deliver frames at 120fps, macOS's AVFoundation framework lacks the decoder for this specific format at high frame rates, resulting in blurry or corrupted output despite stable frame rate reporting.

## User Experience

1. **Problem Scenario**: User connects Openterface with target device outputting 120fps
2. **System Detection**: HID reads 120fps → posts `UnsupportedInputFrameRate` notification
3. **User Notification**: Modal warning dialog appears in English with clear instructions
4. **Resolution**: User follows steps to lower target output to 60Hz or below via display settings
5. **Result**: System captures clear 60fps video without requiring USB port changes or power cycling

## Files Modified
- `/openterface/Settings/AppStatus.swift`
- `/openterface/Core/Video/MS2130SVideoChipset.swift`
- `/openterface/Managers/VideoManager.swift`
- `/openterface/ViewModels/VideoOutputDelegate.swift`
- `/openterface/Views/PlayerView.swift`

## Testing Verification
- [ ] Build succeeds with only pre-existing warnings
- [ ] Warning dialog appears when target outputs >60fps
- [ ] Dialog does not appear at ≤60fps
- [ ] System correctly caps capture at 60fps regardless of target output
- [ ] Logs show appropriate frame rate selection and format details
- [ ] No regression in existing 60fps/30fps functionality

## References
- Original issue: User reported blurriness at stable 120fps vs clarity at 60fps
- Root cause: AVFoundation lacks decoder for MS2130S compressed format at high fps
- Solution: Prevent use of unsupported high frame rates via user guidance