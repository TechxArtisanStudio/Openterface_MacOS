import SwiftUI
import AppKit

final class FloatingKeyboardManager {
    static let shared = FloatingKeyboardManager()
    private var floatingKeyboardWindow: NSWindow?

    func showFloatingKeysWindow() {
        if let existingWindow = floatingKeyboardWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let floatingKeysView = FloatingKeysWindow()
        let controller = NSHostingController(rootView: floatingKeysView)
        let window = NSWindow(contentViewController: controller)
        window.title = "Target Keyboard"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 300, height: 400))
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        floatingKeyboardWindow = window

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
            self?.floatingKeyboardWindow = nil
        }
    }
}

struct FloatingKeysWindow: View {
    var body: some View {
        VStack(spacing: 10) {
            // Function keys row
            HStack(spacing: 5) {
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
            VStack(spacing: 5) {
                HStack(spacing: 5) {
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

                HStack(spacing: 5) {
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

                HStack(spacing: 5) {
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

                HStack(spacing: 5) {
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

                HStack(spacing: 5) {
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
        .frame(width: 800, height: 400)
        .background(Color.white)
        .cornerRadius(10)
        .shadow(radius: 10)
        .padding()
    }
}
