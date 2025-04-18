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
import KeyboardShortcuts

struct SettingsScreen: View {
    var body: some View {
        VStack {
            Form {
                KeyboardShortcuts.Recorder("Exit full screen mode", name: .exitFullScreenMode)
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 10)
            
            Form {
                KeyboardShortcuts.Recorder("Trigger Area OCR", name: .triggerAreaOCR)
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 10)
        }
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

extension Notification.Name {
    static let ocrComplete = Notification.Name("ocrComplete")
}
