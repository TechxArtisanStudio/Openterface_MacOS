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

import SwiftUI

let mm = MouseManager.shared
let km = KeyboardManager.shared
var eventHandler: Any?

class HostManager: ObservableObject, HostManagerProtocol {
    private var  logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    // Singleton instance
    static let shared = HostManager()
    
    @Published var pointerTransparent: Bool = true
    @Published var isProgrammaticMouseMove: Bool = false

    func handleKeyboardEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, isKeyDown: Bool) {
        if isKeyDown {
            km.pressKey(keys: [keyCode], modifiers: modifierFlags)
        } else {
            km.releaseKey(keys: [keyCode])
        }
    }

    func handleRelativeMouseAction(dx: Int, dy: Int, mouseEvent: UInt8 = 0x00, wheelMovement: Int = 0x00, dragged:Bool = false) {
        if isProgrammaticMouseMove {
            return
        }

        mm.handleRelativeMouseAction(dx: Int(dx),
                                    dy: Int(dy),
                                    mouseEvent: mouseEvent,
                                    wheelMovement: scrollWheelEventDeltaMapping(delta: wheelMovement),
                                    dragged: dragged)

    }

    func handleAbsoluteMouseAction(x: Int, y: Int, mouseEvent: UInt8 = 0x00, wheelMovement: Int = 0x00) {
        mm.handleAbsoluteMouseAction(x: Int(x),
                                    y: Int(y),
                                    mouseEvent: mouseEvent,
                                    wheelMovement: wheelMovement)
    }

    func moveToAppCenter(){
        // move mouse to center of window
        if let window = NSApplication.shared.mainWindow {
            let pointInWindow = NSPoint(x: window.frame.width * 0.5, y: window.frame.height * 0.5)
            let pointOnScreen = window.convertPoint(toScreen: pointInWindow)
            let flippedY = NSHeight(NSScreen.main!.frame) - pointOnScreen.y
            let cgPoint = CGPoint(x: pointOnScreen.x, y: flippedY)
            isProgrammaticMouseMove = true
            CGWarpMouseCursorPosition(cgPoint)
            isProgrammaticMouseMove = false
        }
    }
    
    func stayAtCurrentLocation(x: Int, y: Int){
        // The mouse stay at current location
        let mouseMoveEvent = CGEvent(mouseEventSource: nil,
                                    mouseType: .mouseMoved,
                                    mouseCursorPosition: CGPoint(x: x, y: y),
                                    mouseButton: .left)
        mouseMoveEvent?.post(tap: .cghidEventTap)
        logger.log(content: "Moved mouse to current location: \(x), \(y)")
    }
    
    func makeCursorTransparent() {
        if(!self.pointerTransparent){
            return
        }
        let transparentCursorImage = NSImage(size: CGSize(width: 1, height: 1), flipped: false) { rect in
            NSColor.clear.set()
            rect.fill()
            return true
        }
        let transparentCursor = NSCursor(image: transparentCursorImage, hotSpot: NSPoint(x: 0, y: 0))
        transparentCursor.set()
        pointerTransparent = true
    }
    
    func resetCursor() {
        if(self.pointerTransparent){
            return
        }
        NSCursor.arrow.set()
        pointerTransparent = false
    }
}

func isMouseEvent(type:CGEventType) -> Bool{
    return [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel].contains(type)
}

func isKeyboardEvent(type:CGEventType) -> Bool{
    return [.keyDown, .keyUp].contains(type)
}

func scrollWheelEventDeltaMapping(delta: Int) -> UInt8 {
    // Add slowdown factor, larger value means slower scrolling
    let slowdownFactor = 2.5
    
    // Apply slowdown factor
    let slowedDelta = Int(Double(delta) / slowdownFactor)
    
    if slowedDelta == 0 {
        return 0
    } else if slowedDelta > 0 {
        return UInt8(min(slowedDelta, 127))  // 上滚：0x01-0x7F
    }
    return 0xFF - UInt8(abs(max(slowedDelta, -128))) + 1  // 下滚：0x81-0xFF
}

func mouseKeyMapper(hidMouseEventType:CGEventType) -> UInt8{
    var value:UInt8 = 0
    switch hidMouseEventType {
    case .leftMouseDown, .leftMouseDragged:
        value = value | 0x01
    case .rightMouseDown, .rightMouseDragged:
        value = value | 0x02
    case .otherMouseDown:
        value = value | 0x04
    case .leftMouseUp:
        value = value & 0xFE
    case .rightMouseUp:
        value = value & 0xFD
    case .otherMouseUp:
        value = value & 0xFB
    default:
        break
    }
    return value
}

// MARK: - HostManagerProtocol Implementation

extension HostManager {
    func setupHostIntegration() {
        // Implementation for host integration setup
    }
    
    func handleHostEvents() {
        // Implementation for handling host events
    }
    
    func cleanupHostIntegration() {
        // Implementation for cleanup
    }
}
