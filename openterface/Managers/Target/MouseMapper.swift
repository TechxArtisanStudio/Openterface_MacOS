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

class MouseMapper {
    let spm = SerialPortManager.shared
    
    func handleAbsoluteMouseAction(x: Int, y: Int, mouseEvent: UInt8 = 0x00, wheelMovement: UInt8 = 0x00) {
        var command: [UInt8] = SerialPortManager.MOUSE_ABS_ACTION_PREFIX
        command.append(mouseEvent)
        command.append(UInt8(x & 0xFF))
        command.append(UInt8((x >> 8) & 0xFF))
        command.append(UInt8(y & 0xFF))
        command.append(UInt8((y >> 8) & 0xFF))
        command.append(wheelMovement) // scroll up 0x01-0x7F; scroll down: 0x81-0xFF
        spm.sendCommand(command: command)
    }
    
    
    func handleRelativeMouseAction(dx: Int, dy: Int, mouseEvent: UInt8 = 0x00, wheelMovement: UInt8 = 0x00, dragged:Bool = false) {
        var command: [UInt8] = SerialPortManager.MOUSE_REL_ACTION_PREFIX
        let dxByte = translateRelativeMovement(value: dx)
        let dyByte = translateRelativeMovement(value: dy)
        
        command.append(mouseEvent)
        command.append(dxByte)
        command.append(dyByte)
        command.append(wheelMovement) // scroll up 0x01-0x7F; scroll down: 0x81-0xFF
        spm.sendCommand(command: command)
    }
    
    private func translateRelativeMovement(value: Int) -> UInt8 {
        // 不动：dx = 0x00，则表示在X轴方向不移动; 向右移动: 0x01 <= dx <= 0x7F; 移动像素点 = dx; 向左移动: 0x80 <= dx <= 0xFF; 移动像素点 = 0x00 - dx;
        // 不动：dy = 0x00，则表示在Y轴方向不移动；向右移动：0x01 <= dy <= 0x7F； 移动像素点 = dy；向左移动：0x80 <= dy <= 0xFF； 移动像素点 = 0x00 - dy；
        if value >= 0 {
            return UInt8(min(value, 0x7F))
        } else {
            return UInt8(0x100 + max(value, -0x80))
        }
    }
    
    private func logCommand(cmd: [UInt8]) {
        let formattedCmd = cmd.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
        Logger.shared.log(content: "Command Sent: [\(formattedCmd)]")
    }
    
    func relativeMouse2BottomRight() {
        for _ in 1...5 {
            handleRelativeMouseAction(dx: 0x7F, dy: 0x7F)
        }
    }

    func relativeMouse2TopLeft() {
        for _ in 1...5 {
            handleRelativeMouseAction(dx: -0x7F, dy: -0x7F)
        }
    }

    func relativeMouse2BottomLeft() {
        for _ in 1...5 {
            handleRelativeMouseAction(dx: -0x7F, dy: 0x7F)
        }
    }

    func relativeMouse2TopRight() {
        for _ in 1...5 {
            handleRelativeMouseAction(dx: 0x7F, dy: -0x7F)
        }
    }
}
