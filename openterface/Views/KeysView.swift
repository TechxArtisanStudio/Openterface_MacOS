import SwiftUI
import AppKit

// Add a new parameter to CustomButtonStyle to allow programmatic pressed state
struct CustomButtonStyle: ButtonStyle {
    var programmaticPressed: Bool = false
    var isActive: Bool = false  // NEW: for visual feedback
    
    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed || programmaticPressed || isActive
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

public struct FloatingKeysWindow: View {
    @ObservedObject private var keyboardManager = DependencyContainer.shared.resolve(KeyboardManagerProtocol.self) as! KeyboardManager
    private var floatingKeyboardManager = DependencyContainer.shared.resolve(FloatingKeyboardManagerProtocol.self)
    let onClose: () -> Void
    @State private var showMultimediaKeys = false
    
    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }
    
    // Helper function to check if a character matches any of the host pressed key codes
    private func isHostKeyPressed(_ character: String) -> Bool {
        for keyCode in keyboardManager.hostPressedKeyCodes {
            guard let mappedChar = KeyboardMapper.macOSKeyCodeMap[keyCode] else { continue }
            if mappedChar.lowercased() == character.lowercased() {
                return true
            }
        }
        return false
    }
    
    // Helper function to check if a key code matches any of the host pressed key codes
    private func isHostKeyCodePressed(_ keyCode: UInt16) -> Bool {
        return keyboardManager.hostPressedKeyCodes.contains(keyCode)
    }
    
    // Helper function to check if a function key is pressed on the host keyboard
    private func isHostFunctionKeyPressed(_ index: Int) -> Bool {
        let functionKeyMap: [Int: UInt16] = [
            1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98, 8: 100,
            9: 101, 10: 109, 11: 103, 12: 111
        ]
        guard let keyCode = functionKeyMap[index] else { return false }
        return isHostKeyCodePressed(keyCode)
    }
    
    public var body: some View {
        ZStack {
            VStack(spacing: 12) {
                if showMultimediaKeys {
                    HStack(spacing: 6) {
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .power)
                        }) {
                            Image(systemName: "power").font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .power))
                        .help("Power")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .sleep)
                        }) {
                            Text("Sleep").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .sleep))
                        .help("Sleep")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .wakeup)
                        }) {
                            Text("Wakeup").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .wakeup))
                        .help("Wake Up")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .volumeMute)
                        }) {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .volumeMute))
                        .help("Mute")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .volumeDown)
                        }) {
                            Image(systemName: "speaker.wave.1.fill")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .volumeDown))
                        .help("Volume Down")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .volumeUp)
                        }) {
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .volumeUp))
                        .help("Volume Up")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .mediaPrevious)
                        }) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .mediaPrevious))
                        .help("Previous Track")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .mediaPlayPause)
                        }) {
                            Image(systemName: "playpause.fill")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .mediaPlayPause))
                        .help("Play/Pause")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .mediaNext)
                        }) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .mediaNext))
                        .help("Next Track")

                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .mediaStop)
                        }) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .mediaStop))
                        .help("Stop")

                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .mediaEject)
                        }) {
                            Image(systemName: "eject.fill")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .mediaEject))
                        .help("Eject")
                    }
                    
                    // WWW and email keys row 1
                    HStack(spacing: 6) {
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .wwwBack)
                        }) {
                            Text("Back")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .wwwBack))
                        .help("Back")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .wwwForward)
                        }) {
                            Text("Forward")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .wwwForward))
                        .help("Forward")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .wwwHome)
                        }) {
                            Text("Home")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .wwwHome))
                        .help("Home Page")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .wwwStop)
                        }) {
                            Text("Stop")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .wwwStop))
                        .help("Stop Loading")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .refresh)
                        }) {
                            Text("Refresh").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .refresh))
                        .help("Refresh")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .wwwSearch)
                        }) {
                            Text("Search").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .wwwSearch))
                        .help("Search")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .wwwFavorites)
                        }) {
                            Text("Favorites").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .wwwFavorites))
                        .help("Favorites")
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .email)
                        }) {
                            Text("Email").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .email))
                    }
                    
                    // Application keys row 2
                    HStack(spacing: 6) {
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .calculator)
                        }) {
                            Text("Calc")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .calculator))
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .myComputer)
                        }) {
                           Text("Computer")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .myComputer))
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .explorer)
                        }) {
                            Text("Explorer")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .explorer))
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .screenSave)
                        }) {
                            Text("Screen Save")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .screenSave))
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .minimize)
                        }) {
                            Text("Minimize")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .minimize))
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .media)
                        }) {
                            Text("Media")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .media))
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .record)
                        }) {
                            Text("Record")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .record))
                    }
                }
                
                // Function keys row
                HStack(spacing: 6) {
                    Button("Esc", action: {
                        keyboardManager.sendSpecialKeyToKeyboard(code: .esc)
                    })
                    .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .esc || isHostKeyCodePressed(53)))
                    .help("Escape")
                    
                    ForEach((1...12), id: \ .self) { index in
                        Button("F\(index)", action: {
                            if let key = KeyboardMapper.SpecialKey.functionKey(index) {
                                keyboardManager.sendSpecialKeyToKeyboard(code: key)
                            }
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == KeyboardMapper.SpecialKey.functionKey(index) || isHostFunctionKeyPressed(index)))
                        .help("Function \(index)")
                    }
                    Button("Del", action: {
                        keyboardManager.sendSpecialKeyToKeyboard(code: .delete)
                    })
                    .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .delete || isHostKeyCodePressed(117)))
                    .help("Delete")
                }
                
                // Alphanumeric keys row
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(["~", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="], id: \ .self) { key in
                            let displayKey = keyboardManager.getDisplayKey(for: key)
                            Button(displayKey, action: {
                                keyboardManager.sendTextToKeyboard(text: displayKey)
                            })
                            .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == displayKey || isHostKeyPressed(displayKey)))
                        }
                        Button("Backspace", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .backspace)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .backspace || isHostKeyCodePressed(51)))
                        
                        Button("Home", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .home)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .home || isHostKeyCodePressed(115)))
                    }
                    
                    HStack(spacing: 6) {
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .tab)
                        }){
                            Text("Tab")
                                .padding(.horizontal, 20)
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .tab || isHostKeyCodePressed(48)))
                        
                        ForEach(["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"], id: \ .self) { letter in
                            let key = keyboardManager.shouldShowUppercase ? letter : letter.lowercased()
                            Button(key, action: {
                                keyboardManager.sendTextToKeyboard(text: key)
                            })
                            .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == key || isHostKeyPressed(key)))
                        }
                        
                        let leftBracketKey = keyboardManager.getDisplayKey(for: "[")
                        Button(leftBracketKey, action: {
                            keyboardManager.sendTextToKeyboard(text: leftBracketKey)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == leftBracketKey || isHostKeyPressed(leftBracketKey)))
                        
                        let rightBracketKey = keyboardManager.getDisplayKey(for: "]")
                        Button(rightBracketKey, action: {
                            keyboardManager.sendTextToKeyboard(text: rightBracketKey)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == rightBracketKey || isHostKeyPressed(rightBracketKey)))
                        
                        let backslashKey = keyboardManager.getDisplayKey(for: "\\")
                        Button(backslashKey, action: {
                            keyboardManager.sendTextToKeyboard(text: backslashKey)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == backslashKey || isHostKeyPressed(backslashKey)))
                        
                        Button("End", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .end)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .end || isHostKeyCodePressed(119)))
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
                            .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == key || isHostKeyPressed(key)))
                        }
                        
                        let semicolonKey = keyboardManager.getDisplayKey(for: ";")
                        Button(semicolonKey, action: {
                            keyboardManager.sendTextToKeyboard(text: semicolonKey)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == semicolonKey || isHostKeyPressed(semicolonKey)))
                        
                        let apostropheKey = keyboardManager.getDisplayKey(for: "'")
                        Button(apostropheKey, action: {
                            keyboardManager.sendTextToKeyboard(text: apostropheKey)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == apostropheKey || isHostKeyPressed(apostropheKey)))
                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .enter)
                        }){
                            Text("Enter")
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .enter || isHostKeyCodePressed(36)))
                        
                        Button("PgUp", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .pageUp)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .pageUp || isHostKeyCodePressed(116)))
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
                            .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == key || isHostKeyPressed(key)))
                        }
                        
                        let commaKey = keyboardManager.getDisplayKey(for: ",")
                        Button(commaKey, action: {
                            keyboardManager.sendTextToKeyboard(text: commaKey)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == commaKey || isHostKeyPressed(commaKey)))
                        
                        let periodKey = keyboardManager.getDisplayKey(for: ".")
                        Button(periodKey, action: {
                            keyboardManager.sendTextToKeyboard(text: periodKey)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == periodKey || isHostKeyPressed(periodKey)))
                        
                        let slashKey = keyboardManager.getDisplayKey(for: "/")
                        Button(slashKey, action: {
                            keyboardManager.sendTextToKeyboard(text: slashKey)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedCharacter == slashKey || isHostKeyPressed(slashKey)))
                        
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
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .arrowUp || isHostKeyCodePressed(126)))
                        
                        Button("PgDown", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .pageDown)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .pageDown || isHostKeyCodePressed(121)))
                    }
                    
                    HStack(spacing: 6) {
                        Button(action: {
                            keyboardManager.toggleLeftCtrl()
                        }) {
                            Text("Ctrl")
                        }
                        .buttonStyle(CustomButtonStyle(programmaticPressed: keyboardManager.isLeftCtrlHeld))
                        .help("Control (Left)")
                        
                        Button(keyboardManager.currentKeyboardLayout == .windows ? "Win" : "Cmd", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .win)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .win))
                        .help(keyboardManager.currentKeyboardLayout == .windows ? "Windows" : "Command")
                        
                        Button(action: {
                            keyboardManager.toggleLeftAlt()
                        }) {
                            Text(keyboardManager.currentKeyboardLayout == .windows ? "Alt" : "Opt")
                        }
                        .buttonStyle(CustomButtonStyle(programmaticPressed: keyboardManager.isLeftAltHeld))
                        .help(keyboardManager.currentKeyboardLayout == .windows ? "Alt (Left)" : "Option (Left)")

                        
                        Button(action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .space)
                        }) {
                            Text("Space")
                                .padding(.horizontal, 100) // Adjusted to pad only left and right
                        }
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .space || isHostKeyCodePressed(49)))
                        .help("Spacebar")
                        
                        Button(action: {
                            keyboardManager.toggleRightAlt()
                        }) {
                            Text(keyboardManager.currentKeyboardLayout == .windows ? "Alt" : "Opt")
                        }
                        .buttonStyle(CustomButtonStyle(programmaticPressed: keyboardManager.isRightAltHeld))
                        .help(keyboardManager.currentKeyboardLayout == .windows ? "Alt (Right)" : "Option (Right)")
                        
                        Button(action: {
                            keyboardManager.toggleRightCtrl()
                        }) {
                            Text("Ctrl")
                        }
                        .buttonStyle(CustomButtonStyle(programmaticPressed: keyboardManager.isRightCtrlHeld))
                        .help("Control (Right)")
                        
                        Button("◀", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .arrowLeft)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .arrowLeft || isHostKeyCodePressed(123)))
                        .help("Left Arrow")
                        
                        Button("▼", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .arrowDown)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .arrowDown || isHostKeyCodePressed(125)))
                        .help("Down Arrow")
                        
                        Button("▶", action: {
                            keyboardManager.sendSpecialKeyToKeyboard(code: .arrowRight)
                        })
                        .buttonStyle(CustomButtonStyle(isActive: keyboardManager.pressedKey == .arrowRight || isHostKeyCodePressed(124)))
                        .help("Right Arrow")
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
            .padding(.top, 12)
            .padding(.bottom, 12)
            
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
            .help("Close")
            
            // Win/Mac toggle button in top-right corner
            HStack(spacing: 8) {
                // Multimedia keys toggle button
                Button(action: {
                    showMultimediaKeys.toggle()
                    // Adjust window height based on state
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let newHeight: CGFloat = showMultimediaKeys ? 540 : 400
                        floatingKeyboardManager.setFloatingKeyboardHeight(newHeight)
                    }
                }) {
                    Image(systemName: showMultimediaKeys ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(red: 0.45, green: 0.45, blue: 0.45))
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .help(showMultimediaKeys ? "Hide Multimedia Keys" : "Show Multimedia Keys")
                
                // Win/Mac toggle button
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
                .help(keyboardManager.currentKeyboardLayout == .windows ? "Switch to Mac Layout" : "Switch to Windows Layout")
            }
            .position(x: 710, y: 32)
        }
    }
}
