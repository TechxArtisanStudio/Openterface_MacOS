//
//  SettingsScreen.swift
//  openterface
//
//  Created by Shawn Ling on 2024/5/15.
//

import SwiftUI

import SwiftUI
import KeyboardShortcuts

struct SettingsScreen: View {
    var body: some View {
        Form{
            KeyboardShortcuts.Recorder("Exit full screen mode", name: .exitFullScreenMode)
        }
        .padding(.horizontal, 50)
        .padding(.vertical, 10)
        Form{
            KeyboardShortcuts.Recorder("Trigger Area OCR", name: .triggerAreaOCR)
        }
        .padding(.horizontal, 50)
        .padding(.vertical, 10)
    }
}

class SettingsScreenWC<RootView : View>: NSWindowController, NSWindowDelegate {
    convenience init(rootView: RootView) {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.makeKey()
        window.orderFrontRegardless()
        window.setContentSize(hostingController.sizeThatFits(in: NSSize(width: 500, height: CGFloat.infinity)))

        self.init(window: window)
        self.window?.delegate = self
    }
}

extension KeyboardShortcuts.Name {
    static let exitRelativeMode = Self("exitRelativeMode")
    static let exitFullScreenMode = Self("exitFullScreenMode")
    static let triggerAreaOCR = Self("triggerAreaOCR")
}
