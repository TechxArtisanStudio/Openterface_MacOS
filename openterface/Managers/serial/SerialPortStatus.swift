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
import Combine

/// Observable singleton that mirrors the serial-port-related fields from AppStatus.
/// SerialPortManager writes to both AppStatus (for backward-compat with non-UI consumers)
/// and this class (for reactive SwiftUI views).
/// All writes must happen on the main thread.
class SerialPortStatus: ObservableObject {
    static let shared = SerialPortStatus()
    private init() {}

    @Published var isKeyboardConnected: Bool? = false
    @Published var isMouseConnected: Bool? = false
    @Published var isTargetConnected: Bool = false
    @Published var isControlChipsetReady: Bool = false
    @Published var chipVersion: Int8 = 0
    @Published var serialPortName: String = "N/A"
    @Published var serialPortBaudRate: Int = 0
    @Published var isNumLockOn: Bool = false
    @Published var isCapLockOn: Bool = false
    @Published var isScrollOn: Bool = false
    @Published var sdCardDirection: SDCardDirection = .unknown
}
