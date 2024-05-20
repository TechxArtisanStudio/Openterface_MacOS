/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation, either version 3 of the License, or       *
*    (at your option) any later version.                                     *
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
        self.viewHigh = 0.0
        self.isSerialOutput = false
        self.isFullScreen = false
        
    }
    @Published var isSerialOutput: Bool
    @Published var MouseControl:MouseControlMode
    @Published var viewWidth: Float
    @Published var viewHigh: Float
    @Published var edgeThreshold: CGFloat = 10.0
    @Published var isFullScreen: Bool
    @Published var isAbsoluteModeMouseHide: Bool = true
}

enum MouseControlMode: Int {
    case relative = 0
    case absolute = 1
}
