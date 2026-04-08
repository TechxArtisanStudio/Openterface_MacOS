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
*    along with this program. If not, see <http://www.gnu.org/licenses/>.   *
*                                                                            *
* ========================================================================== *
*/

import SwiftUI
import AppKit

struct RDPFrameView: NSViewRepresentable {
    func makeNSView(context: Context) -> RDPInteractiveView {
        RDPInteractiveView()
    }

    func updateNSView(_ nsView: RDPInteractiveView, context: Context) {
        nsView.refreshFrame()
    }
}

final class RDPInteractiveView: NSView {
    private let manager = RDPClientManager.shared
    private var frameObserver: Any?
    private var tracking: NSTrackingArea?
    private var pointerFlags: UInt16 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        frameObserver = NotificationCenter.default.addObserver(
            forName: .rdpFrameUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited]
        let tracking = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        AppStatus.isMouseInView = true
        if UserSettings.shared.isAbsoluteModeMouseHide {
            NSCursor.hide()
            AppStatus.isCursorHidden = true
        } else {
            NSCursor.unhide()
            AppStatus.isCursorHidden = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        AppStatus.isMouseInView = false
        NSCursor.unhide()
        AppStatus.isCursorHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        guard let image = manager.currentFrame else {
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.gray,
                .font: NSFont.systemFont(ofSize: 16, weight: .medium)
            ]
            let text = NSString(string: "Waiting for RDP frame...")
            let size = text.size(withAttributes: attributes)
            let rect = CGRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            text.draw(in: rect, withAttributes: attributes)
            return
        }

        let fitRect = imageRect(for: image)
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.interpolationQuality = .none
        ctx?.draw(image, in: fitRect)
    }

    func refreshFrame() {
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointerFlags = 0x1000
        sendPointer(for: event, flags: 0x8000 | pointerFlags)
    }

    override func mouseUp(with event: NSEvent) {
        let releaseFlags = pointerFlags == 0 ? UInt16(0x1000) : pointerFlags
        sendPointer(for: event, flags: releaseFlags)
        pointerFlags = 0
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointerFlags = 0x2000
        sendPointer(for: event, flags: 0x8000 | pointerFlags)
    }

    override func rightMouseUp(with event: NSEvent) {
        let releaseFlags = pointerFlags == 0 ? UInt16(0x2000) : pointerFlags
        sendPointer(for: event, flags: releaseFlags)
        pointerFlags = 0
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointerFlags = 0x4000
        sendPointer(for: event, flags: 0x8000 | pointerFlags)
    }

    override func otherMouseUp(with event: NSEvent) {
        let releaseFlags = pointerFlags == 0 ? UInt16(0x4000) : pointerFlags
        sendPointer(for: event, flags: releaseFlags)
        pointerFlags = 0
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(for: event, flags: 0x0800)
    }

    override func mouseDragged(with event: NSEvent) {
        let dragFlags = pointerFlags == 0 ? UInt16(0x0800) : UInt16(0x0800 | 0x8000 | pointerFlags)
        sendPointer(for: event, flags: dragFlags)
    }

    override func rightMouseDragged(with event: NSEvent) {
        let dragFlags = pointerFlags == 0 ? UInt16(0x0800) : UInt16(0x0800 | 0x8000 | pointerFlags)
        sendPointer(for: event, flags: dragFlags)
    }

    override func otherMouseDragged(with event: NSEvent) {
        let dragFlags = pointerFlags == 0 ? UInt16(0x0800) : UInt16(0x0800 | 0x8000 | pointerFlags)
        sendPointer(for: event, flags: dragFlags)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = framebufferPoint(for: event) else { return }
        let wheelDelta: UInt16 = 0x0078
        let wheelFlags: UInt16 = event.scrollingDeltaY > 0
            ? UInt16(0x0200 | wheelDelta)
            : UInt16(0x0200 | 0x0100 | wheelDelta)
        manager.sendPointerEvent(x: point.x, y: point.y, flags: wheelFlags)
    }

    override func keyDown(with event: NSEvent) {
        manager.handleKeyEvent(event, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        manager.handleKeyEvent(event, isDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        manager.handleFlagsChanged(event)
    }

    private func sendPointer(for event: NSEvent, flags: UInt16) {
        guard let point = framebufferPoint(for: event) else { return }
        manager.sendPointerEvent(x: point.x, y: point.y, flags: flags)
    }

    private func imageRect(for image: CGImage) -> CGRect {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = bounds.width / bounds.height

        if imageAspect > viewAspect {
            let height = bounds.width / imageAspect
            return CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        }

        let width = bounds.height * imageAspect
        return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
    }

    private func framebufferPoint(for event: NSEvent) -> (x: Int, y: Int)? {
        guard let image = manager.currentFrame else { return nil }
        let drawRect = imageRect(for: image)
        let location = convert(event.locationInWindow, from: nil)
        guard drawRect.contains(location) else { return nil }

        let normalizedX = (location.x - drawRect.minX) / drawRect.width
        let normalizedY = 1.0 - ((location.y - drawRect.minY) / drawRect.height)
        let x = min(max(Int(normalizedX * CGFloat(max(image.width - 1, 0))), 0), max(image.width - 1, 0))
        let y = min(max(Int(normalizedY * CGFloat(max(image.height - 1, 0))), 0), max(image.height - 1, 0))
        return (x, y)
    }
}
