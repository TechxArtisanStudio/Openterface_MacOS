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
import Darwin

class StatusBarManager: NSObject, StatusBarManagerProtocol {
    private var  logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var parallelManager: ParallelManagerProtocol = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)

    var statusBarItem: NSStatusItem!
    private var parallelModeMenuItem: NSMenuItem!
    private var cpuTimer: Timer?
    private var previousCPUTicks: CPUCPUTicks?

    private struct CPUCPUTicks {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64

        var total: UInt64 {
            return user + system + idle + nice
        }
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleParallelModeChanged(_:)), name: Notification.Name("ParallelModeChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handlePlacementChanged(_:)), name: Notification.Name("TargetPlacementChanged"), object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopCPUMonitor()
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

        // Start CPU monitoring after a short delay to ensure all initialization is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startCPUMonitor()
        }
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

    @objc private func handleParallelModeChanged(_ notification: Notification) {
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
        
        // If there is a View menu mirror, nothing extra needed here — the app posts notifications
        // This method updates the status bar submenu states only.
    }

    @objc private func handlePlacementChanged(_ notification: Notification) {
        updatePlacementMenuStates()
    }
    
    // MARK: - StatusBarManagerProtocol Implementation
    
    func setupStatusBar() {
        initBar()
    }
    
    func updateStatusBar() {
        // Implementation for updating status bar
    }
    
    func removeStatusBar() {
        stopCPUMonitor()
        NSStatusBar.system.removeStatusItem(statusBarItem)
    }

    private func getCPUUsage() -> Double {
        var hostInfo: host_cpu_load_info_data_t = host_cpu_load_info_data_t()
        var size: mach_msg_type_number_t = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &hostInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }

        if result != KERN_SUCCESS {
            return -1.0
        }

        let usage = hostInfo
        let totalTicks: UInt64 = (UInt64(usage.cpu_ticks.0) + UInt64(usage.cpu_ticks.1) + UInt64(usage.cpu_ticks.2) + UInt64(usage.cpu_ticks.3))
        let idleTicks = UInt64(usage.cpu_ticks.2)

        if let prevTicks = previousCPUTicks {
            let totalDiff = totalTicks - prevTicks.total
            let idleDiff = idleTicks - prevTicks.idle

            if totalDiff > 0 {
                let usagePercent = 100.0 * (1.0 - Double(idleDiff) / Double(totalDiff))
                previousCPUTicks = CPUCPUTicks(user: UInt64(usage.cpu_ticks.0), system: UInt64(usage.cpu_ticks.1), idle: idleTicks, nice: UInt64(usage.cpu_ticks.3))
                return usagePercent
            }
        } else {
            previousCPUTicks = CPUCPUTicks(user: UInt64(usage.cpu_ticks.0), system: UInt64(usage.cpu_ticks.1), idle: idleTicks, nice: UInt64(usage.cpu_ticks.3))
            return 0.0
        }

        return 0.0
    }

    private func updateCPUDisplay() {
        let usage = getCPUUsage()
        if usage >= 0.0 {
            if let button = statusBarItem.button {
                button.title = String(format: "%.0f%%", usage)
            }
        }
    }

    private func startCPUMonitor() {
        cpuTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateCPUDisplay()
        }
    }

    private func stopCPUMonitor() {
        cpuTimer?.invalidate()
        cpuTimer = nil
    }
}
