/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation, either version 3 of the License, or       *
*    (at your option) any later version.                                     *
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
    @State private var logModeTitle = "LogMode"
    @State private var mouseHideTitle = "Hide"
    
    
    var log = Logger.shared
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                //.frame(width: 1920 / 2, height: 1080 / 2)
                .aspectRatio(16/9, contentMode: .fit)
                .navigationTitle("Openterface Mini-KVM")
                .toolbar{
                    ToolbarItem(placement: .automatic) {
                        Image(systemName: "display")
                            .foregroundColor(.gray)
                    }
                    ToolbarItem(placement: .automatic) {
                        Image(systemName: "keyboard.fill")
                            .foregroundColor(.gray)
                    }
                    ToolbarItem(placement: .automatic) {
                        Image(systemName: "computermouse.fill")
                            .foregroundColor(.gray)
                    }
                }
                .onReceive(timer) { _ in
                   
                }
        }
        .commands { 
            // Customize menu
            CommandMenu("Settings") {
                Menu("Mouse Setting") {
                    Button(action: {
                        UserSettings.shared.isAbsoluteModeMouseHide = !UserSettings.shared.isAbsoluteModeMouseHide
                        if UserSettings.shared.isAbsoluteModeMouseHide {
                            mouseHideTitle = "Unhide"
                        }else{
                            mouseHideTitle = "Hide"
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
                    }) {
                        Text(relativeTitle)
                    }
                    Button(action: {
                        relativeTitle = "Relative"
                        absoluteTitle = "Absolute ✓"
                        UserSettings.shared.MouseControl = .absolute
                    }) {
                        Text(absoluteTitle)
                    }
                }
                Menu("Show Log File"){
                    Button(action: {
                        AppStatus.isLogMode = !AppStatus.isLogMode
                        
                        if AppStatus.isLogMode {
                            logModeTitle = "LogMode ✓"
                            
                            if log.checkLogFileExist() {
                                log.openLogFile()
                            } else {
                                log.createLogFile()
                            }
                            log.logToFile = true
                            log.writeLogFile(string: "Enable Log Mode!")
                        } else {
                            logModeTitle = "LogMode"
                            log.writeLogFile(string: "Disable Log Mode!")
                            log.closeLogFile()
                            log.logToFile = false
                        }
                    }) {
                        Text(logModeTitle)
                    }
                    Button(action: {
                        var infoFilePath: URL?
                        let fileManager = FileManager.default
                        
                        if let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                            infoFilePath = documentsDirectory.appendingPathComponent(AppStatus.logFileName)
                        }
                        
                        NSWorkspace.shared.selectFile(infoFilePath?.relativePath, inFileViewerRootedAtPath: "")
                    }) {
                        Text("Open in Finder")
                    }
                }
                Button(action: {
                    showSetKeyWindow()
                }) {
                    Text("ShortKey")
                }
                Button(action: {
                    takeAreaOCRing()
                }) {
                    Text("Area OCR")
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
        controller.window?.title = "Setting"
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: false)
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


func takeAreaOCRing() {
    if AppStatus.isAreaOCRing == false {
        AppStatus.isAreaOCRing = true
        guard let screen = SCContext.getScreenWithMouse() else { return } // 获取当前鼠标对应屏幕的坐标
        let screenshotWindow = ScreenshotWindow(contentRect: screen.frame, styleMask: [], backing: .buffered, defer: false)
        screenshotWindow.title = "Area Selector".local
        screenshotWindow.makeKeyAndOrderFront(nil)
        screenshotWindow.orderFrontRegardless()
    }
}
