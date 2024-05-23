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
//        Form {
//            KeyboardShortcuts.Recorder("Exit relative mode:", name: .exitRelativeMode)
//        }
        Form{
            KeyboardShortcuts.Recorder("Exit full screen mode", name: .exitFullScreenMode)
        }
        Form{
            KeyboardShortcuts.Recorder("Exit full screen mode", name: .triggerAreaOCR)
        }
    }
}

class SettingsScreenWC<RootView : View>: NSWindowController, NSWindowDelegate {
    convenience init(rootView: RootView) {
        let hostingController = NSHostingController(rootView: rootView.frame(width: 500, height: 500))
        let window = NSWindow(contentViewController: hostingController)
        window.makeKey()
        window.orderFrontRegardless()
        window.setContentSize(NSSize(width: 500, height: 500))

        self.init(window: window)
        // Set the window's delegate to self to receive close notifications
        self.window?.delegate = self
    }
}

extension KeyboardShortcuts.Name {
    static let exitRelativeMode = Self("exitRelativeMode")
    static let exitFullScreenMode = Self("exitFullScreenMode")
    static let triggerAreaOCR = Self("triggerAreaOCR")
}
