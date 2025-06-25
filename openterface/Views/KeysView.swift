import SwiftUI
import AppKit

struct CustomButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .font(.system(size: 14, weight: .medium))
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: configuration.isPressed ? [
                                Color(red: 1.0, green: 0.6, blue: 0.2),  // Orange when pressed
                                Color(red: 0.9, green: 0.4, blue: 0.1)   // Darker orange
                            ] : [
                                Color(red: 0.35, green: 0.35, blue: 0.35), // Normal grey
                                Color(red: 0.25, green: 0.25, blue: 0.25)  // Darker grey
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(configuration.isPressed ? 
                                   Color(red: 1.0, green: 0.7, blue: 0.3) : 
                                   Color(red: 0.45, green: 0.45, blue: 0.45), 
                                   lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 1, x: 0, y: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

final class FloatingKeyboardManager {
    static let shared = FloatingKeyboardManager()
    private var floatingKeyboardWindow: NSWindow?
    private var mainWindowObserver: NSObjectProtocol?

    init() {
        setupMainWindowObserver()
    }
    
    private func setupMainWindowObserver() {
        // Observe main window close notifications
        mainWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Check if the closing window is the main window
            if let window = notification.object as? NSWindow,
               let identifier = window.identifier?.rawValue,
               identifier.contains("main_openterface") {
                self?.closeFloatingKeysWindow()
            }
        }
    }
    
    deinit {
        if let observer = mainWindowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func showFloatingKeysWindow() {
        if let existingWindow = floatingKeyboardWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let floatingKeysView = FloatingKeysWindow()
        let controller = NSHostingController(rootView: floatingKeysView)
        let window = NSWindow(contentViewController: controller)
        window.title = ""
        window.styleMask = [.borderless]
        window.setContentSize(NSSize(width: 800, height: 410))
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        floatingKeyboardWindow = window

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
            self?.floatingKeyboardWindow = nil
        }
    }
    
    func closeFloatingKeysWindow() {
        floatingKeyboardWindow?.close()
        floatingKeyboardWindow = nil
    }
}

struct FloatingKeysWindow: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 12) {
                // Function keys row
                HStack(spacing: 6) {
                    Button("Esc", action: {
                        KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .esc)
                    })
                    .buttonStyle(CustomButtonStyle())
                    
                    ForEach((1...12), id: \ .self) { index in
                        Button("F\(index)", action: {
                            if let key = KeyboardMapper.SpecialKey.functionKey(index) {
                                KeyboardManager.shared.sendSpecialKeyToKeyboard(code: key)
                            }
                        })
                        .buttonStyle(CustomButtonStyle())
                    }
                    Button("Del", action: {
                        KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .delete)
                    })
                    .buttonStyle(CustomButtonStyle())
                }
                
                // Alphanumeric keys row
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(["~", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="], id: \ .self) { key in
                            Button(key, action: {
                                KeyboardManager.shared.sendTextToKeyboard(text: key)
                            })
                            .buttonStyle(CustomButtonStyle())
                        }
                        Button("Backspace", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .backspace)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("Home", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .home)
                        })
                        .buttonStyle(CustomButtonStyle())
                    }
                    
                    HStack(spacing: 6) {
                        Button(action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .tab)
                        }){
                            Text("Tab")
                                .padding(.horizontal, 20)
                        }
                        .buttonStyle(CustomButtonStyle())
                        
                        ForEach(["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"], id: \ .self) { letter in
                            Button(letter, action: {
                                KeyboardManager.shared.sendTextToKeyboard(text: letter.lowercased())
                            })
                            .buttonStyle(CustomButtonStyle())
                        }
                        
                        Button("[", action: {
                            KeyboardManager.shared.sendTextToKeyboard(text: "[")
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("]", action: {
                            KeyboardManager.shared.sendTextToKeyboard(text: "]")
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("\\", action: {
                            KeyboardManager.shared.sendTextToKeyboard(text: "\\")
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("End", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .end)
                        })
                        .buttonStyle(CustomButtonStyle())
                    }
                    
                    HStack(spacing: 6) {
                        Button("Caps Lock", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .capsLock)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        ForEach(["A", "S", "D", "F", "G", "H", "J", "K", "L"], id: \ .self) { letter in
                            Button(letter, action: {
                                KeyboardManager.shared.sendTextToKeyboard(text: letter.lowercased())
                            })
                            .buttonStyle(CustomButtonStyle())
                        }
                        
                        Button(";", action: {
                            KeyboardManager.shared.sendTextToKeyboard(text: ";")
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("'", action: {
                            KeyboardManager.shared.sendTextToKeyboard(text: "'")
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button(action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .enter)
                        }){
                            Text("Enter")
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("PgUp", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .pageUp)
                        })
                        .buttonStyle(CustomButtonStyle())
                    }
                    
                    HStack(spacing: 6) {
                        Button(action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .leftShift)
                        }){
                            Text("Shift")
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(CustomButtonStyle())
                        
                        ForEach(["Z", "X", "C", "V", "B", "N", "M"], id: \ .self) { letter in
                            Button(letter, action: {
                                KeyboardManager.shared.sendTextToKeyboard(text: letter.lowercased())
                            })
                            .buttonStyle(CustomButtonStyle())
                        }
                        
                        Button(",", action: {
                            KeyboardManager.shared.sendTextToKeyboard(text: ",")
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button(".", action: {
                            KeyboardManager.shared.sendTextToKeyboard(text: ".")
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("/", action: {
                            KeyboardManager.shared.sendTextToKeyboard(text: "/")
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button(action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .rightShift)
                        }){
                            Text("Shift")
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(CustomButtonStyle())
                        Button("▲", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .arrowUp)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("PgDown", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .pageDown)
                        })
                        .buttonStyle(CustomButtonStyle())
                    }
                    
                    HStack(spacing: 6) {
                        Button("Ctrl", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .leftCtrl)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("Win", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .win)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("Alt", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .leftAlt)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button(action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .space)
                        }) {
                            Text("Space")
                                .padding(.horizontal, 100) // Adjusted to pad only left and right
                        }
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("Alt", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .rightAlt)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("Ctrl", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .rightCtrl)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("◀", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .arrowLeft)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("▼", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .arrowDown)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("▶", action: {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .arrowRight)
                        })
                        .buttonStyle(CustomButtonStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .padding(8)
            
            // Close button in top-right corner
            Button(action: {
                FloatingKeyboardManager.shared.closeFloatingKeysWindow()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.red)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 16)
            .padding(.trailing, 16)
        }
    }
}
