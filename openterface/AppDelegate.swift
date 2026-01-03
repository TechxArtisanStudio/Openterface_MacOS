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
import Carbon
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    
    // MARK: - Protocol-based Dependencies
    private var audioManager: any AudioManagerProtocol
    private var statusBarManager: any StatusBarManagerProtocol
    private var hostManager: any HostManagerProtocol
    private var keyboardManager: any KeyboardManagerProtocol
    private var serialPortManager: any SerialPortManagerProtocol
    private var videoManager: any VideoManagerProtocol
    private var hidManager: any HIDManagerProtocol
    private var clipboardManager: any ClipboardManagerProtocol
    private var usbDevicesManager: (any USBDevicesManagerProtocol)?
    private var parallelManager: any ParallelManagerProtocol
    private var logger: any LoggerProtocol
    
    //Use half of the screen width as initial window width
    var initialContentSize: CGSize {
        guard let screen = NSScreen.main else {
            return CGSize(width: 1080, height: 659) // Default fallback
        }
        let halfScreenWidth = screen.frame.width / 2
        _ = hidManager.getPixelClock()
        if let resolution = hidManager.getResolution(),
           resolution.width > 0, resolution.height > 0 {
            let aspectRatioValue = CGFloat(resolution.width) / CGFloat(resolution.height)
            let height = halfScreenWidth / aspectRatioValue
            return CGSize(width: halfScreenWidth, height: height)
        } else {
            return CGSize(width: 1080, height: 659) // Default fallback
        }
    }
    private var isInitialLaunch = true
    
    // MARK: - Initialization
    override init() {
        // Get dependencies from DI container (they should already be setup)
        let container = DependencyContainer.shared
        
        // Resolve dependencies
        self.audioManager = container.resolve(AudioManagerProtocol.self)
        self.statusBarManager = container.resolve(StatusBarManagerProtocol.self)
        self.hostManager = container.resolve(HostManagerProtocol.self)
        self.keyboardManager = container.resolve(KeyboardManagerProtocol.self)
        self.serialPortManager = container.resolve(SerialPortManagerProtocol.self)
        self.videoManager = container.resolve(VideoManagerProtocol.self)
        self.hidManager = container.resolve(HIDManagerProtocol.self)
        self.clipboardManager = container.resolve(ClipboardManagerProtocol.self)
        self.parallelManager = container.resolve(ParallelManagerProtocol.self)
        self.logger = container.resolve(LoggerProtocol.self)
        
        // USB Devices Manager is only available on macOS 12.0+
        if #available(macOS 12.0, *) {
            self.usbDevicesManager = container.resolve(USBDevicesManagerProtocol.self)
        }
        
        super.init()
        // Observe menu-related notifications so AppDelegate can keep the main View menu in sync
        NotificationCenter.default.addObserver(self, selector: #selector(handleParallelModeChanged(_:)), name: Notification.Name("ParallelModeChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handlePlacementChanged(_:)), name: Notification.Name("TargetPlacementChanged"), object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Dependency Setup
    static func setupDependencies(container: DependencyContainer) {
        // Register concrete implementations with their protocols
        container.register(LoggerProtocol.self, instance: Logger.shared as any LoggerProtocol)
        container.register(USBDevicesManagerProtocol.self, instance: USBDevicesManager.shared as any USBDevicesManagerProtocol)
        container.register(HIDManagerProtocol.self, instance: HIDManager.shared as any HIDManagerProtocol)
        container.register(AudioManagerProtocol.self, instance: AudioManager.shared as any AudioManagerProtocol)
        container.register(VideoManagerProtocol.self, instance: VideoManager.shared as any VideoManagerProtocol)
        container.register(MouseManagerProtocol.self, instance: MouseManager.shared as any MouseManagerProtocol)
        container.register(KeyboardManagerProtocol.self, instance: KeyboardManager.shared as any KeyboardManagerProtocol)
        container.register(SerialPortManagerProtocol.self, instance: SerialPortManager.shared as any SerialPortManagerProtocol)
        container.register(SwitchableUSBManagerProtocol.self, instance: SwitchableUSBManager.shared as any SwitchableUSBManagerProtocol)
        container.register(HostManagerProtocol.self, instance: HostManager.shared as any HostManagerProtocol)
        container.register(ParallelManagerProtocol.self, instance: ParallelManager() as any ParallelManagerProtocol)
        container.register(StatusBarManagerProtocol.self, instance: StatusBarManager() as any StatusBarManagerProtocol)
        container.register(TipLayerManagerProtocol.self, instance: TipLayerManager() as any TipLayerManagerProtocol)
        container.register(ClipboardManagerProtocol.self, instance: ClipboardManager.shared as any ClipboardManagerProtocol)
        container.register(FloatingKeyboardManagerProtocol.self, instance: FloatingKeyboardManager() as any FloatingKeyboardManagerProtocol)
        container.register(VideoManagerProtocol.self, instance: VideoManager.shared as any VideoManagerProtocol)
        container.register(CameraManagerProtocol.self, instance: CameraManager.shared as any CameraManagerProtocol)
        container.register(PermissionManagerProtocol.self, instance: PermissionManager.shared as any PermissionManagerProtocol)
        
        // OCR Manager (macOS 12.3+ only)
        if #available(macOS 12.3, *) {
            container.register(OCRManagerProtocol.self, instance: OCRManager.shared as any OCRManagerProtocol)
        }
    
        
        // Register VideoManager after USBDevicesManager to avoid dependency resolution issues
        container.register(VideoManagerProtocol.self, instance: VideoManager.shared as any VideoManagerProtocol)
    }
    
    // MARK: - Computed Properties
    var isDarkMode: Bool {
        if #available(macOS 10.14, *) {
            if NSApp.effectiveAppearance.name == .darkAqua {
                return true
            }
        }
        return false
    }
    
    // MARK: - Application Lifecycle
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.mainMenu?.delegate = self
        
        // Initialize USB device management (macOS 12.0+ only)
        if #available(macOS 12.0, *) {
            usbDevicesManager?.update()
        } else {
            logger.log(content: "USB device management requires macOS 12.0 or later. Current functionality is limited.")
        }

        // Initialize Hardware Abstraction Layer
        initializeHAL()

        // Initialize HID Manager after USB device manager is updated
        _ = hidManager
        
        // Initialize audio settings
        audioManager.initializeAudio()
        
        setupMainWindow()
        setupNotificationObservers()
        // Defer menu setup so SwiftUI has a chance to build its menus first,
        // then merge our custom items into the existing View menu.
        DispatchQueue.main.async {
            self.setupAspectRatioMenu()
        }

        // Setup status bar
        statusBarManager.setupStatusBar()
        
        // Switch to U.S. English input method to ensure paste works correctly
        switchToUSEnglishInputMethod()
        
        // Set a delay to mark initial launch as complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isInitialLaunch = false
        }
    }

    // Remove extra system-provided items from the Edit menu we don't want exposed
    private func removeEditMenuExtras() {
        func doRemove() {
            guard let mainMenu = NSApp.mainMenu,
                  let editMenuItem = mainMenu.items.first(where: { $0.title == "Edit" }) else { return }
            guard let editMenu = editMenuItem.submenu else { return }

            // Collect indices to remove (avoid mutating while iterating)
            var indicesToRemove: [Int] = []
            for (index, item) in editMenu.items.enumerated() {
                let title = item.title.lowercased()
                var shouldRemove = false

                // Title-based checks (covers many locales that include these words)
                if title.contains("dictation") || title.contains("emoji") || title.contains("emoj") || title.contains("symbols") {
                    shouldRemove = true
                }

                // Action-based checks for known system selectors
                if !shouldRemove, let action = item.action {
                    let actionName = String(describing: action).lowercased()
                    if actionName.contains("orderfrontcharacterpalette") || actionName.contains("startdictation") || actionName.contains("toggleemojipanel") || actionName.contains("showemoji") {
                        shouldRemove = true
                    }
                }

                if shouldRemove {
                    indicesToRemove.append(index)
                }
            }

            // Remove items in reverse order so indices remain valid
            for index in indicesToRemove.sorted(by: >) {
                editMenu.removeItem(at: index)
            }

            // Also remove any adjacent separators left behind
            for i in (0..<editMenu.items.count).reversed() {
                if editMenu.items[i].isSeparatorItem {
                    // If separator at start or end remove it
                    if i == 0 || i == editMenu.items.count - 1 {
                        editMenu.removeItem(at: i)
                    } else {
                        // If two separators in a row, remove the duplicate
                        if editMenu.items[i - 1].isSeparatorItem {
                            editMenu.removeItem(at: i)
                        }
                    }
                }
            }
        }

        // Attempt removal now and again after a short delay because the system may modify menus after launch
        doRemove()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            doRemove()
        }
    }
    
    // MARK: - Hardware Abstraction Layer
    private func initializeHAL() {
        logger.log(content: "Initializing Hardware Abstraction Layer...")
        
        let halIntegration = HALIntegrationManager.shared
        
        if halIntegration.initializeHALIntegration() {
            // Integrate HAL with existing managers
            halIntegration.integrateWithVideoManager()
            halIntegration.integrateWithHIDManager()
            halIntegration.integrateWithSerialPortManager()
            
            // Log HAL status
            let halStatus = halIntegration.getHALStatus()
            if logger.HalPrint {
                logger.log(content: "HAL Status: \(halStatus.description)")
            }
            
            logger.log(content: "✅ Hardware Abstraction Layer initialized successfully")
        } else {
            logger.log(content: "⚠️ Hardware Abstraction Layer initialization failed - falling back to legacy mode")
        }
    }
    
    private func deinitializeHAL() {
        logger.log(content: "🔄 Deinitializing Hardware Abstraction Layer...")
        
        let halIntegration = HALIntegrationManager.shared
        halIntegration.deinitializeHALIntegration()
        
        logger.log(content: "✅ Hardware Abstraction Layer deinitialized successfully")
    }
    
    // MARK: - Setup Methods
    private func setupMainWindow() {
        NSApplication.shared.windows.forEach { window in
            if let windownName = window.identifier?.rawValue {
                if windownName.contains(UserSettings.shared.mainWindownName) {
                    window.delegate = self
                    window.backgroundColor = NSColor.black
                    
                    // Allow window resizing but maintain aspect ratio
                    window.styleMask.insert(.resizable)

                    let toolbarHeight = window.frame.height - window.contentLayoutRect.height
                    let fullInitialSize = NSSize(width: initialContentSize.width, height: initialContentSize.height + toolbarHeight)
                    let initialFrame = NSRect(x: 0, y: 0, width: fullInitialSize.width, height: fullInitialSize.height)

                    logger.log(content: "InitialContentSize: \(initialContentSize), fullInitialSize: \(fullInitialSize), initialContentSize with toolbar: \(initialFrame.size)")
                    window.setFrame(initialFrame, display: false)
                    
                    // // Set minimum size to prevent too small windows
                    // window.minSize = NSSize(width: aspectRatio.width / 2, height: aspectRatio.height / 2)
                    // // Set maximum size to something reasonable (2x initial size)
                    // window.maxSize = NSSize(width: aspectRatio.width * 2, height: aspectRatio.height * 2)
                    window.center()
                    
                    // Apply always on top setting if enabled
                    WindowUtils.shared.setAlwaysOnTop(UserSettings.shared.isAlwaysOnTop)
                }
            }
        }

        // Disable window tabbing feature
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    private func setupNotificationObservers() {
        // Register for HID resolution change notifications
        
        // Listen for window size update notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowSizeUpdateRequest(_:)),
            name: Notification.Name.updateWindowSize,
            object: nil
        )
        
        // Listen for firmware update notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStopAllOperationsBeforeFirmwareUpdate(_:)),
            name: NSNotification.Name("StopAllOperationsBeforeFirmwareUpdate"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWriteFirmwareToEEPROM(_:)),
            name: NSNotification.Name("WriteFirmwareToEEPROM"),
            object: nil
        )
        
        // Listen for firmware update completion notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReopenContentViewAfterFirmwareUpdate(_:)),
            name: NSNotification.Name("ReopenContentViewAfterFirmwareUpdate"),
            object: nil
        )
        
        // Listen for video ready notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoReady(_:)),
            name: NSNotification.Name("StartVideoSession"),
            object: nil
        )
    }
    
    // MARK: - NSWindowDelegate: Window Focus Management
    /// Called when the window gains focus
    func windowDidBecomeKey(_ notification: Notification) {
        // Resume HID mouse capture if in relative HID mode and window gets focus
        if UserSettings.shared.MouseControl == .relativeHID {
            let mouseManager = MouseManager.shared
            if !mouseManager.isHIDMouseModeActive() {
                mouseManager.startHIDMouseMonitoring()
                logger.log(content: "Window gained focus: Resumed HID mouse monitoring")
            }
        }
    }
    
    /// Called when the window loses focus
    func windowDidResignKey(_ notification: Notification) {
        // Release HID mouse capture when window loses focus in relative HID mode
        if UserSettings.shared.MouseControl == .relativeHID {
            let mouseManager = MouseManager.shared
            if mouseManager.isHIDMouseModeActive() {
                mouseManager.stopHIDMouseMonitoring()
                logger.log(content: "Window lost focus: Stopped HID mouse monitoring")
            }
        }
    }
    
    // Show aspect ratio selection menu
    func showAspectRatioSelection() {
        WindowUtils.shared.showAspectRatioSelector { shouldUpdateWindow in
            if shouldUpdateWindow {
                // Update window size
                if let window = NSApplication.shared.mainWindow {
                    self.updateWindowSize(window: window)
                }
            }
        }
    }
    
    // Select auto detect aspect ratio
    @objc func selectAutoDetectAspectRatio(_ sender: NSMenuItem) {
        // Close user custom aspect ratio
        UserSettings.shared.useCustomAspectRatio = false
        
        // Update menu items status
        updateAspectRatioMenuItems()
        
        // Update window size
        if let window = NSApplication.shared.mainWindow {
            updateWindowSize(window: window)
        }
    }
    
    // Toggle input overlay visibility
    @objc func toggleInputOverlay(_ sender: NSMenuItem) {
        AppStatus.showInputOverlay.toggle()
        sender.state = AppStatus.showInputOverlay ? .on : .off
    }
    
    // Select custom aspect ratio
    @objc func selectAspectRatio(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? AspectRatioOption else { return }
        
        // Save user selection
        UserSettings.shared.customAspectRatio = option
        UserSettings.shared.useCustomAspectRatio = true
        
        // Update menu items status
        updateAspectRatioMenuItems()
        
        // Update window size
        if let window = NSApplication.shared.mainWindow {
            updateWindowSize(window: window)
        }
    }
    
    // Update aspect ratio menu items status
    func updateAspectRatioMenuItems() {
        guard let mainMenu = NSApp.mainMenu,
              let viewMenuItem = mainMenu.items.first(where: { $0.title == "View" || $0.title == "View" }),
              let viewMenu = viewMenuItem.submenu,
              let aspectRatioMenuItem = viewMenu.items.first(where: { $0.title == "Screen Ratio" }),
              let aspectRatioMenu = aspectRatioMenuItem.submenu else { return }
        
        // Update "Auto Detect" option
        if let autoDetectItem = aspectRatioMenu.items.first(where: { $0.title == "Auto Detect" }) {
            autoDetectItem.state = UserSettings.shared.useCustomAspectRatio ? .off : .on
        }
        
        // Update all preset aspect ratio options
        for item in aspectRatioMenu.items {
            if let option = item.representedObject as? AspectRatioOption {
                item.state = (UserSettings.shared.useCustomAspectRatio && UserSettings.shared.customAspectRatio == option) ? .on : .off
            }
        }
    }
    
    
    // Setup aspect ratio selection menu
    func setupAspectRatioMenu() {
        // Get the main menu of the application
        guard let mainMenu = NSApp.mainMenu else { return }
        
        // Find or create the "View" menu
        var viewMenuItem = mainMenu.items.first { $0.title == "View" }
        var viewMenu: NSMenu
        
        if let existingViewMenuItem = viewMenuItem {
            // Use existing View menu
            if let existingMenu = existingViewMenuItem.submenu {
                viewMenu = existingMenu
            } else {
                viewMenu = NSMenu(title: "View")
                existingViewMenuItem.submenu = viewMenu
            }
        } else {
            // Create a new View menu
            viewMenu = NSMenu(title: "View")
            let newViewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            newViewMenuItem.submenu = viewMenu
            
            // Find a suitable position to insert the new menu (usually after "File" and "Edit")
            if let editMenuIndex = mainMenu.items.firstIndex(where: { $0.title == "Edit" }) {
                mainMenu.insertItem(newViewMenuItem, at: editMenuIndex + 1)
            } else {
                mainMenu.addItem(newViewMenuItem)
            }
        }
    }

    // MARK: - View menu handlers (Parallel Mode + Target Placement)

    @objc func toggleParallelModeMenu(_ sender: NSMenuItem) {
        parallelManager.toggleParallelMode()
        // Update menu title immediately
        updateParallelMenuItemTitle()
        NotificationCenter.default.post(name: Notification.Name("ParallelModeChanged"), object: nil)
    }

    @objc func setTargetPlacementLeftMenu(_ sender: NSMenuItem) {
        UserSettings.shared.targetComputerPlacement = .left
        updatePlacementMenuItems()
        NotificationCenter.default.post(name: Notification.Name("TargetPlacementChanged"), object: nil)
    }

    @objc func setTargetPlacementRightMenu(_ sender: NSMenuItem) {
        UserSettings.shared.targetComputerPlacement = .right
        updatePlacementMenuItems()
        NotificationCenter.default.post(name: Notification.Name("TargetPlacementChanged"), object: nil)
    }

    @objc func setTargetPlacementTopMenu(_ sender: NSMenuItem) {
        UserSettings.shared.targetComputerPlacement = .top
        updatePlacementMenuItems()
        NotificationCenter.default.post(name: Notification.Name("TargetPlacementChanged"), object: nil)
    }

    @objc func setTargetPlacementBottomMenu(_ sender: NSMenuItem) {
        UserSettings.shared.targetComputerPlacement = .bottom
        updatePlacementMenuItems()
        NotificationCenter.default.post(name: Notification.Name("TargetPlacementChanged"), object: nil)
    }

    private func updatePlacementMenuItems() {
        guard let mainMenu = NSApp.mainMenu,
              let viewMenuItem = mainMenu.items.first(where: { $0.title == "View" }),
              let viewMenu = viewMenuItem.submenu,
              let placementMenuItem = viewMenu.items.first(where: { $0.title == "Target Screen Placement" }),
              let placementMenu = placementMenuItem.submenu else { return }

        for item in placementMenu.items {
            switch item.action {
            case #selector(setTargetPlacementLeftMenu(_:)):
                item.state = UserSettings.shared.targetComputerPlacement == .left ? .on : .off
            case #selector(setTargetPlacementRightMenu(_:)):
                item.state = UserSettings.shared.targetComputerPlacement == .right ? .on : .off
            case #selector(setTargetPlacementTopMenu(_:)):
                item.state = UserSettings.shared.targetComputerPlacement == .top ? .on : .off
            case #selector(setTargetPlacementBottomMenu(_:)):
                item.state = UserSettings.shared.targetComputerPlacement == .bottom ? .on : .off
            default:
                break
            }
        }
    }

    private func updateParallelMenuItemTitle() {
        guard let mainMenu = NSApp.mainMenu,
              let viewMenuItem = mainMenu.items.first(where: { $0.title == "View" }),
              let viewMenu = viewMenuItem.submenu else { return }

        if let item = viewMenu.items.first(where: { $0.action == #selector(toggleParallelModeMenu(_:)) }) {
            item.title = parallelManager.isParallelModeEnabled ? "Exit Parallel Mode" : "Enter Parallel Mode"
        }
    }

    @objc private func handleParallelModeChanged(_ notification: Notification) {
        updateParallelMenuItemTitle()
    }

    @objc private func handlePlacementChanged(_ notification: Notification) {
        updatePlacementMenuItems()
    }
    
    // Update window size
    func updateWindowSize(window: NSWindow) {
        // Get screen size
        guard let screen = window.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        
        // Calculate new window size
        let targetSize = NSSize(
            width: screenFrame.width * 0.6,
            height: screenFrame.height * 0.6
        )
        
        // Calculate appropriate size
        let newSize = WindowUtils.shared.calculateConstrainedWindowSize(for: window, targetSize: targetSize, initialContentSize: self.initialContentSize)
        
        // Calculate center position
        let newX = screenFrame.origin.x + (screenFrame.width - newSize.width) / 2
        let newY = screenFrame.origin.y + (screenFrame.height - newSize.height) / 2
        
        // Set window size and position
        let newFrame = NSRect(
            x: newX,
            y: newY,
            width: newSize.width,
            height: newSize.height
        )
        
        window.setFrame(newFrame, display: true, animate: true)
    }
    
    func windowDidResize(_ notification: Notification) {
        if let window = NSApplication.shared.mainWindow {
            if let toolbar = window.toolbar, toolbar.isVisible {
                let windowHeight = window.frame.height
                let contentLayoutRect = window.contentLayoutRect
                _ = windowHeight - contentLayoutRect.height
                AppStatus.currentView = contentLayoutRect
                AppStatus.currentWindow = window.frame
            }
        }
//        handleToolbarAutoHide()
    }

    func windowWillResize(_ sender: NSWindow, to targetFrameSize: NSSize) -> NSSize {
        return WindowUtils.shared.calculateConstrainedWindowSize(for: sender, targetSize: targetFrameSize, initialContentSize: self.initialContentSize)
    }

    func windowWillStartLiveResize(_ notification: Notification) {

    }

    func windowDidEndLiveResize(_ notification: Notification) {
//        handleToolbarAutoHide()
    }

    // Handle window moving between screens
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen else { return }
        
        let screenFrame = screen.visibleFrame
        let currentFrame = window.frame
        
        // Calculate the current aspect ratio of the window
        let currentAspectRatio = currentFrame.width / currentFrame.height
        let targetAspectRatio = initialContentSize.width / initialContentSize.height
        
        // Check if aspect ratio is significantly different (allowing for small floating point differences)
        if abs(currentAspectRatio - targetAspectRatio) > 0.01 {
            // Create a target size based on 90% of the screen's maximum size
            let targetSize = NSSize(
                width: screenFrame.width * 0.9,
                height: screenFrame.height * 0.9
            )
            
            // Use calculateConstrainedWindowSize function to calculate new size
            let newSize = WindowUtils.shared.calculateConstrainedWindowSize(for: window, targetSize: targetSize, initialContentSize: self.initialContentSize)
            
            // Ensure the new size is not smaller than minimum allowed
            let finalSize = NSSize(
                width: max(newSize.width, window.minSize.width),
                height: max(newSize.height, window.minSize.height)
            )
            
            // Calculate center position on new screen
            let newX = screenFrame.origin.x + (screenFrame.width - finalSize.width) / 2
            let newY = screenFrame.origin.y + (screenFrame.height - finalSize.height) / 2
            
            let newFrame = NSRect(
                x: newX,
                y: newY,
                width: finalSize.width,
                height: finalSize.height
            )
            
            window.setFrame(newFrame, display: true, animate: true)
        }
    }

    // click on window close button to exit the programme
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't terminate if we're in parallel mode or exiting parallel mode
        if parallelManager.shouldPreventTermination() {
            return false
        }
        return true
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop audio operations
        audioManager.stopAudioSession()
        
        // Deinitialize Hardware Abstraction Layer
        deinitializeHAL()
        return .terminateNow
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        
    }
    
    func applicationWillUpdate(_ notification: Notification) {
        // Remove unwanted system items from Edit menu (e.g., Dictation, Emoji)
        removeEditMenuExtras()
    }
    
    // Add window zoom control
    func windowShouldZoom(_ sender: NSWindow, toFrame newFrame: NSRect) -> Bool {
        // Get current window frame
        let currentFrame = sender.frame
        
        // Get the screen containing the window, if none then return false
        guard let screen = sender.screen ?? NSScreen.main else { return false }
        
        // Get the visible area of the screen
        let screenFrame = screen.visibleFrame
        
        // Get the height of the toolbar (if visible)
        let toolbarHeight: CGFloat = (sender.toolbar?.isVisible == true) ? sender.frame.height - sender.contentLayoutRect.height : 0
        
        // If the window is in normal size, then zoom to max
        if currentFrame.size.width <= initialContentSize.width {
            // Calculate the maximum possible size
            let maxWidth = screenFrame.width
            let maxHeight = screenFrame.height
            
            // Create a target size, representing the maximized state
            let targetSize = NSSize(width: maxWidth, height: maxHeight)
            
            // Use calculateConstrainedWindowSize to maintain the aspect ratio
            let maxSize = WindowUtils.shared.calculateConstrainedWindowSize(for: sender, targetSize: targetSize, initialContentSize: self.initialContentSize)
            
            // Calculate center position
            let newX = screenFrame.origin.x + (screenFrame.width - maxSize.width) / 2
            let newY = screenFrame.origin.y + (screenFrame.height - maxSize.height) / 2
            
            // Set the maximum frame of the window
            let maxFrame = NSRect(
                x: newX,
                y: newY,
                width: maxSize.width,
                height: maxSize.height
            )
            sender.setFrame(maxFrame, display: true, animate: true)
        } else {
            // Return to normal size
            let normalSize: NSSize
            if AppStatus.hidReadResolusion.width > 0 && AppStatus.hidReadResolusion.height > 0 {
                // Calculate normal size based on HID resolution
                let baseWidth = CGFloat(AppStatus.hidReadResolusion.width) / 2
                let baseHeight = CGFloat(AppStatus.hidReadResolusion.height) / 2 + toolbarHeight
                normalSize = NSSize(width: baseWidth, height: baseHeight)
            } else {
                // Use default aspect ratio
                normalSize = NSSize(
                    width: initialContentSize.width,
                    height: initialContentSize.height + toolbarHeight
                )
            }
            
            // Calculate center position
            let newX = screenFrame.origin.x + (screenFrame.width - normalSize.width) / 2
            let newY = screenFrame.origin.y + (screenFrame.height - normalSize.height) / 2
            
            // Set the normal frame of the window
            let normalFrame = NSRect(
                x: newX,
                y: newY,
                width: normalSize.width,
                height: normalSize.height
            )
            sender.setFrame(normalFrame, display: true, animate: true)
        }
        
        // Return false to indicate not to use default zoom behavior
        return false
    }
    
    // Handle window size update request
    @objc func handleWindowSizeUpdateRequest(_ notification: Notification) {
        if let window = NSApplication.shared.mainWindow {
            updateWindowSize(window: window)
        }
    }
    
    // Handle video ready notification
    @objc func handleVideoReady(_ notification: Notification) {
        if let window = NSApplication.shared.mainWindow {
            updateWindowSize(window: window)
        }
    }
    
    // Show HID resolution change alert settings
    @objc func showHidResolutionAlertSettings(_ sender: NSMenuItem) {
        WindowUtils.shared.showHidResolutionAlertSettings()
    }
    
    // MARK: - Firmware Update Notification Handlers
    
    /// Handles stopping all operations before firmware update
    @objc func handleStopAllOperationsBeforeFirmwareUpdate(_ notification: Notification) {
        logger.log(content: "Stopping all operations for firmware update...")
        
        // Stop serial port connections
        serialPortManager.closeSerialPort()
        
        // Stop audio operations  
        audioManager.stopAudioSession()

        // Stop repeating HID operations but keep HID connection open for firmware update
        hidManager.stopAllHIDOperations()

        // Stop video session by posting notification for PlayerViewModel to handle
        logger.log(content: "Posting StopVideoSession notification for firmware update")
        NotificationCenter.default.post(name: NSNotification.Name("StopVideoSession"), object: nil)
        logger.log(content: "Video session stop requested for firmware update")

        // Note: Keep the main window open during firmware update
        // The firmware update dialog runs in its own separate window
        logger.log(content: "Main window remains open during firmware update")

        logger.log(content: "All operations stopped for firmware update")
    }
    
    /// Handles firmware write to EEPROM request
    @objc func handleWriteFirmwareToEEPROM(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let firmwareData = userInfo["firmwareData"] as? Data,
              let continuation = userInfo["continuation"] else {
            logger.log(content: "Invalid firmware write request")
            return
        }
        
        logger.log(content: "Writing firmware to EEPROM...")
        
        // Use HIDManager to write firmware
        DispatchQueue.global(qos: .userInitiated).async {
            let success = self.hidManager.writeEeprom(address: 0x0000, data: firmwareData)
            
            DispatchQueue.main.async {
                if let cont = continuation as? CheckedContinuation<Bool, Never> {
                    cont.resume(returning: success)
                }
            }
        }
    }
    
    /// Handles reopening ContentView window after firmware update completion
    @objc func handleReopenContentViewAfterFirmwareUpdate(_ notification: Notification) {
        logger.log(content: "Restarting operations after firmware update...")
        
        // Restart HID operations first
        hidManager.restartHIDOperations()
        
        // Restart video session by posting notification for PlayerViewModel to handle
        logger.log(content: "Posting StartVideoSession notification after firmware update")
        NotificationCenter.default.post(name: NSNotification.Name("StartVideoSession"), object: nil)
        logger.log(content: "Video session restart requested after firmware update")
        
        // Since we kept the main window open, just log the completion
        // The main window should still be visible and functional
        logger.log(content: "Firmware update completed, operations restarted")
    }
    
    // MARK: - Auto-hide Toolbar Logic
    private var mouseMonitor: Any?
    private var isToolbarHiddenForMaximize = false
    private let toolbarRevealArea: CGFloat = 4 // px from top edge
    private var toolbarAutoHideTimer: Timer?

    private func handleToolbarAutoHide() {
        guard let window = NSApplication.shared.mainWindow else { return }
        let isZoomed = window.zoomedOrFullScreen
        if isZoomed {
            if !isToolbarHiddenForMaximize {
                window.toolbar?.isVisible = false
                isToolbarHiddenForMaximize = true
                startMouseMonitor(for: window)
            }
        } else {
            if isToolbarHiddenForMaximize {
                window.toolbar?.isVisible = true
                isToolbarHiddenForMaximize = false
                stopMouseMonitor()
            }
        }
    }

    private func startMouseMonitor(for window: NSWindow) {
        stopMouseMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self = self else { return event }
            let mouseLocation = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            if mouseLocation.y >= window.frame.height - toolbarRevealArea {
                window.toolbar?.isVisible = true
                self.resetToolbarAutoHideTimer(for: window)
            } else if isToolbarHiddenForMaximize {
                // Only hide if timer is not running (i.e., not in the 10s grace period)
                if self.toolbarAutoHideTimer == nil {
                    window.toolbar?.isVisible = false
                }
            }
            return event
        }
    }

    private func resetToolbarAutoHideTimer(for window: NSWindow) {
        toolbarAutoHideTimer?.invalidate()
        toolbarAutoHideTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self, weak window] _ in
            guard let self = self, let window = window else { return }
            if self.isToolbarHiddenForMaximize {
                window.toolbar?.isVisible = false
            }
            self.toolbarAutoHideTimer = nil
        }
    }

    private func stopMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        toolbarAutoHideTimer?.invalidate()
        toolbarAutoHideTimer = nil
    }
    
    // Switch to U.S. English input method to ensure paste works correctly
    private func switchToUSEnglishInputMethod() {
        let ptr = TISCreateInputSourceList(nil, false)
        // Debug: print the current input source for traceability
        if let currentPtr = TISCopyCurrentKeyboardInputSource() {
            let currentInput = currentPtr.takeRetainedValue()
            var currentId: String = "unknown"
            var currentName: String = "unknown"
            if let idProp = TISGetInputSourceProperty(currentInput, kTISPropertyInputSourceID) {
                currentId = Unmanaged<CFString>.fromOpaque(idProp).takeUnretainedValue() as String
            }
            if let nameProp = TISGetInputSourceProperty(currentInput, kTISPropertyLocalizedName) {
                currentName = Unmanaged<CFString>.fromOpaque(nameProp).takeUnretainedValue() as String
            }
            logger.log(content: "🔤 Current keyboard input source: \(currentName) (\(currentId))")
        } else {
            logger.log(content: "🔤 Current keyboard input source: (none)")
        }
        if let ptr = ptr {
            // TISCreateInputSourceList returns an Unmanaged<CFArray>; use takeRetainedValue() to obtain the CFArray
            let array = ptr.takeRetainedValue()
            let count = CFArrayGetCount(array)

            // Build language search order based on user's preferred languages.
            let preferredLangs = Locale.preferredLanguages
            var languageSearchOrder: [String] = []
            if let first = preferredLangs.first {
                let components = first.split(separator: "-")
                if components.count > 0 {
                    let base = String(components[0])
                    if base == "zh" {
                        // Detect script or region for Traditional vs Simplified
                        if components.count > 1 {
                            let comp1 = String(components[1]).lowercased()
                            if comp1.contains("hant") { languageSearchOrder.append("zh-Hant") }
                            else if comp1.contains("hans") { languageSearchOrder.append("zh-Hans") }
                            else if components.count > 2 {
                                let region = String(components[2]).uppercased()
                                if region == "TW" || region == "HK" { languageSearchOrder.append("zh-Hant") }
                                else { languageSearchOrder.append("zh-Hans") }
                            } else { languageSearchOrder.append("zh-Hans") }
                        } else { languageSearchOrder.append("zh-Hans") }
                    } else {
                        languageSearchOrder.append(base)
                    }
                }
            }
            // Append English as a fallback
            languageSearchOrder.append("en")

            // Helper: find a preferred input source ID matching language codes
            func findPreferredInputID() -> String? {
                for i in 0..<count {
                    let src = unsafeBitCast(CFArrayGetValueAtIndex(array, i), to: TISInputSource.self)
                    // category must be keyboard
                    if let categoryProp = TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory) {
                        let category = Unmanaged<CFString>.fromOpaque(categoryProp).takeUnretainedValue() as String
                        if category != (kTISCategoryKeyboardInputSource as String) { continue }
                    }
                    if let langsProp = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) {
                        let langsArr = Unmanaged<CFArray>.fromOpaque(langsProp).takeUnretainedValue()
                        let langsCount = CFArrayGetCount(langsArr)
                        for j in 0..<langsCount {
                            if let langPtr = CFArrayGetValueAtIndex(langsArr, j) {
                                let code = Unmanaged<CFString>.fromOpaque(langPtr).takeUnretainedValue() as String
                                for target in languageSearchOrder {
                                    if code.lowercased().starts(with: target.lowercased()) || target.lowercased().starts(with: code.lowercased()) {
                                        if let idProp = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                                            let id = Unmanaged<CFString>.fromOpaque(idProp).takeUnretainedValue() as String
                                            // ensure select-capable
                                            if let selectableProp = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable) {
                                                let selectable = Unmanaged<CFBoolean>.fromOpaque(selectableProp).takeUnretainedValue() as! Bool
                                                if selectable { return id }
                                            } else {
                                                return id
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                return nil
            }

            let preferredID = findPreferredInputID()
            logger.log(content: "🔤 languageSearchOrder: \(languageSearchOrder), preferredInputID: \(preferredID ?? "(none)")")

            for i in 0..<count {
                let inputSource = unsafeBitCast(CFArrayGetValueAtIndex(array, i), to: TISInputSource.self)
                if let property = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) {
                    let id = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
                    // If we found a preferred ID, try to use it, otherwise fall back to US layout (ABC)
                    if let pref = preferredID, id == pref {
                        // Only actually select/notify if current input method is different
                        var shouldSelect = true
                        if let currentPtr = TISCopyCurrentKeyboardInputSource() {
                            let currentInputSource = currentPtr.takeRetainedValue()
                            if let curProp = TISGetInputSourceProperty(currentInputSource, kTISPropertyInputSourceID) {
                                let curId = Unmanaged<CFString>.fromOpaque(curProp).takeUnretainedValue() as String
                                shouldSelect = curId != id
                            }
                        }
                        if shouldSelect {
                            logger.log(content: "🔤 Changing input source to preferred layout (id=\(id))")
                            TISSelectInputSource(inputSource)
                            // Notify user that input method has been switched
                            let localizedName: String
                            if let nameProperty = TISGetInputSourceProperty(inputSource, kTISPropertyLocalizedName) {
                                localizedName = Unmanaged<CFString>.fromOpaque(nameProperty).takeUnretainedValue() as String
                            } else {
                                localizedName = id
                            }
                            notifyUserInputSourceSwitched(to: localizedName)
                        } else {
                            // Debug: input source is already preferred
                            logger.log(content: "🔤 Input source is already preferred (id=\(id)); no change needed")
                        }
                        break
                    }
                    else if id == "com.apple.keylayout.ABC" {
                        // Fallback to selecting ABC (US) layout if no preferred found
                        var shouldSelect = true
                        if let currentPtr = TISCopyCurrentKeyboardInputSource() {
                            let currentInputSource = currentPtr.takeRetainedValue()
                            if let curProp = TISGetInputSourceProperty(currentInputSource, kTISPropertyInputSourceID) {
                                let curId = Unmanaged<CFString>.fromOpaque(curProp).takeUnretainedValue() as String
                                shouldSelect = curId != id
                            }
                        }
                        if shouldSelect {
                            logger.log(content: "🔤 Changing input source to US layout (id=\(id))")
                            TISSelectInputSource(inputSource)
                            // Notify user that input method has been switched
                            let localizedName: String
                            if let nameProperty = TISGetInputSourceProperty(inputSource, kTISPropertyLocalizedName) {
                                localizedName = Unmanaged<CFString>.fromOpaque(nameProperty).takeUnretainedValue() as String
                            } else {
                                localizedName = id
                            }
                            notifyUserInputSourceSwitched(to: localizedName)
                        } else {
                            logger.log(content: "🔤 Input source is already US (id=\(id)); no change needed")
                        }
                        break
                    }
                }
            }
        }
    }

    /// Post a local notification (or fallback to logger) to inform user of input source switch
    private func notifyUserInputSourceSwitched(to friendlyName: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            func postNotification() {
                let content = UNMutableNotificationContent()
                content.title = "Input Method Switched"
                content.body = "Input method switched to \(friendlyName)"
                content.sound = UNNotificationSound.default

                // Deliver immediately
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(request) { error in
                    if let error = error {
                        DispatchQueue.main.async {
                            self.logger.log(content: "Failed to post input method notification: \(error.localizedDescription)")
                        }
                    }
                }
            }

            switch settings.authorizationStatus {
            case .authorized:
                postNotification()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if granted { postNotification() }
                    else { DispatchQueue.main.async { self.logger.log(content: "Input method switched to \(friendlyName)") } }
                }
            default:
                DispatchQueue.main.async { self.logger.log(content: "Input method switched to \(friendlyName)") }
            }
        }
    }
}

extension NSWindow {
    var zoomedOrFullScreen: Bool {
//        return self.isZoomed || self.styleMask.contains(.fullScreen)
        return self.isZoomed
    }
}

extension NSColor {
    static func fromHex(_ hex: String) -> NSColor {
        let hexFormatted: String = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        
        var int: UInt64 = 0
        Scanner(string: hexFormatted).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hexFormatted.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        
        return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

