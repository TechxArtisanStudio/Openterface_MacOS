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
    
    // User custom screen ratio settings
    @Published var useCustomAspectRatio: Bool = false
    @Published var customAspectRatio: AspectRatioOption = .ratio16_9 {
        didSet {
            // If the selected aspect ratio is vertical (height > width),
            // switch to Fill (maintain aspect ratio) to avoid pillarboxing
            if customAspectRatio.widthToHeightRatio < 1.0 {
                gravity = .resizeAspectFill
            }
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

// Screen ratio option enumeration
enum AspectRatioOption: String, CaseIterable {
    case ratio21_9 = "21:9"     //2.33333333
    case ratio9_5 = "9:5"       //1.8       (eg: 4096x2160)
    case ratio16_9 = "16:9"     //1.77778   (eg: 1920x1080, 3840x2160)
    case ratio16_10 = "16:10"   //1.6       (eg: 2560x1600, 1920x1200)
    case ratio5_3 = "5:3"       //1.66667   (eg: 2560x1536, 1920x1152)
    case ratio4_3 = "4:3"       //1.33333   (eg: 1600x1200, 1024x768)
    case ratio5_4 = "5:4"       //1.25      (eg: 1280x1024)
    case ratio9_16 = "9:16"     //0.5625        
    case ratio9_19_5 = "9:19.5" // 0.46153846
    case ratio9_20 = "9:20"     // 0.45
    case ratio9_21 = "9:21"     // 0.42857143
    
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