import Foundation
import AppKit

// Shared types used by multiple settings views
enum EnhancedSpecialKey: String {
    case enter = "enter", tab = "tab", escape = "escape", space = "space", delete = "delete", backspace = "backspace"
    case arrowUp = "arrowUp", arrowDown = "arrowDown", arrowLeft = "arrowLeft", arrowRight = "arrowRight"
    case f1 = "f1", f2 = "f2", f3 = "f3", f4 = "f4", f5 = "f5", f6 = "f6"
    case f7 = "f7", f8 = "f8", f9 = "f9", f10 = "f10", f11 = "f11", f12 = "f12"
    case ctrlAltDel = "ctrlAltDel", c = "c", v = "v", s = "s"
}

struct EnhancedKeyboardInput {
    enum KeyType {
        case character(Character)
        case specialKey(EnhancedSpecialKey)
        case keyboardMapperSpecialKey(KeyboardMapper.SpecialKey)
    }
    let key: KeyType
    let modifiers: NSEvent.ModifierFlags
}

struct EnhancedKeyboardMacro {
    let name: String
    let sequence: [EnhancedKeyboardInput]
}
