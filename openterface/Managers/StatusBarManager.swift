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

class StatusBarManager: StatusBarManagerProtocol {
    private var  logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)

    var statusBarItem: NSStatusItem!

    init() {
    }
    
    func initBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: CGFloat(NSStatusItem.variableLength))
        
        if let button = statusBarItem.button {
            button.image = NSImage(systemSymbolName: "gift.circle", accessibilityDescription: "Chart Line")
        } else {
            logger.log(content: "Failed to load icon")
        }
    }
    
    // MARK: - StatusBarManagerProtocol Implementation
    
    func setupStatusBar() {
        initBar()
    }
    
    func updateStatusBar() {
        // Implementation for updating status bar
    }
    
    func removeStatusBar() {
        NSStatusBar.system.removeStatusItem(statusBarItem)
    }
}
