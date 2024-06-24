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

let mm = MouseManager()
let km = KeyboardManager.shared
var eventHandler: Any?

class HostManager {
    // Singleton instance
    static let shared = HostManager()
    
    @Published var pointerTransparent: Bool = true
    
    var eventTap: CFMachPort?
    let keyDownMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let keyUpMask = CGEventMask(1 << CGEventType.keyUp.rawValue)
    let leftMouseDownMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
    let leftMouseUpMask = CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
    let rightMouseDownMask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
    let rightMouseUpMask = CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
    let mouseMovedMask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
    let leftMouseDraggedMask = CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
    let rightMouseDraggedMask = CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
    let scrollWheelMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    let otherMouseDownMask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
    let otherMouseUpMask = CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
    
    init() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let accessibilityEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)

        if !accessibilityEnabled {
            Logger.shared.log(content: "The app doesn't have Accessibility permission.")
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Needed"
            alert.informativeText = "This app needs Accessibility permissions to function. Please enable it in System Preferences."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        DispatchQueue.global().async {
            self.setupEventTap()
        }
    }
    
    func setupEventTap() {
        let eventMask: CGEventMask = keyDownMask | keyUpMask | leftMouseDownMask | leftMouseUpMask | rightMouseDownMask | rightMouseUpMask | mouseMovedMask | leftMouseDraggedMask | rightMouseDraggedMask | scrollWheelMask | otherMouseDownMask | otherMouseUpMask

        eventTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: eventMask, callback: eventTapCallback, userInfo: nil)
        km.monitorKeyboardEvents()
        if let eventTap = eventTap {
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            CFRunLoopRun()
        } else {
            Logger.shared.log(content: "Failed to create event tap")
        }
    }
    
    func moveToAppCenter(){
        // move mouse to center of window
        stayAtCurrentLocation(x: Int(UserSettings.shared.viewWidth/2), y: Int(UserSettings.shared.viewHigh/2))
    }
    
    func stayAtCurrentLocation(x: Int, y: Int){
        // The mouse stay at current location
        let mouseMoveEvent = CGEvent(mouseEventSource: nil,
                                    mouseType: .mouseMoved,
                                    mouseCursorPosition: CGPoint(x: x, y: y),
                                    mouseButton: .left)
        mouseMoveEvent?.post(tap: .cghidEventTap)
        Logger.shared.log(content: "Moved mouse to current location: \(x), \(y)")
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

func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    
    if let handler = eventHandler {
        NSEvent.removeMonitor(handler)
        eventHandler = nil
    }
    
    handleMouseEvent(type:type, event:event, isRelative:UserSettings.shared.MouseControl == .relative)

    return Unmanaged.passRetained(event)
}

func isMouseEvent(type:CGEventType) -> Bool{
    return [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel].contains(type)
}

func isKeyboardEvent(type:CGEventType) -> Bool{
    return [.keyDown, .keyUp].contains(type)
}

func handleMouseEvent(type: CGEventType, event: CGEvent, isRelative: Bool) {
    if AppStatus.isMouseInView && AppStatus.isFouceWindow && AppStatus.isHDMIConnected && AppStatus.isExit == false {
        let mouseLocation = NSEvent.mouseLocation
        
        // computing edge
        let edgeThreshold = isRelative ? UserSettings.shared.edgeThreshold : 0
        let leftEdge = AppStatus.currentWindow.minX + edgeThreshold
        let rightEdge = AppStatus.currentWindow.minX + AppStatus.currentWindow.width - edgeThreshold
        let bottomEdge = AppStatus.currentWindow.minY + edgeThreshold
        let topEdge = AppStatus.currentWindow.minY + AppStatus.currentWindow.height - edgeThreshold - 30
        
        // Logger.shared.log(content: "l \(leftEdge), r \(rightEdge), b \(bottomEdge), t \(topEdge)")
        if (mouseLocation.x < rightEdge) && (mouseLocation.x > leftEdge) && (mouseLocation.y < topEdge) && (mouseLocation.y > bottomEdge) {
            if UserSettings.shared.isAbsoluteModeMouseHide || isRelative {
                if AppStatus.isCursorHidden == false{
                    NSCursor.hide()
                    AppStatus.isCursorHidden = true
                }
            }
            eventHandler = NSEvent.addLocalMonitorForEvents(matching:[
                .leftMouseDown,
                .leftMouseUp,
                .leftMouseDragged,
                .mouseMoved,
                .rightMouseDown,
                .rightMouseUp,
                .rightMouseDragged,
                .otherMouseDown,
                .otherMouseUp,
                .otherMouseDragged] ) { (event) -> NSEvent? in
                    if isRelative { // Lock the mouse in center
                        if let window = NSApplication.shared.mainWindow {
                            let pointInWindow = NSPoint(x: window.frame.width * 0.5, y: window.frame.height * 0.5)
                            let pointOnScreen = window.convertPoint(toScreen: pointInWindow)
                            let flippedY = NSHeight(NSScreen.main!.frame) - pointOnScreen.y
                            let cgPoint = CGPoint(x: pointOnScreen.x, y: flippedY)
                            CGWarpMouseCursorPosition(cgPoint)
                        }
                    }
                    return event
                }
            
            if isKeyboardEvent(type:type) {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                
                if Logger.shared.KeyboardPrint { Logger.shared.log(content: "Key code: \(keyCode)") }
            } else if isMouseEvent(type:type) {
                let location = event.location
                let deltaX = event.getDoubleValueField(.mouseEventDeltaX)
                let deltaY = event.getDoubleValueField(.mouseEventDeltaY)
                let scrollWheelEventDeltaAxis1 = scrollWheelEventDeltaMapping(delta: event.getDoubleValueField(.scrollWheelEventDeltaAxis1))
                var dragged:Bool = false
                
                switch event.type {
                    
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    if Logger.shared.MouseEventPrint {   Logger.shared.log(content: "Mouse down at location: \(location), delta: (\(deltaX), \(deltaY)), type: \(event.type.rawValue), flags: \(event.flags.rawValue)") }
                case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                    if Logger.shared.MouseEventPrint {   Logger.shared.log(content: "Mouse up at location: \(location), delta: (\(deltaX), \(deltaY)), type: \(event.type.rawValue), flags: \(event.flags.rawValue)")}
                case .scrollWheel:
                    if Logger.shared.MouseEventPrint {   Logger.shared.log(content: "Scroll wheel with delta: \(scrollWheelEventDeltaAxis1), type: \(event.type.rawValue)")}
                case .leftMouseDragged, .rightMouseDragged:
                    if Logger.shared.MouseEventPrint {  Logger.shared.log(content: "Mouse dragged at location: \(location), type: \(event.type.rawValue)") }
                    dragged = true
                case .mouseMoved:
                    if deltaX == 0 && deltaY == 0 {
                        return
                    }
                    if Logger.shared.MouseEventPrint { Logger.shared.log(content: "Mouse moved at location: \(location), delta: (\(deltaX), \(deltaY)), type: \(event.type.rawValue)") }
                default:
                    if Logger.shared.MouseEventPrint { Logger.shared.log(content: "Unhandled mouse event: \(event.type.rawValue)")}
                    break
                }

                if isRelative {
                    mm.handleRelativeMouseAction(dx: Int(deltaX),
                                                 dy: Int(deltaY),
                                                 mouseEvent: mouseKeyMapper(hidMouseEventType: event.type),
                                                 wheelMovement:scrollWheelEventDeltaAxis1,
                                                 dragged: dragged)
                } else {
                    let leftPadding = Int((AppStatus.currentWindow.width - AppStatus.currentView.width) / 2)
                    let bottomPadding = Int((AppStatus.currentWindow.height - AppStatus.currentView.height - 30) / 2)
                    let x = (mouseLocation.x - AppStatus.currentWindow.minX - CGFloat(leftPadding)) * 4096 / AppStatus.currentView.width
                    let y = (AppStatus.currentView.height - (mouseLocation.y - AppStatus.currentWindow.minY - CGFloat(bottomPadding))) * 4096 / AppStatus.currentView.height
                    mm.handleAbsoluteMouseAction(x: Int(x),
                                                 y: Int(y),
                                                 mouseEvent: mouseKeyMapper(hidMouseEventType: event.type),
                                                 wheelMovement: scrollWheelEventDeltaAxis1)
                }

            } else {
                if Logger.shared.MouseEventPrint { Logger.shared.log(content: "Unhandled mouse event: \(event.type.rawValue)")}
            }
        }
    } else {
        if AppStatus.isCursorHidden {
            NSCursor.unhide()
            AppStatus.isCursorHidden = false
        }
    }
}

func scrollWheelEventDeltaMapping(delta:Double) -> UInt8 {
    if Int8(delta) == 0 {
        return 0
    } else if Int8(delta) > 0 {
        return UInt8(delta)
    }
    return 0xFF -  UInt8(abs(Int8(delta))) + 1
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
