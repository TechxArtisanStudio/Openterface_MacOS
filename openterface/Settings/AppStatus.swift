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
import AppKit

private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)

// Enum to represent different video chipset types
enum VideoChipsetType {
    case ms2109    // MS2019 VID with MS2109 PID
    case ms2130s    // MS2130S VID with MS2130S PID
    case unknown   // No video chipset detected or unknown type
}

// Enum to represent different control chipset types
enum ControlChipsetType {
    case ch9329    // WCH VID with CH9329 PID
    case ch32v208  // WCH VID with CH32V208 PID
    case unknown   // No control chipset detected or unknown type
}

struct AppStatus {
    // Flags to track the currently connected chipset types
    static var videoChipsetType: VideoChipsetType = .unknown
    static var controlChipsetType: ControlChipsetType = .unknown
    
    static var isFristRun: Bool = false
    
    static var isMouseInView: Bool = true
    static var isFouceWindow: Bool = true
    static var isHDMIConnected: Bool = false
    static var isMouseEdge: Bool = false
    static var isCursorHidden: Bool = false
    static var isExit: Bool = false
    static var isLogMode: Bool = false
    static var isAreaOCRing: Bool = false
    
    static var isKeyboardConnected: Bool? = false
    static var isMouseConnected: Bool? = false
    static var isSwitchToHost: Bool?
    
    static var hidReadResolusion = (width: 0, height: 0)
    static var hidReadFps:Float = 0.0
    static var hidReadPixelClock: UInt32 = 0
    
    static var hidInputHTotal: UInt32 = 0
    static var hidInputVTotal: UInt32 = 0
    static var hidInputHst: UInt32 = 0
    static var hidInputVst: UInt32 = 0
    static var hidInputHsyncWidth: UInt32 = 0
    static var hidInputVsyncWidth: UInt32 = 0

    static var chipVersion: Int8 = 0
    static var isTargetConnected: Bool = false
    static var isControlChipsetReady: Bool = false
    static var isNumLockOn: Bool = false
    static var isCapLockOn: Bool = false
    static var isScrollOn: Bool = false
    static var isSwitchToggleOn: Bool = false
    static var isLockSwitchOn: Bool = false
    
    static var MS2109Version: String = ""
    static var hasHdmiSignal: Bool?
    
    static var isAudioEnabled: Bool = UserSettings.shared.isAudioEnabled
    
    static var eventHandler: Any?
    static var currentView: CGRect = CGRect(x:0,y:0,width:0,height:0)
    static var currentWindow: NSRect = NSRect(x:0,y:0,width:0,height:0)
    static var videoDimensions: CGSize = CGSize(width: 1920, height: 1080)
    
    static var USBDevices: [USBDeviceInfo] = []
    static var groupOpenterfaceDevices: [[USBDeviceInfo]] = []
    static var DefaultVideoDevice: USBDeviceInfo?
    static var isMatchVideoDevice: Bool = false
    static var DefaultUSBSerial: USBDeviceInfo?
    static var isHIDOpen: Bool?
    static let logFileName: String = "openterface.log"
    
    static var serialPortName: String = "N/A"
    static var serialPortBaudRate: Int = 0
    
    static var isHardwareConnetionToTarget: Bool = true
    static var isHardwareSwitchOn: Bool = false {
        didSet {
            if oldValue != isHardwareSwitchOn {
                // Code to be executed when the value changes
                handleHardwareSwitchChange()
            }
        }
    }
    
    static var isSoftwareSwitchOn: Bool = false {
        didSet {
            if oldValue != isSoftwareSwitchOn {
                // Code to be executed when the value changes
                handleSoftwareSwitchChange()
            }
        }
    }
    

    static func handleHardwareSwitchChange() {
        if isHardwareSwitchOn {
            if isSoftwareSwitchOn != isHardwareSwitchOn {
                isSoftwareSwitchOn = isHardwareSwitchOn
                AppStatus.isSwitchToggleOn = isHardwareSwitchOn
            }
        } else {
            if isSoftwareSwitchOn != isHardwareSwitchOn {
                isSoftwareSwitchOn = isHardwareSwitchOn
                AppStatus.isSwitchToggleOn = isHardwareSwitchOn
            }
        }
    }
    
    static func handleSoftwareSwitchChange() {
        if isSoftwareSwitchOn {
            logger.log(content: "Software switch toggled: Switching to Target device mode")

        } else {
            logger.log(content: "Software switch toggled: Switching to Host device mode")
        }
    }
}


struct USBDeviceInfo {
    let productName: String
    let manufacturer: String
    let vendorID: Int
    let productID: Int
    let locationID: String
    let speed: String
}
