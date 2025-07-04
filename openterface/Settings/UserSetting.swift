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

final class UserSettings: ObservableObject {
    static let shared = UserSettings()
    
    private init() {
        self.MouseControl = .absolute
        self.viewWidth = 0.0
        self.viewHeight = 0.0
        self.isSerialOutput = false
        self.isFullScreen = false
        
    }
    @Published var isSerialOutput: Bool
    @Published var MouseControl:MouseControlMode
    @Published var viewWidth: Float
    @Published var viewHeight: Float
    @Published var edgeThreshold: CGFloat = 5
    @Published var isFullScreen: Bool
    @Published var isAbsoluteModeMouseHide: Bool = false
    @Published var mainWindownName: String = "main_openterface"
    
    // User custom screen ratio settings
    @Published var useCustomAspectRatio: Bool = false
    @Published var customAspectRatio: AspectRatioOption = .ratio16_9
    
    // Whether to show HID resolution change alert
    @Published var doNotShowHidResolutionAlert: Bool = false
}

enum MouseControlMode: Int {
    case relative = 0
    case absolute = 1
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
