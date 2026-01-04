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

final class UserSettings: ObservableObject {
    static let shared = UserSettings()
    
    private init() {
        // Migrate old mouse control setting if needed
        let savedMouseMode = UserDefaults.standard.object(forKey: "MouseControl") as? Int
        if let mode = savedMouseMode {
            // Migrate old "relative" (0) to "relativeEvents" (1) for better compatibility
            if mode == 0 {
                self.MouseControl = .relativeEvents
                UserDefaults.standard.set(MouseControlMode.relativeEvents.rawValue, forKey: "MouseControl")
            } else {
                self.MouseControl = MouseControlMode(rawValue: mode) ?? .absolute
            }
        } else {
            self.MouseControl = .absolute
        }
        
        self.viewWidth = 0.0
        self.viewHeight = 0.0
        self.isSerialOutput = false
        self.isFullScreen = false
        // Load paste preferences from UserDefaults
        let savedPasteBehavior = UserDefaults.standard.string(forKey: "pasteBehavior")
        self.pasteBehavior = PasteBehavior(rawValue: savedPasteBehavior ?? "") ?? .askEveryTime
        
        // Load audio enabled preference from UserDefaults
        self.isAudioEnabled = UserDefaults.standard.object(forKey: "isAudioEnabled") as? Bool ?? false
        
        // Load keyboard layout preference from UserDefaults
        let savedKeyboardLayout = UserDefaults.standard.string(forKey: "keyboardLayout")
        self.keyboardLayout = KeyboardLayout(rawValue: savedKeyboardLayout ?? "") ?? .mac
        
        // Load last successful baudrate from UserDefaults
        self.lastBaudrate = UserDefaults.standard.object(forKey: "lastBaudrate") as? Int ?? 9600  // Default to LOWSPEED_BAUDRATE
        
        // Load preferred baudrate from UserDefaults
        let savedPreferredBaudrate = UserDefaults.standard.object(forKey: "preferredBaudrate") as? Int
        self.preferredBaudrate = BaudrateOption(rawValue: savedPreferredBaudrate ?? 115200) ?? .highSpeed
        
        // Load gravity settings from UserDefaults
        let savedGravity = UserDefaults.standard.string(forKey: "gravity")
        self.gravity = GravityOption(rawValue: savedGravity ?? "") ?? .resizeAspect
        
        // Load serial output logging preference from UserDefaults
        self.isSerialOutput = UserDefaults.standard.object(forKey: "isSerialOutput") as? Bool ?? false
        
        // Load log mode preference from UserDefaults
        self.isLogMode = UserDefaults.standard.object(forKey: "isLogMode") as? Bool ?? false
        
        // Load mouse event throttling Hz limit from UserDefaults
        let savedMouseEventThrottleHz = UserDefaults.standard.object(forKey: "mouseEventThrottleHz") as? Int ?? 60
        self.mouseEventThrottleHz = savedMouseEventThrottleHz
        
        // Load control mode from UserDefaults
        let savedControlMode = UserDefaults.standard.object(forKey: "controlMode") as? Int ?? 0x82
        self.controlMode = ControlMode(rawValue: savedControlMode) ?? .compatibility
        
        // Load always on top preference from UserDefaults
        self.isAlwaysOnTop = UserDefaults.standard.object(forKey: "isAlwaysOnTop") as? Bool ?? false
        
        // Load Target Screen placement from UserDefaults
        let savedTargetPlacement = UserDefaults.standard.string(forKey: "targetComputerPlacement")
        self.targetComputerPlacement = TargetComputerPlacement(rawValue: savedTargetPlacement ?? "") ?? .right

        // Load persisted active video rect from UserDefaults
        self.activeVideoX = UserDefaults.standard.object(forKey: "activeVideoX") as? Int ?? 0
        self.activeVideoY = UserDefaults.standard.object(forKey: "activeVideoY") as? Int ?? 0
        self.activeVideoWidth = UserDefaults.standard.object(forKey: "activeVideoWidth") as? Int ?? 0
        self.activeVideoHeight = UserDefaults.standard.object(forKey: "activeVideoHeight") as? Int ?? 0

        // Load aspect ratio mode from UserDefaults, with migration from old useCustomAspectRatio setting
        let savedAspectRatioMode = UserDefaults.standard.string(forKey: "aspectRatioMode")
        let aspectRatioModeValue: AspectRatioMode
        if let mode = savedAspectRatioMode {
            aspectRatioModeValue = AspectRatioMode(rawValue: mode) ?? .custom
        } else {
            // Migrate from old useCustomAspectRatio boolean setting
            let useCustomAspectRatio = UserDefaults.standard.object(forKey: "useCustomAspectRatio") as? Bool ?? false
            aspectRatioModeValue = useCustomAspectRatio ? .custom : .hidResolution
            
            // If we found the old setting, save the new one
            if UserDefaults.standard.object(forKey: "useCustomAspectRatio") != nil {
                UserDefaults.standard.set(aspectRatioModeValue.rawValue, forKey: "aspectRatioMode")
                UserDefaults.standard.removeObject(forKey: "useCustomAspectRatio")
            }
        }
        self.aspectRatioMode = aspectRatioModeValue

        // (doActiveResolutionCheck is loaded from UserDefaults in its declaration)
        
        // Load custom aspect ratio value from UserDefaults
        let savedCustomAspectRatioValue = UserDefaults.standard.object(forKey: "customAspectRatioValue") as? Double ?? 16.0/9.0
        self.customAspectRatioValue = CGFloat(savedCustomAspectRatioValue)
    }
    @Published var isSerialOutput: Bool {
        didSet {
            UserDefaults.standard.set(isSerialOutput, forKey: "isSerialOutput")
        }
    }
    
    // Log mode preference persistence
    @Published var isLogMode: Bool {
        didSet {
            UserDefaults.standard.set(isLogMode, forKey: "isLogMode")
        }
    }
    
    @Published var MouseControl:MouseControlMode {
        didSet {
            UserDefaults.standard.set(MouseControl.rawValue, forKey: "MouseControl")
        }
    }
    @Published var viewWidth: Float
    @Published var viewHeight: Float
    @Published var edgeThreshold: CGFloat = 5
    @Published var isFullScreen: Bool
    @Published var isAbsoluteModeMouseHide: Bool = false
    @Published var mainWindownName: String = "main_openterface"
    
    // Aspect ratio mode setting - determines which aspect ratio source to use
    @Published var aspectRatioMode: AspectRatioMode {
        didSet {
            UserDefaults.standard.set(aspectRatioMode.rawValue, forKey: "aspectRatioMode")
        }
    }
    
    // User custom screen ratio settings
    @Published var customAspectRatio: AspectRatioOption = .ratio16_9 {
        didSet {
            // If the selected aspect ratio is vertical (height > width),
            // switch to Fill (maintain aspect ratio) to avoid pillarboxing
            if customAspectRatio.widthToHeightRatio < 1.0 {
                gravity = .resizeAspectFill
            }
            UserDefaults.standard.set(customAspectRatio.rawValue, forKey: "customAspectRatio")
        }
    }
    
    // Custom aspect ratio value (CGFloat) for arbitrary aspect ratios not in predefined options
    @Published var customAspectRatioValue: CGFloat {
        didSet {
            UserDefaults.standard.set(customAspectRatioValue, forKey: "customAspectRatioValue")
        }
    }
    
    // Whether to show HID resolution change alert
    @Published var doNotShowHidResolutionAlert: Bool = false
    
    // Audio enabled state persistence
    @Published var isAudioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAudioEnabled, forKey: "isAudioEnabled")
        }
    }
    
    // Whether to perform active resolution checking (detect active video area and auto-match aspect)
    // Default is false to avoid unexpected UI changes
    @Published var doActiveResolutionCheck: Bool = UserDefaults.standard.object(forKey: "doActiveResolutionCheck") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(doActiveResolutionCheck, forKey: "doActiveResolutionCheck")
        }
    }
    
    // Keyboard layout preference persistence
    @Published var keyboardLayout: KeyboardLayout {
        didSet {
            UserDefaults.standard.set(keyboardLayout.rawValue, forKey: "keyboardLayout")
        }
    }
    
    // Paste behavior settings
    @Published var pasteBehavior: PasteBehavior {
        didSet {
            UserDefaults.standard.set(pasteBehavior.rawValue, forKey: "pasteBehavior")
        }
    }
    
    // Last successful serial port baudrate persistence
    @Published var lastBaudrate: Int {
        didSet {
            UserDefaults.standard.set(lastBaudrate, forKey: "lastBaudrate")
        }
    }
    
    // Preferred baudrate for serial port connection
    @Published var preferredBaudrate: BaudrateOption {
        didSet {
            UserDefaults.standard.set(preferredBaudrate.rawValue, forKey: "preferredBaudrate")
        }
    }
    
    // Gravity settings for both content and video layers
    @Published var gravity: GravityOption = .resizeAspect {
        didSet {
            UserDefaults.standard.set(gravity.rawValue, forKey: "gravity")
            // Notify interested parties (e.g., PlayerView) about gravity change
            NotificationCenter.default.post(name: Notification.Name.gravitySettingsChanged, object: nil)
        }
    }
    
    // Mouse event throttling Hz limit (events per second)
    @Published var mouseEventThrottleHz: Int = 60 {
        didSet {
            UserDefaults.standard.set(mouseEventThrottleHz, forKey: "mouseEventThrottleHz")
        }
    }
    
    // Control mode setting for the HID chip
    @Published var controlMode: ControlMode {
        didSet {
            UserDefaults.standard.set(controlMode.rawValue, forKey: "controlMode")
        }
    }
    
    // Always on top window setting
    @Published var isAlwaysOnTop: Bool {
        didSet {
            UserDefaults.standard.set(isAlwaysOnTop, forKey: "isAlwaysOnTop")
        }
    }
    
    // Target Screen placement setting
    @Published var targetComputerPlacement: TargetComputerPlacement {
        didSet {
            UserDefaults.standard.set(targetComputerPlacement.rawValue, forKey: "targetComputerPlacement")
        }
    }

    // Persisted active video area (stored in image pixels)
    @Published var activeVideoX: Int {
        didSet { UserDefaults.standard.set(activeVideoX, forKey: "activeVideoX") }
    }
    @Published var activeVideoY: Int {
        didSet { UserDefaults.standard.set(activeVideoY, forKey: "activeVideoY") }
    }
    @Published var activeVideoWidth: Int {
        didSet { UserDefaults.standard.set(activeVideoWidth, forKey: "activeVideoWidth") }
    }
    @Published var activeVideoHeight: Int {
        didSet { UserDefaults.standard.set(activeVideoHeight, forKey: "activeVideoHeight") }
    }

    // Convenience computed rect
    var activeVideoRect: CGRect {
        return CGRect(x: activeVideoX, y: activeVideoY, width: activeVideoWidth, height: activeVideoHeight)
    }
}

enum MouseControlMode: Int {
    case relativeHID = 0
    case relativeEvents = 1
    case absolute = 2
    
    var displayName: String {
        switch self {
        case .relativeHID:
            return "Relative (HID)"
        case .relativeEvents:
            return "Relative (Events)"
        case .absolute:
            return "Absolute"
        }
    }
    
    var description: String {
        switch self {
        case .relativeHID:
            return "Relative mouse control via HID (requires accessibility permissions)"
        case .relativeEvents:
            return "Relative mouse control via window events (no extra permissions)"
        case .absolute:
            return "Absolute mouse positioning"
        }
    }
}

// Paste behavior options
enum PasteBehavior: String, CaseIterable {
    case askEveryTime = "askEveryTime"
    case alwaysPasteToTarget = "alwaysPasteToTarget" 
    case alwaysPassToTarget = "alwaysPassToTarget"
    
    var displayName: String {
        switch self {
        case .askEveryTime:
            return "Ask Every Time"
        case .alwaysPasteToTarget:
            return "Always Host Paste"
        case .alwaysPassToTarget:
            return "Always Local Paste"
        }
    }
    
    var menuDisplayName: String {
        switch self {
        case .askEveryTime:
            return "Ask Every Time"
        case .alwaysPasteToTarget:
            return "Host Paste"
        case .alwaysPassToTarget:
            return "Local Paste"
        }
    }
}

// Keyboard layout enumeration
enum KeyboardLayout: String, CaseIterable {
    case windows = "windows"
    case mac = "mac"
    
    var displayName: String {
        switch self {
        case .windows:
            return "Windows Mode"
        case .mac:
            return "Mac Mode"
        }
    }
    
    var description: String {
        switch self {
        case .windows:
            return "Optimized for Windows targets"
        case .mac:
            return "Optimized for Mac targets"
        }
    }
}

// Aspect ratio mode enumeration - determines which aspect ratio source to use
enum AspectRatioMode: String, CaseIterable {
    case custom = "custom"           // User-specified custom aspect ratio
    case hidResolution = "hid"       // From HID resolution query (capture card info)
    case activeResolution = "active" // From active video area detection
    
    var displayName: String {
        switch self {
        case .custom:
            return "Custom Aspect Ratio"
        case .hidResolution:
            return "HID Resolution (Device Info)"
        case .activeResolution:
            return "Active Resolution (Auto-Detect)"
        }
    }
    
    var description: String {
        switch self {
        case .custom:
            return "Use a custom aspect ratio specified by the user"
        case .hidResolution:
            return "Use HID resolution from the capture card (may have blank areas)"
        case .activeResolution:
            return "Auto-detect the active video area periodically"
        }
    }
}

// Screen ratio option enumeration
enum AspectRatioOption: String, CaseIterable {
    case ratio21_9 = "21:9"     //2.33333333
    case ratio32_15 = "32:15"   //2.13333333 (eg: 1920x900, 1280x600)
    case ratio9_5 = "9:5"       //1.8       (eg: 4096x2160)
    case ratio16_9 = "16:9"     //1.77778   (eg: 1920x1080, 3840x2160)
    case ratio16_10 = "16:10"   //1.6       (eg: 2560x1600, 1920x1200)
    case ratio5_3 = "5:3"       //1.66667   (eg: 2560x1536, 1920x1152)
    case ratio211_135 = "211:135" //1.56296296 (Special handling for 1280:768, the capture card will return such a aspect ratio)
    case ratio3_2 = "3:2"       //1.5
    case ratio4_3 = "4:3"       //1.33333   (eg: 1600x1200, 1024x768)
    case ratio5_4 = "5:4"       //1.25      (eg: 1280x1024)
    case ratio211_180 = "211:180" //1.17222222 (Special handling for 1266:1080, the capture card will return such a aspect ratio)
    case ratio9_16 = "9:16"     //0.5625        
    case ratio9_19_5 = "9:19.5" // 0.46153846 
    case ratio9_20 = "9:20"     // 0.45
    case ratio9_21 = "9:21"     // 0.42857143
    case ratio228_487 = "228:487" // 0.468

    var widthToHeightRatio: CGFloat {
        switch self {
        case .ratio4_3:
            return 4.0 / 3.0
        case .ratio16_9:
            return 16.0 / 9.0
        case .ratio16_10:
            return 16.0 / 10.0
        case .ratio5_3:
            return 5.0 / 3.0
        case .ratio5_4:
            return 5.0 / 4.0
        case .ratio21_9:
            return 21.0 / 9.0
        case .ratio211_135:
            return 211.0 / 135.0
        case .ratio211_180:
            return 211.0 / 180.0
        case .ratio3_2:
            return 3.0/2.0
        case .ratio32_15:
            return 32.0 / 15.0
        case .ratio9_16:
            return 9.0 / 16.0
        case .ratio9_19_5:
            return 9.0 / 19.5
        case .ratio9_20:
            return 9.0 / 20.0
        case .ratio9_21:
            return 9.0 / 21.0
        case .ratio9_5:
            return 9.0 / 5.0
        case .ratio228_487:
            return 228.0 / 487.0
        }
    }
    
    var toString: String {
        return self.rawValue
    }
}

// Baudrate option enumeration
enum BaudrateOption: Int, CaseIterable {
    case lowSpeed = 9600
    case highSpeed = 115200
    
    var displayName: String {
        switch self {
        case .lowSpeed:
            return "9600 bps (Low Speed)"
        case .highSpeed:
            return "115200 bps (High Speed)"
        }
    }
    
    var description: String {
        switch self {
        case .lowSpeed:
            return "Slower, more reliable connection"
        case .highSpeed:
            return "Faster data transmission"
        }
    }
}

// Gravity option enumeration for video layer scaling
enum GravityOption: String, CaseIterable {
    case resize = "Stretch"
    case resizeAspect = "Fit"
    case resizeAspectFill = "Fill"
    
    var displayName: String {
        switch self {
        case .resize:
            return "Stretch to Fit"
        case .resizeAspect:
            return "Fit (Maintain Aspect Ratio)"
        case .resizeAspectFill:
            return "Fill (Maintain Aspect Ratio)"
        }
    }
    
    var description: String {
        switch self {
        case .resize:
            return "Stretches content to fill the entire view"
        case .resizeAspect:
            return "Fits content while preserving aspect ratio"
        case .resizeAspectFill:
            return "Fills view while preserving aspect ratio (may crop)"
        }
    }
    
    var contentsGravity: CALayerContentsGravity {
        switch self {
        case .resize:
            return .resize
        case .resizeAspect:
            return .resizeAspect
        case .resizeAspectFill:
            return .resizeAspectFill
        }
    }
    
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .resize:
            return .resize
        case .resizeAspect:
            return .resizeAspect
        case .resizeAspectFill:
            return .resizeAspectFill
        }
    }
}
// Control mode enumeration for HID chip operation
enum ControlMode: Int, CaseIterable {
    case performance = 0x00        // Performance mode
    case keyboardOnly = 0x01       // Keyboard only mode
    case compatibility = 0x82      // Compatibility mode (default)
    case customHID = 0x03          // Custom HID mode
    
    var displayName: String {
        switch self {
        case .performance:
            return "Performance Mode"
        case .keyboardOnly:
            return "Keyboard Only"
        case .compatibility:
            return "Compatibility Mode"
        case .customHID:
            return "Custom HID"
        }
    }
    
    var description: String {
        switch self {
        case .performance:
            return "Optimized for maximum performance"
        case .keyboardOnly:
            return "Keyboard input only"
        case .compatibility:
            return "Maximum compatibility with target devices (default)"
        case .customHID:
            return "Custom HID configuration"
        }
    }
    
    var modeByteValue: UInt8 {
        return UInt8(self.rawValue)
    }
}

// Target Screen placement enumeration
enum TargetComputerPlacement: String, CaseIterable {
    case left = "left"
    case right = "right"
    case top = "top"
    case bottom = "bottom"
    
    var displayName: String {
        switch self {
        case .left:
            return "Left"
        case .right:
            return "Right"
        case .top:
            return "Top"
        case .bottom:
            return "Bottom"
        }
    }
    
    var description: String {
        switch self {
        case .left:
            return "Target Screen positioned to the left"
        case .right:
            return "Target Screen positioned to the right"
        case .top:
            return "Target Screen positioned at the top"
        case .bottom:
            return "Target Screen positioned at the bottom"
        }
    }
}
