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

class StatusBarManager: NSObject, StatusBarManagerProtocol {
    private var  logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var parallelManager: ParallelManagerProtocol = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)

    var statusBarItem: NSStatusItem!
    private var parallelModeMenuItem: NSMenuItem!

    override init() {
        super.init()
    }
    
    func initBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: CGFloat(NSStatusItem.variableLength))
        
        if let button = statusBarItem.button {
            if let image = NSImage(named: "Icon") {
                // Resize the image to appropriate size for status bar (18x18 is recommended)
                let resizedImage = NSImage(size: NSSize(width: 18, height: 18))
                resizedImage.lockFocus()
                image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18), from: .zero, operation: .copy, fraction: 1.0)
                resizedImage.unlockFocus()
                button.image = resizedImage
            }
        } else {
            logger.log(content: "Failed to load icon")
        }
        
        // Create menu
        let menu = NSMenu()
        
        // Parallel Mode toggle
        parallelModeMenuItem = NSMenuItem(title: "Enter Parallel Mode", action: #selector(toggleParallelMode), keyEquivalent: "")
        parallelModeMenuItem.target = self
        menu.addItem(parallelModeMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Target Screen Placement submenu
        let placementMenuItem = NSMenuItem(title: "Target Screen Placement", action: nil, keyEquivalent: "")
        let placementSubmenu = NSMenu()
        
        let leftItem = NSMenuItem(title: "Left", action: #selector(setTargetPlacementLeft), keyEquivalent: "")
        leftItem.target = self
        leftItem.state = UserSettings.shared.targetComputerPlacement == .left ? .on : .off
        placementSubmenu.addItem(leftItem)
        
        let rightItem = NSMenuItem(title: "Right", action: #selector(setTargetPlacementRight), keyEquivalent: "")
        rightItem.target = self
        rightItem.state = UserSettings.shared.targetComputerPlacement == .right ? .on : .off
        placementSubmenu.addItem(rightItem)
        
        let topItem = NSMenuItem(title: "Top", action: #selector(setTargetPlacementTop), keyEquivalent: "")
        topItem.target = self
        topItem.state = UserSettings.shared.targetComputerPlacement == .top ? .on : .off
        placementSubmenu.addItem(topItem)
        
        let bottomItem = NSMenuItem(title: "Bottom", action: #selector(setTargetPlacementBottom), keyEquivalent: "")
        bottomItem.target = self
        bottomItem.state = UserSettings.shared.targetComputerPlacement == .bottom ? .on : .off
        placementSubmenu.addItem(bottomItem)
        
        placementMenuItem.submenu = placementSubmenu
        menu.addItem(placementMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let exitItem = NSMenuItem(title: "Exit", action: #selector(exitApp), keyEquivalent: "")
        exitItem.target = self
        menu.addItem(exitItem)
        statusBarItem.menu = menu
    }
    
    @objc func exitApp() {
        NSApp.terminate(nil)
    }
    
    @objc func toggleParallelMode() {
        parallelManager.toggleParallelMode()
        
        // Update menu item title based on current state
        if parallelManager.isParallelModeEnabled {
            parallelModeMenuItem.title = "Exit Parallel Mode"
        } else {
            parallelModeMenuItem.title = "Enter Parallel Mode"
        }
    }
    
    @objc func setTargetPlacementLeft() {
        UserSettings.shared.targetComputerPlacement = .left
        updatePlacementMenuStates()
        logger.log(content: "Target Screen placement set to: Left")
        // TODO: Implement left placement logic
    }
    
    @objc func setTargetPlacementRight() {
        UserSettings.shared.targetComputerPlacement = .right
        updatePlacementMenuStates()
        logger.log(content: "Target Screen placement set to: Right")
        // TODO: Implement right placement logic
    }
    
    @objc func setTargetPlacementTop() {
        UserSettings.shared.targetComputerPlacement = .top
        updatePlacementMenuStates()
        logger.log(content: "Target Screen placement set to: Top")
        // TODO: Implement top placement logic
    }
    
    @objc func setTargetPlacementBottom() {
        UserSettings.shared.targetComputerPlacement = .bottom
        updatePlacementMenuStates()
        logger.log(content: "Target Screen placement set to: Bottom")
        // TODO: Implement bottom placement logic
    }
    
    private func updatePlacementMenuStates() {
        if let menu = statusBarItem?.menu,
           let placementMenuItem = menu.items.first(where: { $0.title == "Target Screen Placement" }),
           let submenu = placementMenuItem.submenu {
            
            for item in submenu.items {
                switch item.action {
                case #selector(setTargetPlacementLeft):
                    item.state = UserSettings.shared.targetComputerPlacement == .left ? .on : .off
                case #selector(setTargetPlacementRight):
                    item.state = UserSettings.shared.targetComputerPlacement == .right ? .on : .off
                case #selector(setTargetPlacementTop):
                    item.state = UserSettings.shared.targetComputerPlacement == .top ? .on : .off
                case #selector(setTargetPlacementBottom):
                    item.state = UserSettings.shared.targetComputerPlacement == .bottom ? .on : .off
                default:
                    break
                }
            }
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
