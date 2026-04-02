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
import AppKit

struct VNCFrameView: NSViewRepresentable {
    func makeNSView(context: Context) -> VNCInteractiveView {
        VNCInteractiveView()
    }

    func updateNSView(_ nsView: VNCInteractiveView, context: Context) {
        nsView.refreshFrame()
    }
}

final class VNCInteractiveView: NSView {
    private let manager = VNCClientManager.shared
    private var frameObserver: Any?
    private var tracking: NSTrackingArea?
    private var buttonMask: UInt8 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        frameObserver = NotificationCenter.default.addObserver(
            forName: .vncFrameUpdated,
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .activeAlways, .inVisibleRect, .mouseMoved]
        let tracking = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
        window?.acceptsMouseMovedEvents = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        guard let image = manager.currentFrame else {
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.gray,
                .font: NSFont.systemFont(ofSize: 16, weight: .medium)
            ]
            let text = NSString(string: "Waiting for VNC frame...")
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
        buttonMask |= 0x01
        sendPointer(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        buttonMask &= ~UInt8(0x01)
        sendPointer(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonMask |= 0x02
        sendPointer(for: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttonMask &= ~UInt8(0x02)
        sendPointer(for: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonMask |= 0x04
        sendPointer(for: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        buttonMask &= ~UInt8(0x04)
        sendPointer(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(for: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointer(for: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointer(for: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = framebufferPoint(for: event) else { return }
        manager.sendScroll(x: point.x, y: point.y, deltaY: event.scrollingDeltaY, buttonMask: buttonMask)
    }

    private func sendPointer(for event: NSEvent) {
        guard let point = framebufferPoint(for: event) else { return }
        manager.sendPointerEvent(x: point.x, y: point.y, buttonMask: buttonMask)
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
