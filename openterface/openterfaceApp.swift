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

@main
struct openterfaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    
    @State private var relativeTitle = "Relative"
    @State private var absoluteTitle = "Absolute ✓"
    @State private var logModeTitle = "No logging ✓"
    @State private var mouseHideTitle = "Auto-hide in Control Mode"
    
    @State private var _isSwitchToggleOn = false
    @State private var _isLockSwitch = true
    
    @State private var  _hasHdmiSignal: Bool?
    @State private var  _isKeyboardConnected: Bool?
    @State private var  _isMouseConnected: Bool?
    @State private var  _isSwitchToHost: Bool?
    
    @State private var showButtons = false
    
    @State private var _resolution = (width: "", height: "")
    @State private var _fps = ""
    @State private var _ms2109version = ""
    
    // 添加串口信息状态变量
    @State private var _serialPortName: String = "N/A"
    @State private var _serialPortBaudRate: Int = 0

    var log = Logger.shared
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    
    var body: some Scene {
        WindowGroup(id: UserSettings.shared.mainWindownName) {
            ZStack(alignment: .top) {
                VStack(alignment: .leading) {
                    HStack(spacing: 20) {
                        Button("F1", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F1 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("F2", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F2 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("F3", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F3 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("F4", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F4 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("F5", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F5 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("F6", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F6 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("F7", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F7 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("F8", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F8 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("F9", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F9 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("F10", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F10 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }.onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("F11", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F11 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("F12", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .F12 )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                        Button("DEL", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .del )
                        })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                    }
                    .buttonStyle(TransparentBackgroundButtonStyle())
                    HStack(spacing: 20) {
                        Button("Ctrl + Alt + Del", action: { KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .CtrlAltDel ) })
                            .buttonStyle(CustomButtonStyle())
                            .onHover { hovering in
                                if hovering {
                                    // Mouse entered
                                    AppStatus.isExit = true
                                } else {
                                    // Mouse exited
                                    AppStatus.isExit = false
                                }
                            }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0))
                .cornerRadius(10)
                .opacity(showButtons ? 1 : 0)
                .offset(y: showButtons ? 20 : -100)
                .animation(.easeInOut(duration: 0.5), value: showButtons)
                .zIndex(100)
                ContentView()
                    .navigationTitle("")
                    .toolbar{
                        ToolbarItemGroup(placement: .navigation) {
                            Text("Openterface Mini-KVM")
                        }
                        ToolbarItem(placement: .automatic) {
                            Button(action: {
                                showButtons.toggle()
                            }) {
                                Image(systemName: showButtons ? "keyboard" : "keyboard.chevron.compact.down.fill")
                            }
                        }
                        ToolbarItem(placement: .automatic) {
                            Image(systemName: "poweron") // spacer
                        }
                        ToolbarItem(placement: .automatic) {
                            Image(systemName: "display")
                                .foregroundColor(colorForConnectionStatus(_hasHdmiSignal))
                        }
                        ToolbarItem(placement: .primaryAction) {
                            ResolutionView(width: _resolution.width, height: _resolution.height, fps: _fps)
                        }
                        ToolbarItem(placement: .automatic) {
                            Button(action: {
                                // Add your code to execute when the button is clicked, e.g., open a window
                                showUSBDevicesWindow()
                            }) {
                                HStack {
                                    Image(systemName: "keyboard.fill")
                                        .resizable()
                                        .frame(width: 16, height: 12)
                                        .foregroundColor(colorForConnectionStatus(_isKeyboardConnected))
                                    Image(systemName: "computermouse.fill")
                                        .resizable()
                                        .frame(width: 10, height: 12)
                                        .foregroundColor(colorForConnectionStatus(_isMouseConnected))
                                }
                            }
                        }
                        // Add serial port information display
                        ToolbarItem(placement: .automatic) {
                            SerialInfoView(portName: _serialPortName, baudRate: _serialPortBaudRate)
                        }
                        ToolbarItem(placement: .automatic) {
                            Image(systemName: "poweron") // spacer
                        }
                        ToolbarItemGroup(placement: .automatic) {
                            Toggle(isOn: $_isSwitchToggleOn) {
                                Image(_isSwitchToggleOn ? "Target_icon" : "Host_icon")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 15)
                                Text(_isSwitchToggleOn ? "Target" : "Host")
                            }
                            .toggleStyle(SwitchToggleStyle(width: 30, height: 16))
                            .onChange(of: _isSwitchToggleOn) { newValue in
                                handleSwitchToggle(isOn: newValue)
                            }
                        }
                    }
                    .onReceive(timer) { _ in
                        _isKeyboardConnected = AppStatus.isKeyboardConnected
                        _isMouseConnected = AppStatus.isMouseConnected
                        _isSwitchToggleOn = AppStatus.isSwitchToggleOn
                        _hasHdmiSignal = AppStatus.hasHdmiSignal
                        
                        // 更新串口信息
                        _serialPortName = AppStatus.serialPortName
                        _serialPortBaudRate = AppStatus.serialPortBaudRate
                        
                        if _hasHdmiSignal == nil {
                            _resolution.width = "-"
                            _resolution.height = "-"
                            _fps = "-"
                        }else if _hasHdmiSignal == false {
                            _resolution.width = "?"
                            _resolution.height = "?"
                            _fps = "?"
                        }else {
                            _resolution.width = "\( AppStatus.hidReadResolusion.width)"
                            _resolution.height = "\( AppStatus.hidReadResolusion.height)"
                            _fps = "\(AppStatus.hidReadFps)Hz"
                        }
                    }
            }
        }
        .commands { 
            // Customize menu
            CommandMenu("Settings") {
                Menu("Cursor Behavior") {
                    Button(action: {
                        UserSettings.shared.isAbsoluteModeMouseHide = !UserSettings.shared.isAbsoluteModeMouseHide
                        if UserSettings.shared.isAbsoluteModeMouseHide {
                            mouseHideTitle = "Always Show Host Cursor"
                        } else {
                            mouseHideTitle = "Auto-hide Host Cursor"
                        }
                    }, label: {
                        Text(mouseHideTitle)
                    })
                }
                Menu("Mouse Mode"){
                    Button(action: {
                        relativeTitle = "Relative ✓"
                        absoluteTitle = "Absolute"
                        UserSettings.shared.MouseControl = .relative
                        NotificationCenter.default.post(name: .enableRelativeModeNotification, object: nil)
                        NSCursor.hide()
                    }) {
                        Text(relativeTitle)
                    }
                    Button(action: {
                        relativeTitle = "Relative"
                        absoluteTitle = "Absolute ✓"
                        UserSettings.shared.MouseControl = .absolute
                        NSCursor.unhide()
                    }) {
                        Text(absoluteTitle)
                    }
                }
                Menu("Logging Setting"){
                    Button(action: {
                        AppStatus.isLogMode = false
                        logModeTitle = "No logging ✓"
                        log.writeLogFile(string: "Disable Log Mode!")
                        log.closeLogFile()
                        log.logToFile = false
                    }) {
                        Text(logModeTitle == "No logging ✓" ? "No logging ✓" : "No logging")
                    }
                    
                    Button(action: {
                        AppStatus.isLogMode = true
                        logModeTitle = "Log to file ✓"
                        if log.checkLogFileExist() {
                            log.openLogFile()
                        } else {
                            log.createLogFile()
                        }
                        log.logToFile = true
                        log.writeLogFile(string: "Enable Log Mode!")
                    }) {
                        Text(logModeTitle == "Log to file ✓" ? "Log to file ✓" : "Log to file")
                    }
                    
                    Divider()
                    
                    Button(action: {
                        var infoFilePath: URL?
                        let fileManager = FileManager.default
                        
                        if let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                            infoFilePath = documentsDirectory.appendingPathComponent(AppStatus.logFileName)
                        }
                        
                        NSWorkspace.shared.selectFile(infoFilePath?.relativePath, inFileViewerRootedAtPath: "")
                    }) {
                        Text("Reveal in Finder")
                    }
                }
                Button(action: {
                    showSetKeyWindow()
                }) {
                    Text("Shortcut Keys")
                }
                Button(action: {
                    takeAreaOCRing()
                }) {
                    Text("Target Screen OCR")
                }
                Button(action: {
                    showUSBDevicesWindow()
                }) {
                    Text("USB Info")
                }
                Divider()
                
                Button(action: {
                    showResetFactoryWindow()
                }) {
                    Text("Serial Reset Tool...")
                }
            }
            CommandGroup(replacing: CommandGroupPlacement.undoRedo) {
                EmptyView()
            }
            CommandGroup(replacing: CommandGroupPlacement.pasteboard){
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    if let string = pasteboard.string(forType: .string) {
                        KeyboardManager.shared.sendTextToKeyboard(text: string)
                    }
                }) {
                    Text("Paste")
                }
                .keyboardShortcut("v", modifiers: .command)
            }
        }
    }
    
    func showSetKeyWindow(){
        NSApp.activate(ignoringOtherApps: true)
        let detailView = SettingsScreen()
        let controller = SettingsScreenWC(rootView: detailView)
        controller.window?.title = "Shortcut Keys Setting"
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
    
    private func colorForConnectionStatus(_ isConnected: Bool?) -> Color {
        Logger.shared.log(content: "colorForConnectionStatus")
        switch isConnected {
        case .some(true):
            return Color(red: 124 / 255.0, green: 205 / 255.0, blue: 124 / 255.0)
        case .some(false):
            return .orange
        case .none:
            return .gray
        }
    }
    
    private func handleSwitchToggle(isOn: Bool) {
        Logger.shared.log(content: "handleSwitchToggle")


        if isOn {
            Logger.shared.log(content: "Switching USB connection to Target device")
            let hid = HIDManager.shared
            hid.setUSBtoTrager()
        } else {
            Logger.shared.log(content: "Switching USB connection to Host device")
            let hid = HIDManager.shared
            hid.setUSBtoHost()
        }
        
        // update AppStatus
        AppStatus.isSwitchToggleOn = isOn
        
        let ser = SerialPortManager.shared
        ser.raiseDTR()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            ser.lowerDTR()
        }
    }
}


@MainActor
final class AppState: ObservableObject {
    init() {
        KeyboardShortcuts.onKeyUp(for: .exitRelativeMode) {
            // TODO: exitRelativeMode
            Logger.shared.log(content: "Exit Relative Mode...")
        }
        
        KeyboardShortcuts.onKeyUp(for: .exitFullScreenMode) {
            // TODO: exitFullScreenMode
            Logger.shared.log(content: "Exit FullScreen Mode...")
            // Exit full screen
            if let window = NSApp.windows.first {
                let isFullScreen = window.styleMask.contains(.fullScreen)
                if isFullScreen {
                    window.toggleFullScreen(nil)
                }
            }
        }
        
        KeyboardShortcuts.onKeyUp(for: .triggerAreaOCR) {
            takeAreaOCRing()
        }
    }
}

func hexStringToDecimalInt(hexString: String) -> Int? {
    var cleanedHexString = hexString
    if hexString.hasPrefix("0x") {
        cleanedHexString = String(hexString.dropFirst(2))
    }
    
    guard let hexValue = UInt(cleanedHexString, radix: 16) else {
        return nil
    }
    
    return Int(hexValue)
}

func takeAreaOCRing() {
    if AppStatus.isAreaOCRing == false {
        // Show tip before starting OCR
        if let window = NSApplication.shared.mainWindow {
            TipLayerManager.shared.showTip(
                text: "Double Click to copy text from target",
                window: window
            )
        }
        
        // Wait a moment to let user read the tip, then start OCR
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppStatus.isAreaOCRing = true
            if #available(macOS 12.3, *) {
                guard let screen = SCContext.getScreenWithMouse() else { return }
                let screenshotWindow = ScreenshotWindow(contentRect: screen.frame, styleMask: [], backing: .buffered, defer: false)
                screenshotWindow.title = "Area Selector".local
                screenshotWindow.makeKeyAndOrderFront(nil)
                screenshotWindow.orderFrontRegardless()
            } else {
                let alert = NSAlert()
                alert.messageText = "OCR feature not available"
                alert.informativeText = "OCR function is not available on this version of macOS. Please upgrade to macOS 12.3 or later."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Ok")
                alert.runModal()
            }
        }
    }
}


struct SwitchToggleStyle: ToggleStyle {
    var width: CGFloat
    var height: CGFloat
    
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            RoundedRectangle(cornerRadius: height / 2)
                .fill(configuration.isOn ? Color.gray : Color.orange)
                .frame(width: width, height: height)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .frame(width: height - 2, height: height - 2)
                        .offset(x: configuration.isOn ? (width / 2 - height / 2) : -(width / 2 - height / 2))
                        .animation(.linear(duration: 0.1), value: configuration.isOn)
                    )
                .onTapGesture {
                withAnimation(.spring(duration: 0.1)) { // withAnimation
                    configuration.isOn.toggle()
                }
            }
        }
        .frame(width: 105, height: 24)
    }
}


extension Color {
    init(red255: Double, green255: Double, blue255: Double, opacity: Double = 1.0) {
        self.init(red: red255 / 255.0, green: green255 / 255.0, blue: blue255 / 255.0, opacity: opacity)
    }
}

struct TransparentBackgroundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.blue) 
            .padding()
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.01))
                .opacity(configuration.isPressed ? 0.01 : 1))
                .scaleEffect(configuration.isPressed ? 1.2 : 1)
            .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue, lineWidth: 2))
    }
}

struct CustomButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding()
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
            .scaleEffect(configuration.isPressed ? 1.2 : 1)
    }
}

func showUSBDevicesWindow() {
    let usbDevicesView = USBDevicesView()
    let controller = NSHostingController(rootView: usbDevicesView)
    let window = NSWindow(contentViewController: controller)
    window.title = "USB Devices"
    window.setContentSize(NSSize(width: 400, height: 600))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

func showResetFactoryWindow() {
    if let existingWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "resetSerialToolWindow" }) {
        // 如果窗口已存在，则使其震动并成为前台窗口
        
        // 使用系统提供的注意力请求功能（会使窗口或Dock图标弹跳）
        NSApp.requestUserAttention(.criticalRequest)
        
        // 将窗口带到前台
        existingWindow.makeKeyAndOrderFront(nil)
        existingWindow.orderFrontRegardless()
        return
    }
    
    // 如果窗口不存在，则创建新窗口
    let resetFactoryView = ResetFactoryView()
    let controller = NSHostingController(rootView: resetFactoryView)
    let window = NSWindow(contentViewController: controller)
    window.title = "Serial Reset Tool"
    window.identifier = NSUserInterfaceItemIdentifier(rawValue: "resetSerialToolWindow")
    window.setContentSize(NSSize(width: 400, height: 760))
    window.styleMask = [.titled, .closable]
    window.center()
    window.makeKeyAndOrderFront(nil)
    
    // 设置窗口关闭时的回调，以清除引用
    window.isReleasedWhenClosed = false
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in
        // aboutWindow = nil
//        if let windown = NSApp.windows.first(where: { $0.identifier?.rawValue == "resetFactoryWindow" }) {
//            windown.close()
//        }
    }
    
    // 保存窗口引用
    // aboutWindow = window
    NSApp.activate(ignoringOtherApps: true)
}
