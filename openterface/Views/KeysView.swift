import SwiftUI
import AppKit

// Add a new parameter to CustomButtonStyle to allow programmatic pressed state
struct CustomButtonStyle: ButtonStyle {
    var programmaticPressed: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed || programmaticPressed
        return configuration.label
            .foregroundColor(.white)
            .font(.system(size: 14, weight: .medium))
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: isPressed ? [
                                Color(red: 1.0, green: 0.6, blue: 0.2),
                                Color(red: 0.9, green: 0.4, blue: 0.1)
                            ] : [
                                Color(red: 0.35, green: 0.35, blue: 0.35),
                                Color(red: 0.25, green: 0.25, blue: 0.25)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isPressed ?
                                   Color(red: 1.0, green: 0.7, blue: 0.3) :
                                   Color(red: 0.45, green: 0.45, blue: 0.45),
                                   lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 1, x: 0, y: 1)
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
    }
}

struct FloatingKeysWindow: View {
    @ObservedObject private var keyboardManager = DependencyContainer.shared.resolve(KeyboardManagerProtocol.self) as! KeyboardManager
    let onClose: () -> Void
    
    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                // Function keys row
                HStack(spacing: 6) {
                    Button("Esc", action: {
                        keyboardManager.sendSpecialKeyToKeyboard(code: .esc)
                    })
                    .buttonStyle(CustomButtonStyle())
                    
                    ForEach((1...12), id: \ .self) { index in
                        Button("F\(index)", action: {
                            if let key = KeyboardMapper.SpecialKey.functionKey(index) {
                                keyboardManager.sendSpecialKeyToKeyboard(code: key)
                            }
                        })
                        .buttonStyle(CustomButtonStyle())
                    }
                    Button("Del", action: {
                        keyboardManager.sendSpecialKeyToKeyboard(code: .delete)
                    })
                    .buttonStyle(CustomButtonStyle())
                }
                
                // Alphanumeric keys row
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(["~", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="], id: \ .self) { key in
                            let displayKey = keyboardManager.getDisplayKey(for: key)
                            Button(displayKey, action: {
                                keyboardManager.sendTextToKeyboard(text: displayKey)
                            })
                            .buttonStyle(CustomButtonStyle())
                        }
                        Button("Backspace", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .backspace)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("Home", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .home)
                        })
                        .buttonStyle(CustomButtonStyle())
                    }
                    
                    HStack(spacing: 6) {
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .tab)
                        }){
                            Text("Tab")
                                .padding(.horizontal, 20)
                        }
                        .buttonStyle(CustomButtonStyle())
                        
                        ForEach(["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"], id: \ .self) { letter in
                            let key = keyboardManager.shouldShowUppercase ? letter : letter.lowercased()
                            Button(key, action: {
                                keyboardManager.sendTextToKeyboard(text: key)
                            })
                            .buttonStyle(CustomButtonStyle())
                        }
                        
                        let leftBracketKey = keyboardManager.getDisplayKey(for: "[")
                        Button(leftBracketKey, action: {
                            keyboardManager.sendTextToKeyboard(text: leftBracketKey)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        let rightBracketKey = keyboardManager.getDisplayKey(for: "]")
                        Button(rightBracketKey, action: {
                            keyboardManager.sendTextToKeyboard(text: rightBracketKey)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        let backslashKey = keyboardManager.getDisplayKey(for: "\\")
                        Button(backslashKey, action: {
                            keyboardManager.sendTextToKeyboard(text: backslashKey)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("End", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .end)
                        })
                        .buttonStyle(CustomButtonStyle())
                    }
                    
                    HStack(spacing: 6) {
                        Button("Caps Lock", action: {
                            keyboardManager.toggleCapsLock()
                        })
                        .buttonStyle(CustomButtonStyle(programmaticPressed: keyboardManager.isCapsLockOn))
                        
                        ForEach(["A", "S", "D", "F", "G", "H", "J", "K", "L"], id: \ .self) { letter in
                            let key = keyboardManager.shouldShowUppercase ? letter : letter.lowercased()
                            Button(key, action: {
                                keyboardManager.sendTextToKeyboard(text: key)
                            })
                            .buttonStyle(CustomButtonStyle())
                        }
                        
                        let semicolonKey = keyboardManager.getDisplayKey(for: ";")
                        Button(semicolonKey, action: {
                            keyboardManager.sendTextToKeyboard(text: semicolonKey)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        let apostropheKey = keyboardManager.getDisplayKey(for: "'")
                        Button(apostropheKey, action: {
                            keyboardManager.sendTextToKeyboard(text: apostropheKey)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .enter)
                        }){
                            Text("Enter")
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("PgUp", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .pageUp)
                        })
                        .buttonStyle(CustomButtonStyle())
                    }
                    
                    HStack(spacing: 6) {
                        Button(action: {
                            keyboardManager.toggleLeftShift()
                        }) {
                            Text("Shift")
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(CustomButtonStyle(programmaticPressed: keyboardManager.isLeftShiftHeld))
                        
                        ForEach(["Z", "X", "C", "V", "B", "N", "M"], id: \ .self) { letter in
                            let key = keyboardManager.shouldShowUppercase ? letter : letter.lowercased()
                            Button(key, action: {
                                keyboardManager.sendTextToKeyboard(text: key)
                            })
                            .buttonStyle(CustomButtonStyle())
                        }
                        
                        let commaKey = keyboardManager.getDisplayKey(for: ",")
                        Button(commaKey, action: {
                            keyboardManager.sendTextToKeyboard(text: commaKey)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        let periodKey = keyboardManager.getDisplayKey(for: ".")
                        Button(periodKey, action: {
                            keyboardManager.sendTextToKeyboard(text: periodKey)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        let slashKey = keyboardManager.getDisplayKey(for: "/")
                        Button(slashKey, action: {
                            keyboardManager.sendTextToKeyboard(text: slashKey)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button(action: {
                            keyboardManager.toggleRightShift()
                        }) {
                            Text("Shift")
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(CustomButtonStyle(programmaticPressed: keyboardManager.isRightShiftHeld))


                        Button("▲", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .arrowUp)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("PgDown", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .pageDown)
                        })
                        .buttonStyle(CustomButtonStyle())
                    }
                    
                    HStack(spacing: 6) {
                        Button(action: {
                            keyboardManager.toggleLeftCtrl()
                        }) {
                            Text("Ctrl")
                        }
                        .buttonStyle(CustomButtonStyle(programmaticPressed: keyboardManager.isLeftCtrlHeld))
                        
                        Button(keyboardManager.currentKeyboardLayout == .windows ? "Win" : "Cmd", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .win)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button(action: {
                            keyboardManager.toggleLeftAlt()
                        }) {
                            Text(keyboardManager.currentKeyboardLayout == .windows ? "Alt" : "Opt")
                        }
                        .buttonStyle(CustomButtonStyle(programmaticPressed: keyboardManager.isLeftAltHeld))

                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .space)
                        }) {
                            Text("Space")
                                .padding(.horizontal, 100) // Adjusted to pad only left and right
                        }
                        .buttonStyle(CustomButtonStyle())
                        
                        Button(action: {
                            keyboardManager.toggleRightAlt()
                        }) {
                            Text(keyboardManager.currentKeyboardLayout == .windows ? "Alt" : "Opt")
                        }
                        .buttonStyle(CustomButtonStyle(programmaticPressed: keyboardManager.isRightAltHeld))
                        
                        Button(action: {
                            keyboardManager.toggleRightCtrl()
                        }) {
                            Text("Ctrl")
                        }
                        .buttonStyle(CustomButtonStyle(programmaticPressed: keyboardManager.isRightCtrlHeld))
                        
                        Button("◀", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .arrowLeft)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("▼", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .arrowDown)
                        })
                        .buttonStyle(CustomButtonStyle())
                        
                        Button("▶", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .arrowRight)
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
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            
            // Close button in top-left corner

            Button(action: {
                onClose()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.red)
            }
            .buttonStyle(PlainButtonStyle())
            .position(x: 32, y: 32)
            
            // Win/Mac toggle button in top-right corner
            Button(action: {
                keyboardManager.toggleKeyboardLayout()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: keyboardManager.currentKeyboardLayout == .windows ? 
                          "laptopcomputer" : "applelogo")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                    Text(keyboardManager.currentKeyboardLayout == .windows ? "Win" : "Mac")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(keyboardManager.currentKeyboardLayout == .windows ? 
                              Color.blue : Color.orange)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .position(x: 748, y: 32)
        }
    }
}
